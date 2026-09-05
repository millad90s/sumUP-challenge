# Teams

One directory per team, holding **only** its declaration:

```
teams/
  team-alpha/
    team.yaml           # the ONLY file team-alpha edits
  team-beta/
    team.yaml
```

There is no per-team Terraform code. The single shared root config lives in
[`../deploy/`](../deploy/) and is pointed at whichever team's `team.yaml` and
state key it should operate on for a given run — see
[`../scripts/run-team.sh`](../scripts/run-team.sh). `deploy/main.tf` never
changes when a team is onboarded, offboarded, or edits its buckets.

## Onboarding a new team

`teams/<team-name>/team.yaml` is created externally — by the team itself or
by an IDP/self-service tool — against the schema `validate-team-config.py`
enforces (see that script for the required shape). No file outside that new
one is touched — the shared module (pinned by tag in `deploy/main.tf`) and
`deploy/` itself are never modified to add a team, so this scales the same
way from 1 team to 300+.

Once `team.yaml` exists (buckets, visibility, trusted principals, tags), the
team opens a PR.

## Running Terraform for one team

```
scripts/run-team.sh team-alpha plan
scripts/run-team.sh team-alpha apply
```

This runs `deploy/` via `tflocal` against LocalStack, using the real S3
backend declared in `deploy/main.tf` with `team-alpha`'s own state key
(`teams/team-alpha/terraform.tfstate` in the shared bucket `bootstrap/`
creates) — giving fully isolated state per team from one shared root
module, without needing a real AWS account. `apply` and `destroy` run for
real against LocalStack (`-auto-approve`) — safe there, but never do that
against a real backend without a human reviewing a saved plan first (see
the comment at the top of `run-team.sh`).

## Offboarding

Remove `teams/<team-name>/team.yaml` so the CI pipeline detects it as
removed and runs `scripts/run-team.sh <team-name> destroy` against that
team's isolated state — see
[`.github/workflows/teams-pipeline.yml`](../.github/workflows/teams-pipeline.yml)
(`destroy` job) for the approval gate a real deployment would require on
that step.

Don't just `rm -rf` the file, though — move it to
`teams/_offboarded/<team-name>/team.yaml` in the same PR (or a prompt
follow-up commit). `teams/_offboarded/` is an archive: `git diff` still
sees the file disappear from its original `teams/<team-name>/` path (so the
`destroy` job still fires), but the record of what that team had — buckets,
trusted principals, tags — isn't lost to `git log` archaeology. It's
excluded from every team-detection script (`detect-changed-teams.sh`,
`validate-team-config.py`), so nothing ever treats an archived file as a
live team.

Real infrastructure teardown should also never be one step: destroying the
team's IAM role/policy is safe to automate immediately (cheap to recreate
if it's a mistake), but the S3 buckets themselves — and whatever data is in
them — should only ever be destroyed after a human approval and, ideally,
a retention window, never automatically in the same run that revokes
access.

## Changes to `deploy/`

A change to `deploy/main.tf` (e.g. bumping the pinned module `ref`) affects
every team's plan at once, unlike a `teams/**` change which only affects
the one team that edited its own file. That's checked separately by
[`.github/workflows/deploy-checks.yml`](../.github/workflows/deploy-checks.yml)
(`terraform fmt`/`validate` plus an advisory Trivy scan) rather than by this
workflow.
