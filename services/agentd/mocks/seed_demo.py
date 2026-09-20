#!/usr/bin/env python3
"""Load (or clear) the demo profile.

A memory demo that opens on an empty profile spends its first two minutes proving nothing.
This seeds a plausible history so the first question the bird is asked can be answered from
memory — and `--wipe` puts it back to zero so the *earning* of a memory can be demoed too.

    python -m mocks.seed_demo                  # load the demo profile
    python -m mocks.seed_demo --wipe           # empty it
    python -m mocks.seed_demo --show           # print what is remembered
    python -m mocks.seed_demo --file other.json --replace

Seeded facts carry `source: "seed"`, so nothing here can be mistaken later for something the
user actually said.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from agentd.profile import ProfileStore

DEMO = Path(__file__).parent / "profiles" / "demo.json"


def main() -> int:
    parser = argparse.ArgumentParser(description="seed the demo profile")
    parser.add_argument("--file", default=str(DEMO), help="profile JSON to import")
    parser.add_argument("--profile", default=None, help="where to write (default AGENTD_PROFILE)")
    parser.add_argument("--replace", action="store_true", help="drop existing facts first")
    parser.add_argument("--wipe", action="store_true", help="empty the profile and exit")
    parser.add_argument("--show", action="store_true", help="print the profile and exit")
    args = parser.parse_args()

    store = ProfileStore(args.profile)
    if args.wipe:
        print(f"forgot {store.wipe()} facts -> {store.path}")
        return 0
    if args.show:
        print(store.digest() or "(empty)")
        print(f"\n{len(store)} facts at {store.path}")
        return 0

    payload = json.loads(Path(args.file).read_text())
    added = store.import_facts(payload, replace=args.replace)
    print(f"added {added} facts ({len(store)} total) -> {store.path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
