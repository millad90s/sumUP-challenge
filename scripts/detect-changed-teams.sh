#!/usr/bin/env bash
# Print the names of teams whose teams/<name>/ directory changed between
# two git refs, one per line.
#
# Usage: scripts/detect-changed-teams.sh <base-ref> <head-ref>
#   scripts/detect-changed-teams.sh origin/main HEAD
#
# Used by CI to figure out which team(s) a PR/push touched, so only those
# get planned/applied — a change to team-alpha never triggers a plan for
# the other 299 teams. A change outside teams/ (e.g. platform-module/,
# deploy/) is intentionally NOT reported here — that's a platform-wide
# change and should be handled separately (see the workflow for how it's
# treated).

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <base-ref> <head-ref>" >&2
  exit 1
fi

base_ref="$1"
head_ref="$2"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

git diff --name-only "$base_ref" "$head_ref" -- 'teams/*' \
  | awk -F/ '{ print $2 }' \
  | sort -u
