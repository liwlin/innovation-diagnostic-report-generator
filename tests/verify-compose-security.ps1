$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$composePath = Join-Path $projectRoot 'deploy\compose.yaml'
$deployRoot = Join-Path $projectRoot 'deploy'

function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-PathComparison {
    if ($IsWindows) {
        return [System.StringComparison]::OrdinalIgnoreCase
    }
    return [System.StringComparison]::Ordinal
}

function Normalize-FullPath {
    param([string]$Path)
    $separators = [char[]]@(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    [System.IO.Path]::GetFullPath($Path).TrimEnd($separators)
}

function Test-PathWithinRoot {
    param([string]$Path, [string]$Root)
    $comparison = Get-PathComparison
    $normalizedPath = Normalize-FullPath $Path
    $normalizedRoot = Normalize-FullPath $Root
    if ([string]::Equals($normalizedPath, $normalizedRoot, $comparison)) {
        return $true
    }
    foreach ($separator in @(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )) {
        if ($separator -and $normalizedPath.StartsWith($normalizedRoot + $separator, $comparison)) {
            return $true
        }
    }
    return $false
}

Assert-Condition (Test-Path -LiteralPath $composePath -PathType Leaf) 'deploy/compose.yaml is missing.'

$dummyBase = Join-Path ([System.IO.Path]::GetTempPath()) 'makerseed-compose-policy'
$dummyProjectRoot = Join-Path $dummyBase 'project'
$dummyReportRoot = Join-Path $dummyBase 'reports'
$dummySecretsRoot = Join-Path $dummyProjectRoot 'secrets'
Assert-Condition (Test-PathWithinRoot (Join-Path $dummyProjectRoot 'data/postgres') $dummyProjectRoot) 'Containment self-test must accept a child path.'
Assert-Condition (-not (Test-PathWithinRoot ($dummyProjectRoot + '-evil') $dummyProjectRoot)) 'Containment self-test must reject sibling-prefix paths.'

$previous = @{
    APP_IMAGE = $env:APP_IMAGE
    PROJECT_ROOT = $env:PROJECT_ROOT
    REPORT_ROOT = $env:REPORT_ROOT
    SECRETS_ROOT = $env:SECRETS_ROOT
    RELEASE_ROOT = $env:RELEASE_ROOT
}

try {
    $env:APP_IMAGE = 'ghcr.io/liwlin/innovation-diagnostic-report-generator:test@sha256:' + ('0' * 64)
    $env:PROJECT_ROOT = $dummyProjectRoot
    $env:REPORT_ROOT = $dummyReportRoot
    $env:SECRETS_ROOT = $dummySecretsRoot
    $env:RELEASE_ROOT = $deployRoot

    $json = docker compose -f $composePath config --format json
    Assert-Condition ($LASTEXITCODE -eq 0) 'docker compose config failed.'
    $config = $json | ConvertFrom-Json -Depth 100
    $serviceNames = @($config.services.PSObject.Properties.Name | Sort-Object)
    Assert-Condition (($serviceNames -join ',') -eq 'app,db') 'Exactly app and db services are required.'

    $app = $config.services.app
    $db = $config.services.db
    Assert-Condition ($app.user -eq '10001:10001') 'App must run as UID/GID 10001.'
    Assert-Condition ($db.user -eq '999:999') 'Database must run as UID/GID 999.'
    Assert-Condition ($app.read_only -eq $true) 'App root filesystem must be read-only.'
    Assert-Condition ($db.read_only -eq $true) 'Database root filesystem must be read-only.'
    Assert-Condition (@($app.cap_drop) -contains 'ALL') 'App must drop all Linux capabilities.'
    Assert-Condition (@($db.cap_drop) -contains 'ALL') 'Database must drop all Linux capabilities.'
    Assert-Condition ((@($app.security_opt) -join ',') -match 'no-new-privileges') 'App must set no-new-privileges.'
    Assert-Condition ((@($db.security_opt) -join ',') -match 'no-new-privileges') 'Database must set no-new-privileges.'
    Assert-Condition (-not ($app.PSObject.Properties.Name -contains 'cpus')) 'App must not use CFS cpus on DS220+ cgroup v1.'
    Assert-Condition (-not ($db.PSObject.Properties.Name -contains 'cpus')) 'Database must not use CFS cpus on DS220+ cgroup v1.'
    Assert-Condition (-not ($app.PSObject.Properties.Name -contains 'pids_limit')) 'App must not rely on discarded pids_limit.'
    Assert-Condition (-not ($db.PSObject.Properties.Name -contains 'pids_limit')) 'Database must not rely on discarded pids_limit.'
    Assert-Condition ([string]$app.cpuset -eq '1') 'App must be pinned to DS220+ CPU 1.'
    Assert-Condition ([string]$db.cpuset -eq '0') 'Database must be pinned to DS220+ CPU 0.'
    Assert-Condition ([int]$app.cpu_shares -eq 512) 'App must use conservative relative CPU shares.'
    Assert-Condition ([int]$db.cpu_shares -eq 512) 'Database must use conservative relative CPU shares.'
    Assert-Condition ([int]$app.ulimits.nproc.soft -le 128) 'App nproc soft limit must be at most 128.'
    Assert-Condition ([int]$app.ulimits.nproc.hard -le 128) 'App nproc hard limit must be at most 128.'
    Assert-Condition ([int]$db.ulimits.nproc.soft -le 256) 'Database nproc soft limit must be at most 256.'
    Assert-Condition ([int]$db.ulimits.nproc.hard -le 256) 'Database nproc hard limit must be at most 256.'
    Assert-Condition ([int64]$app.mem_limit -le 1610612736) 'App memory limit exceeds 1536 MiB.'
    Assert-Condition ([int64]$db.mem_limit -le 2147483648) 'Database memory limit exceeds 2048 MiB.'

    $appPorts = @($app.ports | Where-Object { $null -ne $_ })
    Assert-Condition ($appPorts.Count -eq 1) 'App must expose exactly one host port.'
    Assert-Condition ($appPorts[0].host_ip -eq '127.0.0.1') 'App port must bind to loopback.'
    Assert-Condition (@($db.ports | Where-Object { $null -ne $_ }).Count -eq 0) 'PostgreSQL must expose no host port.'

    foreach ($service in @($app, $db)) {
        Assert-Condition (-not $service.privileged) 'privileged containers are forbidden.'
        Assert-Condition ($service.network_mode -ne 'host') 'host networking is forbidden.'
        Assert-Condition (@($service.devices | Where-Object { $null -ne $_ }).Count -eq 0) 'Device mounts are forbidden.'
        Assert-Condition ($service.image -match '@sha256:[0-9a-f]{64}$') 'Every runtime image must be digest pinned.'
        Assert-Condition ($service.image -notmatch ':latest') 'latest image tags are forbidden.'
    }

    $serialized = $config | ConvertTo-Json -Depth 100
    foreach ($forbidden in @('/var/run/docker.sock', '\\.\pipe\docker_engine', 'network_mode": "host', 'privileged": true')) {
        Assert-Condition ($serialized -notlike "*$forbidden*") "Forbidden Compose setting found: $forbidden"
    }

    foreach ($volume in @($app.volumes) + @($db.volumes)) {
        if ($volume.type -ne 'bind') { continue }
        $source = [string]$volume.source
        $allowed = (Test-PathWithinRoot $source $dummyProjectRoot) `
            -or (Test-PathWithinRoot $source $dummyReportRoot) `
            -or (Test-PathWithinRoot $source $deployRoot)
        Assert-Condition $allowed "Unapproved host bind mount: $source"
    }

    Assert-Condition ($config.networks.default.internal -eq $true) 'Project Docker network must be internal.'
    Write-Output 'PASS: Compose defines exactly two hardened, isolated, digest-pinned services.'
}
finally {
    foreach ($name in $previous.Keys) {
        if ($null -eq $previous[$name]) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
        else { Set-Item "Env:$name" $previous[$name] }
    }
}
