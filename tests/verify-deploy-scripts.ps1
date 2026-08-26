$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$requiredScripts = @(
    'deploy/scripts/common.sh',
    'deploy/scripts/migrate.sh',
    'deploy/scripts/backup.sh',
    'deploy/scripts/restore-verify.sh'
)

function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

foreach ($relative in $requiredScripts) {
    $path = Join-Path $projectRoot $relative
    Assert-Condition (Test-Path -LiteralPath $path -PathType Leaf) "Missing deployment script: $relative"
    $source = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    Assert-Condition ($source -notmatch 'rm\s+-rf') "$relative contains forbidden rm -rf."
    Assert-Condition ($source -notmatch '(?m)^\s*(echo|printf).*password') "$relative may echo a password."
    Assert-Condition ($source -notmatch '(/volume1/?)\s*["'']?\s*$') "$relative contains a broad /volume1 target."
}

foreach ($relative in @('deploy/scripts/migrate.sh', 'deploy/scripts/backup.sh', 'deploy/scripts/restore-verify.sh')) {
    $source = Get-Content -LiteralPath (Join-Path $projectRoot $relative) -Raw -Encoding UTF8
    $guardPosition = $source.IndexOf('require_exact_project_root')
    $dockerPosition = $source.IndexOf('compose ')
    Assert-Condition ($guardPosition -ge 0) "$relative does not call require_exact_project_root."
    Assert-Condition ($dockerPosition -lt 0 -or $guardPosition -lt $dockerPosition) "$relative calls Docker before the root guard."
}

$backup = Get-Content -LiteralPath (Join-Path $projectRoot 'deploy/scripts/backup.sh') -Raw -Encoding UTF8
Assert-Condition ($backup -match 'makerseed_.*\.dump') 'Backup filename contract is missing.'
Assert-Condition ($backup -match 'pg_dump') 'Backup script does not call pg_dump.'
Assert-Condition ($backup -match 'pg_restore\s+--list') 'Backup script does not validate the archive listing.'
Assert-Condition ($backup -match 'sha256sum') 'Backup script does not create a SHA-256 proof.'
Assert-Condition ($backup -match '\.json') 'Backup script does not create a JSON manifest.'

$restore = Get-Content -LiteralPath (Join-Path $projectRoot 'deploy/scripts/restore-verify.sh') -Raw -Encoding UTF8
Assert-Condition ($restore -match 'makerseed_verify_') 'Restore verification database prefix is missing.'
Assert-Condition ($restore -match 'pg_restore') 'Restore verification does not execute pg_restore.'
Assert-Condition ($restore -match 'dropdb') 'Restore verification does not clean its disposable database.'
Assert-Condition ($restore -notmatch 'pg_restore[^\r\n]*makerseed(?:\s|"|''|$)') 'Restore script may target the live makerseed database.'

$shell = 'C:\Users\lwl56\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\git\usr\bin\sh.exe'
Assert-Condition (Test-Path -LiteralPath $shell) 'Git sh.exe is unavailable for script syntax checks.'
& $shell -n @($requiredScripts | ForEach-Object { Join-Path $projectRoot $_ })
Assert-Condition ($LASTEXITCODE -eq 0) 'POSIX shell syntax check failed.'

$guardCommands = @(
    'PATH=/usr/bin:/bin:$PATH PROJECT_ROOT=/tmp/not-makerseed RELEASE_ROOT=/tmp SECRETS_ROOT=/tmp ./deploy/scripts/migrate.sh',
    'PATH=/usr/bin:/bin:$PATH PROJECT_ROOT=/tmp/not-makerseed RELEASE_ROOT=/tmp APP_VERSION=test ./deploy/scripts/backup.sh',
    'PATH=/usr/bin:/bin:$PATH PROJECT_ROOT=/tmp/not-makerseed RELEASE_ROOT=/tmp ./deploy/scripts/restore-verify.sh --backup /tmp/none.dump'
)
Push-Location $projectRoot
try {
    foreach ($command in $guardCommands) {
        & $shell -c $command 2>$null
        Assert-Condition ($LASTEXITCODE -eq 20) "Root guard did not stop command before mutation: $command"
    }
}
finally {
    Pop-Location
}

Write-Output 'PASS: deployment scripts are guarded, non-recursive, and backup/restore contracts are present.'
