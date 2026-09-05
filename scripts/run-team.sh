#!/usr/bin/env bash
# Plan/apply/destroy one team's resources against LocalStack (via tflocal),
# using the real S3 backend already declared in deploy/main.tf — tflocal
# redirects it (and the AWS provider) to LocalStack, no real AWS account
# needed. Each team gets its own state key in the shared bucket.
#
# apply/destroy run for real against LocalStack (-auto-approve) — that's
# safe here because it's LocalStack, never do this against a real backend
# without a human reviewing a saved plan first.
#
# Real usage is identical, just with plain `terraform` instead of `tflocal`,
# and never with -auto-approve:
#
#   cd deploy
#   terraform init -backend-config="key=teams/<team>/terraform.tfstate"
#   terraform plan -var="team_config_path=../teams/<team>/team.yaml"
#
# Usage: scripts/run-team.sh <team-name> <plan|apply|destroy>

set -euo pipefail

team_name="$1"
action="$2"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
team_yaml="$repo_root/teams/$team_name/team.yaml"

cd "$repo_root/deploy"

tflocal init -input=false -reconfigure \
  -backend-config="key=teams/${team_name}/terraform.tfstate"

case "$action" in
  plan)
    tflocal plan -input=false -no-color -var="team_config_path=${team_yaml}"
    ;;
  apply)
    tflocal apply -input=false -no-color -auto-approve -var="team_config_path=${team_yaml}"
    ;;
  destroy)
    tflocal destroy -input=false -no-color -auto-approve -var="team_config_path=${team_yaml}"
    ;;
  *)
    echo "Error: action must be one of plan, apply, destroy." >&2
    exit 1
    ;;
esac
