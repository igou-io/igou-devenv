#!/usr/bin/env python3
"""Merge baked JSON config into a user config file.

Usage:
    merge-config.py <baked> <target> [--key KEY]

Without --key: deep-merges all top-level keys from baked into target.
  - dict values are merged (baked takes precedence)
  - non-dict values are overwritten

With --key KEY: only merges the specified key from baked into target,
  using dict.update() (shallow merge within that key).
"""
import argparse
import json
import sys


def main():
    parser = argparse.ArgumentParser(description="Merge baked JSON config into user config")
    parser.add_argument("baked", help="Path to baked config file")
    parser.add_argument("target", help="Path to user config file (modified in place)")
    parser.add_argument("--key", help="Only merge this top-level key (shallow update)")
    args = parser.parse_args()

    with open(args.target) as f:
        user = json.load(f)
    with open(args.baked) as f:
        baked = json.load(f)

    if args.key:
        # Shallow merge of a single key (e.g. mcpServers)
        user.setdefault(args.key, {}).update(baked.get(args.key, {}))
    else:
        # Deep merge: dict values are merged, others overwritten
        for key, val in baked.items():
            if isinstance(val, dict) and isinstance(user.get(key), dict):
                user[key].update(val)
            else:
                user[key] = val

    with open(args.target, "w") as f:
        json.dump(user, f, indent=2)


if __name__ == "__main__":
    main()
