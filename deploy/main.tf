# Single root config shared by every team — this file never changes when a
# team is onboarded, offboarded, or edits its bucket list. Which team it
# operates on is decided entirely at invocation time:
#
#   terraform init  -backend-config="key=teams/<team-name>/terraform.tfstate"
#   terraform plan  -var="team_config_path=../teams/<team-name>/team.yaml"
#
# See scripts/run-team.sh, which wraps exactly this.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }

  # Isolated state per team: same bucket, one object per team, keyed by the
  # team name and supplied via -backend-config at init time (see above) so
  # this block itself never mentions a specific team. A bad apply or a stuck
  # lock for one team can never touch another team's state.
  backend "s3" {
    bucket       = "acme-platform-terraform-state"
    region       = "eu-west-1"
    encrypt      = true
    use_lockfile = true
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
  # Pinned to a tagged release of the module's own repo — never a branch —
  # so a change there can only reach teams by a deliberate version bump
  # here, reviewed like any other change.
  source = "git::https://github.com/millad90s/sumUp-tf-module.git?ref=v1.0.0"

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
