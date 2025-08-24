variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-2"
}

variable "aws_profile" {
  description = "AWS CLI profile name"
  type        = string
  default     = "terraform-admin"
}

variable "key_name" {
  description = "EC2 key pair name"
  type        = string
  default     = "main-key"
}

variable "db_name" {
  description = "RDS database name"
  type        = string
  default     = "mnraderdb"
}

variable "db_username" {
  description = "RDS master username"
  type        = string
  default     = "admin"
}

variable "db_password" {
  description = "RDS master password"
  type        = string
  sensitive   = true
}

variable "bucket_name" {
  description = "S3 bucket name"
  type        = string
  default     = "mnrader-bucket"
}