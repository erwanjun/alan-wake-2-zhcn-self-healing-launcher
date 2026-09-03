param(
    [string]$GameRoot,
    [string]$StringTablePath,
    [string]$FontSourceRoot,
    [switch]$SkipInitialRepair
)

$ErrorActionPreference = 'Stop'
$installRoot = $PSScriptRoot
$expectedFonts = @(
    'aktivgroteskcd_bd.ttf', 'aktivgroteskcd_it.ttf', 'aktivgroteskcd_md.ttf', 'aktivgroteskcd_rg.ttf',
    'aktivgroteskex_bd.ttf', 'aktivgroteskex_blk.ttf', 'aktivgroteskex_it.ttf', 'aktivgroteskex_md.ttf',
    'aktivgroteskex_rg.ttf', 'bestten-crt.otf', 'digitalnumbers-regular.ttf', 'pressstart2p-regular.ttf',
    'feltpenpro-medium.otf', 'prestige12pitchbt-bold.ttf'
)

function Select-Folder([string]$Description, [string]$InitialPath) {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = [Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = $Description
    $dialog.ShowNewFolderButton = $false
    if ($InitialPath -and (Test-Path -LiteralPath $InitialPath -PathType Container)) {
        $dialog.SelectedPath = $InitialPath
    }
    try {
        if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { throw '用户取消了目录选择。' }
        return $dialog.SelectedPath
    } finally { $dialog.Dispose() }
}

function Select-StringTable {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = [Windows.Forms.OpenFileDialog]::new()
    $dialog.Title = '选择汉化补丁中的 string_table.bin'
    $dialog.Filter = 'Alan Wake 2 字符串表 (string_table.bin)|string_table.bin|所有文件 (*.*)|*.*'
    $dialog.CheckFileExists = $true
    try {
        if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { throw '用户取消了文件选择。' }
        return $dialog.FileName
    } finally { $dialog.Dispose() }
}

if (-not $GameRoot) {
    $candidate = 'D:\Programs\AlanWake2'
    if (-not (Test-Path -LiteralPath (Join-Path $candidate 'AlanWake2.exe'))) { $candidate = $null }
    $GameRoot = Select-Folder '选择《心灵杀手 2》安装目录（里面应有 AlanWake2.exe）' $candidate
}
$GameRoot = [IO.Path]::GetFullPath($GameRoot).TrimEnd('\')
if (-not (Test-Path -LiteralPath (Join-Path $GameRoot 'AlanWake2.exe') -PathType Leaf)) {
    throw "所选目录不是有效的《心灵杀手 2》目录：$GameRoot"
}

if (-not $StringTablePath) { $StringTablePath = Select-StringTable }
if (-not (Test-Path -LiteralPath $StringTablePath -PathType Leaf) -or [IO.Path]::GetFileName($StringTablePath) -cne 'string_table.bin') {
    throw '请选择汉化补丁中名为 string_table.bin 的文件。'
}

if (-not $FontSourceRoot) {
    $FontSourceRoot = Select-Folder '选择包含多字体补丁文件的目录；程序会递归查找 14 个字体文件' $null
}
$fontFiles = @(Get-ChildItem -LiteralPath $FontSourceRoot -Recurse -File | Where-Object { $expectedFonts -ccontains $_.Name })
foreach ($fontName in $expectedFonts) {
    $matches = @($fontFiles | Where-Object Name -CEQ $fontName)
    if ($matches.Count -ne 1) { throw "字体 $fontName 应恰好找到 1 份，实际找到 $($matches.Count) 份。" }
}

$sourceRoot = Join-Path $installRoot 'sources'
$fontTarget = Join-Path $sourceRoot 'fonts'
New-Item -ItemType Directory -Path $fontTarget -Force | Out-Null
Copy-Item -LiteralPath $StringTablePath -Destination (Join-Path $sourceRoot 'string_table.bin') -Force
foreach ($fontName in $expectedFonts) {
    $source = @($fontFiles | Where-Object Name -CEQ $fontName)[0]
    Copy-Item -LiteralPath $source.FullName -Destination (Join-Path $fontTarget $fontName) -Force
}

$config = [ordered]@{
    Schema = 1
    GameRoot = $GameRoot
    Repository = 'erwanjun/alan-wake-2-zhcn-self-healing-launcher'
    CheckForUpdates = $true
}
$config | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $installRoot 'config.json') -Encoding UTF8

$powershell = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $powershell)) { $powershell = 'powershell.exe' }
$launcher = Join-Path $installRoot 'Start-AlanWake2-Chinese.ps1'
$desktop = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktop '心灵杀手2 中文自愈启动器.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $powershell
$shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$launcher`""
$shortcut.WorkingDirectory = $GameRoot
$shortcut.IconLocation = (Join-Path $GameRoot 'AlanWake2.exe') + ',0'
$shortcut.Description = '自动维护《心灵杀手 2》中文与多字体补丁'
$shortcut.Save()

Write-Host "配置完成：$shortcutPath" -ForegroundColor Green
if (-not $SkipInitialRepair) {
    & $powershell -NoProfile -ExecutionPolicy Bypass -File $launcher -RepairOnly
    if ($LASTEXITCODE -ne 0) { throw "首次修复失败，退出代码：$LASTEXITCODE" }
    Write-Host '首次修复完成。以后请用桌面快捷方式启动游戏。' -ForegroundColor Green
}

