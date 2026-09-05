# bootstrap

Creates the shared state backend every team's `deploy/main.tf` points at:
one S3 bucket (versioned, encrypted, private) for state, and one DynamoDB
table for locking. Run once by the platform team, before onboarding the
first team.

```bash
cd bootstrap
tflocal init
tflocal apply
```

(plain `terraform` instead of `tflocal` against real AWS.)

This config has its own local state — there's no shared backend to use yet,
since this is the thing that creates it. Keep that local state file
somewhere safe, or move it to a backend of its own after the first apply.

Every team's `deploy/` then points at the bucket/table this creates via
`-backend-config`, with a state key unique to that team — see
[`../scripts/run-team.sh`](../scripts/run-team.sh).
