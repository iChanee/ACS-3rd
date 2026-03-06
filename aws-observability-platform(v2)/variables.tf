variable "aws_region" {
  description = "AWS Region"
  type        = string
  default     = "ap-northeast-2"
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
  default     = "log-platform-dev"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "development"
}

variable "ec2_ami_id" {
  description = "AMI ID for EC2 instance (Ubuntu 22.04 - ap-northeast-2)"
  type        = string
  default     = "ami-0c9c942bd7bf113a2"
}

variable "ec2_key_name" {
  description = "EC2 Key Pair name for SSH access"
  type        = string
  default     = "log-platform-key-v4"
}

variable "ec2_key_path" {
  description = "Local path to EC2 private key file for SSH (used by null_resource provisioner)"
  type        = string
  default     = "C:\\Users\\DS8\\Downloads\\aws-observability-platform\\log-platform-key-v4.pem"
}

variable "opensearch_master_user" {
  description = "OpenSearch master username"
  type        = string
  default     = "admin"
}

variable "opensearch_master_password" {
  description = "OpenSearch master password"
  type        = string
  sensitive   = true
  # 최소 8자, 대문자, 소문자, 숫자, 특수문자 포함
  default = "Fkvk1234!"
}

# Slack 연동 시 사용
variable "slack_bot_token" {
  description = "Slack Bot OAuth Token"
  type        = string
  sensitive   = true # terraform plan 출력에서 가려짐
}

variable "slack_channel" {
  description = "Slack 알림 채널 ID"
  type        = string
}

# variable "slack_webhook_url" {
#   description = "Slack Webhook URL for alerts"
#   type        = string
#   sensitive   = true
# }
