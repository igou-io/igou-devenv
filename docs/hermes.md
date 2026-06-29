# Hermes Runtime Validation

Hermes uses its own rootless Podman container through the Hermes docker terminal
setting. This repo may or may not be the image Hermes enters. Validate the
actual Hermes-entered container before making capability claims.

## What To Check

Inside the Hermes-entered container:

```bash
command -v bwrap
bwrap --version
command -v rg
rg --version
command -v unshare
unshare --version
command -v socat
socat -V
cat /proc/self/uid_map
cat /proc/self/gid_map
```

If this repo is present in that container, run:

```bash
tests/test-sandbox-primitives.sh
```

When Hermes must provide these primitives, run:

```bash
REQUIRE_SANDBOX_PRIMITIVES=true tests/test-sandbox-primitives.sh
```

Record which checks pass or fail in the context of the specific image tag and
Hermes docker terminal configuration being tested.

## Interpretation

- Missing commands are image dependency problems. Patch the image Hermes
  actually enters.
- `unshare -Ur true` failures are runtime/user-namespace restrictions.
- bubblewrap failures may be package, user-namespace, mount-namespace, seccomp,
  or container runtime restrictions.
- OpenCode permissions do not provide OS isolation. The outer Hermes container
  remains the primary isolation boundary.
