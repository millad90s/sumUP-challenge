# Design Q&A

Short answers to the review criteria, pointing at where each thing actually
lives in the code.

## Module design
Clean and single-purpose: `platform-terraform-modules` takes 7 inputs
(`company_prefix`, `team`, `buckets`, `owner_email`, `cost_center`,
`trusted_principal_arns`, `force_destroy`) and outputs `role_arn`,
`bucket_names`, `public_bucket_names`. No provider/backend config inside
it — the caller (`deploy/main.tf`) owns that, so the module is reusable
across environments without editing it. Naming, tagging, and security
defaults are all enforced *inside* the module, not left to caller
discipline.

## Scalability
Adding team #301 means adding one `team.yaml` file — zero Terraform code
changes, zero shared-file edits. `deploy/main.tf` is identical for every
team; only the state key and `team_config_path` differ per run
(`-backend-config`, `-var`). CI mirrors this: a change to N teams runs as N
independent, parallel jobs (`strategy.matrix`), so cost/runtime scale with
the size of a change, not the size of the fleet.

## Security
- IAM trust policy: only `trusted_principal_arns` (per team, explicit) can
  assume the role — never a wildcard.
- IAM permission policy: `Resource` list is built from
  `[for b in aws_s3_bucket.this : b.arn]` — the actual buckets *this*
  module invocation created, never a `prefix-team-*` pattern. A manually
  created bucket that happens to match a naming pattern can't silently
  grant access.
- Public buckets are opt-in only (`visibility: "public"`, no default). Even
  then, only `block_public_policy`/`restrict_public_buckets` relax — ACLs
  stay blocked always, and the public grant is `s3:GetObject`-only via an
  explicit bucket policy, never a public ACL.
- Every bucket, public or private, denies non-TLS access
  (`aws:SecureTransport: false` → Deny) and gets SSE + versioning.

## State isolation
One shared S3 bucket + one DynamoDB lock table (created once by
`bootstrap/`), but every team gets its own state **key**:
`teams/<team>/terraform.tfstate`. Chosen over one-bucket-per-team because
it avoids operating/monitoring 300 buckets (versioning, encryption, IAM,
lifecycle rules × 300) for what's fundamentally one concern — and S3 keys +
DynamoDB lock rows are independent, so one team's apply/lock can never
touch another's state.

## Developer experience
A team never touches Terraform. Onboarding is: write one `team.yaml`
(buckets + visibility + trusted principals + tags), open a PR. CI plans it
and comments the result back; merge applies it. `validate-team-config.py`
rejects a malformed file in milliseconds, before any `terraform init` is
even attempted, so mistakes are caught fast.

**Next step for DX: Backstage.** Even a PR against a YAML file is still a
git workflow — a developer has to know the repo, the file path, and the
schema. A [Backstage](https://backstage.io) portal in front of this repo
removes that: a developer logs in through the company's central IdP (SSO —
no separate credentials), picks a self-service "Create S3 bucket" /
"Onboard team" template, fills in a form (team name, bucket names,
visibility, owner), and Backstage opens the PR against `teams/<team>/team.yaml`
on their behalf. This repo's pipeline (`validate` → `plan` → `apply`) needs
no changes to support that — it already just reacts to a PR touching
`teams/**`, regardless of whether a human or a Backstage template authored
it. It also gives the platform team a software catalog view of every
onboarded team and their resources, instead of that living only as
scattered YAML files.

## CI/CD thinking
`scripts/detect-changed-teams.sh` diffs two git refs under `teams/*`, and
prints just the team names that changed. That list is split into `active`
(file still exists → plan/apply) vs `removed` (file gone → destroy), then
fed into a GitHub Actions `matrix` so each team plans/applies/destroys in
its own parallel job. A PR only ever plans (safe on untrusted branches); a
merge to `main` applies; a removed `team.yaml` always triggers a destroy
plan, gated separately from routine applies.

## Testing
`terraform test` (`tests/*.tftest.hcl`) against a fake/unauthenticated AWS
provider (`skip_credentials_validation`, dummy creds) — no real AWS account
needed. `aws_iam_policy_document` and other local computation is asserted
on for real (it's not a mocked provider call); AWS-API-backed resources
(the bucket itself, its ARN) are faked via `override_resource` since their
values are unknown without a real account. Covers: naming convention,
public/private posture, least-privilege IAM resource scoping, and
validation-rule rejections (bad visibility, duplicate names, empty bucket
list, no trusted principals, oversized composed bucket name). Static
scanning (Trivy, advisory) runs in CI alongside it.

## Code quality
Every non-obvious decision has an inline comment explaining *why*, not
*what* (e.g. why `for_each` over `count`, why the IAM resource list is
built from real resources not a pattern). READMEs at the root and in each
subdirectory (`teams/`, `bootstrap/`) explain layout and flow without
needing to read every file first.

---

## Bonus: team offboarding

Two different things need two different treatments:

**The config file** — archived, not deleted. Move
`teams/<team>/team.yaml` to `teams/_offboarded/<team>/team.yaml` in the
same PR. `git diff` still sees it disappear from its live path (so the
pipeline's `destroy` job still fires), but the record of what that team
had isn't lost to `git log` archaeology. `_offboarded/` is excluded from
every team-detection script, so an archived file is never mistaken for a
live team.

**The infrastructure** — never one step. Destroying the IAM role/policy is
safe to automate immediately (cheap to recreate if it's a mistake).
Destroying the S3 buckets — and whatever data is in them — should only
happen after a human approval and, ideally, a retention window, never
automatically in the same run that revokes access. `force_destroy`
defaults to `false` for exactly this reason: Terraform refuses to delete a
non-empty bucket unless a human explicitly opts in.
