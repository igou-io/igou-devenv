#!/usr/bin/env python3
"""Report the Python and Ansible actually present in a built image."""

import argparse
import importlib.metadata
import json
import pathlib
import platform
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--revision", default="unknown")
parser.add_argument("--image")
parser.add_argument("--digest")
args = parser.parse_args()

owner = subprocess.run(
    ["rpm", "-qf", "--qf", "%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}",
     str(pathlib.Path(sys.executable).resolve())],
    capture_output=True, text=True, check=False,
)
print(json.dumps({
    "python_version": platform.python_version(),
    "python_executable": sys.executable,
    "python_rpm": owner.stdout if owner.returncode == 0 else None,
    "ansible_core_version": importlib.metadata.version("ansible-core"),
    "source_revision": args.revision,
    "image": args.image,
    "image_digest": args.digest or None,
}, sort_keys=True))
