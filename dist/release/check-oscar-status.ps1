param(
    [string]$BaseDir = ".",
    [string]$MonitorDir = "",
    [string]$OutFile = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'
Set-Location $BaseDir

if ([string]::IsNullOrWhiteSpace($MonitorDir)) {
    $MonitorDir = Get-ChildItem -Directory -Filter 'oscar-monitor-*' | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $MonitorDir -or -not (Test-Path $MonitorDir)) { throw 'No oscar-monitor-* directory found.' }
if ([string]::IsNullOrWhiteSpace($OutFile)) { $OutFile = Join-Path (Get-Location) ("oscar-status-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss')) }

$snaps = Get-ChildItem -Path $MonitorDir -Directory | Sort-Object Name
$first = $snaps | Select-Object -First 1
$last = $snaps | Select-Object -Last 1
$jvmPidFile = Join-Path $MonitorDir 'jvm-pid.txt'
$pidFromMonitor = if (Test-Path $jvmPidFile) { (Get-Content $jvmPidFile | Select-Object -First 1).Trim() } else { '' }
$javaProc = Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'java.exe' -and $_.CommandLine -match 'SensorHubWrapper' } | Select-Object -First 1

function Read-Text([string]$Path) { if (Test-Path $Path) { Get-Content $Path -Raw } else { '' } }
function Read-First([string]$Path) { if (Test-Path $Path) { (Get-Content $Path | Select-Object -First 1).Trim() } else { '' } }
function Extract-DbCount([string]$Path, [string]$State) {
    if (-not (Test-Path $Path)) { return '' }
    foreach ($line in Get-Content $Path) {
        $parts = $line -split '\|'
        if ($parts.Count -ge 2 -and $parts[0].Trim() -eq $State) { return $parts[1].Trim() }
    }
    ''
}
function Calc-Slots($MaxConn, $Reserved) {
    if ($MaxConn -match '^\d+$' -and $Reserved -match '^\d+$') { return [int]$MaxConn - [int]$Reserved }
    ''
}

$sb = [System.Text.StringBuilder]::new()
$null = $sb.AppendLine('OSCAR STATUS REPORT')
$null = $sb.AppendLine("Generated: $(Get-Date -Format o)")
$null = $sb.AppendLine("Base directory: $(Get-Location)")
$null = $sb.AppendLine("Monitor directory: $MonitorDir")
$null = $sb.AppendLine("Output file: $OutFile")
$null = $sb.AppendLine()
$null = $sb.AppendLine('=== PROCESS STATUS ===')
$null = $sb.AppendLine("PID from monitor: $pidFromMonitor")
$null = $sb.AppendLine(("Live OSCAR PID:   {0}" -f ($(if ($javaProc) { $javaProc.ProcessId } else { '<none>' }))))
$null = $sb.AppendLine()
$null = $sb.AppendLine((Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'monitor-oscar' } | Select-Object ProcessId, Name, CommandLine | Format-Table -AutoSize | Out-String))
$null = $sb.AppendLine((Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'java.exe' -and $_.CommandLine -match 'SensorHubWrapper' } | Select-Object ProcessId, Name, CommandLine | Format-Table -AutoSize | Out-String))
$null = $sb.AppendLine((& docker ps --filter name=oscar-postgis-container | Out-String))
$null = $sb.AppendLine('=== SYSTEM MEMORY AND PAGEFILE ===')
$null = $sb.AppendLine((Get-CimInstance Win32_OperatingSystem | Select-Object TotalVisibleMemorySize,FreePhysicalMemory,TotalVirtualMemorySize,FreeVirtualMemory | Format-List | Out-String))
$null = $sb.AppendLine((Get-Counter '\Memory\Committed Bytes','\Memory\Commit Limit','\Paging File(_Total)\% Usage' | Out-String))

if ($javaProc) {
    $null = $sb.AppendLine('=== LIVE JVM PROCESS ===')
    $null = $sb.AppendLine((Get-Process -Id $javaProc.ProcessId | Select-Object Id,ProcessName,Threads,VirtualMemorySize64,WorkingSet64,PrivateMemorySize64,CPU,StartTime | Format-List | Out-String))
    $null = $sb.AppendLine('=== LIVE JVM JFR STATUS ===')
    $null = $sb.AppendLine((& jcmd $javaProc.ProcessId JFR.check | Out-String))
    $null = $sb.AppendLine('=== LIVE JVM GC HEAP INFO ===')
    $null = $sb.AppendLine((& jcmd $javaProc.ProcessId GC.heap_info | Out-String))
    $null = $sb.AppendLine('=== LIVE JVM NATIVE MEMORY SUMMARY ===')
    $null = $sb.AppendLine((& jcmd $javaProc.ProcessId VM.native_memory summary | Out-String))
}

$lastMax = Read-First (Join-Path $last.FullName 'db-max-connections.txt')
$lastReserved = Read-First (Join-Path $last.FullName 'db-superuser-reserved-connections.txt')
$lastTotal = Read-First (Join-Path $last.FullName 'db-total-sessions.txt')
$null = $sb.AppendLine('=== LIVE POSTGRES STATUS (FROM LAST SNAPSHOT) ===')
$null = $sb.AppendLine("max_connections: $lastMax")
$null = $sb.AppendLine("superuser_reserved_connections: $lastReserved")
$null = $sb.AppendLine("usable_client_slots: $(Calc-Slots $lastMax $lastReserved)")
$null = $sb.AppendLine("total_sessions: $lastTotal")
$null = $sb.AppendLine("active: $(Extract-DbCount (Join-Path $last.FullName 'db-by-state.txt') 'active')")
$null = $sb.AppendLine("idle: $(Extract-DbCount (Join-Path $last.FullName 'db-by-state.txt') 'idle')")
$null = $sb.AppendLine("idle in transaction: $(Extract-DbCount (Join-Path $last.FullName 'db-by-state.txt') 'idle in transaction')")
$null = $sb.AppendLine()
$null = $sb.AppendLine('--- db-by-state ---')
$null = $sb.AppendLine((Read-Text (Join-Path $last.FullName 'db-by-state.txt')))
$null = $sb.AppendLine('--- db-by-app ---')
$null = $sb.AppendLine((Read-Text (Join-Path $last.FullName 'db-by-app.txt')))
$null = $sb.AppendLine('--- db-error ---')
$null = $sb.AppendLine((Read-Text (Join-Path $last.FullName 'db-error.txt')))

$null = $sb.AppendLine('=== FIRST SNAPSHOT SUMMARY ===')
$null = $sb.AppendLine("First snapshot: $($first.FullName)")
$null = $sb.AppendLine((Read-Text (Join-Path $first.FullName 'powershell-process.txt')))
$null = $sb.AppendLine("db total sessions: $(Read-First (Join-Path $first.FullName 'db-total-sessions.txt'))")
$null = $sb.AppendLine('=== LATEST SNAPSHOT SUMMARY ===')
$null = $sb.AppendLine("Latest snapshot: $($last.FullName)")
$null = $sb.AppendLine((Read-Text (Join-Path $last.FullName 'powershell-process.txt')))
$null = $sb.AppendLine("db total sessions: $(Read-First (Join-Path $last.FullName 'db-total-sessions.txt'))")

$null = $sb.AppendLine('=== RECENT TREND (LAST 20 SNAPSHOTS) ===')
foreach ($d in ($snaps | Select-Object -Last 20)) {
    $dbTotal = Read-First (Join-Path $d.FullName 'db-total-sessions.txt')
    $dbMax = Read-First (Join-Path $d.FullName 'db-max-connections.txt')
    $dbReserved = Read-First (Join-Path $d.FullName 'db-superuser-reserved-connections.txt')
    $dbActive = Extract-DbCount (Join-Path $d.FullName 'db-by-state.txt') 'active'
    $dbIdle = Extract-DbCount (Join-Path $d.FullName 'db-by-state.txt') 'idle'
    $proc = (Read-Text (Join-Path $d.FullName 'powershell-process.txt')) -replace '\r?\n',' '
    $null = $sb.AppendLine("$($d.Name) $proc db_total=$dbTotal db_active=$dbActive db_idle=$dbIdle db_slots=$(Calc-Slots $dbMax $dbReserved)")
}
$null = $sb.AppendLine()

$dbCsv = Join-Path $MonitorDir 'db-connection-trend.csv'
if (Test-Path $dbCsv) {
    $null = $sb.AppendLine('=== DB CONNECTION TREND CSV (LAST 40 LINES) ===')
    $null = $sb.AppendLine(((Get-Content $dbCsv | Select-Object -Last 40) -join [Environment]::NewLine))
    $null = $sb.AppendLine()
}

$null = $sb.AppendLine('=== LOG TAILS ===')
$null = $sb.AppendLine('--- launch.stdout.log (last 50 lines) ---')
$null = $sb.AppendLine(((Get-Content (Join-Path $MonitorDir 'launch.stdout.log') -Tail 50) -join [Environment]::NewLine))
$null = $sb.AppendLine()
$null = $sb.AppendLine('--- launch.stderr.log (last 50 lines) ---')
$null = $sb.AppendLine(((Get-Content (Join-Path $MonitorDir 'launch.stderr.log') -Tail 50) -join [Environment]::NewLine))
$null = $sb.AppendLine()
$null = $sb.AppendLine('--- postgres docker logs (last captured 100 lines) ---')
$null = $sb.AppendLine(((Get-Content (Join-Path $last.FullName 'docker-logs-tail.txt') -Tail 100) -join [Environment]::NewLine))
$null = $sb.AppendLine()

$null = $sb.AppendLine('=== QUICK READ ===')
$null = $sb.AppendLine("First DB total sessions:  $(Read-First (Join-Path $first.FullName 'db-total-sessions.txt'))")
$null = $sb.AppendLine("Latest DB total sessions: $(Read-First (Join-Path $last.FullName 'db-total-sessions.txt'))")
$null = $sb.AppendLine("Latest DB usable client slots: $(Calc-Slots $lastMax $lastReserved)")
$null = $sb.AppendLine('Interpretation guide:')
$null = $sb.AppendLine('- Healthy memory: process memory and JVM native memory plateau.')
$null = $sb.AppendLine('- Healthy DB: total sessions rise at startup and then plateau well below usable client slots.')
$null = $sb.AppendLine('- Suspicious DB: total sessions keep climbing, idle sessions pile up, or db-error shows too many clients already.')

[System.IO.File]::WriteAllText($OutFile, $sb.ToString())
Write-Host "Wrote report to: $OutFile"
