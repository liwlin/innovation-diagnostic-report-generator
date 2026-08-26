# Image and Release Evidence Summary

Published image:

- Tag: `ghcr.io/liwlin/innovation-diagnostic-report-generator:0.1.0`
- Index digest: `sha256:996d991c215fc30f62ea782315b76d093cda0d8da98fd058fea2a60e6c4ca718`
- Linux/amd64 manifest digest: `sha256:256eea792348d1a576b628b2e48e9fbfcd844ea2745df91003becec420948cc3`
- Config digest: `sha256:2cef241b6cc638cb7dd1703a2444904c8690c7e8c931a0a9dd4dcb4bb3c45dba`
- Layers: 14
- User: `10001:10001`
- CMD: Uvicorn `makerseed_app.main:app`, one worker, no access log
- Version/commit labels and environment: `v0.1.0` / `ddc9164bfd8320d9a56bfa4f2124c5253a64d6c0`

Registry proof:

- GHCR manifest HEAD for tag `0.1.0` returned HTTP 200.
- `Docker-Content-Digest` matched `sha256:996d991c215fc30f62ea782315b76d093cda0d8da98fd058fea2a60e6c4ca718`.
- GitHub Packages REST query returned 403 because local `gh` lacks `read:packages`; registry digest proof still succeeded.

Release artifacts:

- `release-manifest.json` SHA-256: `b6fa5342a6d78f2eae0d8cf7fff03dea86c0a89a9a82495a886352ad8207fa3`
- `sbom.cdx.json` SHA-256: `fc020f7306905e28363418ffd68b9318bfd41aed9611e16c4adedbba1caae1d6`
- SBOM: CycloneDX 1.6, 153 components, subject exact image digest
- Vulnerability gate: HIGH/CRITICAL fixed-vulnerability scan passed in release run

Provenance:

- `gh attestation verify oci://ghcr.io/liwlin/innovation-diagnostic-report-generator@sha256:996d991c215fc30f62ea782315b76d093cda0d8da98fd058fea2a60e6c4ca718 --repo liwlin/innovation-diagnostic-report-generator --signer-workflow liwlin/innovation-diagnostic-report-generator/.github/workflows/release.yml --source-digest ddc9164bfd8320d9a56bfa4f2124c5253a64d6c0 --source-ref refs/tags/v0.1.0 --deny-self-hosted-runners --format json` returned exit 0.
- SLSA provenance v1 subject is the exact index digest.
- Source digest/ref are `ddc9164bfd8320d9a56bfa4f2124c5253a64d6c0` and `refs/tags/v0.1.0`.

Layer inspection:

- All 14 layers downloaded to ignored scratch, about 92 MiB total.
- Every layer SHA matched.
- 10,420 paths inspected.
- Path traversal findings: 0.
- Expected `index.html`, logos, shared runtime, vendor React, and Alembic files present.
- Secret pattern matches: 0.
- Project tests/docs/deploy/.git/.env/secrets absent.
- Third-party `greenlet` package tests exist under `.venv`; this is a minor slimming item, not project test leakage or a secret finding.

Boundary: this proves the published release image contents and provenance, not NAS runtime execution.