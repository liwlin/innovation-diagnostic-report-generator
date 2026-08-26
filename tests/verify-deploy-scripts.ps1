$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$requiredScripts = @(
    'deploy/scripts/common.sh',
    'deploy/scripts/migrate.sh',
    'deploy/scripts/backup.sh',
    'deploy/scripts/restore-verify.sh',
    'deploy/scripts/preflight.sh',
    'deploy/scripts/install-layout.sh',
    'deploy/scripts/smoke.sh',
    'deploy/scripts/deploy.sh',
    'deploy/scripts/rollback.sh'
)

function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

foreach ($relative in $requiredScripts) {
    $gitEntry = git -C $projectRoot ls-files -s -- $relative
    Assert-Condition ($LASTEXITCODE -eq 0) "Failed to inspect Git mode for deployment script: $relative"
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($gitEntry)) "Deployment script is not tracked by Git: $relative"
    Assert-Condition ($gitEntry -match '^100755\s+[0-9a-f]{40,64}\s+\d+\t') "Deployment script must be tracked as executable mode 100755: $relative"

    $path = Join-Path $projectRoot $relative
    Assert-Condition (Test-Path -LiteralPath $path -PathType Leaf) "Missing deployment script: $relative"
    $source = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    Assert-Condition ($source -notmatch 'rm\s+-rf') "$relative contains forbidden rm -rf."
    Assert-Condition ($source -notmatch '(?m)^\s*(echo|printf).*password') "$relative may echo a password."
    Assert-Condition ($source -notmatch '(/volume1/?)\s*["'']?\s*$') "$relative contains a broad /volume1 target."
}

foreach ($relative in @('deploy/scripts/migrate.sh', 'deploy/scripts/backup.sh', 'deploy/scripts/restore-verify.sh', 'deploy/scripts/preflight.sh', 'deploy/scripts/install-layout.sh', 'deploy/scripts/smoke.sh', 'deploy/scripts/deploy.sh', 'deploy/scripts/rollback.sh')) {
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

$preflight = Get-Content -LiteralPath (Join-Path $projectRoot 'deploy/scripts/preflight.sh') -Raw -Encoding UTF8
foreach ($mutation in @('mkdir', 'touch', 'docker pull', 'docker load', 'docker-compose up', 'mv ', 'cp ')) {
    Assert-Condition ($preflight -notlike "*$mutation*") "Preflight must remain read-only; found: $mutation"
}
Assert-Condition ($preflight -match 'PREFLIGHT_NONCE') 'Preflight must require and report a caller-provided nonce.'
Assert-Condition ($preflight -match 'MIN_COMPOSE_VERSION') 'Preflight must enforce a minimum Docker Compose version.'
Assert-Condition ($preflight -match 'stat -c %a') 'Preflight must validate secret file modes.'
Assert-Condition ($preflight -match 'REPORT_ROOT') 'Preflight must validate the declared report mount root.'
Assert-Condition ($preflight -match 'readlink -f "\$REPORT_ROOT"') 'Preflight must resolve declared mounts before approval.'
foreach ($bindSource in @('data/postgres', 'backups', 'postgres-init/10-create-runtime-role.sh')) {
    Assert-Condition ($preflight -like "*$bindSource*") "Preflight must validate bind source: $bindSource"
}
Assert-Condition ($preflight -match 'canonical_bind_source') 'Preflight must canonicalize every declared bind source.'
Assert-Condition ($preflight -match 'must not be a symbolic link') 'Preflight must reject symlinked bind sources.'
Assert-Condition ($preflight -match '"nonce":"%s"') 'Preflight verdict must include the nonce for install-layout binding.'
Assert-Condition ($preflight -match 'docker ps[^\r\n]*com\.docker\.compose\.project=makerseed-diagnostic') 'Preflight must check project container collisions.'
Assert-Condition ($preflight -match 'docker ps[^\r\n]*publish=18081') 'Preflight must inspect the actual port 18081 owner.'
Assert-Condition ($preflight -match 'com\.docker\.compose\.project\.working_dir') 'Preflight must verify the compose working directory for collisions.'
foreach ($containerName in @('makerseed-diagnostic-app-1', 'makerseed-diagnostic-db-1')) {
    Assert-Condition ($preflight -like "*$containerName*") "Preflight must inspect exact container ownership for $containerName"
}

$layout = Get-Content -LiteralPath (Join-Path $projectRoot 'deploy/scripts/install-layout.sh') -Raw -Encoding UTF8
Assert-Condition ($layout -match 'PREFLIGHT_NONCE') 'Install layout must require the successful preflight nonce.'
Assert-Condition ($layout -match 'preflight\.sh') 'Install layout must bind itself to a fresh successful preflight.'
Assert-Condition ($layout -match 'unexpected entry exists in project root') 'Install layout must reject unexpected pre-existing entries.'
Assert-Condition ($layout -notmatch '(synoshare|synouser|synogroup)') 'Install layout must not create DSM shares, users, or groups.'

$deploy = Get-Content -LiteralPath (Join-Path $projectRoot 'deploy/scripts/deploy.sh') -Raw -Encoding UTF8
$backupPosition = $deploy.IndexOf('backup.sh')
$verifyPosition = $deploy.IndexOf('restore-verify.sh')
$migratePosition = $deploy.IndexOf('migrate.sh')
$appUpPosition = $deploy.IndexOf('compose up -d --no-deps app')
$smokePosition = $deploy.IndexOf('smoke.sh')
Assert-Condition ($backupPosition -ge 0 -and $backupPosition -lt $migratePosition) 'Deploy must back up before migration.'
Assert-Condition ($verifyPosition -gt $backupPosition -and $verifyPosition -lt $migratePosition) 'Deploy must restore-verify before migration.'
Assert-Condition ($appUpPosition -gt $migratePosition) 'Deploy must start only the app after migration.'
Assert-Condition ($smokePosition -gt $appUpPosition) 'Deploy must smoke-test after app startup.'
Assert-Condition ($deploy -match 'rollback\.sh') 'Deploy does not invoke rollback on failure.'
Assert-Condition ($deploy -match 'docker image inspect "\$APP_IMAGE"') 'Deploy must verify the requested digest-pinned app image.'
Assert-Condition ($deploy -match 'APP_IMAGE=%s') 'Deploy state must persist the requested digest.'
Assert-Condition ($deploy -match 'MIGRATION_COMPATIBILITY') 'Deploy must require an explicit migration compatibility contract.'
Assert-Condition ($deploy -match 'SCHEMA_COMPATIBLE=%s') 'Deploy state must persist schema compatibility for rollback.'
Assert-Condition ($deploy -match 'bootstrap.*password') 'Deploy must remove temporary bootstrap password material after successful smoke.'

$rollback = Get-Content -LiteralPath (Join-Path $projectRoot 'deploy/scripts/rollback.sh') -Raw -Encoding UTF8
Assert-Condition ($rollback -match 'deployment-state') 'Rollback does not require recorded deployment state.'
Assert-Condition ($rollback -match 'sha256sum') 'Rollback does not verify its state or backup proof.'
Assert-Condition ($rollback -match 'CONFIRM_INCOMPATIBLE_SCHEMA_RESTORE') 'Rollback must require a separate confirmation for incompatible-schema database restore.'
Assert-Condition ($rollback -match 'restore-verify\.sh') 'Rollback must verify the backup before any incompatible-schema database restore.'
Assert-Condition ($rollback -match 'pg_restore') 'Rollback must implement the confirmed incompatible-schema restore path.'
Assert-Condition ($rollback -match 'compose stop app') 'Rollback must stop app before an incompatible-schema database restore.'

$smoke = Get-Content -LiteralPath (Join-Path $projectRoot 'deploy/scripts/smoke.sh') -Raw -Encoding UTF8
foreach ($token in @('/api/health', '/api/session', '/api/auth/login', '/api/admin/users', '/api/batches', '/evaluations', 'X-CSRF-Token', '/trash', '/restore')) {
    Assert-Condition ($smoke -like "*$token*") "Smoke test is missing authenticated flow token: $token"
}
Assert-Condition ($smoke -match 'SMOKE_ADMIN_USERNAME') 'Smoke must use an existing admin account to create a temporary test account.'
Assert-Condition ($smoke -match 'mkseed_csrf') 'Smoke must extract and reuse the CSRF cookie.'
Assert-Condition ($smoke -match 'csrf_failed') 'Smoke must prove CSRF rejection before authenticated mutation.'
Assert-Condition ($smoke -match 'SMOKE_TEST_PASSWORD') 'Smoke must require a temporary test-account password.'
Assert-Condition ($smoke -match 'permanent.*delete|DELETE') 'Smoke must remove test data through the application.'
Assert-Condition ($smoke -notmatch 'curl[^\r\n]*(SMOKE_ADMIN_PASSWORD|SMOKE_TEST_PASSWORD)') 'Smoke must not place passwords in curl argv.'
Assert-Condition ($smoke -notmatch '--data\s+.*(SMOKE_ADMIN_PASSWORD|SMOKE_TEST_PASSWORD)') 'Smoke must not send passwords through inline --data arguments.'
Assert-Condition ($smoke -match '--data-binary\s+@') 'Smoke must send JSON bodies through files or stdin.'
Assert-Condition ($smoke -match 'json_escape') 'Smoke must JSON-escape credential and user-provided values.'
Assert-Condition ($smoke -match 'chmod 600') 'Smoke temp request bodies must be mode 0600.'

$isWindowsHost = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::Windows
)

function Test-ExecutableFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $item -or $item.PSIsContainer) { return $false }
    if ($isWindowsHost) { return $item.Extension -ieq '.exe' }
    return $true
}

function Resolve-PosixShell {
    $pathShell = Get-Command sh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $pathShell -and (Test-ExecutableFile $pathShell.Source)) {
        return (Get-Item -LiteralPath $pathShell.Source).FullName
    }

    if (-not $isWindowsHost) {
        throw 'POSIX sh is unavailable for deployment script syntax checks.'
    }

    $candidateRoots = @(
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)}
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    $candidates = @()
    foreach ($root in $candidateRoots) {
        $candidates += Join-Path $root 'Git\usr\bin\sh.exe'
        $candidates += Join-Path $root 'Git\bin\sh.exe'
    }
    foreach ($profileRoot in @($env:USERPROFILE, $env:LOCALAPPDATA)) {
        if (-not [string]::IsNullOrWhiteSpace($profileRoot)) {
            $candidates += Join-Path $profileRoot '.cache\codex-runtimes\codex-primary-runtime\dependencies\native\git\usr\bin\sh.exe'
            $candidates += Join-Path $profileRoot 'codex-runtimes\codex-primary-runtime\dependencies\native\git\usr\bin\sh.exe'
        }
    }

    foreach ($candidate in $candidates | Select-Object -Unique) {
        if (Test-ExecutableFile $candidate) {
            return (Get-Item -LiteralPath $candidate).FullName
        }
    }

    throw 'Git sh.exe is unavailable for deployment script syntax checks.'
}

$shell = Resolve-PosixShell
& $shell -n @($requiredScripts | ForEach-Object { Join-Path $projectRoot $_ })
Assert-Condition ($LASTEXITCODE -eq 0) 'POSIX shell syntax check failed.'

$guardCommands = @(
    'PATH=/usr/bin:/bin:$PATH PROJECT_ROOT=/tmp/not-makerseed RELEASE_ROOT=/tmp SECRETS_ROOT=/tmp ./deploy/scripts/migrate.sh',
    'PATH=/usr/bin:/bin:$PATH PROJECT_ROOT=/tmp/not-makerseed RELEASE_ROOT=/tmp APP_VERSION=test ./deploy/scripts/backup.sh',
    'PATH=/usr/bin:/bin:$PATH PROJECT_ROOT=/tmp/not-makerseed RELEASE_ROOT=/tmp ./deploy/scripts/restore-verify.sh --backup /tmp/none.dump',
    'PATH=/usr/bin:/bin:$PATH PROJECT_ROOT=/tmp/not-makerseed RELEASE_ROOT=/tmp ./deploy/scripts/preflight.sh',
    'PATH=/usr/bin:/bin:$PATH PROJECT_ROOT=/tmp/not-makerseed RELEASE_ROOT=/tmp ./deploy/scripts/install-layout.sh',
    'PATH=/usr/bin:/bin:$PATH PROJECT_ROOT=/tmp/not-makerseed RELEASE_ROOT=/tmp ./deploy/scripts/smoke.sh',
    'PATH=/usr/bin:/bin:$PATH PROJECT_ROOT=/tmp/not-makerseed RELEASE_ROOT=/tmp APP_VERSION=test ./deploy/scripts/deploy.sh',
    'PATH=/usr/bin:/bin:$PATH PROJECT_ROOT=/tmp/not-makerseed RELEASE_ROOT=/tmp ./deploy/scripts/rollback.sh'
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
