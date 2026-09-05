#!/usr/bin/env python3
"""Validate team.yaml declaration files before they ever reach Terraform.

This mirrors (and duplicates on purpose) the validation rules enforced by
platform-module's variables.tf, but runs in milliseconds with no `terraform
init`, no provider plugins, and no AWS credentials — so CI can reject a
malformed team.yaml on every PR, instantly, before spending time on a plan.
Terraform's own `validation` blocks remain the source of truth / last line
of defense; this script is a fast, cheap first line of defense.

Usage:
    scripts/validate-team-config.py                  # validate every team under teams/
    scripts/validate-team-config.py team-alpha        # validate just one team
    scripts/validate-team-config.py team-alpha team-beta

Exit status is 0 if every checked team is valid, 1 otherwise. All errors
found (across all checked teams) are printed before exiting, rather than
stopping at the first one, so a PR touching multiple teams gets one full
report.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("error: PyYAML is required (`pip install pyyaml`).", file=sys.stderr)
    sys.exit(2)

REPO_ROOT = Path(__file__).resolve().parent.parent
TEAMS_DIR = REPO_ROOT / "teams"

NAME_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$")
BUCKET_NAME_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,40}[a-z0-9])?$")
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
ARN_RE = re.compile(r"^arn:aws[a-zA-Z-]*:iam::\d{12}:(role|user)/.+$")
VALID_VISIBILITIES = {"public", "private"}
ALLOWED_BUCKET_KEYS = {"name", "visibility"}
ALLOWED_TOP_KEYS = {"team", "trusted_principal_arns", "buckets", "tags"}
ALLOWED_TAG_KEYS = {"owner", "cost_center"}


class TeamConfigError(Exception):
    """A collected list of validation failures for one team."""

    def __init__(self, errors: list[str]):
        super().__init__("\n".join(errors))
        self.errors = errors


def discover_team_names() -> list[str]:
    if not TEAMS_DIR.is_dir():
        return []
    return sorted(
        p.name
        for p in TEAMS_DIR.iterdir()
        if p.is_dir() and not p.name.startswith("_")
    )


def load_yaml(path: Path, errors: list[str]) -> dict | None:
    if not path.is_file():
        errors.append(f"{path}: file does not exist")
        return None
    try:
        raw = path.read_text()
    except OSError as e:
        errors.append(f"{path}: could not read file ({e})")
        return None
    try:
        data = yaml.safe_load(raw)
    except yaml.YAMLError as e:
        errors.append(f"{path}: invalid YAML ({e})")
        return None
    if not isinstance(data, dict):
        errors.append(f"{path}: top level must be a YAML mapping, got {type(data).__name__}")
        return None
    return data


def validate_team(team_dir_name: str) -> list[str]:
    errors: list[str] = []
    path = TEAMS_DIR / team_dir_name / "team.yaml"
    data = load_yaml(path, errors)
    if data is None:
        return errors

    unknown_keys = set(data.keys()) - ALLOWED_TOP_KEYS
    if unknown_keys:
        errors.append(f"{path}: unknown top-level key(s): {', '.join(sorted(unknown_keys))}")

    missing_keys = ALLOWED_TOP_KEYS - set(data.keys())
    if missing_keys:
        errors.append(f"{path}: missing required key(s): {', '.join(sorted(missing_keys))}")
        # Without these, the rest of the checks can't run meaningfully.
        return errors

    _validate_team_name(path, data["team"], team_dir_name, errors)
    _validate_trusted_principal_arns(path, data["trusted_principal_arns"], errors)
    _validate_buckets(path, data["buckets"], errors)
    _validate_tags(path, data["tags"], errors)

    return errors


def _validate_team_name(path: Path, team, dir_name: str, errors: list[str]) -> None:
    if not isinstance(team, str):
        errors.append(f"{path}: 'team' must be a string, got {type(team).__name__}")
        return
    if not NAME_RE.match(team):
        errors.append(
            f"{path}: 'team' value \"{team}\" must be lowercase alphanumeric/hyphen, 1-32 chars"
        )
    if team != dir_name:
        errors.append(
            f"{path}: 'team' value \"{team}\" must match its directory name \"{dir_name}\""
        )


def _validate_trusted_principal_arns(path: Path, arns, errors: list[str]) -> None:
    if not isinstance(arns, list) or not arns:
        errors.append(f"{path}: 'trusted_principal_arns' must be a non-empty list")
        return
    for arn in arns:
        if not isinstance(arn, str) or not ARN_RE.match(arn):
            errors.append(
                f"{path}: 'trusted_principal_arns' entry {arn!r} is not a valid IAM role/user ARN"
            )


def _validate_buckets(path: Path, buckets, errors: list[str]) -> None:
    if not isinstance(buckets, list) or not buckets:
        errors.append(f"{path}: 'buckets' must be a non-empty list")
        return

    seen_names: set[str] = set()
    for i, bucket in enumerate(buckets):
        label = f"buckets[{i}]"
        if not isinstance(bucket, dict):
            errors.append(f"{path}: {label} must be a mapping with 'name' and 'visibility'")
            continue

        unknown = set(bucket.keys()) - ALLOWED_BUCKET_KEYS
        if unknown:
            errors.append(f"{path}: {label} has unknown key(s): {', '.join(sorted(unknown))}")

        missing = ALLOWED_BUCKET_KEYS - set(bucket.keys())
        if missing:
            errors.append(f"{path}: {label} is missing required key(s): {', '.join(sorted(missing))}")
            continue

        name = bucket["name"]
        visibility = bucket["visibility"]

        if not isinstance(name, str) or not BUCKET_NAME_RE.match(name):
            errors.append(
                f"{path}: {label}.name {name!r} must be lowercase alphanumeric/hyphen, 1-42 chars"
            )
        elif name in seen_names:
            errors.append(f"{path}: duplicate bucket name \"{name}\"")
        else:
            seen_names.add(name)

        # No default is intentional: visibility must be exactly "public" or
        # "private", spelled exactly that way, every time.
        if visibility not in VALID_VISIBILITIES:
            errors.append(
                f"{path}: {label}.visibility {visibility!r} must be exactly "
                f"\"public\" or \"private\" — there is no default"
            )


def _validate_tags(path: Path, tags, errors: list[str]) -> None:
    if not isinstance(tags, dict):
        errors.append(f"{path}: 'tags' must be a mapping")
        return

    unknown = set(tags.keys()) - ALLOWED_TAG_KEYS
    if unknown:
        errors.append(f"{path}: 'tags' has unknown key(s): {', '.join(sorted(unknown))}")

    missing = ALLOWED_TAG_KEYS - set(tags.keys())
    if missing:
        errors.append(f"{path}: 'tags' is missing required key(s): {', '.join(sorted(missing))}")
        return

    owner = tags["owner"]
    if not isinstance(owner, str) or not EMAIL_RE.match(owner):
        errors.append(f"{path}: tags.owner {owner!r} must be a valid email address")

    cost_center = tags["cost_center"]
    if not isinstance(cost_center, str) or not cost_center.strip() or cost_center == "CHANGE-ME":
        errors.append(f"{path}: tags.cost_center must be set to a real cost center code")


def main(argv: list[str]) -> int:
    team_names = argv if argv else discover_team_names()

    if not team_names:
        print(f"No teams found under {TEAMS_DIR}")
        return 0

    all_errors: list[str] = []
    for name in team_names:
        team_dir = TEAMS_DIR / name
        if not team_dir.is_dir():
            all_errors.append(f"teams/{name}: no such team directory")
            continue
        all_errors.extend(validate_team(name))

    if all_errors:
        print(f"Found {len(all_errors)} problem(s):\n", file=sys.stderr)
        for err in all_errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    print(f"OK: {len(team_names)} team config(s) valid.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
