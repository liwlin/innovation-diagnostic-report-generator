# Image and Release Gates

Local state:

- `docker version` returned client version 29.7.2 but could not connect to the Docker Desktop Linux engine.
- `gh api /users/liwlin/packages/container/innovation-diagnostic-report-generator/versions` returned `Package not found`.
- `git tag --points-at HEAD` returned no tag.
- `gh release list --repo liwlin/innovation-diagnostic-report-generator --limit 20` returned no releases.

Static inspection:

- `deploy/Dockerfile` uses a digest-pinned Python base, OCI labels, UID/GID `10001`, CJK font installation, cache cleanup, copied static assets, and Uvicorn one-worker CMD.
- `deploy/compose.yaml` uses digest-pinned images, `app` plus `db` only, loopback app port, no DB host port, read-only roots, dropped capabilities, no-new-privileges, bounded resources, tmpfs, explicit secrets, and internal networking.
- `.github/workflows/release.yml` publishes only on immutable `v*` SemVer tags or explicit dispatch against such a tag, re-runs verification, pushes SemVer and commit-SHA GHCR tags, generates SBOM, scans HIGH/CRITICAL vulnerabilities, attests provenance, and writes a release manifest.

Required before Task 7:

- Tag and run release workflow from the reviewed commit.
- Capture GHCR digest, SBOM, vulnerability verdict, provenance, and release manifest.
- Inspect published image user, entrypoint/CMD, labels, embedded version/revision, layers for secret names/content, and expected static assets.
