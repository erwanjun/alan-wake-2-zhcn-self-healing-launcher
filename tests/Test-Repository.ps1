$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$errors = [Collections.Generic.List[string]]::new()
foreach ($script in Get-ChildItem -LiteralPath (Join-Path $root 'launcher') -Filter '*.ps1') {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$parseErrors)
    foreach ($parseError in $parseErrors) { $errors.Add("$($script.Name): $($parseError.Message)") }
}

$forbidden = @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object Extension -Match '^\.(bin|ttf|otf|ttc|rmdtoc|rmdblob)$')
if ($forbidden.Count -gt 0) { $errors.Add('仓库含有不应发布的游戏、翻译或字体资源。') }

$rmdtocSource = Get-Content -LiteralPath (Join-Path $root 'src\RmdtocTool\Core\rmdtoc.cs') -Raw
if ($rmdtocSource -notmatch 'info\.BufferOffset\s*=\s*stream\.Position') {
    $errors.Add('缺少 64 位 RMDBLOB 偏移修复。')
}

foreach ($required in @('README.md', 'LICENSE', 'VERSION', 'launcher\Setup.ps1', 'launcher\Update-Self.ps1', 'launcher\Start-AlanWake2-Chinese.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $required) -PathType Leaf)) { $errors.Add("缺少文件：$required") }
}

$launcherSource = Get-Content -LiteralPath (Join-Path $root 'launcher\Start-AlanWake2-Chinese.ps1') -Raw
if ($launcherSource -match 'Start-Process\s+-FilePath\s+\$gameExe') { $errors.Add('启动器不得绕过 Epic 直接执行 AlanWake2.exe。') }
if ($launcherSource -notmatch 'com\.epicgames\.launcher://apps/') { $errors.Add('启动器缺少 Epic Games Launcher URI 启动路径。') }

if ($errors.Count -gt 0) { throw ($errors -join [Environment]::NewLine) }
Write-Host '仓库结构、脚本语法与发布边界检查通过。'
