#!/usr/bin/env python3
"""Require anonymous commits; allow personal triggers only by explicit opt-in.

Deleting a completed run does not erase GitHub audit records or notifications.
"""

import os
import subprocess
import sys


def fail(message: str) -> None:
    print(f"::error::{message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    allow_personal = os.environ.get("ALLOW_PERSONAL_TRIGGER") == "true"
    if not allow_personal:
        for key in ("RELEASE_ACTOR", "RELEASE_TRIGGERING_ACTOR"):
            if not os.environ.get(key, "").endswith("[bot]"):
                fail("Publishing requires a bot trigger or explicit personal-trigger opt-in")
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
