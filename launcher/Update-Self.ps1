param(
    [Parameter(Mandatory = $true)][string]$InstallRoot,
    [Parameter(Mandatory = $true)][string]$Repository,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$currentVersionPath = Join-Path $InstallRoot 'VERSION'
$statePath = Join-Path $InstallRoot 'update-state.json'
$state = if (Test-Path -LiteralPath $statePath) { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } else { $null }
if (-not $Force -and $state -and $state.LastChecked) {
    $lastChecked = [DateTimeOffset]::Parse([string]$state.LastChecked)
    if (([DateTimeOffset]::Now - $lastChecked).TotalHours -lt 24) { exit 0 }
}

try {
    $headers = @{ 'User-Agent' = 'AW2-ZHCN-Self-Healing-Launcher' }
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/latest" -Headers $headers
    @{ LastChecked = [DateTimeOffset]::Now.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
    $latest = ([string]$release.tag_name).TrimStart('v')
    $current = if (Test-Path -LiteralPath $currentVersionPath) { (Get-Content -LiteralPath $currentVersionPath -Raw).Trim() } else { '0.0.0' }
    if ([version]$latest -le [version]$current) { exit 0 }

    $zipAsset = @($release.assets | Where-Object name -Like '*.zip' | Select-Object -First 1)
    $sumAsset = @($release.assets | Where-Object name -EQ 'SHA256SUMS.txt' | Select-Object -First 1)
    if ($zipAsset.Count -ne 1 -or $sumAsset.Count -ne 1) { throw '最新版本缺少 ZIP 或 SHA256SUMS.txt。' }

    $temporary = Join-Path ([IO.Path]::GetTempPath()) ('aw2-launcher-update-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporary | Out-Null
    try {
        $zipPath = Join-Path $temporary $zipAsset[0].name
        $sumPath = Join-Path $temporary 'SHA256SUMS.txt'
        Invoke-WebRequest -UseBasicParsing -Uri $zipAsset[0].browser_download_url -Headers $headers -OutFile $zipPath
        Invoke-WebRequest -UseBasicParsing -Uri $sumAsset[0].browser_download_url -Headers $headers -OutFile $sumPath
        $expected = ((Get-Content -LiteralPath $sumPath -Raw) -split '\s+')[0].ToUpperInvariant()
        $actual = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
        if ($expected -cne $actual) { throw '更新包 SHA-256 校验失败。' }

        $expanded = Join-Path $temporary 'expanded'
        Expand-Archive -LiteralPath $zipPath -DestinationPath $expanded
        $payload = $expanded
        if (-not (Test-Path -LiteralPath (Join-Path $payload 'VERSION'))) {
            $children = @(Get-ChildItem -LiteralPath $expanded -Directory)
            if ($children.Count -eq 1 -and (Test-Path -LiteralPath (Join-Path $children[0].FullName 'VERSION'))) { $payload = $children[0].FullName }
        }
        if (-not (Test-Path -LiteralPath (Join-Path $payload 'VERSION'))) { throw '更新包结构无效。' }

        foreach ($file in Get-ChildItem -LiteralPath $payload -Recurse -File) {
            $relative = $file.FullName.Substring($payload.Length).TrimStart('\')
            if ($relative -match '^(sources|backups|logs)(\\|$)' -or $relative -in @('config.json', 'state.json', 'update-state.json')) { continue }
            $destination = Join-Path $InstallRoot $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
    }
    exit 10
} catch {
    Write-Warning "自动更新失败：$_"
    exit 1
}

