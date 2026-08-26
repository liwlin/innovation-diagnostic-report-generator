$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$composePath = Join-Path $projectRoot 'deploy\compose.yaml'

function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

Assert-Condition (Test-Path -LiteralPath $composePath -PathType Leaf) 'deploy/compose.yaml is missing.'

$previous = @{
    APP_IMAGE = $env:APP_IMAGE
    PROJECT_ROOT = $env:PROJECT_ROOT
    REPORT_ROOT = $env:REPORT_ROOT
    SECRETS_ROOT = $env:SECRETS_ROOT
}

try {
    $env:APP_IMAGE = 'ghcr.io/liwlin/innovation-diagnostic-report-generator:test@sha256:' + ('0' * 64)
    $env:PROJECT_ROOT = 'C:/makerseed-diagnostic'
    $env:REPORT_ROOT = 'C:/makerseed-report'
    $env:SECRETS_ROOT = 'C:/makerseed-diagnostic/secrets'

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
    Assert-Condition ([int]$app.pids_limit -le 128) 'App pids_limit must be at most 128.'
    Assert-Condition ([int]$db.pids_limit -le 256) 'Database pids_limit must be at most 256.'
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
        $normalized = [System.IO.Path]::GetFullPath($source)
        $allowed = $normalized.StartsWith('C:\makerseed-diagnostic', [System.StringComparison]::OrdinalIgnoreCase) `
            -or $normalized.StartsWith('C:\makerseed-report', [System.StringComparison]::OrdinalIgnoreCase) `
            -or $normalized.StartsWith((Join-Path $projectRoot 'deploy'), [System.StringComparison]::OrdinalIgnoreCase)
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
