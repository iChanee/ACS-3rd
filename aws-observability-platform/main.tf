# AWS Observability Platform with Bedrock
# Architecture: External OTel App → EC2 OTel Collector → AMP / OpenSearch Ingestion / S3

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.27.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "ObservabilityPlatform"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ============================================================
# VPC / Network
# ============================================================

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "${var.project_name}-vpc" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project_name}-public-subnet" }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "${var.aws_region}a"
  tags              = { Name = "${var.project_name}-private-subnet" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project_name}-igw" }
}

# NAT Gateway용 Elastic IP
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.project_name}-nat-eip" }
}

# NAT Gateway (Public Subnet에 배치)
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  tags          = { Name = "${var.project_name}-nat-gw" }
  depends_on    = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${var.project_name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Private Route Table (NAT Gateway 통해 인터넷 접근)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
  tags = { Name = "${var.project_name}-private-rt" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# ============================================================
# Security Groups
# ============================================================

resource "aws_security_group" "otel_collector" {
  name        = "${var.project_name}-otel-collector-sg"
  description = "Receives OTLP from external OTel Collectors (LFS148 apps)"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "OTLP gRPC - from external OTel Collector"
    from_port   = 4317
    to_port     = 4317
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "OTLP HTTP - from external OTel Collector"
    from_port   = 4318
    to_port     = 4318
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-otel-sg" }
}

resource "aws_security_group" "opensearch" {
  name        = "${var.project_name}-opensearch-sg"
  description = "OpenSearch access from VPC only"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-opensearch-sg" }
}

# ============================================================
# IAM - EC2 OTel Collector
# ============================================================

resource "aws_iam_role" "otel_collector" {
  name = "${var.project_name}-otel-collector-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "otel_collector" {
  name = "${var.project_name}-otel-collector-policy"
  role = aws_iam_role.otel_collector.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AMPWrite"
        Effect   = "Allow"
        Action   = ["aps:RemoteWrite", "aps:QueryMetrics", "aps:GetSeries", "aps:GetLabels", "aps:GetMetricMetadata"]
        Resource = "*"
      },
      {
        Sid    = "S3Write"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:PutObjectAcl"]
        Resource = [
          "${aws_s3_bucket.logs_backup.arn}/*",
          "${aws_s3_bucket.traces_backup.arn}/*",
          "${aws_s3_bucket.metrics_backup.arn}/*"
        ]
      },
      {
        Sid    = "OSISIngest"
        Effect = "Allow"
        Action = ["osis:Ingest"]
        Resource = [
          aws_osis_pipeline.logs.pipeline_arn,
          aws_osis_pipeline.traces.pipeline_arn
        ]
      },
      {
        Sid      = "CloudWatch"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "otel_collector" {
  name = "${var.project_name}-otel-collector-profile"
  role = aws_iam_role.otel_collector.name
}

# ============================================================
# IAM - OpenSearch Ingestion Pipeline
# ============================================================

resource "aws_iam_role" "osis_pipeline" {
  name = "${var.project_name}-osis-pipeline-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "osis-pipelines.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "osis_pipeline" {
  name = "${var.project_name}-osis-pipeline-policy"
  role = aws_iam_role.osis_pipeline.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["es:DescribeDomain", "es:ESHttp*"]
        Resource = [
          aws_opensearch_domain.main.arn,
          "${aws_opensearch_domain.main.arn}/*"
        ]
      }
    ]
  })
}


# ============================================================
# IAM - Bedrock Agent
# ============================================================

resource "aws_iam_role" "bedrock_agent" {
  name = "${var.project_name}-bedrock-agent-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "bedrock.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "bedrock_agent" {
  name = "${var.project_name}-bedrock-agent-policy"
  role = aws_iam_role.bedrock_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["aps:QueryMetrics", "aps:GetSeries", "aps:GetLabels"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["es:ESHttpGet", "es:ESHttpPost"]
        Resource = "${aws_opensearch_domain.main.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.runbooks.arn, "${aws_s3_bucket.runbooks.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = "*"
      }
    ]
  })
}

# ============================================================
# EC2 - 우리 시스템의 OTel Collector
# ============================================================

resource "aws_instance" "otel_collector" {
  ami                    = var.ec2_ami_id
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.otel_collector.id]
  iam_instance_profile   = aws_iam_instance_profile.otel_collector.name
  key_name               = var.ec2_key_name

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/user_data.sh", {
    amp_remote_write_url = aws_prometheus_workspace.main.prometheus_endpoint
    aws_region           = var.aws_region
    osis_logs_endpoint   = tolist(aws_osis_pipeline.logs.ingest_endpoint_urls)[0]
    osis_traces_endpoint = tolist(aws_osis_pipeline.traces.ingest_endpoint_urls)[0]
    s3_logs_bucket       = aws_s3_bucket.logs_backup.id
    s3_traces_bucket     = aws_s3_bucket.traces_backup.id
    s3_metrics_bucket    = aws_s3_bucket.metrics_backup.id
    project_name         = var.project_name
    cognito_user_pool_id = aws_cognito_user_pool.otel_auth.id
    cognito_client_id    = aws_cognito_user_pool_client.otel_customer.id
  })
  tags = { Name = "${var.project_name}-otel-collector" }

  depends_on = [
    aws_prometheus_workspace.main,
    aws_opensearch_domain.main,
    aws_osis_pipeline.logs,
    aws_osis_pipeline.traces,
    aws_s3_bucket.logs_backup,
    aws_s3_bucket.traces_backup,
    aws_s3_bucket.metrics_backup,
  ]
}


resource "aws_eip" "otel_collector" {
  instance = aws_instance.otel_collector.id
  domain   = "vpc"
  tags     = { Name = "${var.project_name}-otel-collector-eip" }
}

# ============================================================
# Amazon Managed Prometheus (AMP)
# ============================================================

resource "aws_prometheus_workspace" "main" {
  alias = "${var.project_name}-amp"
  tags  = { Name = "${var.project_name}-amp" }
}

# ============================================================
# S3 Buckets
# ============================================================

resource "aws_s3_bucket" "logs_backup" {
  bucket = "${var.project_name}-logs-backup-${data.aws_caller_identity.current.account_id}"
  tags   = { Name = "${var.project_name}-logs-backup" }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs_backup" {
  bucket = aws_s3_bucket.logs_backup.id
  rule {
    id     = "delete-old-logs"
    status = "Enabled"
    filter { prefix = "" }
    expiration { days = 30 }
  }
}

resource "aws_s3_bucket" "traces_backup" {
  bucket = "${var.project_name}-traces-backup-${data.aws_caller_identity.current.account_id}"
  tags   = { Name = "${var.project_name}-traces-backup" }
}

resource "aws_s3_bucket_lifecycle_configuration" "traces_backup" {
  bucket = aws_s3_bucket.traces_backup.id
  rule {
    id     = "delete-old-traces"
    status = "Enabled"
    filter { prefix = "" }
    expiration { days = 30 }
  }
}

resource "aws_s3_bucket" "metrics_backup" {
  bucket = "${var.project_name}-metrics-backup-${data.aws_caller_identity.current.account_id}"
  tags   = { Name = "${var.project_name}-metrics-backup" }
}

resource "aws_s3_bucket_lifecycle_configuration" "metrics_backup" {
  bucket = aws_s3_bucket.metrics_backup.id
  rule {
    id     = "expire-old-metrics"
    status = "Enabled"
    expiration { days = 365 }
  }
}

resource "aws_s3_bucket" "runbooks" {
  bucket = "${var.project_name}-runbooks-${data.aws_caller_identity.current.account_id}"
  tags   = { Name = "${var.project_name}-runbooks" }
}


# ============================================================
# OpenSearch Domain
# ============================================================

resource "aws_opensearch_domain" "main" {
  domain_name    = var.project_name
  engine_version = "OpenSearch_2.11"

  cluster_config {
    instance_type  = "t3.small.search"
    instance_count = 1
  }

  ebs_options {
    ebs_enabled = true
    volume_size = 10
    volume_type = "gp3"
  }

  vpc_options {
    subnet_ids         = [aws_subnet.public.id]
    security_group_ids = [aws_security_group.opensearch.id]
  }

  advanced_security_options {
    enabled                        = true
    internal_user_database_enabled = true
    master_user_options {
      master_user_name     = var.opensearch_master_user
      master_user_password = var.opensearch_master_password
    }
  }

  encrypt_at_rest { enabled = true }
  node_to_node_encryption { enabled = true }

  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-2019-07"
  }

  access_policies = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { AWS = "*" }
        Action    = "es:*"
        Resource  = "arn:aws:es:${var.aws_region}:${data.aws_caller_identity.current.account_id}:domain/${var.project_name}/*"
      }
    ]
  })

  tags = { Name = "${var.project_name}-opensearch" }
}

# ============================================================
# OpenSearch Role 매핑 자동화
# terraform apply 후 OSIS Role을 all_access에 자동 매핑
# EC2를 통해 VPC 내부에서 OpenSearch에 접근
# ============================================================

resource "null_resource" "opensearch_role_mapping" {
  triggers = {
    opensearch_domain = aws_opensearch_domain.main.endpoint
    osis_role_arn     = aws_iam_role.osis_pipeline.arn
    always_run        = timestamp()
  }

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      host        = aws_instance.otel_collector.public_ip
      user        = "ubuntu"
      private_key = file(var.ec2_key_path)
      timeout     = "5m"
    }

    inline = [
      "echo 'Waiting for OpenSearch to be ready...'",
      "sleep 120",
      "curl -sk -u '${var.opensearch_master_user}:${var.opensearch_master_password}' -X PUT 'https://${aws_opensearch_domain.main.endpoint}/_plugins/_security/api/rolesmapping/all_access' -H 'Content-Type: application/json' -d '{\"backend_roles\":[\"${aws_iam_role.osis_pipeline.arn}\"],\"users\":[\"${var.opensearch_master_user}\"]}' || true",
      "curl -sk -u '${var.opensearch_master_user}:${var.opensearch_master_password}' -X PUT 'https://${aws_opensearch_domain.main.endpoint}/_plugins/_ism/policies/delete-after-30-days' -H 'Content-Type: application/json' -d '{\"policy\":{\"description\":\"Delete indices after 30 days\",\"default_state\":\"hot\",\"states\":[{\"name\":\"hot\",\"actions\":[],\"transitions\":[{\"state_name\":\"delete\",\"conditions\":{\"min_index_age\":\"30d\"}}]},{\"name\":\"delete\",\"actions\":[{\"delete\":{}}],\"transitions\":[]}]}}' || true",
      "echo 'OpenSearch setup done!'"
    ]
  }

  depends_on = [
    aws_opensearch_domain.main,
    aws_instance.otel_collector
  ]
}

# ============================================================
# OpenSearch Ingestion Pipelines (OSIS)
# VPC 연결로 OpenSearch VPC 도메인에 안전하게 접근
# ============================================================

resource "aws_osis_pipeline" "logs" {
  pipeline_name = "${var.project_name}-logs"

  vpc_options {
    subnet_ids         = [aws_subnet.public.id]
    security_group_ids = [aws_security_group.opensearch.id]
  }

  pipeline_configuration_body = <<-YAML
    version: "2"
    log-pipeline:
      source:
        otel_logs_source:
          path: "/v1/logs"
      processor:
        - add_entries:
            entries:
              - key: "pipeline_name"
                value: "logs"
      sink:
        - opensearch:
            hosts: ["https://${aws_opensearch_domain.main.endpoint}"]
            index: "logs-%%{yyyy.MM.dd}"
            aws:
              sts_role_arn: "${aws_iam_role.osis_pipeline.arn}"
              region: "${var.aws_region}"
              serverless: false
  YAML

  min_units  = 1
  max_units  = 4
  tags       = { Name = "${var.project_name}-logs-pipeline" }
  depends_on = [aws_opensearch_domain.main]
}

resource "aws_osis_pipeline" "traces" {
  pipeline_name = "${var.project_name}-traces"

  vpc_options {
    subnet_ids         = [aws_subnet.public.id]
    security_group_ids = [aws_security_group.opensearch.id]
  }

  pipeline_configuration_body = <<-YAML
    version: "2"
    entry-pipeline:
      source:
        otel_trace_source:
          path: "/v1/traces"
      processor:
        - otel_traces:
      sink:
        - opensearch:
            hosts: ["https://${aws_opensearch_domain.main.endpoint}"]
            index_type: trace-analytics-raw
            aws:
              sts_role_arn: "${aws_iam_role.osis_pipeline.arn}"
              region: "${var.aws_region}"
              serverless: false
        - pipeline:
            name: "service-map-pipeline"
    service-map-pipeline:
      source:
        pipeline:
          name: "entry-pipeline"
      processor:
        - service_map:
      sink:
        - opensearch:
            hosts: ["https://${aws_opensearch_domain.main.endpoint}"]
            index_type: trace-analytics-service-map
            aws:
              sts_role_arn: "${aws_iam_role.osis_pipeline.arn}"
              region: "${var.aws_region}"
              serverless: false
  YAML

  min_units  = 1
  max_units  = 4
  tags       = { Name = "${var.project_name}-traces-pipeline" }
  depends_on = [aws_opensearch_domain.main]
}

# ============================================================
# Glue Database + Crawler (S3 → Athena 장기 분석)
# ============================================================

resource "aws_glue_catalog_database" "observability" {
  name = "${replace(var.project_name, "-", "_")}_observability"
}

resource "aws_iam_role" "glue_crawler" {
  name = "${var.project_name}-glue-crawler-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue_crawler.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_s3" {
  name = "${var.project_name}-glue-s3-policy"
  role = aws_iam_role.glue_crawler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:GetObject", "s3:ListBucket"]
      Resource = [
        aws_s3_bucket.logs_backup.arn,
        "${aws_s3_bucket.logs_backup.arn}/*",
        aws_s3_bucket.traces_backup.arn,
        "${aws_s3_bucket.traces_backup.arn}/*",
        aws_s3_bucket.metrics_backup.arn,
        "${aws_s3_bucket.metrics_backup.arn}/*",
      ]
    }]
  })
}

resource "aws_glue_crawler" "logs" {
  name          = "${var.project_name}-logs-crawler"
  database_name = aws_glue_catalog_database.observability.name
  role          = aws_iam_role.glue_crawler.arn
  schedule      = "cron(0 2 * * ? *)" # 매일 새벽 2시 실행

  s3_target {
    path = "s3://${aws_s3_bucket.logs_backup.id}/logs/"
  }

  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"
    delete_behavior = "LOG"
  }

  tags = { Name = "${var.project_name}-logs-crawler" }
}

resource "aws_glue_crawler" "traces" {
  name          = "${var.project_name}-traces-crawler"
  database_name = aws_glue_catalog_database.observability.name
  role          = aws_iam_role.glue_crawler.arn
  schedule      = "cron(0 2 * * ? *)" # 매일 새벽 2시 실행

  s3_target {
    path = "s3://${aws_s3_bucket.traces_backup.id}/traces/"
  }

  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"
    delete_behavior = "LOG"
  }

  tags = { Name = "${var.project_name}-traces-crawler" }
}

resource "aws_glue_crawler" "metrics" {
  name          = "${var.project_name}-metrics-crawler"
  database_name = aws_glue_catalog_database.observability.name
  role          = aws_iam_role.glue_crawler.arn
  schedule      = "cron(0 2 * * ? *)"

  s3_target {
    path = "s3://${aws_s3_bucket.metrics_backup.id}/metrics/"
  }

  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"
    delete_behavior = "LOG"
  }

  tags = { Name = "${var.project_name}-metrics-crawler" }
}

# ============================================================
# Athena Workgroup + S3 쿼리 결과 버킷
# ============================================================

resource "aws_s3_bucket" "athena_results" {
  bucket = "${var.project_name}-athena-results-${data.aws_caller_identity.current.account_id}"
  tags   = { Name = "${var.project_name}-athena-results" }
}

resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  rule {
    id     = "expire-query-results"
    status = "Enabled"
    expiration { days = 7 }
  }
}

resource "aws_athena_workgroup" "observability" {
  name          = "${var.project_name}-observability"
  force_destroy = true

  configuration {
    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.id}/query-results/"
    }
  }

  tags = { Name = "${var.project_name}-athena-workgroup" }
}

# ============================================================
# Cognito - 고객 OTel Collector 인증
# 고객별 client_id/secret 발급 → Envoy JWT 검증으로 우리 EC2 접근 인증
# ============================================================

resource "aws_cognito_user_pool" "otel_auth" {
  name = "${var.project_name}-otel-auth"

  password_policy {
    minimum_length    = 16
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = true
  }

  tags = { Name = "${var.project_name}-otel-auth" }
}

# Cognito Domain (토큰 엔드포인트 URL용)
resource "aws_cognito_user_pool_domain" "otel_auth" {
  domain       = "${var.project_name}-otel-auth"
  user_pool_id = aws_cognito_user_pool.otel_auth.id
}

# Resource Server (API 스코프 정의)
resource "aws_cognito_resource_server" "otel" {
  identifier   = "https://${var.project_name}.otel"
  name         = "${var.project_name}-otel-resource-server"
  user_pool_id = aws_cognito_user_pool.otel_auth.id

  scope {
    scope_name        = "ingest"
    scope_description = "OTel 데이터 수집 권한"
  }
}

# 고객용 App Client (client_credentials 방식 - 서버간 통신)
resource "aws_cognito_user_pool_client" "otel_customer" {
  name         = "${var.project_name}-otel-customer-client"
  user_pool_id = aws_cognito_user_pool.otel_auth.id

  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["${aws_cognito_resource_server.otel.identifier}/ingest"]
  generate_secret                      = true

  depends_on = [aws_cognito_resource_server.otel]
}

# ============================================================
# API Gateway - 비활성화 (Envoy JWT 프록시로 대체)
# ============================================================

# resource "aws_api_gateway_rest_api" "otel" {
#   name        = "${var.project_name}-otel-gateway"
#   description = "OTel 데이터 수집 API Gateway"
#   tags = { Name = "${var.project_name}-otel-gateway" }
# }
# resource "aws_api_gateway_resource" "v1" {
#   rest_api_id = aws_api_gateway_rest_api.otel.id
#   parent_id   = aws_api_gateway_rest_api.otel.root_resource_id
#   path_part   = "v1"
# }
# resource "aws_api_gateway_resource" "logs" {
#   rest_api_id = aws_api_gateway_rest_api.otel.id
#   parent_id   = aws_api_gateway_resource.v1.id
#   path_part   = "logs"
# }
# resource "aws_api_gateway_resource" "traces" {
#   rest_api_id = aws_api_gateway_rest_api.otel.id
#   parent_id   = aws_api_gateway_resource.v1.id
#   path_part   = "traces"
# }
# resource "aws_api_gateway_resource" "metrics" {
#   rest_api_id = aws_api_gateway_rest_api.otel.id
#   parent_id   = aws_api_gateway_resource.v1.id
#   path_part   = "metrics"
# }
# resource "aws_api_gateway_method" "logs_post" {
#   rest_api_id      = aws_api_gateway_rest_api.otel.id
#   resource_id      = aws_api_gateway_resource.logs.id
#   http_method      = "POST"
#   authorization    = "NONE"
#   api_key_required = true
# }
# resource "aws_api_gateway_method" "traces_post" {
#   rest_api_id      = aws_api_gateway_rest_api.otel.id
#   resource_id      = aws_api_gateway_resource.traces.id
#   http_method      = "POST"
#   authorization    = "NONE"
#   api_key_required = true
# }
# resource "aws_api_gateway_method" "metrics_post" {
#   rest_api_id      = aws_api_gateway_rest_api.otel.id
#   resource_id      = aws_api_gateway_resource.metrics.id
#   http_method      = "POST"
#   authorization    = "NONE"
#   api_key_required = true
# }
# resource "aws_api_gateway_integration" "logs" {
#   rest_api_id             = aws_api_gateway_rest_api.otel.id
#   resource_id             = aws_api_gateway_resource.logs.id
#   http_method             = aws_api_gateway_method.logs_post.http_method
#   type                    = "HTTP_PROXY"
#   integration_http_method = "POST"
#   uri                     = "http://${aws_eip.otel_collector.public_ip}:4318/v1/logs"
# }
# resource "aws_api_gateway_integration" "traces" {
#   rest_api_id             = aws_api_gateway_rest_api.otel.id
#   resource_id             = aws_api_gateway_resource.traces.id
#   http_method             = aws_api_gateway_method.traces_post.http_method
#   type                    = "HTTP_PROXY"
#   integration_http_method = "POST"
#   uri                     = "http://${aws_eip.otel_collector.public_ip}:4318/v1/traces"
# }
# resource "aws_api_gateway_integration" "metrics" {
#   rest_api_id             = aws_api_gateway_rest_api.otel.id
#   resource_id             = aws_api_gateway_resource.metrics.id
#   http_method             = aws_api_gateway_method.metrics_post.http_method
#   type                    = "HTTP_PROXY"
#   integration_http_method = "POST"
#   uri                     = "http://${aws_eip.otel_collector.public_ip}:4318/v1/metrics"
# }
# resource "aws_api_gateway_deployment" "otel" {
#   rest_api_id = aws_api_gateway_rest_api.otel.id
#   depends_on = [
#     aws_api_gateway_integration.logs,
#     aws_api_gateway_integration.traces,
#     aws_api_gateway_integration.metrics,
#   ]
#   lifecycle { create_before_destroy = true }
# }
# resource "aws_api_gateway_stage" "otel" {
#   deployment_id = aws_api_gateway_deployment.otel.id
#   rest_api_id   = aws_api_gateway_rest_api.otel.id
#   stage_name    = "prod"
#   tags = { Name = "${var.project_name}-otel-stage" }
# }
# resource "aws_api_gateway_usage_plan" "otel" {
#   name = "${var.project_name}-otel-usage-plan"
#   api_stages {
#     api_id = aws_api_gateway_rest_api.otel.id
#     stage  = aws_api_gateway_stage.otel.stage_name
#   }
# }
# resource "aws_api_gateway_api_key" "customer_1" {
#   name    = "${var.project_name}-customer-1"
#   enabled = true
# }
# resource "aws_api_gateway_usage_plan_key" "customer_1" {
#   key_id        = aws_api_gateway_api_key.customer_1.id
#   key_type      = "API_KEY"
#   usage_plan_id = aws_api_gateway_usage_plan.otel.id
# }
