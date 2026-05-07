param(
    [string]$BaseDirectory = $PSScriptRoot,
    [string]$MonitorDirectory
)

$ErrorActionPreference = "SilentlyContinue"

function Add-Line {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$Text = ""
    )
    $Lines.Add($Text) | Out-Null
}

function Add-Block {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        $Lines.Add("") | Out-Null
        return
    }

    $normalized = $Text -replace "`r`n", "`n"
    foreach ($line in ($normalized -split "`n")) {
        $Lines.Add($line) | Out-Null
    }
}

function Load-DotEnv {
    param([string]$Path)

    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return $map
    }

    foreach ($rawLine in Get-Content -LiteralPath $Path) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.StartsWith("#")) { continue }

        if ($line.StartsWith("export ")) {
            $line = $line.Substring(7).Trim()
        }

        $idx = $line.IndexOf("=")
        if ($idx -lt 1) { continue }

        $key = $line.Substring(0, $idx).Trim()
        $value = $line.Substring($idx + 1)

        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            if ($value.Length -ge 2) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }

        $map[$key] = $value
    }

    return $map
}

function Get-ActiveMonitorDirectory {
    param([string]$BaseDir)

    $activePath = Join-Path $BaseDir ".monitor-active-dir"
    if (-not (Test-Path -LiteralPath $activePath)) {
        return $null
    }

    $candidate = (Get-Content -LiteralPath $activePath -TotalCount 1 | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return $null
    }

    if (Test-Path -LiteralPath $candidate) {
        return Get-Item -LiteralPath $candidate
    }

    return $null
}

function Get-LatestMonitorDirectory {
    param([string]$BaseDir)

    $dirs = Get-ChildItem -LiteralPath $BaseDir -Directory |
        Where-Object { $_.Name -like "oscar-monitor-*" } |
        Sort-Object Name -Descending

    return ($dirs | Select-Object -First 1)
}

function Get-OscarJavaProcesses {
    $procs = Get-CimInstance Win32_Process |
        Where-Object {
            $_.Name -match '^(java|javaw)(\.exe)?$' -and
            $null -ne $_.CommandLine -and
            $_.CommandLine -match 'com\.botts\.impl\.security\.SensorHubWrapper'
        } |
        Sort-Object ProcessId

    return @($procs)
}

function Resolve-ToolPath {
    param([string]$Name)

    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) {
        return $cmd.Source
    }

    $whereExe = Get-Command where.exe -ErrorAction SilentlyContinue
    if ($whereExe) {
        try {
            $resolved = & $whereExe.Source $Name 2>$null | Select-Object -First 1
            if ($resolved -and (Test-Path -LiteralPath $resolved)) {
                return $resolved
            }
        }
        catch {
        }
    }

    return $null
}

function Resolve-JcmdPath {
    $jcmd = Resolve-ToolPath -Name "jcmd.exe"
    if ($jcmd) {
        return $jcmd
    }

    $jcmd = Resolve-ToolPath -Name "jcmd"
    if ($jcmd) {
        return $jcmd
    }

    if ($env:JAVA_HOME) {
        $candidate = Join-Path $env:JAVA_HOME "bin\jcmd.exe"
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    $javaCmd = Resolve-ToolPath -Name "java.exe"
    if (-not $javaCmd) {
        $javaCmd = Resolve-ToolPath -Name "java"
    }

    if ($javaCmd) {
        $javaDir = Split-Path -Parent $javaCmd
        $candidate = Join-Path $javaDir "jcmd.exe"
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

function Invoke-ExternalCapture {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $script:LastExternalExitCode = 0

    if ([string]::IsNullOrWhiteSpace($FilePath)) {
        $script:LastExternalExitCode = 1
        return "Tool path is empty."
    }

    if (-not (Test-Path -LiteralPath $FilePath)) {
        $script:LastExternalExitCode = 1
        return "Tool not found: $FilePath"
    }

    try {
        $result = & $FilePath @Arguments 2>&1 | Out-String -Width 4096
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode) { $exitCode = 0 }
        $script:LastExternalExitCode = $exitCode

        $trimmed = $result.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($trimmed) -and $exitCode -ne 0) {
            return "Command failed with exit code $exitCode and returned no output."
        }

        return $trimmed
    }
    catch {
        $script:LastExternalExitCode = 1
        return ($_ | Out-String).TrimEnd()
    }
}

function Get-DockerContainerRecord {
    param(
        [string]$DockerExe,
        [string]$ContainerName
    )

    if (-not $DockerExe) {
        return $null
    }

    $raw = Invoke-ExternalCapture -FilePath $DockerExe -Arguments @(
        "ps", "-a",
        "--format", "{{.ID}}|{{.Image}}|{{.Status}}|{{.Names}}|{{.Ports}}|{{.Command}}"
    )

    if ($script:LastExternalExitCode -ne 0) {
        return @{
            Error = $raw
        }
    }

    $lines = @($raw -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 })
    foreach ($line in $lines) {
        $parts = $line.Split("|")
        if ($parts.Count -ge 6 -and $parts[3] -eq $ContainerName) {
            return @{
                Id      = $parts[0]
                Image   = $parts[1]
                Status  = $parts[2]
                Name    = $parts[3]
                Ports   = $parts[4]
                Command = $parts[5]
            }
        }
    }

    return $null
}

function Get-DockerTableText {
    param($ContainerRecord)

    if ($null -eq $ContainerRecord) {
        return "Container not found."
    }

    if ($ContainerRecord.ContainsKey("Error")) {
        return $ContainerRecord.Error
    }

    return @"
CONTAINER ID   IMAGE           STATUS              PORTS                                         NAMES
$($ContainerRecord.Id)   $($ContainerRecord.Image)   $($ContainerRecord.Status)   $($ContainerRecord.Ports)   $($ContainerRecord.Name)
"@.TrimEnd()
}

function Invoke-PsqlInContainer {
    param(
        [string]$DockerExe,
        [string]$ContainerName,
        [string]$DbUser,
        [string]$DbName,
        [string]$DbPassword,
        [string]$Sql
    )

    return Invoke-ExternalCapture -FilePath $DockerExe -Arguments @(
        "exec",
        "-e", "PGPASSWORD=$DbPassword",
        $ContainerName,
        "psql",
        "-U", $DbUser,
        "-d", $DbName,
        "-At",
        "-c", $Sql
    )
}

function Get-LaunchTail {
    param(
        [string]$MonitorDir,
        [string]$FileName,
        [int]$Tail = 50
    )

    if ([string]::IsNullOrWhiteSpace($MonitorDir)) { return "" }

    $path = Join-Path $MonitorDir $FileName
    if (-not (Test-Path -LiteralPath $path)) {
        return ""
    }

    return (Get-Content -LiteralPath $path -Tail $Tail | Out-String -Width 4096).TrimEnd()
}

function Run-JcmdSection {
    param(
        [string]$JcmdExe,
        [string]$Pid,
        [string[]]$Args
    )

    if (-not $Pid -or $Pid -notmatch '^\d+$') {
        return "No live OSCAR JVM found."
    }

    if (-not $JcmdExe) {
        return "jcmd.exe not found."
    }

    if (-not (Test-Path -LiteralPath $JcmdExe)) {
        return "jcmd.exe path does not exist: $JcmdExe"
    }

    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()

    try {
        $proc = Start-Process `
            -FilePath $JcmdExe `
            -ArgumentList (@($Pid) + $Args) `
            -NoNewWindow `
            -Wait `
            -PassThru `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError $stderrFile

        $stdout = ""
        $stderr = ""

        if (Test-Path -LiteralPath $stdoutFile) {
            $stdout = Get-Content -LiteralPath $stdoutFile -Raw
        }

        if (Test-Path -LiteralPath $stderrFile) {
            $stderr = Get-Content -LiteralPath $stderrFile -Raw
        }

        $output = ($stdout + $stderr).TrimEnd()
        $exitCode = $proc.ExitCode

        if ($exitCode -ne 0) {
            if ([string]::IsNullOrWhiteSpace($output)) {
                return "jcmd failed with exit code $exitCode using: $JcmdExe $Pid $($Args -join ' ')"
            }
            return $output
        }

        if ([string]::IsNullOrWhiteSpace($output)) {
            return "jcmd returned no output using: $JcmdExe $Pid $($Args -join ' ')"
        }

        return $output
    }
    catch {
        return ($_ | Out-String).TrimEnd()
    }
    finally {
        Remove-Item -LiteralPath $stdoutFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

$envMap = Load-DotEnv -Path (Join-Path $BaseDirectory ".env")

$containerName = if ($envMap.ContainsKey("CONTAINER_NAME")) { $envMap["CONTAINER_NAME"] } else { "oscar-postgis-container" }
$dbUser        = if ($envMap.ContainsKey("DB_USER"))        { $envMap["DB_USER"] }        else { "postgres" }
$dbName        = if ($envMap.ContainsKey("DB_NAME"))        { $envMap["DB_NAME"] }        else { "gis" }
$dbPassword    = if ($envMap.ContainsKey("DB_PASSWORD"))    { $envMap["DB_PASSWORD"] }    else { "postgres" }

$monitorDirItem = $null
if (-not [string]::IsNullOrWhiteSpace($MonitorDirectory)) {
    if (Test-Path -LiteralPath $MonitorDirectory) {
        $monitorDirItem = Get-Item -LiteralPath $MonitorDirectory
    }
}
else {
    $monitorDirItem = Get-ActiveMonitorDirectory -BaseDir $BaseDirectory
    if ($null -eq $monitorDirItem) {
        $monitorDirItem = Get-LatestMonitorDirectory -BaseDir $BaseDirectory
    }
}

$monitorDir = if ($null -ne $monitorDirItem) { $monitorDirItem.FullName } else { "" }

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outputFile = Join-Path $BaseDirectory "oscar-status-$timestamp.txt"

$pidFromMonitor = ""
if ($monitorDir) {
    $pidPath = Join-Path $monitorDir "jvm-pid.txt"
    if (Test-Path -LiteralPath $pidPath) {
        $pidFromMonitor = (Get-Content -LiteralPath $pidPath -TotalCount 1 | Out-String).Trim()
    }
}

$oscarJava = Get-OscarJavaProcesses
$liveProc = $null

if ($pidFromMonitor -match '^\d+$') {
    $liveProc = $oscarJava | Where-Object { $_.ProcessId -eq [int]$pidFromMonitor } | Select-Object -First 1
}
if ($null -eq $liveProc) {
    $liveProc = $oscarJava | Select-Object -First 1
}

$livePid = if ($null -ne $liveProc) { [string]$liveProc.ProcessId } else { "" }

$dockerExe = Resolve-ToolPath -Name "docker"
$jcmdExe   = Resolve-JcmdPath

$dockerContainer = Get-DockerContainerRecord -DockerExe $dockerExe -ContainerName $containerName
$dockerTableText = Get-DockerTableText -ContainerRecord $dockerContainer

$containerRunning = $false
if ($dockerContainer -and -not $dockerContainer.ContainsKey("Error")) {
    if ($dockerContainer.Status -like "Up*") {
        $containerRunning = $true
    }
}

$osInfo = Get-CimInstance Win32_OperatingSystem |
    Select-Object TotalVisibleMemorySize, FreePhysicalMemory, TotalVirtualMemorySize, FreeVirtualMemory
$osInfoText = ($osInfo | Format-List | Out-String -Width 4096).TrimEnd()

$counterText = ""
try {
    $counters = Get-Counter '\Memory\Committed Bytes','\Memory\Commit Limit','\Paging File(_Total)\% Usage'
    $counterText = ($counters | Out-String -Width 4096).TrimEnd()
}
catch {
    $counterText = "Could not read performance counters."
}

$liveJvmText = ""
if ($livePid -match '^\d+$') {
    $liveJvmText = (Get-Process -Id ([int]$livePid) |
        Select-Object Id, ProcessName, Threads, VirtualMemorySize64, WorkingSet64, PrivateMemorySize64, CPU, StartTime |
        Format-List | Out-String -Width 4096).TrimEnd()
}
else {
    $liveJvmText = "No live OSCAR JVM found."
}

$jfrText = ""
$heapText = ""
$nmtText = ""

if ($livePid -match '^\d+$' -and $jcmdExe -and (Test-Path -LiteralPath $jcmdExe)) {
    try {
        $jfrText = (& $jcmdExe $livePid JFR.check 2>&1 | Out-String -Width 4096).TrimEnd()
        if ([string]::IsNullOrWhiteSpace($jfrText)) {
            $jfrText = "jcmd returned no output for JFR.check"
        }
    }
    catch {
        $jfrText = ($_ | Out-String).TrimEnd()
    }

    try {
        $heapText = (& $jcmdExe $livePid GC.heap_info 2>&1 | Out-String -Width 4096).TrimEnd()
        if ([string]::IsNullOrWhiteSpace($heapText)) {
            $heapText = "jcmd returned no output for GC.heap_info"
        }
    }
    catch {
        $heapText = ($_ | Out-String).TrimEnd()
    }

    try {
        $nmtText = (& $jcmdExe $livePid VM.native_memory summary 2>&1 | Out-String -Width 4096).TrimEnd()
        if ([string]::IsNullOrWhiteSpace($nmtText)) {
            $nmtText = "jcmd returned no output for VM.native_memory summary"
        }
    }
    catch {
        $nmtText = ($_ | Out-String).TrimEnd()
    }
}
else {
    $jfrText = "jcmd.exe not found or no live OSCAR JVM found."
    $heapText = $jfrText
    $nmtText = $jfrText
}

$dbMetaText = ""
$dbByStateText = ""
$dbByAppText = ""
$dbErrorText = ""

$maxConnections = ""
$superuserReservedConnections = ""
$usableClientSlots = ""
$totalSessions = ""
$activeSessions = ""
$idleSessions = ""
$idleInTransaction = ""

if (-not $dockerExe) {
    $dbErrorText = "docker.exe not found in PATH."
}
elseif ($null -eq $dockerContainer) {
    $dbErrorText = "Container '$containerName' not found."
}
elseif ($dockerContainer.ContainsKey("Error")) {
    $dbErrorText = $dockerContainer.Error
}
elseif (-not $containerRunning) {
    $dbErrorText = "Container '$containerName' is present but not running. Status: $($dockerContainer.Status)"
}
else {
    $dbMetaSql = "select current_setting('max_connections'), current_setting('superuser_reserved_connections'), (current_setting('max_connections')::int - current_setting('superuser_reserved_connections')::int), count(*), count(*) filter (where state = 'active'), count(*) filter (where state = 'idle'), count(*) filter (where state = 'idle in transaction') from pg_stat_activity;"
    $dbByStateSql = "select coalesce(state,'<null>') || '|' || count(*)::text from pg_stat_activity group by state order by 1;"
    $dbByAppSql = "select coalesce(application_name,'<null>') || '|' || coalesce(usename,'<null>') || '|' || coalesce(client_addr::text,'<null>') || '|' || coalesce(state,'<null>') || '|' || count(*)::text from pg_stat_activity group by application_name, usename, client_addr, state order by application_name, usename, client_addr, state;"

    $dbMetaText = Invoke-PsqlInContainer -DockerExe $dockerExe -ContainerName $containerName -DbUser $dbUser -DbName $dbName -DbPassword $dbPassword -Sql $dbMetaSql
    $dbByStateText = Invoke-PsqlInContainer -DockerExe $dockerExe -ContainerName $containerName -DbUser $dbUser -DbName $dbName -DbPassword $dbPassword -Sql $dbByStateSql
    $dbByAppText = Invoke-PsqlInContainer -DockerExe $dockerExe -ContainerName $containerName -DbUser $dbUser -DbName $dbName -DbPassword $dbPassword -Sql $dbByAppSql

    $metaLine = ($dbMetaText -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 } | Select-Object -First 1)
    if ($metaLine -and $metaLine.Contains("|")) {
        $parts = $metaLine.Split("|")
        if ($parts.Count -ge 7) {
            $maxConnections = $parts[0]
            $superuserReservedConnections = $parts[1]
            $usableClientSlots = $parts[2]
            $totalSessions = $parts[3]
            $activeSessions = $parts[4]
            $idleSessions = $parts[5]
            $idleInTransaction = $parts[6]
        }
    }
    else {
        if ([string]::IsNullOrWhiteSpace($dbMetaText)) {
            $dbErrorText = "psql returned no DB metadata output."
        }
        else {
            $dbErrorText = $dbMetaText
        }
    }
}

$snapshotDirs = @()
if ($monitorDir -and (Test-Path -LiteralPath $monitorDir)) {
    $snapshotDirs = Get-ChildItem -LiteralPath $monitorDir -Directory |
        Where-Object { $_.Name -match '^\d{8}-\d{6}$' } |
        Sort-Object Name
}

$firstSnapshot = if ($snapshotDirs.Count -gt 0) { $snapshotDirs[0].FullName } else { "" }
$latestSnapshot = if ($snapshotDirs.Count -gt 0) { $snapshotDirs[-1].FullName } else { "" }

$recentSnapshotLines = @()
if ($snapshotDirs.Count -gt 0) {
    $recentSnapshotLines = $snapshotDirs |
        Select-Object -Last ([Math]::Min(20, $snapshotDirs.Count)) |
        ForEach-Object { $_.Name }
}

$launchStdoutTail = Get-LaunchTail -MonitorDir $monitorDir -FileName "launch.stdout.log" -Tail 50
$launchStderrTail = Get-LaunchTail -MonitorDir $monitorDir -FileName "launch.stderr.log" -Tail 50

$dockerLogsTail = ""
if ($dockerExe -and $containerRunning) {
    $dockerLogsTail = Invoke-ExternalCapture -FilePath $dockerExe -Arguments @("logs", "--tail", "100", $containerName)
}

$procTableText = ""
if ($liveProc) {
    $procTableText = ($liveProc |
        Select-Object ProcessId, Name, CommandLine |
        Format-Table -AutoSize | Out-String -Width 4096).TrimEnd()
}
else {
    $procTableText = "No live OSCAR Java process found."
}

$lines = New-Object 'System.Collections.Generic.List[string]'

Add-Line $lines "OSCAR STATUS REPORT"
Add-Line $lines ("Generated: " + (Get-Date).ToString("o"))
Add-Line $lines ("Base directory: " + $BaseDirectory)
Add-Line $lines ("Monitor directory: " + $(if ($monitorDir) { $monitorDir } else { "" }))
Add-Line $lines ("Output file: " + $outputFile)
Add-Line $lines ""

Add-Line $lines "=== PROCESS STATUS ==="
Add-Line $lines ("PID from monitor: " + $pidFromMonitor)
Add-Line $lines ("Live OSCAR PID:   " + $livePid)
Add-Line $lines ""
Add-Block $lines $procTableText
Add-Line $lines ""
Add-Block $lines $dockerTableText
Add-Line $lines ""

Add-Line $lines "=== SYSTEM MEMORY AND PAGEFILE ==="
Add-Line $lines ""
Add-Block $lines $osInfoText
Add-Line $lines ""
Add-Block $lines $counterText
Add-Line $lines ""

Add-Line $lines "=== LIVE JVM PROCESS ==="
Add-Line $lines ""
Add-Block $lines $liveJvmText
Add-Line $lines ""

Add-Line $lines "=== LIVE JVM JFR STATUS ==="
Add-Block $lines $jfrText
Add-Line $lines ""

Add-Line $lines "=== LIVE JVM GC HEAP INFO ==="
Add-Block $lines $heapText
Add-Line $lines ""

Add-Line $lines "=== LIVE JVM NATIVE MEMORY SUMMARY ==="
Add-Block $lines $nmtText
Add-Line $lines ""

Add-Line $lines "=== LIVE POSTGRES STATUS ==="
Add-Line $lines ("max_connections: " + $maxConnections)
Add-Line $lines ("superuser_reserved_connections: " + $superuserReservedConnections)
Add-Line $lines ("usable_client_slots: " + $usableClientSlots)
Add-Line $lines ("total_sessions: " + $totalSessions)
Add-Line $lines ("active: " + $activeSessions)
Add-Line $lines ("idle: " + $idleSessions)
Add-Line $lines ("idle in transaction: " + $idleInTransaction)
Add-Line $lines ""
Add-Line $lines "--- db-by-state ---"
Add-Block $lines $dbByStateText
Add-Line $lines ""
Add-Line $lines "--- db-by-app ---"
Add-Block $lines $dbByAppText
Add-Line $lines ""
Add-Line $lines "--- db-error ---"
Add-Block $lines $dbErrorText
Add-Line $lines ""

Add-Line $lines "=== SNAPSHOT STATUS ==="
Add-Line $lines ("Snapshot count: " + $snapshotDirs.Count)
Add-Line $lines ("First snapshot: " + $firstSnapshot)
Add-Line $lines ("Latest snapshot: " + $latestSnapshot)
Add-Line $lines ""

Add-Line $lines "=== RECENT SNAPSHOTS (LAST 20) ==="
foreach ($snap in $recentSnapshotLines) {
    Add-Line $lines $snap
}
Add-Line $lines ""

Add-Line $lines "=== LOG TAILS ==="
Add-Line $lines "--- launch.stdout.log (last 50 lines) ---"
Add-Block $lines $launchStdoutTail
Add-Line $lines ""
Add-Line $lines "--- launch.stderr.log (last 50 lines) ---"
Add-Block $lines $launchStderrTail
Add-Line $lines ""
Add-Line $lines "--- postgres docker logs (last captured 100 lines) ---"
Add-Block $lines $dockerLogsTail
Add-Line $lines ""

Add-Line $lines "=== QUICK READ ==="
Add-Line $lines ("Live JVM PID: " + $livePid)
Add-Line $lines ("Snapshots captured: " + $snapshotDirs.Count)
if ($totalSessions) { Add-Line $lines ("DB total sessions: " + $totalSessions) }
if ($usableClientSlots) { Add-Line $lines ("DB usable client slots: " + $usableClientSlots) }
Add-Line $lines "Interpretation guide:"
Add-Line $lines "- Healthy memory: process memory and JVM native memory plateau."
Add-Line $lines "- Healthy DB: total sessions rise at startup and then plateau well below usable client slots."
Add-Line $lines "- Suspicious DB: total sessions keep climbing, idle sessions pile up, or db-error shows query failures."

$reportText = ($lines -join "`r`n")
Set-Content -LiteralPath $outputFile -Value $reportText -Encoding UTF8
Write-Output $reportText