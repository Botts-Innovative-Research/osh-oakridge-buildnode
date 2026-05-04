param(
    [string]$BaseDir = ".",
    [string]$MonitorDir = "",
    [string]$OutFile = ""
)

$ErrorActionPreference = 'Stop'

function Get-LatestMonitorDir {
    param([string]$Root)
    Get-ChildItem -Path $Root -Directory -Filter 'oscar-monitor-*' |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Get-SnapshotDirs {
    param([string]$Dir)
    Get-ChildItem -Path $Dir -Directory |
        Where-Object { $_.Name -match '^\d{8}-\d{6}$' } |
        Sort-Object Name
}

function Get-FirstMatchingLine {
    param(
        [string]$Path,
        [string]$Pattern
    )
    if (-not (Test-Path $Path)) { return $null }
    Select-String -Path $Path -Pattern $Pattern | Select-Object -First 1 | ForEach-Object { $_.Line }
}

function Add-Section {
    param(
        [System.Text.StringBuilder]$Sb,
        [string]$Title,
        [string[]]$Lines
    )
    [void]$Sb.AppendLine("=== $Title ===")
    foreach ($line in $Lines) {
        [void]$Sb.AppendLine($line)
    }
    [void]$Sb.AppendLine()
}

function Add-CommandOutput {
    param(
        [System.Text.StringBuilder]$Sb,
        [string]$Title,
        [scriptblock]$Script
    )
    [void]$Sb.AppendLine("=== $Title ===")
    try {
        $result = & $Script 2>&1 | Out-String
        [void]$Sb.Append($result)
    }
    catch {
        [void]$Sb.AppendLine("ERROR: $($_.Exception.Message)")
    }
    [void]$Sb.AppendLine()
}

$ResolvedBase = (Resolve-Path $BaseDir).Path
Set-Location $ResolvedBase

if ([string]::IsNullOrWhiteSpace($MonitorDir)) {
    $latest = Get-LatestMonitorDir -Root $ResolvedBase
    if (-not $latest) {
        throw "No oscar-monitor-* directory found in $ResolvedBase"
    }
    $MonitorDir = $latest.FullName
}
elseif (-not [System.IO.Path]::IsPathRooted($MonitorDir)) {
    $MonitorDir = Join-Path $ResolvedBase $MonitorDir
}

if (-not (Test-Path $MonitorDir)) {
    throw "Monitor directory not found: $MonitorDir"
}

if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $OutFile = Join-Path $ResolvedBase ("oscar-status-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
elseif (-not [System.IO.Path]::IsPathRooted($OutFile)) {
    $OutFile = Join-Path $ResolvedBase $OutFile
}

$Snapshots = Get-SnapshotDirs -Dir $MonitorDir
$FirstSnap = $Snapshots | Select-Object -First 1
$LastSnap  = $Snapshots | Select-Object -Last 1

$JvmPidFile = Join-Path $MonitorDir 'jvm-pid.txt'
$PidFromMonitor = if (Test-Path $JvmPidFile) { (Get-Content $JvmPidFile -Raw).Trim() } else { '' }

$LiveJava = Get-CimInstance Win32_Process -Filter "Name='java.exe'" | Where-Object {
    $_.CommandLine -match 'com\.botts\.impl\.security\.SensorHubWrapper'
} | Select-Object -First 1
$LivePid = if ($LiveJava) { [string]$LiveJava.ProcessId } else { '' }

$Sb = New-Object System.Text.StringBuilder
[void]$Sb.AppendLine('OSCAR STATUS REPORT')
[void]$Sb.AppendLine("Generated: $(Get-Date -Format o)")
[void]$Sb.AppendLine("Base directory: $ResolvedBase")
[void]$Sb.AppendLine("Monitor directory: $MonitorDir")
[void]$Sb.AppendLine("Output file: $OutFile")
[void]$Sb.AppendLine()

Add-Section -Sb $Sb -Title 'PROCESS STATUS' -Lines @(
    "PID from monitor: $PidFromMonitor",
    "Live OSCAR PID:   $LivePid"
)

Add-CommandOutput -Sb $Sb -Title 'LIVE OSCAR PROCESS LIST' -Script {
    Get-CimInstance Win32_Process -Filter "Name='java.exe'" |
        Where-Object { $_.CommandLine -match 'com\.botts\.impl\.security\.SensorHubWrapper' } |
        Select-Object ProcessId, Name, CommandLine | Format-List *
}

Add-CommandOutput -Sb $Sb -Title 'DOCKER STATUS' -Script {
    docker ps --filter name=oscar-postgis-container
}

Add-CommandOutput -Sb $Sb -Title 'SYSTEM MEMORY' -Script {
    $os = Get-CimInstance Win32_OperatingSystem
    $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
    $freeGB = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
    $usedGB = [math]::Round($totalGB - $freeGB, 2)
    $totalVirtGB = [math]::Round($os.TotalVirtualMemorySize / 1MB, 2)
    $freeVirtGB = [math]::Round($os.FreeVirtualMemory / 1MB, 2)
    $usedVirtGB = [math]::Round($totalVirtGB - $freeVirtGB, 2)
    "Physical RAM total: $totalGB GB"
    "Physical RAM used:  $usedGB GB"
    "Physical RAM free:  $freeGB GB"
    "Virtual total:      $totalVirtGB GB"
    "Virtual used:       $usedVirtGB GB"
    "Virtual free:       $freeVirtGB GB"
    ''
    Get-Counter '\Memory\Committed Bytes','\Memory\Commit Limit','\Paging File(_Total)\% Usage' |
        Select-Object -ExpandProperty CounterSamples |
        Select-Object Path, CookedValue | Format-Table -AutoSize
}

if ($LivePid) {
    Add-CommandOutput -Sb $Sb -Title 'LIVE JVM PROCESS DETAILS' -Script {
        $p = Get-Process -Id $LivePid
        $perf = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process | Where-Object { $_.IDProcess -eq [int]$LivePid }
        $obj = [PSCustomObject]@{
            Id = $p.Id
            ProcessName = $p.ProcessName
            CPU = $p.CPU
            StartTime = $p.StartTime
            WorkingSetMB = [math]::Round($p.WorkingSet64 / 1MB, 2)
            PrivateMB = [math]::Round($p.PrivateMemorySize64 / 1MB, 2)
            VirtualMB = [math]::Round($p.VirtualMemorySize64 / 1MB, 2)
            HandleCount = $p.HandleCount
            ThreadCount = $p.Threads.Count
            PageFileMB = if ($perf) { [math]::Round($perf.PageFileBytes / 1MB, 2) } else { $null }
            PerfWorkingSetMB = if ($perf) { [math]::Round($perf.WorkingSet / 1MB, 2) } else { $null }
            PerfPrivateMB = if ($perf) { [math]::Round($perf.PrivateBytes / 1MB, 2) } else { $null }
        }
        $obj | Format-List *
    }

    if (Get-Command jcmd -ErrorAction SilentlyContinue) {
        Add-CommandOutput -Sb $Sb -Title 'LIVE JVM JFR STATUS' -Script { jcmd $LivePid JFR.check }
        Add-CommandOutput -Sb $Sb -Title 'LIVE JVM GC HEAP INFO' -Script { jcmd $LivePid GC.heap_info }
        Add-CommandOutput -Sb $Sb -Title 'LIVE JVM NATIVE MEMORY SUMMARY' -Script { jcmd $LivePid VM.native_memory summary }
    }
    else {
        Add-Section -Sb $Sb -Title 'LIVE JVM TOOLING' -Lines @('jcmd not found on PATH')
    }
}

$FirstProc = if ($FirstSnap) { Join-Path $FirstSnap.FullName 'process.txt' } else { '' }
$FirstPerf = if ($FirstSnap) { Join-Path $FirstSnap.FullName 'perfproc.txt' } else { '' }
$FirstNmt  = if ($FirstSnap) { Join-Path $FirstSnap.FullName 'nmt-summary.txt' } else { '' }
$FirstGc   = if ($FirstSnap) { Join-Path $FirstSnap.FullName 'gc-heap-info.txt' } else { '' }

$LastProc = if ($LastSnap) { Join-Path $LastSnap.FullName 'process.txt' } else { '' }
$LastPerf = if ($LastSnap) { Join-Path $LastSnap.FullName 'perfproc.txt' } else { '' }
$LastNmt  = if ($LastSnap) { Join-Path $LastSnap.FullName 'nmt-summary.txt' } else { '' }
$LastGc   = if ($LastSnap) { Join-Path $LastSnap.FullName 'gc-heap-info.txt' } else { '' }

Add-Section -Sb $Sb -Title 'FIRST SNAPSHOT SUMMARY' -Lines @(
    "First snapshot: $($FirstSnap.FullName)",
    (Get-FirstMatchingLine -Path $FirstProc -Pattern '^WorkingSet64\s*:'),
    (Get-FirstMatchingLine -Path $FirstProc -Pattern '^PrivateMemorySize64\s*:'),
    (Get-FirstMatchingLine -Path $FirstProc -Pattern '^VirtualMemorySize64\s*:'),
    (Get-FirstMatchingLine -Path $FirstProc -Pattern '^ThreadCount\s*:'),
    (Get-FirstMatchingLine -Path $FirstPerf -Pattern '^PageFileBytes\s*:'),
    (Get-FirstMatchingLine -Path $FirstNmt -Pattern '^Total:')
).Where({ $_ }))

if (Test-Path $FirstGc) {
    Add-CommandOutput -Sb $Sb -Title 'FIRST SNAPSHOT GC HEAP INFO' -Script { Get-Content $FirstGc }
}

Add-Section -Sb $Sb -Title 'LATEST SNAPSHOT SUMMARY' -Lines @(
    "Latest snapshot: $($LastSnap.FullName)",
    (Get-FirstMatchingLine -Path $LastProc -Pattern '^WorkingSet64\s*:'),
    (Get-FirstMatchingLine -Path $LastProc -Pattern '^PrivateMemorySize64\s*:'),
    (Get-FirstMatchingLine -Path $LastProc -Pattern '^VirtualMemorySize64\s*:'),
    (Get-FirstMatchingLine -Path $LastProc -Pattern '^ThreadCount\s*:'),
    (Get-FirstMatchingLine -Path $LastPerf -Pattern '^PageFileBytes\s*:'),
    (Get-FirstMatchingLine -Path $LastNmt -Pattern '^Total:')
).Where({ $_ }))

if (Test-Path $LastGc) {
    Add-CommandOutput -Sb $Sb -Title 'LATEST SNAPSHOT GC HEAP INFO' -Script { Get-Content $LastGc }
}

[void]$Sb.AppendLine('=== RECENT TREND (LAST 20 SNAPSHOTS) ===')
$Recent = $Snapshots | Select-Object -Last 20
foreach ($snap in $Recent) {
    $proc = Join-Path $snap.FullName 'process.txt'
    $perf = Join-Path $snap.FullName 'perfproc.txt'
    $nmt  = Join-Path $snap.FullName 'nmt-summary.txt'
    $parts = @($snap.Name)

    $ws = Get-FirstMatchingLine -Path $proc -Pattern '^WorkingSet64\s*:'
    if ($ws) { $parts += ($ws -replace '^\s+', '') }
    $priv = Get-FirstMatchingLine -Path $proc -Pattern '^PrivateMemorySize64\s*:'
    if ($priv) { $parts += ($priv -replace '^\s+', '') }
    $thr = Get-FirstMatchingLine -Path $proc -Pattern '^ThreadCount\s*:'
    if ($thr) { $parts += ($thr -replace '^\s+', '') }
    $pf = Get-FirstMatchingLine -Path $perf -Pattern '^PageFileBytes\s*:'
    if ($pf) { $parts += ($pf -replace '^\s+', '') }
    $tot = Get-FirstMatchingLine -Path $nmt -Pattern '^Total:'
    if ($tot) { $parts += $tot }

    [void]$Sb.AppendLine(($parts -join ' | '))
}
[void]$Sb.AppendLine()

$StdoutLog = Join-Path $MonitorDir 'launch.stdout.log'
$StderrLog = Join-Path $MonitorDir 'launch.stderr.log'
if (Test-Path $StdoutLog) {
    Add-CommandOutput -Sb $Sb -Title 'LAUNCH STDOUT TAIL (LAST 50 LINES)' -Script { Get-Content $StdoutLog -Tail 50 }
}
if (Test-Path $StderrLog) {
    Add-CommandOutput -Sb $Sb -Title 'LAUNCH STDERR TAIL (LAST 50 LINES)' -Script { Get-Content $StderrLog -Tail 50 }
}

$FirstWs = Get-FirstMatchingLine -Path $FirstProc -Pattern '^WorkingSet64\s*:'
$LastWs  = Get-FirstMatchingLine -Path $LastProc -Pattern '^WorkingSet64\s*:'
$FirstPriv = Get-FirstMatchingLine -Path $FirstProc -Pattern '^PrivateMemorySize64\s*:'
$LastPriv  = Get-FirstMatchingLine -Path $LastProc -Pattern '^PrivateMemorySize64\s*:'
$FirstThr = Get-FirstMatchingLine -Path $FirstProc -Pattern '^ThreadCount\s*:'
$LastThr  = Get-FirstMatchingLine -Path $LastProc -Pattern '^ThreadCount\s*:'
$FirstPf = Get-FirstMatchingLine -Path $FirstPerf -Pattern '^PageFileBytes\s*:'
$LastPf  = Get-FirstMatchingLine -Path $LastPerf -Pattern '^PageFileBytes\s*:'

Add-Section -Sb $Sb -Title 'QUICK READ' -Lines @(
    "First WorkingSet64:  $FirstWs",
    "Latest WorkingSet64: $LastWs",
    "First PrivateMemory: $FirstPriv",
    "Latest PrivateMemory: $LastPriv",
    "First ThreadCount:   $FirstThr",
    "Latest ThreadCount:  $LastThr",
    "First PageFileBytes: $FirstPf",
    "Latest PageFileBytes: $LastPf",
    '',
    'Interpretation guide:',
    '- Healthy: working set, pagefile bytes, private bytes, and thread count rise at startup and then flatten.',
    '- Suspicious: working set, pagefile bytes, private bytes, or thread count keep climbing hour after hour.',
    '- Pagefile usage alone is not failure; rising committed bytes, shrinking available memory, and repeated hard faults are more concerning.'
)

[System.IO.File]::WriteAllText($OutFile, $Sb.ToString())
Write-Host "Wrote report to: $OutFile"
