# ADR-0004: Software Bill of Materials (SBOM) Generation

## Status

Accepted

## Date

2026-03-29

## Context

Container images built in this project (devcontainer and Claude container) contain a wide range of tools installed from multiple sources: apt packages, pip packages, binary downloads from GitHub releases, npm packages, and native installers. Tracking what's inside these images is important for security auditing, vulnerability management, and supply chain transparency.

[Syft](https://github.com/anchore/syft) (by Anchore) is already installed on the host and can generate SBOMs from locally-built container images without requiring any cloud services or API calls.

### Requirements

- Generate SBOMs for both the devcontainer and Claude container images
- Use industry-standard formats (SPDX, CycloneDX) for tool compatibility
- Integrate into the existing Makefile workflow
- Run on the host (not inside the container) since syft is a host tool
- Store SBOMs in a gitignored output directory to avoid bloating the repo

## Decision

Add Makefile targets that run `syft` against locally-built images to generate SBOMs in both SPDX JSON and CycloneDX JSON formats. SBOMs are written to `sbom/` (gitignored) and named by image.

### Output formats

Two formats are generated for each image:

| Format | File | Use case |
|---|---|---|
| SPDX JSON | `sbom/<image>.spdx.json` | ISO/IEC 5962 standard, broad compliance tooling support |
| CycloneDX JSON | `sbom/<image>.cdx.json` | OWASP standard, detailed dependency representation |

Both are widely supported by vulnerability scanners (Grype, Trivy, Snyk) and compliance tools.

### Makefile targets

```
make sbom                # Generate SBOMs for all images
make sbom-devcontainer   # SBOM for the devcontainer image
make sbom-claude         # SBOM for the Claude container image
```

SBOMs are generated from the locally-built images using syft's container image source. For the devcontainer, syft reads the Docker/Podman image by name. For the Claude container, syft reads the podman image.

### What syft detects

Syft scans container image layers and identifies packages from:
- apt/dpkg packages (devcontainer)
- RPM/dnf packages (Claude container, via UBI10)
- Python packages (pip-installed in both images)
- npm packages (if node_modules are present)
- Go binaries (kubectl, helm, argocd, etc. — detected by embedded module info)
- Standalone binaries (detected by file metadata where possible)

Binary downloads without embedded package metadata (e.g., `mc`, `oc`) may not appear in the SBOM. The Renovate-managed ARG version pins in the Dockerfile/Containerfile remain the authoritative version record for those tools.

### Storage

SBOMs are generated locally into `sbom/` and gitignored. They are not committed to the repository because:
- They change on every image rebuild (even without code changes, due to timestamps and base image updates)
- They can be regenerated from the image at any time
- Committing them would add noise to the git history

### CI integration (GitHub Actions)

The CI workflow (`.github/workflows/build.yaml`) generates SBOMs for both images on every push and PR using `anchore/sbom-action`:

1. **Artifacts**: SBOMs are uploaded as workflow artifacts (`devcontainer-sbom`, `claude-devenv-sbom`), downloadable from the Actions run page
2. **Dependency graph**: SBOMs are submitted to GitHub's dependency graph API via `dependency-snapshot: true`, enabling Dependabot vulnerability alerts on container contents

The workflow builds both images, runs tests, then generates SBOMs in SPDX JSON format. The `contents: write` permission is required for dependency snapshot submission.

### File layout

```
sbom/                           # gitignored
├── devcontainer.spdx.json
├── devcontainer.cdx.json
├── claude-devenv.spdx.json
└── claude-devenv.cdx.json
```

## Consequences

### Benefits

- **Visibility**: Know exactly what's in each image at the package level
- **Vulnerability scanning**: SBOMs can be fed to Grype, Trivy, or other scanners without re-scanning the image
- **Compliance**: SPDX and CycloneDX are accepted formats for software supply chain requirements
- **No infrastructure needed**: syft runs locally, no cloud services or API keys required
- **Non-intrusive**: Makefile targets are opt-in, no impact on build or test workflows
- **GitHub dependency graph**: Dependabot alerts surface vulnerabilities in container contents automatically
- **CI artifacts**: SBOMs downloadable from every workflow run for audit or external scanning

### Tradeoffs

- **Host dependency**: syft must be installed on the host for local generation. CI uses `anchore/sbom-action` which bundles syft
- **Binary detection gaps**: Standalone binary downloads without embedded metadata may not appear in the SBOM
- **Point-in-time snapshots**: SBOMs reflect the image at generation time, not the running container state
