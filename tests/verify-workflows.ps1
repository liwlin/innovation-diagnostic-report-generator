$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$workflowRoot = Join-Path $projectRoot '.github/workflows'
$ciPath = Join-Path $workflowRoot 'ci.yml'
$releasePath = Join-Path $workflowRoot 'release.yml'
$dockerfilePath = Join-Path $projectRoot 'deploy/Dockerfile'

function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Read-RequiredWorkflow {
    param([string]$Path, [string]$Name)
    Assert-Condition (Test-Path -LiteralPath $Path -PathType Leaf) "Missing workflow: $Name"
    Get-Content -LiteralPath $Path -Raw -Encoding UTF8
}

function Assert-PinnedActions {
    param([string]$Source, [string]$Name)

    $usesMatches = [regex]::Matches($Source, '(?m)^\s*uses:\s*[''"]?([^''"\s#]+)')
    Assert-Condition ($usesMatches.Count -gt 0) "$Name has no action uses entries."
    foreach ($match in $usesMatches) {
        $value = $match.Groups[1].Value
        Assert-Condition ($value -notmatch '^docker://') "$Name uses a docker action reference instead of a pinned action: $value"
        Assert-Condition ($value -match '@') "$Name action is missing an explicit ref: $value"
        $ref = ($value -split '@')[-1]
        Assert-Condition ($ref -match '^[0-9a-f]{40}$') "$Name action is not pinned to a full 40-character commit SHA: $value"
    }
}

function Assert-WorkflowCommonPolicy {
    param([string]$Source, [string]$Name)

    Assert-Condition ($Source -notmatch 'pull_request_target') "$Name must not use pull_request_target."
    Assert-PinnedActions -Source $Source -Name $Name
    Assert-Condition ($Source -match '(?ms)^permissions:\s*\r?\n\s+contents:\s+read\s*(?:\r?\n(?!\S).*)?') "$Name must default to contents: read."
    $withoutRunnerLabels = $Source -replace '(?m)^\s*runs-on:\s+ubuntu-latest\s*$', ''
    Assert-Condition ($withoutRunnerLabels -notmatch '(?m)(^|[\s''"])[a-z0-9][a-z0-9._/-]*:[Ll][Aa][Tt][Ee][Ss][Tt]([\s''"]|$)') "$Name must not publish or depend on latest container tags."
}

$ci = Read-RequiredWorkflow -Path $ciPath -Name 'ci.yml'
$release = Read-RequiredWorkflow -Path $releasePath -Name 'release.yml'
Assert-Condition (Test-Path -LiteralPath $dockerfilePath -PathType Leaf) 'deploy/Dockerfile is missing.'
$dockerfile = Get-Content -LiteralPath $dockerfilePath -Raw -Encoding UTF8
$indexPath = Join-Path $projectRoot 'index.html'
Assert-Condition (Test-Path -LiteralPath $indexPath -PathType Leaf) 'index.html is missing.'
$index = Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8

Assert-WorkflowCommonPolicy -Source $ci -Name 'ci.yml'
Assert-WorkflowCommonPolicy -Source $release -Name 'release.yml'
Assert-Condition (($ci + $release + $dockerfile) -notmatch 'fonts-noto-cjk|NotoSansCJK') 'Workflows and Dockerfile must not use incompatible Noto CJK CFF fonts.'

Assert-Condition ($ci -match '(?ms)on:\s*\r?\n\s+push:\s*\r?\n\s+pull_request:\s*\r?\n\s+workflow_dispatch:') 'CI must run on push, pull_request, and workflow_dispatch.'
Assert-Condition ($ci -notmatch 'packages:\s+write') 'CI and PR checks must not grant package write permissions.'
foreach ($token in @(
    'uv run --project server pytest',
    'uv run --project server ruff check',
    'uv run --project server mypy server/src/makerseed_app',
    'node --test',
    'tests/verify-static-site.ps1',
    'tests/verify-compose-security.ps1',
    'tests/verify-deploy-scripts.ps1',
    'tests/linux/verify-bootstrap-preflight.sh',
    'tests/linux/verify-first-install-admin.sh',
    'MKSEED_EPHEMERAL_VOLUME1_TEST=1',
    'tests/verify-workflows.ps1',
    'fonts-wqy-zenhei',
    'git grep',
    'push: false',
    'cache-dependency-path: server/uv.lock'
)) {
    Assert-Condition ($ci -like "*$token*") "CI is missing required check or policy token: $token"
}
Assert-Condition ($ci -match '(?ms)docker-build:.*needs:\s*\[[^\]]*python[^\]]*node[^\]]*static[^\]]*policy[^\]]*secret') 'CI Docker build must depend on all test, static, policy, and secret checks.'

Assert-Condition ($release -match '(?ms)on:\s*\r?\n\s+push:\s*\r?\n\s+tags:\s*\r?\n\s+- [''"]?v\*[''"]?\s*\r?\n\s+workflow_dispatch:') 'Release must run only on v* tags or explicit workflow_dispatch.'
Assert-Condition ($release -notmatch '(?ms)on:\s*\r?\n\s+push:\s*\r?\n\s+branches:') 'Release must not run on branch pushes.'
Assert-Condition ($release -notmatch '(?ms)workflow_dispatch:\s*\r?\n\s+inputs:') 'Manual release dispatch must not accept free-form version inputs.'
Assert-Condition ($release -notmatch '\$\{\{\s*inputs\.version\s*\}\}') 'Release version must never come from workflow_dispatch input.'
foreach ($token in @(
    'github.ref_type',
    'github.ref_name',
    'git rev-list -n 1',
    '${{ github.sha }}',
    'outputs:',
    'semver: ${{ steps.version.outputs.semver }}',
    'needs.verify.outputs.semver'
)) {
    Assert-Condition ($release -like "*$token*") "Release must derive and share SemVer from the immutable v* tag commit: $token"
}
foreach ($token in @(
    'uv run --project server pytest',
    'uv run --project server ruff check',
    'uv run --project server mypy server/src/makerseed_app',
    'node --test',
    'tests/verify-static-site.ps1',
    'tests/verify-compose-security.ps1',
    'tests/verify-deploy-scripts.ps1',
    'tests/linux/verify-bootstrap-preflight.sh',
    'tests/linux/verify-first-install-admin.sh',
    'MKSEED_EPHEMERAL_VOLUME1_TEST=1',
    'tests/verify-workflows.ps1',
    'fonts-wqy-zenhei',
    'ghcr.io/liwlin/innovation-diagnostic-report-generator:${{ needs.verify.outputs.semver }}',
    'ghcr.io/liwlin/innovation-diagnostic-report-generator:${{ needs.verify.outputs.release_sha }}',
    'ghcr.io/liwlin/innovation-diagnostic-report-generator@${{ steps.docker_build.outputs.digest }}',
    'exit-code: ''1''',
    'ignore-unfixed: true',
    'severity: HIGH,CRITICAL',
    'vuln-type: os,library',
    'format: cyclonedx',
    'sbom.cdx.json',
    'actions/attest-build-provenance@',
    'push-to-registry: true',
    'release-manifest.json',
    'pages_commit =',
    'nas_image_digest =',
    'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a',
    'if-no-files-found: error',
    'retention-days:',
    'release-evidence',
    'sbom.cdx.json',
    'release-manifest.json'
)) {
    Assert-Condition ($release -like "*$token*") "Release is missing required release gate or artifact token: $token"
}
Assert-Condition ($release -match '(?ms)publish-image:.*needs:\s*\[[^\]]*verify[^\]]*pages-artifact') 'Release image publishing must wait for re-verification and the Pages artifact.'
Assert-Condition ($release -match '(?ms)pages-artifact:.*permissions:\s*\r?\n\s+contents:\s+read\s*\r?\n\s+pages:\s+write\s*\r?\n\s+id-token:\s+write') 'Pages job must use only contents/pages/id-token permissions.'
Assert-Condition ($release -match '(?ms)publish-image:.*permissions:\s*\r?\n\s+contents:\s+read\s*\r?\n\s+packages:\s+write\s*\r?\n\s+attestations:\s+write\s*\r?\n\s+id-token:\s+write') 'Image publishing job must scope GHCR and attestation permissions to that job.'

$pagesRequired = @(
    'Copy-Item -LiteralPath index.html',
    'Copy-Item -LiteralPath 科创方向诊断报告生成器.dc.html',
    'Copy-Item -LiteralPath support.js',
    'Copy-Item -LiteralPath doc-page.js',
    'Copy-Item -LiteralPath assets',
    'Copy-Item -LiteralPath shared',
    'Copy-Item -LiteralPath vendor'
)
foreach ($token in $pagesRequired) {
    Assert-Condition ($release -like "*$token*") "Pages artifact is missing allowlisted path copy: $token"
}
Assert-Condition ($release -notmatch 'Copy-Item[^\r\n]*(server|deploy|nas-web|secrets|\.env)') 'Pages artifact must not copy server, deploy, NAS runtime, secrets, or env data.'
Assert-Condition ($release -notmatch 'path:\s*\.') 'Pages artifact must not upload the repository root.'
Assert-Condition ($release -match 'path:\s+\$\{\{\s*runner\.temp\s*\}\}/pages-artifact') 'Pages upload must use the explicit allowlisted artifact directory.'
Assert-Condition ($index -notmatch 'content=""') 'Root Pages metadata must not contain blank placeholders.'
Assert-Condition ($index -match 'makerseed-app-version') 'Root Pages metadata must expose the local-mode app version.'
Assert-Condition ($index -match 'makerseed-commit-sha') 'Root Pages metadata must expose the source commit.'
Assert-Condition ($index -match '版本') 'Root Pages entry must show version metadata visibly.'
Assert-Condition ($release -match 'makerseed-app-version') 'Release Pages artifact must render the version into root metadata.'
Assert-Condition ($release -match 'makerseed-commit-sha') 'Release Pages artifact must render the commit into root metadata.'
Assert-Condition ($release -match 'Substring\(0,\s*7\)') 'Release Pages artifact must render a short visible commit.'

foreach ($token in @(
    'ARG APP_VERSION=dev',
    'ARG COMMIT_SHA=unknown',
    'org.opencontainers.image.version="${APP_VERSION}"',
    'org.opencontainers.image.revision="${COMMIT_SHA}"',
    'MKSEED_APP_VERSION="${APP_VERSION}"',
    'MKSEED_COMMIT_SHA="${COMMIT_SHA}"'
)) {
    Assert-Condition ($dockerfile -like "*$token*") "Dockerfile must pass immutable build metadata into labels and runtime settings: $token"
}

Write-Output 'PASS: GitHub workflow policy is pinned, least-privilege, test-gated, and release-scoped.'
