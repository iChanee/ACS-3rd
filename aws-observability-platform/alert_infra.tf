# ============================================================
# Lambda용 Security Group
# ============================================================

resource "aws_security_group" "lambda" {
  name        = "${var.project_name}-lambda-sg"
  description = "Lambda - private subnet, outbound via NAT Gateway"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-lambda-sg" }
}

resource "aws_security_group_rule" "opensearch_from_lambda" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.opensearch.id
  source_security_group_id = aws_security_group.lambda.id
  description              = "Allow Lambda to access OpenSearch"
}

# ============================================================
# SNS Topic - Alertmanager가 알람을 쏘는 곳
# ============================================================

resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-alerts"
  tags = { Name = "${var.project_name}-alerts" }
}

resource "aws_sns_topic_policy" "alerts" {
  arn = aws_sns_topic.alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "aps.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.alerts.arn
      }
    ]
  })
}

# ============================================================
# Lambda IAM Role
# ============================================================

resource "aws_iam_role" "lambda_agent" {
  name = "${var.project_name}-lambda-agent-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_agent" {
  name = "${var.project_name}-lambda-agent-policy"
  role = aws_iam_role.lambda_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Sid      = "AMP"
        Effect   = "Allow"
        Action   = ["aps:QueryMetrics", "aps:GetSeries", "aps:GetLabels"]
        Resource = "*"
      },
      {
        Sid      = "OpenSearch"
        Effect   = "Allow"
        Action   = ["es:ESHttpGet", "es:ESHttpPost"]
        Resource = "${aws_opensearch_domain.main.arn}/*"
      },
      {
        Sid      = "Bedrock"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = "*"
      },
      {
        Sid      = "S3"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.runbooks.arn}/lambda/*"
      },
      {
        Sid    = "VPC"
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface"
        ]
        Resource = "*"
      }
    ]
  })
}

# ============================================================
# Lambda 함수
# ============================================================

data "archive_file" "lambda_agent" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_package"
  output_path = "${path.module}/lambda_handler.zip"
}

# S3에 코드 zip 업로드
resource "aws_s3_object" "lambda_agent" {
  bucket = aws_s3_bucket.runbooks.id
  key    = "lambda/lambda_handler.zip"
  source = data.archive_file.lambda_agent.output_path
  etag   = data.archive_file.lambda_agent.output_md5
}

# S3에 layer zip 업로드
resource "aws_s3_object" "agent_deps_layer" {
  bucket = aws_s3_bucket.runbooks.id
  key    = "lambda/lambda_layer.zip"
  source = "${path.module}/lambda_layer.zip"
  etag   = filemd5("${path.module}/lambda_layer.zip")
}

# Lambda Layer - S3에서 로드
resource "aws_lambda_layer_version" "agent_deps" {
  layer_name          = "${var.project_name}-agent-deps"
  s3_bucket           = aws_s3_bucket.runbooks.id
  s3_key              = aws_s3_object.agent_deps_layer.key
  source_code_hash    = filebase64sha256("${path.module}/lambda_layer.zip")
  compatible_runtimes = ["python3.12"]
}

resource "aws_lambda_function" "agent" {
  function_name    = "${var.project_name}-observability-agent"
  role             = aws_iam_role.lambda_agent.arn
  handler          = "lambda_handler.handler"
  runtime          = "python3.12"
  s3_bucket        = aws_s3_bucket.runbooks.id
  s3_key           = aws_s3_object.lambda_agent.key
  source_code_hash = data.archive_file.lambda_agent.output_base64sha256
  layers           = [aws_lambda_layer_version.agent_deps.arn]
  timeout          = 300
  memory_size      = 512

  vpc_config {
    subnet_ids         = [aws_subnet.private.id]
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      AMP_ENDPOINT        = aws_prometheus_workspace.main.prometheus_endpoint
      OPENSEARCH_ENDPOINT = aws_opensearch_domain.main.endpoint
      OPENSEARCH_USER     = var.opensearch_master_user
      OPENSEARCH_PASSWORD = var.opensearch_master_password
      # SLACK_WEBHOOK_URL   = var.slack_webhook_url                                   # (슬랙 연동 시 사용했었음)
      SLACK_BOT_TOKEN = var.slack_bot_token # (슬랙 연동 시 사용) 실제 토큰으로 변경
      SLACK_CHANNEL   = var.slack_channel   # 채널 ID로 변경
      AWS_REGION_NAME = var.aws_region
      AOSS_ENDPOINT   = aws_opensearchserverless_collection.runbooks.collection_endpoint # 런북용 OpenSearch Serverless 엔드포인트
    }
  }

  tags = { Name = "${var.project_name}-observability-agent" }
}

resource "aws_lambda_permission" "sns_trigger" {
  statement_id  = "AllowSNSTrigger"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.agent.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alerts.arn
}

resource "aws_sns_topic_subscription" "lambda" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.agent.arn
}

# ============================================================
# AMP Alert Rule
# ============================================================

resource "aws_prometheus_rule_group_namespace" "alerts" {
  name         = "observability-alerts"
  workspace_id = aws_prometheus_workspace.main.id

  data = <<-YAML
    groups:
      - name: service-alerts
        interval: 1m
        rules:

          - alert: HighJvmCpu
            expr: jvm_cpu_recent_utilization_ratio > 0.8
            for: 2m
            labels:
              severity: critical
            annotations:
              summary: "JVM CPU 사용률 80% 초과"
              description: "서비스 {{ $labels.service_name }}의 CPU가 {{ $value | humanizePercentage }} 입니다"

          - alert: HighJvmMemory
            expr: jvm_memory_used_bytes / jvm_memory_limit_bytes > 0.85
            for: 2m
            labels:
              severity: critical
            annotations:
              summary: "JVM 메모리 85% 초과"
              description: "서비스 {{ $labels.service_name }}의 메모리가 {{ $value | humanizePercentage }} 입니다"

          - alert: HighHttpErrorRate
            expr: |
              rate(http_server_request_duration_seconds_count{http_response_status_code=~"4..|5.."}[5m])
              /
              rate(http_server_request_duration_seconds_count[5m])
              > 0.5
            for: 30s
            labels:
              severity: critical
            annotations:
              summary: "HTTP 에러율 50% 초과"
              description: "서비스 {{ $labels.service_name }}의 에러율이 {{ $value | humanizePercentage }} 입니다"

          - alert: HighHttpLatency
            expr: |
              histogram_quantile(0.95,
                rate(http_server_request_duration_seconds_bucket[5m])
              ) > 1.0
            for: 2m
            labels:
              severity: warning
            annotations:
              summary: "HTTP 응답시간 P95 1초 초과"
              description: "서비스 {{ $labels.service_name }}의 P95 응답시간이 {{ $value }}초 입니다"

          - alert: HighDbConnectionPending
            expr: db_client_connections_pending_requests > 5
            for: 1m
            labels:
              severity: warning
            annotations:
              summary: "DB 커넥션 대기 급증"
              description: "서비스 {{ $labels.service_name }}의 DB 커넥션 대기가 {{ $value }}개 입니다"
  YAML
}

# ============================================================
# AMP Alertmanager 설정
# ============================================================

resource "aws_prometheus_alert_manager_definition" "main" {
  workspace_id = aws_prometheus_workspace.main.id

  definition = <<-YAML
    alertmanager_config: |
      global:
        resolve_timeout: 5m

      route:
        group_by: ['alertname', 'service_name']
        group_wait: 30s
        group_interval: 5m
        repeat_interval: 5m  # 1h → 5m
        receiver: sns-alert

        routes:
          - match:
              severity: critical
            receiver: sns-alert
            group_wait: 10s
          - match:
              severity: warning
            receiver: sns-alert
            group_wait: 30s

      receivers:
        - name: sns-alert
          sns_configs:
            - topic_arn: ${aws_sns_topic.alerts.arn}
              sigv4:
                region: ${var.aws_region}
              attributes:
                severity: '{{ .CommonLabels.severity }}'
  YAML
}
