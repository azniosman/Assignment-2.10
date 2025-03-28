variable "local_prefix" {
  type        = string
  description = "Prefix to be used for naming resources consistently"
  default     = "myapp"
}

variable "aws_region" {
  type        = string
  description = "AWS region for resources"
  default     = "us-east-1"
}

variable "sec_group_name" {
  type        = string
  description = "Name for the VPC security group"
  default     = "vpc-security-group"
}

data "aws_route53_zone" "sctp_zone" {
  name         = "sctp-sandbox.com"
  private_zone = false
}
