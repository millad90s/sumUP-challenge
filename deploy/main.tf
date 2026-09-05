
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }

  # Shared state bucket + lock table, created once by bootstrap/. Every
  # team's init supplies its own `key` via -backend-config — see
  # scripts/run-team.sh — so this block never mentions a specific team.
  backend "s3" {
    bucket         = "acme-platform-terraform-state"
    region         = "eu-west-1"
    encrypt        = true
    dynamodb_table = "acme-platform-terraform-locks"
  }
}

provider "aws" {
  region = "eu-west-1"

  default_tags {
    tags = {
      managed-by = "terraform"
      platform   = "self-service-aws"
    }
  }
}

variable "team_config_path" {
  description = "Path to the team's team.yaml (e.g. \"../teams/team-alpha/team.yaml\")."
  type        = string
}

locals {
  team_config = yamldecode(file(var.team_config_path))
}

module "team" {
  source = "git::https://github.com/millad90s/sumUp-tf-module.git?ref=v2.0.0"

  company_prefix         = "acme"
  team                   = local.team_config.team
  buckets                = local.team_config.buckets
  trusted_principal_arns = local.team_config.trusted_principal_arns
  owner_email            = local.team_config.tags.owner
  cost_center            = local.team_config.tags.cost_center
}

output "role_arn" {
  value = module.team.role_arn
}

output "bucket_names" {
  value = module.team.bucket_names
}

output "public_bucket_names" {
  value = module.team.public_bucket_names
}
