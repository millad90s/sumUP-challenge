# sumUP2

Self-service AWS onboarding platform: each team declares one YAML file
(`teams/<team>/team.yaml`), and CI plans/applies a shared Terraform root
config against it — one IAM role + N S3 buckets per team, fully isolated
state, zero platform code changes per team.

The actual Terraform resources (IAM role + S3 buckets, naming, tagging,
public/private policy) live in a separate, versioned module repo —
[`platform-terraform-modules`](https://github.com/millad90s/sumUp-tf-module) —
pinned by tag in `deploy/main.tf`. This repo only owns *which team gets what*
(the declarations) and *how changes get planned/applied* (the pipeline).

## `bootstrap/`

One-time platform setup, run once before onboarding the first team: creates
the shared S3 bucket (versioned, encrypted, private) and DynamoDB lock table
that every team's `deploy/` backend points at. Has its own local state,
since there's nothing to isolate it in yet — see
[`bootstrap/README.md`](bootstrap/README.md).

## `deploy/`

- **`main.tf`** — the one root config every team's plan/apply runs through.
  It's never edited per team: which team it operates on is decided entirely
  at invocation time, via `-backend-config="key=teams/<team>/terraform.tfstate"`
  and `-var="team_config_path=../teams/<team>/team.yaml"`. It reads that
  team's `team.yaml`, decodes it with `yamldecode()`, and passes the values
  into the `team` module (sourced from `platform-terraform-modules`, pinned
  to a tag — never a branch — so a module change only reaches teams via a
  deliberate, reviewed version bump here). Its `backend "s3"` block names
  the shared bucket/lock table `bootstrap/` creates, but never a specific
  team's state key — that's supplied per run via `-backend-config`.

## `scripts/`

- **`detect-changed-teams.sh <base-ref> <head-ref>`** — diffs two git refs
  under `teams/*`, prints the changed team names (one per line). Used by CI
  to figure out which team(s) a PR/push touched, so a change to one team
  never triggers a plan for every other team.
- **`validate-team-config.py [team ...]`** — validates `team.yaml` files
  against the same rules `platform-terraform-modules`'s Terraform
  `validation` blocks enforce (naming convention, required fields, no
  default `visibility`, valid ARNs/email), but in milliseconds with no
  `terraform init`, so a malformed file is rejected instantly, before any
  plan is attempted.
- **`run-team.sh <team-name> <plan|apply|destroy>`** — the one entry point
  for running Terraform against a team. Runs `tflocal` (not `terraform`)
  against the real backend/provider declared in `deploy/main.tf`, which
  `tflocal` transparently redirects to LocalStack — no real AWS account
  needed, and no separate override files to maintain. Real (non-demo) usage
  is the same commands with plain `terraform` — see the comment at the top
  of the script.

## `teams/`

One directory per team, holding only `team.yaml` — the single file a team
owns. `team.yaml` is created externally (by the team itself, or an
IDP/self-service tool) against the rules `validate-team-config.py` enforces;
nothing here scaffolds it. See [`teams/README.md`](teams/README.md) for the
full contract, onboarding, and offboarding flow.

## GitHub workflows (`.github/workflows/`)

### `teams-pipeline.yml` — per-team plan / apply / destroy

Triggered by anything touching `teams/**`, on `pull_request` and on `push`
to `main`/`master`.

1. **`detect`** — diffs the two refs (`origin/<base>` for a PR, `github.event.before`
   for a push — using `origin/<default>` for a push would diff a commit
   against itself, since by checkout time it already points at the pushed
   commit) via `detect-changed-teams.sh`, then splits the changed team names
   into `active` (directory still exists → onboarded/updated) vs `removed`
   (directory gone → offboarded).
2. **`validate`** — runs `validate-team-config.py` against every `active`
   team, before spending any time on a plan.
3. **`plan`** (PR only) — for every `active` team, in parallel
   (`strategy.matrix`), runs `run-team.sh <team> plan` and posts the output
   as a PR comment.
4. **`apply`** (push to `main`/`master` only) — same fan-out, runs
   `run-team.sh <team> apply` for every `active` team. In a real (non-demo)
   pipeline this job would sit behind a protected `environment` requiring
   reviewer approval.
5. **`destroy`** — runs whenever any team was `removed`, regardless of
   trigger. Checks out the *parent* commit (where the deleted `team.yaml`
   still exists — it's gone at HEAD) and runs `run-team.sh <team> destroy`.
   A real pipeline would gate this behind its own protected environment,
   separate from `apply`'s, so approving a routine bucket addition can never
   also approve someone else's offboarding destroy.

Because each matrix entry is one team with its own isolated state, N changed
teams run as N independent parallel jobs — the pipeline's cost scales with
the size of a change, not the size of the fleet.

### `deploy-checks.yml` — shared root config checks

Triggered by anything touching `deploy/**` (the one file every team's plan
runs through, so a change here can affect every team at once — unlike a
`teams/**` change, which only ever affects one team).

1. **`validate`** — `terraform fmt -check` and `terraform validate` against
   `deploy/main.tf`.
2. **`security-scan`** — a Trivy IaC config scan, advisory only
   (`exit-code 0`): findings are uploaded as SARIF to the repo's Security
   tab rather than blocking the PR, until findings have been triaged and
   it's ready to gate merges.

This is deliberately a separate workflow from `teams-pipeline.yml` — a
`deploy/` change has a different blast radius (every team) and different
approval needs than a single team's `teams/**` change, so it's checked on
its own rather than folded into the per-team fan-out.
