#!/usr/bin/env python3
"""Reject publishing with a personal actor or personal Git commit identity.

This guard cannot hide the actor of a run that has already been triggered.
The push/dispatch must itself use a dedicated GitHub App or bot credential.
"""

import os
import subprocess
import sys


def fail(message: str) -> None:
    print(f"::error::{message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    for key in ("RELEASE_ACTOR", "RELEASE_TRIGGERING_ACTOR"):
        if not os.environ.get(key, "").endswith("[bot]"):
            fail("Publishing requires a GitHub App/bot for both actor and triggering actor")
    if not os.environ.get("RELEASE_TAG", "").strip():
        fail("Publishing requires an explicit version tag")

    identity = subprocess.check_output(
        ["git", "show", "-s", "--format=%an%n%ae%n%cn%n%ce", "HEAD"],
        text=True,
    ).splitlines()
    permitted = {
        ("Anonymous", "anonymous@users.noreply.github.com"),
        ("github-actions[bot]", "41898282+github-actions[bot]@users.noreply.github.com"),
    }
    if len(identity) != 4 or any(
        tuple(identity[offset:offset + 2]) not in permitted for offset in (0, 2)
    ):
        fail("Publishing requires an anonymous or GitHub Actions bot commit identity")
    print("Release actor and commit identity checks passed")


if __name__ == "__main__":
    main()
