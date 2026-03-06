# ============================================================
# OpenSearch Serverless - 런북 벡터 검색용
# main.tf에 추가
# ============================================================

# 암호화 정책
resource "aws_opensearchserverless_security_policy" "runbooks_encryption" {
  name        = "${var.project_name}-runbooks-enc"
  type        = "encryption"
  description = "런북 벡터 검색 암호화 정책"

  policy = jsonencode({
    Rules = [{
      ResourceType = "collection"
      Resource     = ["collection/${var.project_name}-runbooks"]
    }]
    AWSOwnedKey = true
  })
}

# 네트워크 정책
resource "aws_opensearchserverless_security_policy" "runbooks_network" {
  name        = "${var.project_name}-runbooks-net"
  type        = "network"
  description = "런북 벡터 검색 네트워크 정책"

  policy = jsonencode([{
    Rules = [
      {
        ResourceType = "collection"
        Resource     = ["collection/${var.project_name}-runbooks"]
      },
      {
        ResourceType = "dashboard"
        Resource     = ["collection/${var.project_name}-runbooks"]
      }
    ]
    AllowFromPublic = true
  }])
}

# 데이터 접근 정책
resource "aws_opensearchserverless_access_policy" "runbooks" {
  name        = "${var.project_name}-runbooks-access"
  type        = "data"
  description = "런북 벡터 검색 접근 정책"

  policy = jsonencode([{
    Rules = [
      {
        ResourceType = "index"
        Resource     = ["index/${var.project_name}-runbooks/*"]
        Permission   = ["aoss:*"]
      },
      {
        ResourceType = "collection"
        Resource     = ["collection/${var.project_name}-runbooks"]
        Permission   = ["aoss:*"]
      }
    ]
    Principal = [
      aws_iam_role.lambda_agent.arn,
      aws_iam_role.bedrock_agent.arn,
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
    ]
  }])
}

# OpenSearch Serverless 컬렉션
resource "aws_opensearchserverless_collection" "runbooks" {
  name        = "${var.project_name}-runbooks"
  type        = "VECTORSEARCH"
  description = "런북 벡터 검색 컬렉션"

  tags = { Name = "${var.project_name}-runbooks-vector" }

  depends_on = [
    aws_opensearchserverless_security_policy.runbooks_encryption,
    aws_opensearchserverless_security_policy.runbooks_network,
    aws_opensearchserverless_access_policy.runbooks,
  ]
}

# ============================================================
# 런북 인덱싱 Lambda (S3 업로드 시 자동 실행)
# ============================================================

data "archive_file" "runbooks_indexer" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_package"
  output_path = "${path.module}/runbooks_aws.zip"
}

# S3에 zip 업로드
resource "aws_s3_object" "runbooks_indexer" {
  bucket = aws_s3_bucket.runbooks.id
  key    = "lambda/runbooks_aws.zip"
  source = data.archive_file.runbooks_indexer.output_path
  etag   = data.archive_file.runbooks_indexer.output_md5
}

resource "aws_lambda_function" "runbooks_indexer" {
  function_name    = "${var.project_name}-runbooks-indexer"
  role             = aws_iam_role.lambda_agent.arn
  handler          = "runbooks_aws.indexing_handler"
  runtime          = "python3.12"
  s3_bucket        = aws_s3_bucket.runbooks.id
  s3_key           = aws_s3_object.runbooks_indexer.key
  source_code_hash = data.archive_file.runbooks_indexer.output_base64sha256
  timeout          = 300
  memory_size      = 512
  layers           = [aws_lambda_layer_version.agent_deps.arn]

  environment {
    variables = {
      RUNBOOKS_BUCKET = aws_s3_bucket.runbooks.id
      AOSS_ENDPOINT   = aws_opensearchserverless_collection.runbooks.collection_endpoint
      AWS_REGION_NAME = var.aws_region
    }
  }

  tags = { Name = "${var.project_name}-runbooks-indexer" }

  depends_on = [aws_opensearchserverless_collection.runbooks]
}

# S3 업로드 → Lambda 트리거
resource "aws_s3_bucket_notification" "runbooks" {
  bucket = aws_s3_bucket.runbooks.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.runbooks_indexer.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "runbooks/"
    filter_suffix       = ".md"
  }

  depends_on = [aws_lambda_permission.s3_runbooks_trigger]
}

resource "aws_lambda_permission" "s3_runbooks_trigger" {
  statement_id  = "AllowS3Trigger"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.runbooks_indexer.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.runbooks.arn
}

# ============================================================
# Lambda IAM - AOSS + Bedrock 권한 추가
# ============================================================

resource "aws_iam_role_policy" "lambda_aoss" {
  name = "${var.project_name}-lambda-aoss-policy"
  role = aws_iam_role.lambda_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AOSS"
        Effect   = "Allow"
        Action   = ["aoss:APIAccessAll"]
        Resource = aws_opensearchserverless_collection.runbooks.arn
      },
      {
        Sid      = "BedrockEmbedding"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = "arn:aws:bedrock:${var.aws_region}::foundation-model/amazon.titan-embed-text-v2:0"
      },
      {
        Sid    = "S3Runbooks"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket", "s3:PutObject"]
        Resource = [
          aws_s3_bucket.runbooks.arn,
          "${aws_s3_bucket.runbooks.arn}/*"
        ]
      }
    ]
  })
}
