#!/usr/bin/env bash
# No server credentials or network required. Also run against the plain image
# with an arbitrary UID and writable HOME to catch lifecycle-hook dependencies.
set -euo pipefail

omnigent --version
omnigent host --help >/dev/null

/opt/omnigent/bin/python - <<'PY'
import inspect
import sys
from importlib.metadata import version

from websockets.asyncio.client import connect

assert sys.prefix == "/opt/omnigent", sys.prefix
assert version("omnigent-client") == version("omnigent")
assert version("omnigent-ui-sdk") == version("omnigent")
assert inspect.signature(connect).parameters["proxy"].default is True
print("Omnigent SDKs match; WebSocket client defaults to environment proxy support")
PY

# Reject additional dependency conflicts while documenting the one tested
# override. A future upstream fix can remove both this exception and the
# second requirements file/install step.
if check=$(/opt/omnigent/bin/pip check 2>&1); then
    echo "Omnigent dependencies are consistent"
elif [[ "$check" == "omnigent 0.15.0 has requirement websockets<15,>=10.4, but you have websockets 15.0.1." ]]; then
    echo "Only the documented OpenShell websockets override is present"
else
    printf '%s\n' "$check" >&2
    exit 1
fi
