$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$workflowRoot = Join-Path $projectRoot '.github/workflows'
$ciPath = Join-Path $workflowRoot 'ci.yml'
$releasePath = Join-Path $workflowRoot 'release.yml'

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
    Assert-Condition ($Source -notmatch '(?m)^\s*(?:tags|image-ref|image|PYTHON_IMAGE):[^\r\n]*:latest(?:\s|$)') "$Name must not publish or depend on latest tags."
}

$ci = Read-RequiredWorkflow -Path $ciPath -Name 'ci.yml'
$release = Read-RequiredWorkflow -Path $releasePath -Name 'release.yml'

Assert-WorkflowCommonPolicy -Source $ci -Name 'ci.yml'
Assert-WorkflowCommonPolicy -Source $release -Name 'release.yml'

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
    'tests/verify-workflows.ps1',
    'git grep',
    'push: false',
    'cache-dependency-path: server/uv.lock'
)) {
    Assert-Condition ($ci -like "*$token*") "CI is missing required check or policy token: $token"
}
Assert-Condition ($ci -match '(?ms)docker-build:.*needs:\s*\[[^\]]*python[^\]]*node[^\]]*static[^\]]*policy[^\]]*secret') 'CI Docker build must depend on all test, static, policy, and secret checks.'

Assert-Condition ($release -match '(?ms)on:\s*\r?\n\s+push:\s*\r?\n\s+tags:\s*\r?\n\s+- [''"]?v\*[''"]?\s*\r?\n\s+workflow_dispatch:') 'Release must run only on v* tags or explicit workflow_dispatch.'
Assert-Condition ($release -notmatch '(?ms)on:\s*\r?\n\s+push:\s*\r?\n\s+branches:') 'Release must not run on branch pushes.'
foreach ($token in @(
    'uv run --project server pytest',
    'uv run --project server ruff check',
    'uv run --project server mypy server/src/makerseed_app',
    'node --test',
    'tests/verify-static-site.ps1',
    'tests/verify-compose-security.ps1',
    'tests/verify-deploy-scripts.ps1',
    'tests/verify-workflows.ps1',
    'ghcr.io/liwlin/innovation-diagnostic-report-generator:${{ steps.version.outputs.semver }}',
    'ghcr.io/liwlin/innovation-diagnostic-report-generator:${{ github.sha }}',
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
    'nas_image_digest ='
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

Write-Output 'PASS: GitHub workflow policy is pinned, least-privilege, test-gated, and release-scoped.'
