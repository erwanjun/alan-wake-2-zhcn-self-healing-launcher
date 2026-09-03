param(
    [string]$GameRoot,
    [switch]$RepairOnly,
    [switch]$AuditOnly,
    [switch]$NoElevation,
    [switch]$SkipSelfUpdate
)

$ErrorActionPreference = 'Stop'
$runtimeRoot = $PSScriptRoot
$configPath = Join-Path $runtimeRoot 'config.json'
$config = if (Test-Path -LiteralPath $configPath) {
    Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
} else {
    $null
}
if (-not $GameRoot -and $config -and $config.GameRoot) { $GameRoot = [string]$config.GameRoot }
if (-not $GameRoot) {
    throw '尚未配置游戏目录。请先运行 Setup.ps1。'
}
$GameRoot = [IO.Path]::GetFullPath($GameRoot).TrimEnd('\')
$statePath = Join-Path $runtimeRoot 'state.json'
$sourceTable = Join-Path $runtimeRoot 'sources\string_table.bin'
$sourceFonts = Join-Path $runtimeRoot 'sources\fonts'
$toolAssembly = Join-Path $runtimeRoot 'tools\Aw2Rmdtoc.dll'
$lz4Assembly = Join-Path $runtimeRoot 'tools\LZ4.dll'
$gameExe = Join-Path $GameRoot 'AlanWake2.exe'
$genericToc = Join-Path $GameRoot 'data_pack2\pc\base-generic.rmdtoc'
$englishToc = Join-Path $GameRoot 'data_pack2\pc\base-en.rmdtoc'
$englishPrimaryBlob = Join-Path $GameRoot 'data_pack2\pc\base-en-000.rmdblob'
$logPath = Join-Path $runtimeRoot 'logs\launcher.log'

New-Item -ItemType Directory -Path (Split-Path -Parent $logPath) -Force | Out-Null

function Write-Log([string]$Message) {
    $line = "{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $Message
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    Write-Host $Message
}

function Get-SHA256([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

function Get-ByteSHA256([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Get-FontSourceDigest {
    $lines = foreach ($file in Get-ChildItem -LiteralPath $sourceFonts -Recurse -File | Sort-Object FullName) {
        $relative = $file.FullName.Substring($sourceFonts.Length).TrimStart('\').Replace('\', '/')
        "$relative`:$((Get-SHA256 $file.FullName))"
    }
    return Get-ByteSHA256 ([Text.Encoding]::UTF8.GetBytes(($lines -join "`n")))
}

function Import-PackTool {
    if (-not ('alan_wake_2_rmdtoc_Tool.rmdtoc' -as [type])) {
        [void][Reflection.Assembly]::LoadFrom($lz4Assembly)
        [void][Reflection.Assembly]::LoadFrom($toolAssembly)
    }
}

function Resolve-GameBlobPath([string]$Reference) {
    $relative = $Reference.Replace('/', '\')
    if ($relative.StartsWith('..\pc\')) {
        return Join-Path $GameRoot ('data_pack2\pc\' + $relative.Substring(6))
    }
    if ($relative.StartsWith('..\generic\')) {
        return Join-Path $GameRoot ('data_pack2\generic\' + $relative.Substring(11))
    }
    return [IO.Path]::GetFullPath((Join-Path (Join-Path $GameRoot 'data_pack2\pc') $relative))
}

function Resolve-StageBlobPath([string]$StagePcDirectory, [string]$Reference) {
    $relative = $Reference.Replace('/', '\')
    if ($relative.StartsWith('..\pc\')) {
        return Join-Path $StagePcDirectory $relative.Substring(6)
    }
    return [IO.Path]::GetFullPath((Join-Path $StagePcDirectory $relative))
}

function Copy-Atomic([string]$Source, [string]$Destination, [string]$Suffix = 'self-heal') {
    $temporary = "$Destination.$Suffix.tmp"
    $replaceBackup = "$Destination.$Suffix.replace-backup"
    Copy-Item -LiteralPath $Source -Destination $temporary -Force
    [IO.File]::Replace($temporary, $Destination, $replaceBackup, $true)
    Remove-Item -LiteralPath $replaceBackup -Force
}

function Read-Aw2StringTable([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $reader = [IO.BinaryReader]::new($stream, [Text.Encoding]::UTF8, $false)
    try {
        $count = $reader.ReadInt32()
        $entries = [Collections.Generic.List[object]]::new($count)
        for ($index = 0; $index -lt $count; $index++) {
            $nameLength = $reader.ReadInt32()
            $name = [Text.Encoding]::UTF8.GetString($reader.ReadBytes($nameLength))
            $valueLength = $reader.ReadInt32()
            $value = [Text.Encoding]::Unicode.GetString($reader.ReadBytes($valueLength * 2))
            $entries.Add([pscustomobject]@{ Name = $name; Value = $value })
        }
        if ($stream.Position -ne $stream.Length) { throw "Unexpected trailing bytes in $Path" }
        return ,$entries
    }
    finally { $reader.Dispose() }
}

function Write-Aw2StringTable([Collections.IList]$Entries, [string]$Path) {
    $stream = [IO.File]::Open($Path, 'Create', 'Write', 'None')
    $writer = [IO.BinaryWriter]::new($stream, [Text.Encoding]::UTF8, $false)
    try {
        $writer.Write([int]$Entries.Count)
        foreach ($entry in $Entries) {
            $nameBytes = [Text.Encoding]::UTF8.GetBytes($entry.Name)
            $valueBytes = [Text.Encoding]::Unicode.GetBytes($entry.Value)
            $writer.Write([int]$nameBytes.Length)
            $writer.Write($nameBytes)
            $writer.Write([int]($valueBytes.Length / 2))
            $writer.Write($valueBytes)
        }
    }
    finally { $writer.Dispose() }
}

function New-MergedStringTable([string]$BaseTablePath, [string]$OutputPath) {
    $baseEntries = Read-Aw2StringTable $BaseTablePath
    $translatedEntries = Read-Aw2StringTable $sourceTable
    # Some Remedy tables intentionally contain duplicate keys. Preserve their
    # occurrence order instead of collapsing them into a last-value-wins map.
    $translations = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($entry in $translatedEntries) {
        if (-not $translations.ContainsKey($entry.Name)) {
            $translations[$entry.Name] = [Collections.Generic.Queue[string]]::new()
        }
        $translations[$entry.Name].Enqueue($entry.Value)
    }

    $translated = 0
    $fallback = 0
    foreach ($entry in $baseEntries) {
        if ($translations.ContainsKey($entry.Name) -and $translations[$entry.Name].Count -gt 0) {
            $entry.Value = $translations[$entry.Name].Dequeue()
            $translated++
        } else {
            $fallback++
        }
        if ($entry.Name -ceq 'MENU_OPTIONS_LANGUAGE_EN') {
            $entry.Value = '中文（修订多字体／英语语音）'
        }
    }
    Write-Aw2StringTable $baseEntries $OutputPath
    return [pscustomobject]@{ Total = $baseEntries.Count; Translated = $translated; EnglishFallback = $fallback }
}

function New-SparseFile([string]$Path, [long]$Length) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllBytes($Path, [byte[]]::new(0))
    & fsutil sparse setflag $Path | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not mark staging file sparse: $Path" }
    $stream = [IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
    try { $stream.SetLength($Length) }
    finally { $stream.Dispose() }
}

function Copy-RangeToFile([string]$Source, [long]$Offset, [string]$Destination) {
    $input = [IO.File]::OpenRead($Source)
    $output = [IO.File]::Create($Destination)
    try { $input.Position = $Offset; $input.CopyTo($output, 4MB) }
    finally { $input.Dispose(); $output.Dispose() }
}

function Assert-FilesEqual([string]$Left, [string]$Right, [long]$RightOffset = 0) {
    $leftStream = [IO.File]::OpenRead($Left)
    $rightStream = [IO.File]::OpenRead($Right)
    try {
        $rightStream.Position = $RightOffset
        $leftBuffer = [byte[]]::new(1MB)
        $rightBuffer = [byte[]]::new(1MB)
        while (($count = $leftStream.Read($leftBuffer, 0, $leftBuffer.Length)) -gt 0) {
            if ($rightStream.Read($rightBuffer, 0, $count) -ne $count) { throw "Short comparison read: $Right" }
            for ($index = 0; $index -lt $count; $index++) {
                if ($leftBuffer[$index] -ne $rightBuffer[$index]) { throw "File comparison failed: $Left vs $Right" }
            }
        }
    }
    finally { $leftStream.Dispose(); $rightStream.Dispose() }
}

function New-GenericPlan([string]$SessionRoot) {
    Import-PackTool
    $originalTocHash = Get-SHA256 $genericToc
    $stagePc = Join-Path $SessionRoot 'generic\data_pack2\pc'
    New-Item -ItemType Directory -Path $stagePc -Force | Out-Null
    $stageToc = Join-Path $stagePc 'base-generic.rmdtoc'
    Copy-Item -LiteralPath $genericToc -Destination $stageToc

    $toc = [alan_wake_2_rmdtoc_Tool.rmdtoc]::new($stageToc)
    $targets = [Collections.Generic.List[object]]::new()
    $blobIndexes = [Collections.Generic.HashSet[int]]::new()
    try {
        foreach ($source in Get-ChildItem -LiteralPath $sourceFonts -Recurse -File | Where-Object Extension -Match '^\.(ttf|otf|ttc)$') {
            $matches = @($toc.Files | Where-Object Name -CEQ $source.Name)
            if ($matches.Count -ne 1) { throw "Font $($source.Name) occurs $($matches.Count) times in the updated base-generic index." }
            if ($matches[0].CompressInfos.Count -lt 1) { throw "Font has no blob record: $($source.Name)" }
            [void]$blobIndexes.Add([int]$matches[0].CompressInfos[0].FileIndex)
            $targets.Add([pscustomobject]@{ Source = $source.FullName; Entry = $matches[0] })
        }

        $blobPlans = [Collections.Generic.List[object]]::new()
        foreach ($index in $blobIndexes) {
            $reference = $toc.RMDBLOBPaths[$index].Path
            $actual = Resolve-GameBlobPath $reference
            if (-not (Test-Path -LiteralPath $actual -PathType Leaf)) { throw "Missing updated blob: $actual" }
            $stageBlob = Resolve-StageBlobPath $stagePc $reference
            $originalLength = (Get-Item -LiteralPath $actual).Length
            New-SparseFile $stageBlob $originalLength
            $blobPlans.Add([pscustomobject]@{
                Index = $index; Reference = $reference; ActualPath = $actual
                StagePath = $stageBlob; OriginalLength = $originalLength
            })
        }

        foreach ($target in $targets) {
            $target.Entry.NewFileBytes = [IO.File]::ReadAllBytes($target.Source)
            $target.Entry.IsEdited = $true
        }
        $toc.Save()
    }
    finally { $toc.Dispose() }

    $toc = [alan_wake_2_rmdtoc_Tool.rmdtoc]::new($stageToc)
    try {
        foreach ($target in $targets) {
            $entry = @($toc.Files | Where-Object Name -CEQ ([IO.Path]::GetFileName($target.Source)))[0]
            $packedHash = Get-ByteSHA256 $entry.GetFile()
            if ($packedHash -cne (Get-SHA256 $target.Source)) { throw "Packed font verification failed: $($target.Source)" }
        }
    }
    finally { $toc.Dispose() }

    foreach ($plan in $blobPlans) {
        $plan | Add-Member NewLength (Get-Item -LiteralPath $plan.StagePath).Length
        $tail = Join-Path $SessionRoot ("generic-tail-{0}.append" -f $plan.Index)
        Copy-RangeToFile $plan.StagePath $plan.OriginalLength $tail
        $plan | Add-Member TailPath $tail
    }
    return [pscustomobject]@{ TocPath = $stageToc; OriginalTocSHA256 = $originalTocHash; Blobs = @($blobPlans); FontCount = $targets.Count }
}

function New-EnglishPlan([string]$SessionRoot) {
    Import-PackTool
    $originalTocHash = Get-SHA256 $englishToc
    $stagePc = Join-Path $SessionRoot 'english\data_pack2\pc'
    New-Item -ItemType Directory -Path $stagePc -Force | Out-Null
    $stageToc = Join-Path $stagePc 'base-en.rmdtoc'
    Copy-Item -LiteralPath $englishToc -Destination $stageToc

    $toc = [alan_wake_2_rmdtoc_Tool.rmdtoc]::new($stageToc)
    try {
        $target = @($toc.Files | Where-Object Name -CEQ 'string_table.bin')
        if ($target.Count -ne 1 -or $target[0].CompressInfos.Count -lt 1) { throw 'The updated English pack has no unique string_table.bin.' }
        $indexes = @($target[0].CompressInfos | ForEach-Object FileIndex | Sort-Object -Unique)
        foreach ($index in $indexes) {
            $reference = $toc.RMDBLOBPaths[$index].Path
            $actual = Resolve-GameBlobPath $reference
            $stageBlob = Resolve-StageBlobPath $stagePc $reference
            New-Item -ItemType Directory -Path (Split-Path -Parent $stageBlob) -Force | Out-Null
            Copy-Item -LiteralPath $actual -Destination $stageBlob
        }
        $baseTable = Join-Path $SessionRoot 'updated-base-en-string_table.bin'
        [IO.File]::WriteAllBytes($baseTable, $target[0].GetFile())
        $mergedTable = Join-Path $SessionRoot 'merged-string_table.bin'
        $merge = New-MergedStringTable $baseTable $mergedTable
        $target[0].NewFileBytes = [IO.File]::ReadAllBytes($mergedTable)
        $target[0].IsEdited = $true
        $modifiedBlobIndex = [int]$target[0].CompressInfos[0].FileIndex
        $modifiedReference = $toc.RMDBLOBPaths[$modifiedBlobIndex].Path
        $toc.Save()
    }
    finally { $toc.Dispose() }

    $toc = [alan_wake_2_rmdtoc_Tool.rmdtoc]::new($stageToc)
    try {
        $packed = @($toc.Files | Where-Object Name -CEQ 'string_table.bin')[0].GetFile()
        if ((Get-ByteSHA256 $packed) -cne (Get-SHA256 $mergedTable)) { throw 'Packed merged string table failed verification.' }
    }
    finally { $toc.Dispose() }

    $stageBlob = Resolve-StageBlobPath $stagePc $modifiedReference
    return [pscustomobject]@{
        TocPath = $stageToc
        OriginalTocSHA256 = $originalTocHash
        BlobPath = $stageBlob
        ActualBlobPath = Resolve-GameBlobPath $modifiedReference
        OriginalBlobSHA256 = Get-SHA256 (Resolve-GameBlobPath $modifiedReference)
        Merge = $merge
    }
}

function Test-CanWriteGameDirectory {
    $probe = Join-Path (Split-Path -Parent $genericToc) ('.aw2-self-heal-write-test-' + [guid]::NewGuid().ToString('N'))
    try { [IO.File]::WriteAllBytes($probe, [byte[]]::new(0)); return $true }
    catch { return $false }
    finally { if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Force } }
}

function Invoke-ElevatedRepair {
    $pwsh = if ($PSVersionTable.PSEdition -eq 'Core') {
        Join-Path $PSHOME 'pwsh.exe'
    } else {
        Join-Path $PSHOME 'powershell.exe'
    }
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -GameRoot `"$GameRoot`" -RepairOnly -SkipSelfUpdate -NoElevation"
    $process = Start-Process -FilePath $pwsh -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Elevated repair exited with code $($process.ExitCode)." }
}

function Assert-PackNotLocked([string[]]$Paths) {
    foreach ($path in $Paths | Sort-Object -Unique) {
        $stream = [IO.File]::Open($path, 'Open', 'ReadWrite', 'None')
        $stream.Dispose()
    }
}

function Append-PlanBlob($Plan) {
    $currentLength = (Get-Item -LiteralPath $Plan.ActualPath).Length
    if ($currentLength -ne $Plan.OriginalLength) { throw "Blob changed during staging: $($Plan.ActualPath)" }
    $input = [IO.File]::OpenRead($Plan.TailPath)
    $output = [IO.File]::Open($Plan.ActualPath, 'Open', 'Write', 'None')
    try { $output.Position = $output.Length; $input.CopyTo($output, 4MB); $output.Flush($true) }
    finally { $input.Dispose(); $output.Dispose() }
    Assert-FilesEqual $Plan.TailPath $Plan.ActualPath $Plan.OriginalLength
}

function Remove-OldBackups {
    $directories = @(Get-ChildItem -LiteralPath (Join-Path $runtimeRoot 'backups') -Directory | Sort-Object Name -Descending)
    foreach ($directory in $directories | Select-Object -Skip 2) {
        Remove-Item -LiteralPath $directory.FullName -Recurse -Force
    }
}

function Save-State([string]$LastBackup, [string]$EnglishBlobPath) {
    $englishBlobRelative = $EnglishBlobPath.Substring($GameRoot.Length).TrimStart('\')
    $state = [ordered]@{
        Schema = 1
        InstalledAt = (Get-Date).ToString('o')
        GameVersion = (Get-Item -LiteralPath $gameExe).VersionInfo.FileVersion
        GenericTocSHA256 = Get-SHA256 $genericToc
        EnglishTocSHA256 = Get-SHA256 $englishToc
        EnglishPrimaryBlobRelativePath = $englishBlobRelative
        EnglishPrimaryBlobSHA256 = Get-SHA256 $EnglishBlobPath
        SourceTableSHA256 = Get-SHA256 $sourceTable
        SourceFontsDigest = Get-FontSourceDigest
        LastBackup = $LastBackup
    }
    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8
}

function Start-Game {
    Write-Log 'Starting Alan Wake 2.'
    Start-Process -FilePath $gameExe -WorkingDirectory $GameRoot
}

function Invoke-SelfUpdate {
    if ($SkipSelfUpdate -or $AuditOnly -or ($config -and $config.CheckForUpdates -eq $false)) { return }
    $updater = Join-Path $runtimeRoot 'Update-Self.ps1'
    if (-not (Test-Path -LiteralPath $updater -PathType Leaf)) { return }
    $repository = if ($config -and $config.Repository) { [string]$config.Repository } else { 'erwanjun/alan-wake-2-zhcn-self-healing-launcher' }
    $powershell = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'powershell.exe' }
    & $powershell -NoProfile -ExecutionPolicy Bypass -File $updater -InstallRoot $runtimeRoot -Repository $repository
    $updateExitCode = $LASTEXITCODE
    if ($updateExitCode -eq 10) {
        Write-Log '启动器已自动更新，正在重新启动。'
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -GameRoot `"$GameRoot`" -SkipSelfUpdate"
        if ($RepairOnly) { $arguments += ' -RepairOnly' }
        if ($AuditOnly) { $arguments += ' -AuditOnly' }
        if ($NoElevation) { $arguments += ' -NoElevation' }
        Start-Process -FilePath $powershell -ArgumentList $arguments
        exit 0
    }
    if ($updateExitCode -ne 0) { Write-Log '自动更新检查失败；将继续使用当前版本。' }
}

try {
    Invoke-SelfUpdate
    foreach ($required in @($gameExe, $genericToc, $englishToc, $sourceTable, $toolAssembly, $lz4Assembly)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing required file: $required" }
    }
    if (Get-Process -Name AlanWake2 -ErrorAction SilentlyContinue) {
        Write-Log 'Alan Wake 2 is already running; no repair was attempted.'
        exit 0
    }

    $state = if (Test-Path -LiteralPath $statePath) { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } else { $null }
    $monitoredEnglishBlob = if ($state -and $state.EnglishPrimaryBlobRelativePath) {
        Join-Path $GameRoot $state.EnglishPrimaryBlobRelativePath
    } else {
        $englishPrimaryBlob
    }
    $currentFontDigest = Get-FontSourceDigest
    $currentTableHash = Get-SHA256 $sourceTable
    $genericNeedsRepair = $null -eq $state -or (Get-SHA256 $genericToc) -cne $state.GenericTocSHA256 -or $currentFontDigest -cne $state.SourceFontsDigest
    $englishNeedsRepair = $null -eq $state -or (Get-SHA256 $englishToc) -cne $state.EnglishTocSHA256 -or (Get-SHA256 $monitoredEnglishBlob) -cne $state.EnglishPrimaryBlobSHA256 -or $currentTableHash -cne $state.SourceTableSHA256

    if (-not $genericNeedsRepair -and -not $englishNeedsRepair) {
        Write-Log 'Chinese pack state is current; no rebuild needed.'
        if (-not $RepairOnly -and -not $AuditOnly) { Start-Game }
        exit 0
    }

    $reason = @()
    if ($genericNeedsRepair) { $reason += 'generic/font resources changed' }
    if ($englishNeedsRepair) { $reason += 'English text pack or translation source changed' }
    Write-Log ("Repair required: " + ($reason -join '; '))
    if ($AuditOnly) { exit 2 }

    if (-not (Test-CanWriteGameDirectory)) {
        if ($NoElevation) { throw 'The game directory is not writable in the current process.' }
        Write-Log 'Requesting administrator permission for this post-update repair only.'
        Invoke-ElevatedRepair
        if (-not $RepairOnly) { Start-Game }
        exit 0
    }

    $sessionRoot = Join-Path $env:TEMP ('aw2-self-heal-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $sessionRoot | Out-Null
    try {
        $genericPlan = if ($genericNeedsRepair) { New-GenericPlan $sessionRoot } else { $null }
        $englishPlan = if ($englishNeedsRepair) { New-EnglishPlan $sessionRoot } else { $null }

        # Abort before any write if Epic or another updater touched the packs
        # while the offline staging and verification were running.
        if ($genericPlan -and (Get-SHA256 $genericToc) -cne $genericPlan.OriginalTocSHA256) {
            throw 'base-generic changed while the repair was being staged.'
        }
        if ($englishPlan -and ((Get-SHA256 $englishToc) -cne $englishPlan.OriginalTocSHA256 -or (Get-SHA256 $englishPlan.ActualBlobPath) -cne $englishPlan.OriginalBlobSHA256)) {
            throw 'The English pack changed while the repair was being staged.'
        }

        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backup = Join-Path (Join-Path $runtimeRoot 'backups') $stamp
        New-Item -ItemType Directory -Path $backup | Out-Null
        $rollback = [ordered]@{ GenericBlobs = @() }
        if ($genericPlan) {
            Copy-Item -LiteralPath $genericToc -Destination (Join-Path $backup 'base-generic.rmdtoc')
            foreach ($blob in $genericPlan.Blobs) {
                $rollback.GenericBlobs += [ordered]@{ Path = $blob.ActualPath; OriginalLength = $blob.OriginalLength; NewLength = $blob.NewLength }
            }
        }
        if ($englishPlan) {
            Copy-Item -LiteralPath $englishToc -Destination (Join-Path $backup 'base-en.rmdtoc')
            Copy-Item -LiteralPath $englishPlan.ActualBlobPath -Destination (Join-Path $backup ([IO.Path]::GetFileName($englishPlan.ActualBlobPath)))
            $rollback.EnglishBlobPath = $englishPlan.ActualBlobPath
        }
        $rollback | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $backup 'rollback.json') -Encoding UTF8

        $lockPaths = @($genericToc, $englishToc)
        if ($genericPlan) { $lockPaths += $genericPlan.Blobs.ActualPath }
        if ($englishPlan) { $lockPaths += $englishPlan.ActualBlobPath }
        Assert-PackNotLocked $lockPaths

        try {
            if ($genericPlan) {
                foreach ($blob in $genericPlan.Blobs) { Append-PlanBlob $blob }
                Copy-Atomic $genericPlan.TocPath $genericToc 'self-heal-generic'
            }
            if ($englishPlan) {
                Copy-Atomic $englishPlan.BlobPath $englishPlan.ActualBlobPath 'self-heal-english-blob'
                Copy-Atomic $englishPlan.TocPath $englishToc 'self-heal-english-toc'
            }
        }
        catch {
            $installFailure = $_
            if ($genericPlan) {
                Copy-Item -LiteralPath (Join-Path $backup 'base-generic.rmdtoc') -Destination $genericToc -Force
                foreach ($blob in $genericPlan.Blobs) {
                    $currentLength = (Get-Item -LiteralPath $blob.ActualPath).Length
                    if ($currentLength -ge $blob.OriginalLength -and $currentLength -le $blob.NewLength) {
                        $stream = [IO.File]::Open($blob.ActualPath, 'Open', 'Write', 'None')
                        try { $stream.SetLength($blob.OriginalLength) } finally { $stream.Dispose() }
                    }
                }
            }
            if ($englishPlan) {
                Copy-Item -LiteralPath (Join-Path $backup 'base-en.rmdtoc') -Destination $englishToc -Force
                Copy-Item -LiteralPath (Join-Path $backup ([IO.Path]::GetFileName($englishPlan.ActualBlobPath))) -Destination $englishPlan.ActualBlobPath -Force
            }
            throw "Post-update repair failed and was rolled back: $installFailure"
        }

        $stateEnglishBlob = if ($englishPlan) { $englishPlan.ActualBlobPath } else { $monitoredEnglishBlob }
        Save-State $backup $stateEnglishBlob
        Remove-OldBackups
        if ($englishPlan) {
            Write-Log ("Repair complete. Text entries: {0}; translated: {1}; English fallback for new keys: {2}." -f $englishPlan.Merge.Total, $englishPlan.Merge.Translated, $englishPlan.Merge.EnglishFallback)
        } else {
            Write-Log 'Repair complete. Font resources were rebuilt.'
        }
    }
    finally {
        if (Test-Path -LiteralPath $sessionRoot) { Remove-Item -LiteralPath $sessionRoot -Recurse -Force }
    }

    if (-not $RepairOnly) { Start-Game }
    exit 0
}
catch {
    Write-Log ("ERROR: " + $_)
    if (-not $RepairOnly -and -not $AuditOnly) { [void](Read-Host 'Press Enter to close') }
    exit 1
}
