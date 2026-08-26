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
    'deploy/scripts/rollback.sh',
    'deploy/postgres-init/10-create-runtime-role.sh'
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
    $guardPositions = @(
        $source.IndexOf('require_exact_project_root'),
        $source.IndexOf('require_project_root_identity')
    ) | Where-Object { $_ -ge 0 } | Sort-Object
    $guardPosition = if ($guardPositions.Count -gt 0) { $guardPositions[0] } else { -1 }
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
$preflightCommon = $preflight + (Get-Content -LiteralPath (Join-Path $projectRoot 'deploy/scripts/common.sh') -Raw -Encoding UTF8)
$envExample = Get-Content -LiteralPath (Join-Path $projectRoot 'deploy/env.example') -Raw -Encoding UTF8
$composeYaml = Get-Content -LiteralPath (Join-Path $projectRoot 'deploy/compose.yaml') -Raw -Encoding UTF8
Assert-Condition ($envExample -match 'REPORT_ROOT_PHASE=isolated') 'env.example must default hardware preflight to the isolated report-root phase.'
Assert-Condition ($envExample -match 'REPORT_ROOT=/volume1/docker/makerseed-diagnostic/reports-staging') 'env.example must default reports to project-owned staging before File Station promotion.'
Assert-Condition ($envExample -match 'RELEASE_ROOT=/volume1/docker/makerseed-diagnostic/releases/.+/deploy') 'env.example must use an immutable release deploy path.'
Assert-Condition ($envExample -notmatch 'current/deploy') 'env.example must not point RELEASE_ROOT at mutable current/deploy.'
Assert-Condition ($envExample -notmatch '(?m)^APP_IMAGE=.*:[^@\r\n]+@sha256:' -and $envExample -match '(?m)^APP_IMAGE=ghcr\.io/liwlin/innovation-diagnostic-report-generator@sha256:' ) 'env.example must prefer digest-only APP_IMAGE references.'
Assert-Condition ($composeYaml -match 'source:\s*\$\{REPORT_ROOT') 'Compose must mount the explicit phase-validated REPORT_ROOT.'
foreach ($mutation in @('mkdir', 'touch', 'docker pull', 'docker load', 'docker-compose up', 'mv ', 'cp ')) {
    Assert-Condition ($preflight -notlike "*$mutation*") "Preflight must remain read-only; found: $mutation"
}
Assert-Condition ($preflight -match 'PREFLIGHT_MODE') 'Preflight must require bootstrap/runtime modes.'
Assert-Condition ($preflight -match 'validate_app_image') 'Preflight must validate the app image digest as lowercase hex, not shell wildcards.'
Assert-Condition ($preflight -match 'bootstrap\)') 'Preflight must implement bootstrap mode.'
Assert-Condition ($preflight -match 'runtime\)') 'Preflight must implement runtime mode.'
Assert-Condition ($preflight -match 'BOOTSTRAP_STAGE') 'Bootstrap preflight must validate the isolated bootstrap stage.'
Assert-Condition ($preflight -match 'STAGED_RELEASE_ROOT') 'Bootstrap preflight must validate the staged release root.'
Assert-Condition ($preflight -match 'RELEASE_TREE_MANIFEST') 'Bootstrap preflight must verify the staged release tree manifest.'
Assert-Condition ($preflight -match 'binding_hash') 'Preflight verdict must include the release binding hash.'
Assert-Condition ($preflight -match 'IMAGE_TAR_PROOF') 'Bootstrap tar image evidence must require a descriptor proof.'
Assert-Condition ($preflight -match 'image_tar_hash') 'Preflight binding must include tar evidence hashes when tar proof is used.'
Assert-Condition ($preflight -match 'project_root_before_state') 'Preflight verdict must include the project-root before-state.'
Assert-Condition ($preflight -match 'database_owner_url') 'Runtime preflight must require the owner migration URL secret.'
Assert-Condition ($preflight -match 'PROJECT_ROOT.*must not exist for bootstrap') 'Bootstrap preflight must fail closed when the final project root already exists.'
$bootstrapFunction = [regex]::Match($preflight, '(?ms)bootstrap_preflight\(\)\s*\{(?<body>.*?)\n\}').Groups['body'].Value
Assert-Condition (-not [string]::IsNullOrWhiteSpace($bootstrapFunction)) 'Bootstrap preflight function is missing.'
Assert-Condition ($bootstrapFunction -notmatch 'SECRETS_ROOT is required') 'Bootstrap preflight must not require final secrets.'
Assert-Condition ($bootstrapFunction -notmatch 'RELEASE_ROOT is required') 'Bootstrap preflight must not require the final release root.'
Assert-Condition ($preflight -match 'PREFLIGHT_NONCE') 'Preflight must require and report a caller-provided nonce.'
Assert-Condition ($preflight -match 'MIN_COMPOSE_VERSION') 'Preflight must enforce a minimum Docker Compose version.'
Assert-Condition ($preflight -match 'stat -c %a') 'Preflight must validate secret file modes.'
Assert-Condition ($preflight -match 'REPORT_ROOT') 'Preflight must validate the declared report mount root.'
Assert-Condition ($preflight -match 'canonical_bind_source "\$REPORT_ROOT"') 'Preflight must resolve the report mount through the missing-parent-safe canonicalizer.'
Assert-Condition ($preflight -notmatch '(?m)^\s*resolved_report=\$\(readlink -f "\$REPORT_ROOT"\)') 'Preflight must not raw readlink REPORT_ROOT before the safe missing-parent canonicalizer.'
Assert-Condition ($preflight -match 'REPORT_ROOT_PHASE') 'Preflight must require an explicit isolated/promoted report-root phase.'
Assert-Condition ($preflight -match 'reports-staging') 'Isolated hardware preflight must approve only the project-owned reports-staging root.'
Assert-Condition ($preflight -match '/volume1/科创诊断报告') 'Promoted preflight must approve only the final encrypted File Station share.'
Assert-Condition ($preflight -notmatch 'current/deploy') 'Preflight must not accept the mutable current/deploy symlink as a release input.'
Assert-Condition ($preflight -match 'releases/\*/deploy') 'Preflight must require immutable release deploy paths.'
foreach ($bindSource in @('data/postgres', 'backups', 'postgres-init/10-create-runtime-role.sh')) {
    Assert-Condition ($preflight -like "*$bindSource*") "Preflight must validate bind source: $bindSource"
}
Assert-Condition ($preflight -match 'canonical_bind_source') 'Preflight must canonicalize every declared bind source.'
Assert-Condition ($preflightCommon -match 'must not be a symbolic link') 'Preflight must reject symlinked bind sources.'
Assert-Condition ($preflight -match '"nonce":"%s"') 'Preflight verdict must include the nonce for install-layout binding.'
Assert-Condition ($preflight -match 'docker ps[^\r\n]*com\.docker\.compose\.project=makerseed-diagnostic') 'Preflight must check project container collisions.'
Assert-Condition ($preflight -match 'docker ps[^\r\n]*publish=18081') 'Preflight must inspect the actual port 18081 owner.'
Assert-Condition ($preflight -match 'com\.docker\.compose\.project\.working_dir') 'Preflight must verify the compose working directory for collisions.'
foreach ($containerName in @('makerseed-diagnostic-app-1', 'makerseed-diagnostic-db-1')) {
    Assert-Condition ($preflight -like "*$containerName*") "Preflight must inspect exact container ownership for $containerName"
}

$layout = Get-Content -LiteralPath (Join-Path $projectRoot 'deploy/scripts/install-layout.sh') -Raw -Encoding UTF8
Assert-Condition ($layout -match 'PREFLIGHT_BINDING_HASH') 'Install layout must require the successful bootstrap binding hash.'
Assert-Condition ($layout -match 'PREFLIGHT_MODE=bootstrap') 'Install layout must re-run bootstrap preflight.'
Assert-Condition ($layout -match 're-verify copied release tree') 'Install layout must re-verify the copied release tree before publishing it.'
Assert-Condition ($layout -match 'release-tree\.sha256') 'Install layout must persist the canonical release tree manifest into the immutable release.'
Assert-Condition ($layout -match '\.incoming-\$RELEASE_ID-\$PREFLIGHT_NONCE') 'Install layout must copy through a nonce-bound incoming release path.'
Assert-Condition ($layout -match 'mv "\$incoming_release" "\$target_release"') 'Install layout must atomically publish the copied immutable release.'
Assert-Condition ($layout -match 'PREFLIGHT_NONCE') 'Install layout must require the successful preflight nonce.'
Assert-Condition ($layout -match 'preflight\.sh') 'Install layout must bind itself to a fresh successful preflight.'
Assert-Condition ($layout -match 'project root exists before bootstrap layout') 'Install layout must reject any pre-existing project root before bootstrap writes.'
Assert-Condition ($layout -notmatch '(synoshare|synouser|synogroup)') 'Install layout must not create DSM shares, users, or groups.'

$deploy = Get-Content -LiteralPath (Join-Path $projectRoot 'deploy/scripts/deploy.sh') -Raw -Encoding UTF8
$backupPosition = $deploy.IndexOf('backup.sh')
$verifyPosition = $deploy.IndexOf('restore-verify.sh')
$migratePosition = $deploy.IndexOf('migrate.sh')
$appUpPosition = $deploy.IndexOf('compose up -d --no-deps --force-recreate app')
$dbUpPosition = $deploy.IndexOf('compose up -d db')
$smokePosition = $deploy.IndexOf('smoke.sh')
$bootstrapPosition = $deploy.IndexOf('bootstrap-admin')
Assert-Condition ($backupPosition -ge 0 -and $backupPosition -lt $migratePosition) 'Deploy must back up before migration.'
Assert-Condition ($verifyPosition -gt $backupPosition -and $verifyPosition -lt $migratePosition) 'Deploy must restore-verify before migration.'
Assert-Condition ($appUpPosition -gt $migratePosition) 'Deploy must start only the app after migration.'
Assert-Condition ($bootstrapPosition -gt $migratePosition -and $bootstrapPosition -lt $appUpPosition) 'First-install admin bootstrap must run after migration and before app startup.'
Assert-Condition ($dbUpPosition -lt 0 -or $dbUpPosition -gt $backupPosition) 'Upgrade deployment must not start/reconcile db before backup.'
Assert-Condition ($deploy -match 'previous_exists.*-eq 0') 'Deploy must separate first-install database creation from upgrade handling.'
Assert-Condition ($deploy -match 'verify_existing_db_state') 'Deploy must verify existing DB identity, health, and persisted state before upgrade backup.'
Assert-Condition ($deploy -match 'DB_IMAGE=') 'Deploy state must persist the DB image/digest used for drift detection.'
Assert-Condition ($deploy -match 'DB_CONTAINER_CONFIG_HASH=') 'Deploy state must persist a DB config hash for upgrade drift detection.'
Assert-Condition ($deploy -match 'compose up -d --no-deps --force-recreate app') 'Ordinary deploy must recreate only app without reconciling db.'
Assert-Condition ($smokePosition -gt $appUpPosition) 'Deploy must smoke-test after app startup.'
Assert-Condition ($deploy -match 'rollback\.sh') 'Deploy does not invoke rollback on failure.'
Assert-Condition ($deploy -match 'docker image inspect "\$APP_IMAGE"') 'Deploy must verify the requested digest-pinned app image.'
Assert-Condition ($deploy -notmatch 'docker load') 'Deploy must not load image tarballs before runtime preflight approval.'
Assert-Condition ($deploy -match 'APP_IMAGE=%s') 'Deploy state must persist the requested digest.'
Assert-Condition ($deploy -match 'MIGRATION_COMPATIBILITY') 'Deploy must require an explicit migration compatibility contract.'
Assert-Condition ($deploy -match 'SCHEMA_COMPATIBLE=%s') 'Deploy state must persist schema compatibility for rollback.'
Assert-Condition ($deploy -match 'INITIAL_ADMIN_PASSWORD_FILE') 'Deploy must read the initial admin credential only from the exact first-install secret file path.'
Assert-Condition ($deploy -match 'SMOKE_TEST_PASSWORD_FILE') 'Deploy must read smoke credentials only from password file paths.'
Assert-Condition ($deploy -match 'SMOKE_ADMIN_PASSWORD_FILE=.*INITIAL_ADMIN_PASSWORD_FILE') 'First install must pass the initial admin password file to smoke without reading it.'
Assert-Condition ($deploy -match 'INITIAL_ADMIN_HANDOFF=pending') 'Deploy state must record pending initial admin handoff without credential material.'
Assert-Condition ($deploy -match 'rm -f "\$SMOKE_TEST_PASSWORD_FILE"') 'Deploy must remove only the exact temporary smoke-test password file after successful smoke.'
Assert-Condition ($deploy -notmatch 'rm -f "\$INITIAL_ADMIN_PASSWORD_FILE"') 'Deploy must not remove the preserved initial admin password automatically.'
Assert-Condition ($deploy -match 'current\.env exists but is not a regular non-symlink file') 'Deploy must fail closed when current.env exists but is unsafe.'
Assert-Condition ($deploy -match '\[ -e "\$previous_state" \] \|\| \[ -L "\$previous_state" \]') 'Deploy must treat a broken current.env symlink as existing unsafe state.'
Assert-Condition ($deploy -match 'detect_existing_db_footprint') 'Deploy must check for existing DB evidence before treating a run as first install.'
Assert-Condition ($deploy -match 'compose ps -a -q db') 'Deploy must inspect the exact project db container before first-install DB creation.'
Assert-Condition ($deploy -match 'data_postgres_has_entries') 'Deploy must inspect persisted postgres data before first-install DB creation.'
Assert-Condition ($deploy -match '\[ -e "\$child" \] \|\| \[ -L "\$child" \]') 'Deploy must count a broken symlink child in data/postgres as existing DB footprint.'
Assert-Condition ($deploy -match 'refusing first install over existing database evidence') 'Deploy must require an audited baseline instead of reconciling existing DB evidence.'

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
Assert-Condition ($smoke -match 'SMOKE_ADMIN_PASSWORD_FILE') 'Smoke must read the admin password from a password file.'
Assert-Condition ($smoke -match 'SMOKE_TEST_PASSWORD_FILE') 'Smoke must read the temporary test-account password from a password file.'
Assert-Condition ($smoke -notmatch '(?m)^\s*:\s*"\$\{SMOKE_ADMIN_PASSWORD:') 'Smoke must not require inline admin password environment values.'
Assert-Condition ($smoke -notmatch '(?m)^\s*:\s*"\$\{SMOKE_TEST_PASSWORD:') 'Smoke must not require inline test password environment values.'
Assert-Condition ($smoke -match 'permanent.*delete|DELETE') 'Smoke must remove test data through the application.'
Assert-Condition ($smoke -notmatch 'curl[^\r\n]*(SMOKE_ADMIN_PASSWORD|SMOKE_TEST_PASSWORD)') 'Smoke must not place passwords in curl argv.'
Assert-Condition ($smoke -notmatch '--data\s+.*(SMOKE_ADMIN_PASSWORD|SMOKE_TEST_PASSWORD)') 'Smoke must not send passwords through inline --data arguments.'
Assert-Condition ($smoke -match '--data-binary\s+@') 'Smoke must send JSON bodies through files or stdin.'
Assert-Condition ($smoke -match 'json_escape') 'Smoke must JSON-escape credential and user-provided values.'
Assert-Condition ($smoke -match 'chmod 600') 'Smoke temp request bodies must be mode 0600.'

$handoffRunbookPath = Join-Path $projectRoot 'deploy/synology/initial-admin-handoff.md'
Assert-Condition (Test-Path -LiteralPath $handoffRunbookPath -PathType Leaf) 'Initial admin handoff runbook is missing.'
$handoffRunbook = Get-Content -LiteralPath $handoffRunbookPath -Raw -Encoding UTF8
Assert-Condition ($handoffRunbook -match '\[ -f "\$state_file" \] && \[ ! -L "\$state_file" \]') 'Handoff cleanup must verify current.env is a regular non-symlink before editing.'
Assert-Condition ($handoffRunbook -match 'sha256sum -c "\$state_hash"') 'Handoff cleanup must verify the current.env checksum before editing.'
Assert-Condition ($handoffRunbook -match "grep -c '\^INITIAL_ADMIN_HANDOFF=pending\$'") 'Handoff cleanup must require exactly one pending handoff line.'
Assert-Condition ($handoffRunbook -match 'tmp_hash=.*\.sha256\.handoff') 'Handoff cleanup must build a replacement checksum before committing state.'
Assert-Condition ($handoffRunbook -match 'rm -f "\$initial_password_file"') 'Handoff cleanup must remove only the exact initial password file.'
Assert-Condition ($handoffRunbook -match 'mv "\$tmp_state" "\$state_file"') 'Handoff cleanup must atomically replace state.'
Assert-Condition ($handoffRunbook -match 'mv "\$tmp_hash" "\$state_hash"') 'Handoff cleanup must atomically replace checksum.'
Assert-Condition ($handoffRunbook -match 'rollback_state\(\)') 'Handoff cleanup must define a rollback path for state/hash replacement.'

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
