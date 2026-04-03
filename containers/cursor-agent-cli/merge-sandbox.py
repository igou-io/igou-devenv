#!/usr/bin/env python3
"""Merge baked Cursor sandbox config into a workspace sandbox.json.

Usage:
    merge-sandbox.py <baked> <target>

Merges:
- additionalReadwritePaths / additionalReadonlyPaths: union of lists, sorted
- networkPolicy.default: "deny" wins if either side says deny
- networkPolicy.allow / deny: union of lists, sorted
- disableTmpWrite: True wins if baked sets it
"""
import json
import sys


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <baked> <target>", file=sys.stderr)
        sys.exit(1)

    baked_path, target_path = sys.argv[1], sys.argv[2]

    with open(target_path) as f:
        user = json.load(f)
    with open(baked_path) as f:
        baked = json.load(f)

    # Merge path lists
    for key in ("additionalReadwritePaths", "additionalReadonlyPaths"):
        merged = list(set(user.get(key, []) + baked.get(key, [])))
        if merged:
            user[key] = sorted(merged)

    # Merge network policy
    bp = baked.get("networkPolicy", {})
    up = user.setdefault("networkPolicy", {})
    if bp.get("default") == "deny" or up.get("default") == "deny":
        up["default"] = "deny"
    up["allow"] = sorted(set(up.get("allow", []) + bp.get("allow", [])))
    up["deny"] = sorted(set(up.get("deny", []) + bp.get("deny", [])))

    # Boolean flags where True wins
    for key in ("disableTmpWrite",):
        if baked.get(key, False):
            user[key] = True

    with open(target_path, "w") as f:
        json.dump(user, f, indent=2)


if __name__ == "__main__":
    main()
