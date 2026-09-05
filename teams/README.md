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

This runs `deploy/` against a local, credential-free backend, with state for
`team-alpha` kept isolated in its own file under `deploy/.demo-state/` —
giving fully isolated state per team from one shared root module, without
needing a real AWS account. `apply` and `destroy` compute and print the plan
that action would run rather than executing it against real infrastructure
(see the comment at the top of `run-team.sh`).

## Offboarding

Delete `teams/<team-name>/`. The CI pipeline detects the removed directory
and runs `scripts/run-team.sh <team-name> destroy` against that team's
isolated state — see [`.github/workflows/teams-pipeline.yml`](../.github/workflows/teams-pipeline.yml)
(`destroy` job) for the approval gate a real deployment would require on
that step.

## Changes to `deploy/`

A change to `deploy/main.tf` (e.g. bumping the pinned module `ref`) affects
every team's plan at once, unlike a `teams/**` change which only affects
the one team that edited its own file. That's checked separately by
[`.github/workflows/deploy-checks.yml`](../.github/workflows/deploy-checks.yml)
(`terraform fmt`/`validate` plus an advisory Trivy scan) rather than by this
workflow.
