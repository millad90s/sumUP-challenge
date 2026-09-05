# One-time platform bootstrap: creates the shared Terraform state backend
# every team's deploy/main.tf points at (S3 bucket for state, DynamoDB
# table for locking). Run once by the platform team, before onboarding the
# first team — this config has its own local state, since there's nothing
# to isolate it in yet.
#
#   cd bootstrap
#   tflocal init
#   tflocal apply
#
# (plain `terraform` instead of `tflocal` against real AWS.)

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

variable "state_bucket_name" {
  description = "Name of the shared S3 bucket holding every team's Terraform state."
  type        = string
  default     = "acme-platform-terraform-state"
}

variable "lock_table_name" {
  description = "Name of the shared DynamoDB table used for Terraform state locking."
  type        = string
  default     = "acme-platform-terraform-locks"
}

variable "aws_region" {
  description = "AWS region the shared backend resources are created in."
  type        = string
  default     = "eu-west-1"
}

provider "aws" {
  region = var.aws_region
}

resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "lock" {
  name         = var.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  lifecycle {
    prevent_destroy = true
  }
}
