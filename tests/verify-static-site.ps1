param(
    [int]$Port = 8876
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$server = $null

function Assert-Condition {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

try {
    $python = Get-Command python -ErrorAction Stop
    $server = Start-Process `
        -FilePath $python.Source `
        -ArgumentList @('-m', 'http.server', $Port, '--bind', '127.0.0.1') `
        -WorkingDirectory $projectRoot `
        -WindowStyle Hidden `
        -PassThru

    $baseUrl = "http://127.0.0.1:$Port"
    $rootResponse = $null

    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        try {
            $rootResponse = Invoke-WebRequest -Uri "$baseUrl/" -UseBasicParsing
            break
        }
        catch {
            Start-Sleep -Milliseconds 100
        }
    }

    Assert-Condition ($null -ne $rootResponse) 'Static server did not become ready.'
    Assert-Condition ($rootResponse.StatusCode -eq 200) 'Root route did not return HTTP 200.'
    Assert-Condition ($rootResponse.Content -notmatch 'Directory listing for') 'Root route exposes a directory listing instead of the application.'

    $runtimePaths = @(
        '/科创方向诊断报告生成器.dc.html',
        '/support.js',
        '/doc-page.js',
        '/shared/report-filename.js',
        '/shared/runtime-config.js',
        '/shared/editor-repository.js',
        '/assets/logo-lockup.png',
        '/assets/logo-mark.png'
    )

    foreach ($path in $runtimePaths) {
        $response = Invoke-WebRequest -Uri "$baseUrl$path" -UseBasicParsing
        Assert-Condition ($response.StatusCode -eq 200) "Required runtime path is unavailable: $path"
    }

    $sourcePage = Invoke-WebRequest -Uri "$baseUrl/科创方向诊断报告生成器.dc.html" -UseBasicParsing
    Assert-Condition ($sourcePage.Content -match '<title>科创体验报告 · 生成器</title>') 'The application page is missing its browser title.'

    Write-Output 'PASS: root entry and all required static runtime files are available.'
}
finally {
    if ($null -ne $server -and -not $server.HasExited) {
        Stop-Process -Id $server.Id
    }
}
