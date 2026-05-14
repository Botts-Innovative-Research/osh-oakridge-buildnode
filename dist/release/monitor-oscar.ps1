param(
    [string]$AttachToExisting,
    [string]$ForceRestart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BaseDir = Split-Path -Parent $PSCommandPath
$script:MonitorDir = Join-Path $script:BaseDir ("oscar-monitor-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$script:StatusFile = Join-Path $script:MonitorDir 'monitor-status.txt'
$script:HeartbeatFile = Join-Path $script:BaseDir 'monitor.heartbeat'
$script:BackendPidFile = Join-Path $script:BaseDir 'oscar.pid'
$script:CurrentMonitorFile = Join-Path $script:BaseDir 'current-monitor-dir.txt'
$script:MonitorLockDir = Join-Path $script:BaseDir '.monitor-lock'
$script:MonitorLockInfo = Join-Path $script:MonitorLockDir 'owner.json'
$script:LockAcquired = $false

New-Item -ItemType Directory -Force -Path $script:MonitorDir | Out-Null
Set-Content -Path $script:CurrentMonitorFile -Value $script:MonitorDir -Encoding ASCII

function Write-Status {
    param([string]$Message)

    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "$ts $Message"
    Write-Host $Message
    Add-Content -Path $script:StatusFile -Value $line -Encoding UTF8
}

function Load-DotEnv {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return
    }

    foreach ($rawLine in Get-Content -Path $Path) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.StartsWith('#')) { continue }

        $idx = $line.IndexOf('=')
        if ($idx -lt 1) { continue }

        $name = $line.Substring(0, $idx).Trim()
        $value = $line.Substring($idx + 1)

        if (
            ($value.Length -ge 2) -and
            (
                ($value.StartsWith('"') -and $value.EndsWith('"')) -or
                ($value.StartsWith("'") -and $value.EndsWith("'"))
            )
        ) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        [Environment]::SetEnvironmentVariable($name, $value, 'Process')
    }
}

function Convert-ToFlag {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    switch -Regex ($Value.Trim()) {
        '^(?i:1|true|yes|y|on)$' { return $true }
        default { return $false }
    }
}

function Get-BackendProcess {
    $proc = Get-CimInstance Win32_Process | Where-Object {
        $_.Name -match '^java(w)?\.exe$' -and
        $_.CommandLine -match 'SensorHubWrapper'
    } | Select-Object -First 1

    return $proc
}

function Get-ProcessStartTimeUtcString {
    param([int]$Pid)

    try {
        return (Get-Process -Id $Pid -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o')
    }
    catch {
        return $null
    }
}

function Update-Heartbeat {
    param(
        [string]$State,
        [Nullable[int]]$BackendPid = $null
    )

    $lines = @(
        "timestamp=$((Get-Date).ToString('o'))"
        "state=$State"
        "monitor_pid=$PID"
        "monitor_dir=$script:MonitorDir"
    )

    if ($null -ne $BackendPid) {
        $lines += "backend_pid=$BackendPid"
    }

    Set-Content -Path $script:HeartbeatFile -Value $lines -Encoding ASCII
}

function Release-MonitorLock {
    if (Test-Path $script:MonitorLockDir) {
        Remove-Item -Path $script:MonitorLockDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Acquire-MonitorLock {
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            New-Item -ItemType Directory -Path $script:MonitorLockDir -ErrorAction Stop | Out-Null

            $owner = [ordered]@{
                pid           = $PID
                acquiredUtc   = (Get-Date).ToUniversalTime().ToString('o')
                processName   = (Get-Process -Id $PID).ProcessName
                processStart  = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
                scriptPath    = $PSCommandPath
                hostName      = $env:COMPUTERNAME
            }

            $owner | ConvertTo-Json | Set-Content -Path $script:MonitorLockInfo -Encoding UTF8
            $script:LockAcquired = $true

            return @{
                Acquired    = $true
                ExistingPid = $null
            }
        }
        catch {
            $existingPid = $null
            $alive = $false

            if (Test-Path $script:MonitorLockInfo) {
                try {
                    $info = Get-Content -Path $script:MonitorLockInfo -Raw | ConvertFrom-Json
                    $existingPid = [int]$info.pid
                    $currentStart = Get-ProcessStartTimeUtcString -Pid $existingPid
                    if ($currentStart -and $currentStart -eq $info.processStart) {
                        $alive = $true
                    }
                }
                catch {
                    $alive = $false
                }
            }

            if ($alive) {
                return @{
                    Acquired    = $false
                    ExistingPid = $existingPid
                }
            }

            Remove-Item -Path $script:MonitorLockDir -Recurse -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 200
        }
    }

    throw "Could not acquire monitor lock at $script:MonitorLockDir"
}

function Invoke-Monitor {
    Load-DotEnv -Path (Join-Path $script:BaseDir '.env')

    if ([string]::IsNullOrWhiteSpace($AttachToExisting)) {
        $AttachToExisting = $env:ATTACH_TO_EXISTING
    }

    if ([string]::IsNullOrWhiteSpace($ForceRestart)) {
        $ForceRestart = $env:FORCE_RESTART
    }

    $attach = Convert-ToFlag $AttachToExisting
    $force = Convert-ToFlag $ForceRestart

    Write-Status "Monitor output: $script:MonitorDir"

    $lock = Acquire-MonitorLock
    if (-not $lock.Acquired) {
        Write-Status "Monitor script already running with PID $($lock.ExistingPid)."
        Write-Status "Exiting without starting a second monitor."
        return 200
    }

    Update-Heartbeat -State 'startup'

    $backend = Get-BackendProcess

    if ($null -ne $backend) {
        $backendPid = [int]$backend.ProcessId

        if ($force) {
            Write-Status "Existing OSCAR backend found with PID $backendPid. FORCE_RESTART=1, stopping it first..."
            & (Join-Path $script:BaseDir 'stop-all.bat')
            $stopRc = $LASTEXITCODE
            Start-Sleep -Seconds 5

            $backend = Get-BackendProcess
            if ($null -ne $backend) {
                throw "OSCAR backend still running with PID $($backend.ProcessId) after stop-all.bat."
            }

            Write-Status "Previous OSCAR backend stopped."
        }
        elseif (-not $attach) {
            Write-Status "OSCAR is already running with PID $backendPid."
            Write-Status "Set ATTACH_TO_EXISTING=1 to monitor it, or FORCE_RESTART=1 to replace it."
            return 201
        }
        else {
            Write-Status "Attaching to existing OSCAR backend PID $backendPid..."
        }
    }

    if ($null -eq $backend) {
        Write-Status "Launching OSCAR stack..."
        & (Join-Path $script:BaseDir 'launch-all.bat')
        $launchRc = $LASTEXITCODE

        if ($launchRc -ne 0) {
            throw "launch-all.bat failed with exit code $launchRc."
        }

        $backend = $null
        for ($i = 1; $i -le 60; $i++) {
            Start-Sleep -Seconds 1
            $backend = Get-BackendProcess
            if ($null -ne $backend) {
                break
            }
        }

        if ($null -eq $backend) {
            throw "Timed out waiting for OSCAR backend to appear."
        }
    }

    $backendPid = [int]$backend.ProcessId
    Set-Content -Path $script:BackendPidFile -Value $backendPid -Encoding ASCII

    Write-Status "Monitoring OSCAR backend PID $backendPid..."

    while ($true) {
        Update-Heartbeat -State 'running' -BackendPid $backendPid
        Start-Sleep -Seconds 30

        $backend = Get-BackendProcess
        if ($null -eq $backend) {
            Write-Status "OSCAR backend is no longer running."
            Update-Heartbeat -State 'stopped'
            return 0
        }

        $backendPid = [int]$backend.ProcessId
        Set-Content -Path $script:BackendPidFile -Value $backendPid -Encoding ASCII
    }
}

$exitCode = 0

try {
    $exitCode = Invoke-Monitor
}
catch {
    Write-Status "ERROR: $($_.Exception.Message)"
    Update-Heartbeat -State 'error'
    $exitCode = 500
}
finally {
    if ($script:LockAcquired) {
        Release-MonitorLock
    }
}

exit $exitCode