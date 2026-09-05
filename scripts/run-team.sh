#!/usr/bin/env bash
# Exercises the full detect -> validate -> plan -> "apply" -> "destroy"
# pipeline shape against a local, credential-free backend, so CI jobs turn
# green without ever touching a real AWS account or creating a single real
# resource.
#
# Every action here runs `terraform plan` (or `plan -destroy`) under the
# hood. A real `apply`/`destroy` makes real AWS API calls no matter what
# credentials are configured — fake credentials make them fail, they don't
# make them succeed silently — so the only honest way to show a green
# "apply"/"destroy" job with zero real infrastructure is to compute and
# display the plan for that action rather than execute it.
#
# Usage: scripts/run-team.sh <team-name> <plan|apply|destroy>

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <team-name> <plan|apply|destroy>" >&2
  exit 1
fi

team_name="$1"
action="$2"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
deploy_dir="$repo_root/deploy"
team_yaml="$repo_root/teams/$team_name/team.yaml"
state_dir="$deploy_dir/.demo-state"
state_file="$state_dir/${team_name}.tfstate"

if [[ ! -f "$team_yaml" ]]; then
  echo "Error: $team_yaml not found." >&2
  exit 1
fi

case "$action" in
  plan|apply|destroy) ;;
  *)
    echo "Error: action must be one of plan, apply, destroy." >&2
    exit 1
    ;;
esac

mkdir -p "$state_dir"
cd "$deploy_dir"

cp demo/backend_override.tf.demo backend_override.tf
cp demo/provider_override.tf.demo provider_override.tf
cleanup() { rm -f backend_override.tf provider_override.tf; }
trap cleanup EXIT

terraform init -input=false -reconfigure

case "$action" in
  plan)
    echo "[DEMO] planning ${team_name} (no real AWS account involved)"
    terraform plan -input=false \
      -state="$state_file" \
      -var="team_config_path=${team_yaml}"
    ;;
  apply)
    echo "[DEMO] simulated apply for ${team_name} — showing the plan a real apply would execute, nothing is actually created"
    terraform plan -input=false \
      -state="$state_file" \
      -var="team_config_path=${team_yaml}"
    ;;
  destroy)
    echo "[DEMO] simulated destroy for ${team_name} — showing the plan a real destroy would execute, nothing is actually destroyed"
    terraform plan -destroy -input=false \
      -state="$state_file" \
      -var="team_config_path=${team_yaml}"
    ;;
esac
