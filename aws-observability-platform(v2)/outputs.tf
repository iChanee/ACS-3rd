output "otel_collector_public_ip" {
  description = "우리 OTel Collector EC2 Public IP (LFS148 앱이 이 주소로 데이터를 전송)"
  value       = aws_eip.otel_collector.public_ip
}

output "otel_collector_otlp_grpc" {
  description = "OTLP gRPC 엔드포인트 (LFS148 앱 OTel Collector exporter에 설정)"
  value       = "${aws_eip.otel_collector.public_ip}:4317"
}

output "otel_collector_otlp_http" {
  description = "OTLP HTTP 엔드포인트 (LFS148 앱 OTel Collector exporter에 설정)"
  value       = "http://${aws_eip.otel_collector.public_ip}:4318"
}

output "amp_workspace_id" {
  description = "Amazon Managed Prometheus Workspace ID"
  value       = aws_prometheus_workspace.main.id
}

output "amp_endpoint" {
  description = "AMP 엔드포인트 (메트릭 저장)"
  value       = aws_prometheus_workspace.main.prometheus_endpoint
}

output "opensearch_endpoint" {
  description = "OpenSearch 도메인 엔드포인트 (로그/트레이스 저장)"
  value       = "https://${aws_opensearch_domain.main.endpoint}"
}

output "opensearch_dashboard_url" {
  description = "OpenSearch 대시보드 URL"
  value       = "https://${aws_opensearch_domain.main.endpoint}/_dashboards"
}

output "osis_logs_endpoint" {
  description = "OSIS 로그 파이프라인 수신 엔드포인트"
  value       = tolist(aws_osis_pipeline.logs.ingest_endpoint_urls)[0]
}

output "osis_traces_endpoint" {
  description = "OSIS 트레이스 파이프라인 수신 엔드포인트"
  value       = tolist(aws_osis_pipeline.traces.ingest_endpoint_urls)[0]
}

output "s3_logs_backup_bucket" {
  description = "로그 S3 백업 버킷 이름"
  value       = aws_s3_bucket.logs_backup.id
}

output "s3_traces_backup_bucket" {
  description = "트레이스 S3 백업 버킷 이름"
  value       = aws_s3_bucket.traces_backup.id
}

output "s3_metrics_backup_bucket" {
  description = "메트릭 S3 백업 버킷 이름"
  value       = aws_s3_bucket.metrics_backup.id
}

output "s3_runbooks_bucket" {
  description = "Bedrock 런북 S3 버킷 이름"
  value       = aws_s3_bucket.runbooks.id
}

output "bedrock_agent_role_arn" {
  description = "Bedrock Agent IAM Role ARN"
  value       = aws_iam_role.bedrock_agent.arn
}

output "ssh_command" {
  description = "EC2 SSH 접속 명령어"
  value       = "ssh -i ${var.ec2_key_path} ubuntu@${aws_eip.otel_collector.public_ip}"
}

output "athena_workgroup" {
  description = "Athena 워크그룹 이름"
  value       = aws_athena_workgroup.observability.name
}

output "glue_database" {
  description = "Glue 카탈로그 데이터베이스 이름"
  value       = aws_glue_catalog_database.observability.name
}

output "cognito_user_pool_id" {
  description = "Cognito User Pool ID"
  value       = aws_cognito_user_pool.otel_auth.id
}

output "cognito_client_id" {
  description = "고객 OTel Collector용 Client ID"
  value       = aws_cognito_user_pool_client.otel_customer.id
}

output "cognito_client_secret" {
  description = "고객 OTel Collector용 Client Secret"
  value       = aws_cognito_user_pool_client.otel_customer.client_secret
  sensitive   = true
}

output "cognito_token_endpoint" {
  description = "고객 OTel Collector가 토큰 발급받는 엔드포인트"
  value       = "https://${aws_cognito_user_pool_domain.otel_auth.domain}.auth.${var.aws_region}.amazoncognito.com/oauth2/token"
}

output "cognito_jwks_uri" {
  description = "Envoy가 토큰 검증하는 JWKS URI"
  value       = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.otel_auth.id}/.well-known/jwks.json"
}

output "next_steps" {
  description = "배포 후 다음 단계"
  sensitive   = true
  value       = <<-EOT

  ========================================
  인프라 배포 완료!
  ========================================

  [인증 구조]
  고객 OTel → Envoy(4317/4318) → JWT 검증(Cognito) → OTelCol(14317/14318)

  [Step 1] 토큰 발급 (PowerShell)
  terraform output -raw cognito_client_secret
  → CLIENT_ID / CLIENT_SECRET 확인 후 토큰 발급

  [Step 2] LFS148 otel-collector-config.yml 설정
  oauth2client extension에 client_id/secret/token_url 설정

  [Step 3] Envoy 상태 확인
  ssh ubuntu@${aws_eip.otel_collector.public_ip}
  docker logs envoy -f

  [Step 4] OTel Collector 상태 확인
  sudo systemctl status otelcol
  sudo journalctl -u otelcol -f

  ========================================
  EOT
}
