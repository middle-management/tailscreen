#!/usr/bin/env python3
"""Gate for the parts of the release workflow that only ever run on a release.

Two bugs shipped in v0.10.0-rc.1, and neither could have been caught by any
existing check, because the paths they live on are not exercised by a PR:

  1. `macos` was the only job with `needs: [version, unlabel]`. `unlabel` runs
     only on `pull_request`, so on a `release` event it is SKIPPED — and a
     skipped need propagates, so the macOS job silently skipped too. The
     release published with no macOS app and nothing red to explain it.

  2. `linux-upload` downloads an artifact and calls `gh release upload`, but
     never checks out the repository. `gh` resolves owner/repo from the git
     remote, so it died with "not a git repository" before uploading anything.

Both are wiring, both are decidable by reading the YAML, and both are exactly
the kind of thing a person reads past. So: read the YAML.

Run: scripts/test-release-wiring.py
"""

import pathlib
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - the CI step installs it first
    sys.exit("PyYAML is required: pip install pyyaml")

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOWS = ROOT / ".github" / "workflows"

failures: list[str] = []


def check(condition: bool, message: str) -> None:
    if not condition:
        failures.append(message)


def if_text(node: dict) -> str:
    """A job's `if:` as one flat string, or '' when it has none."""
    return " ".join(str(node.get("if", "")).split())


def runs_on_release(cond: str) -> bool:
    """Does this job run when the workflow fires for a published release?"""
    if not cond:
        return True  # no condition at all — runs for every trigger
    return "github.event_name != 'pull_request'" in cond


def requires_pull_request(cond: str) -> bool:
    """Is this job gated to pull_request events only?"""
    if not cond:
        return False
    return (
        "github.event_name == 'pull_request'" in cond
        and "github.event_name != 'pull_request'" not in cond
    )


def needs_of(job: dict) -> list[str]:
    needs = job.get("needs", [])
    return [needs] if isinstance(needs, str) else list(needs)


# ---------------------------------------------------------------------------
# 1. A job that must run on a release may not depend on a PR-only job.
#
# GitHub propagates SKIPPED through `needs` unless the dependent job's `if`
# uses a status function, so this is silent: no failure, no annotation, just a
# deliverable that never got built.
# ---------------------------------------------------------------------------
release = yaml.safe_load((WORKFLOWS / "release.yml").read_text())
jobs = release["jobs"]

for name, job in jobs.items():
    cond = if_text(job)
    if not runs_on_release(cond):
        continue
    for need in needs_of(job):
        need_cond = if_text(jobs.get(need, {}))
        check(
            not requires_pull_request(need_cond),
            f"release.yml: job '{name}' runs on a release but needs '{need}', "
            f"which is pull_request-only — '{name}' will be silently SKIPPED",
        )

# A release must actually produce all three platforms. Named explicitly so
# that deleting a job is a deliberate act rather than a quiet regression.
for required in ("macos", "linux", "windows"):
    check(required in jobs, f"release.yml: no '{required}' job")
    check(
        runs_on_release(if_text(jobs.get(required, {}))),
        f"release.yml: job '{required}' does not run on a published release",
    )

# ---------------------------------------------------------------------------
# 2. `gh release upload` needs to know which repository it is talking to.
#
# It infers that from the git remote, so a job that never checked out the repo
# must pass --repo. This one at least fails loudly — but it fails AFTER the
# 25-minute build that produced the artifact.
# ---------------------------------------------------------------------------
for path in sorted(WORKFLOWS.glob("*.yml")):
    doc = yaml.safe_load(path.read_text())
    for name, job in (doc.get("jobs") or {}).items():
        steps = job.get("steps") or []
        checks_out = any("actions/checkout" in str(s.get("uses", "")) for s in steps)
        for step in steps:
            run = str(step.get("run", ""))
            if "gh release upload" not in run:
                continue
            check(
                checks_out or "--repo" in run,
                f"{path.name}: job '{name}' calls `gh release upload` without "
                f"checking out the repo and without --repo — gh cannot resolve "
                f"owner/repo and exits before uploading",
            )

# ---------------------------------------------------------------------------
if failures:
    for f in failures:
        print(f"FAIL  {f}")
    print(f"\nrelease-wiring: {len(failures)} check(s) FAILED")
    sys.exit(1)

print("release-wiring: all checks passed")
