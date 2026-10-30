[CmdletBinding()]
param(
    [ValidateSet('check', 'apply', 'help')]
    [string]$Mode = 'check',
    [string[]]$AuthorizeSshPublicKey = @(),
    [string]$AuthorizeSshPublicKeyFile,
    [switch]$ConfigureLanHttpsFirewall,
    [switch]$KeepHibernate,
    [ValidateRange(0, 1440)]
    [int]$MonitorTimeoutMinutesAc = 0,
    [switch]$Json,
    [switch]$Strict
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$SubSleepGuid = '238c9fa8-0aad-41ed-83f4-97be242c8f20'
$SettingStandbyIdleGuid = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'
$SettingHibernateIdleGuid = '9d7815a6-7ee4-497e-8888-515a05f02364'
$SettingUnattendSleepGuid = '7bc4a2f9-d8fc-4469-b07b-33eb785aaca0'

$SubDiskGuid = '0012ee47-9041-4b5d-9b77-535fba8b1442'
$SettingDiskIdleGuid = '6738e2c4-e8a5-4a42-b16a-e040e769756e'

$SubVideoGuid = '7516b95f-f776-4464-8c53-06167f40cc99'
$SettingVideoIdleGuid = '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'

$SubButtonsGuid = '4f971e89-eebd-4455-a8de-9e59040e7347'
$SettingLidActionGuid = '5ca83367-6e45-459f-a27b-476b1d01c936'

$SubUsbGuid = '2a737441-1930-4402-8d77-b2bebba308a3'
$SettingUsbSelectiveSuspendGuid = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
$SettingUsb3LinkPowerGuid = 'd4e98f31-5ffe-4ce1-be31-1b38b384c009'

$SubPciExpressGuid = '501a4d13-42af-4429-9fd1-a8218c268e20'
$SettingPciExpressAspmGuid = 'ee12f906-d277-404b-b6da-e5fa1a576df5'

$SubWirelessGuid = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'
$SettingWirelessPowerGuid = '12bbebe6-58d6-4636-95bb-3217ef867c1a'

function Show-HostPrepHelp {
    @'
OSCAR Windows 11 unattended server preparation

  .\configure-windows-host.ps1 [-Mode check|apply] [-Strict] [-Json]
      [-MonitorTimeoutMinutesAc 0] [-KeepHibernate] [-ConfigureLanHttpsFirewall]
      [-AuthorizeSshPublicKey KEY[,KEY...]] [-AuthorizeSshPublicKeyFile FILE]

Modes:
  check   Read-only audit of sleep, hibernate, disk spin-down, USB selective
          suspend, PnP USB/NIC power saving, PCIe ASPM, OpenSSH Server,
          Windows Time, Windows Update auto-restart guard, Win32 long paths,
          wired LAN firewall profile, WSL 2, and Docker.
  apply   Requires an Administrator Windows PowerShell 5.1 session. Applies
          24/7 unattended server settings without resetting active network
          links, enables Win32 long paths, optionally configures Private wired
          LAN + scoped HTTPS firewall access (-ConfigureLanHttpsFirewall),
          optionally enrolls SSH public keys with strict Windows OpenSSH
          administrators_authorized_keys ACLs, and re-verifies state.
'@ | Write-Host
}

function Test-HostAdministrator {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return $false }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-HostAdministrator {
    if (-not (Test-HostAdministrator)) {
        throw 'Run configure-windows-host.ps1 -Mode apply from an Administrator Windows PowerShell 5.1 session.'
    }
}

function Assert-NoReparseScriptPath([string]$CandidatePath) {
    if ([string]::IsNullOrWhiteSpace($CandidatePath)) { return }
    $resolved = [IO.Path]::GetFullPath($CandidatePath)
    $current = $resolved
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing to run from a symlink, junction, or reparse path: $current"
            }
        }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or [String]::Equals($parent, $current, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $current = $parent
    }
}

function Test-ValidSshPublicKeyLine([string]$Line) {
    if ([string]::IsNullOrWhiteSpace($Line)) { return $false }
    $trimmed = $Line.Trim()
    if ($trimmed.IndexOf([char]0) -ge 0 -or $trimmed.IndexOf("`r") -ge 0 -or $trimmed.IndexOf("`n") -ge 0) {
        return $false
    }
    return ($trimmed -cmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)\s+[A-Za-z0-9+/=]+(\s+[^\r\n]+)?$')
}

function Resolve-RequestedSshPublicKeys([string[]]$InlineKeys, [string]$KeyFilePath) {
    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($InlineKeys)) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        foreach ($line in ($entry -split '\r?\n')) {
            $candidate = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($candidate) -or $candidate.StartsWith('#')) { continue }
            if (-not (Test-ValidSshPublicKeyLine $candidate)) {
                throw "Invalid SSH public key entry: $candidate"
            }
            if (-not ($keys -ccontains $candidate)) { $keys.Add($candidate) }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($KeyFilePath)) {
        Assert-NoReparseScriptPath $KeyFilePath
        if (-not (Test-Path -LiteralPath $KeyFilePath -PathType Leaf)) {
            throw "SSH public key file does not exist: $KeyFilePath"
        }
        foreach ($line in [IO.File]::ReadAllLines($KeyFilePath)) {
            $candidate = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($candidate) -or $candidate.StartsWith('#')) { continue }
            if (-not (Test-ValidSshPublicKeyLine $candidate)) {
                throw "Invalid SSH public key in ${KeyFilePath}: $candidate"
            }
            if (-not ($keys -ccontains $candidate)) { $keys.Add($candidate) }
        }
    }
    return @($keys)
}

function Parse-PowerCfgSettingIndices([string[]]$Lines) {
    $acIndex = $null
    $dcIndex = $null
    foreach ($line in @($Lines)) {
        if ($line -match 'Current AC Power Setting Index:\s*0x([0-9A-Fa-f]+)') {
            $acIndex = [Convert]::ToInt64($Matches[1], 16)
        } elseif ($line -match 'Current DC Power Setting Index:\s*0x([0-9A-Fa-f]+)') {
            $dcIndex = [Convert]::ToInt64($Matches[1], 16)
        }
    }
    if ($null -eq $acIndex -and $null -eq $dcIndex) {
        return $null
    }
    return [pscustomobject]@{
        AcValue = $acIndex
        DcValue = $dcIndex
    }
}

function Get-PowerCfgSettingValues([string]$SubGroupGuid, [string]$SettingGuid) {
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& powercfg.exe /query SCHEME_CURRENT $SubGroupGuid $SettingGuid 2>$null)
        $parsed = if ($LASTEXITCODE -eq 0) { Parse-PowerCfgSettingIndices $output } else { $null }
        if ($null -eq $parsed) {
            $output = @(& powercfg.exe /qh SCHEME_CURRENT $SubGroupGuid $SettingGuid 2>$null)
            if ($LASTEXITCODE -ne 0) { return $null }
            $parsed = Parse-PowerCfgSettingIndices $output
        }
        return $parsed
    } finally {
        $ErrorActionPreference = $previousPreference
    }
}

function Set-PowerCfgSettingBoth([string]$SubGroupGuid, [string]$SettingGuid, [int]$AcValue, [int]$DcValue) {
    $existing = Get-PowerCfgSettingValues $SubGroupGuid $SettingGuid
    if ($null -eq $existing) { return $false }
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & powercfg.exe /setacvalueindex SCHEME_CURRENT $SubGroupGuid $SettingGuid $AcValue *> $null
        $acExit = $LASTEXITCODE
        & powercfg.exe /setdcvalueindex SCHEME_CURRENT $SubGroupGuid $SettingGuid $DcValue *> $null
        $dcExit = $LASTEXITCODE
        return ($acExit -eq 0 -and $dcExit -eq 0)
    } finally {
        $ErrorActionPreference = $previousPreference
    }
}

function Get-ActivePowerSchemeSummary {
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = (@(& powercfg.exe /getactivescheme 2>$null) -join ' ').Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($output)) { return 'unknown' }
        return $output
    } finally {
        $ErrorActionPreference = $previousPreference
    }
}

function Test-HibernateEnabled {
    $powerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
    if (-not (Test-Path -LiteralPath $powerKey)) { return $false }
    $props = Get-ItemProperty -LiteralPath $powerKey -ErrorAction SilentlyContinue
    if ($null -eq $props -or $null -eq $props.PSObject.Properties['HibernateEnabled']) {
        return (Test-Path -LiteralPath 'C:\hiberfil.sys')
    }
    return ([int]$props.HibernateEnabled -ne 0)
}

function Set-ProtectedAdministratorsAuthorizedKeys([string]$AuthorizedKeysPath, [string[]]$NewKeys) {
    $sshProgramDataDir = Split-Path -Parent $AuthorizedKeysPath
    if (-not (Test-Path -LiteralPath $sshProgramDataDir -PathType Container)) {
        New-Item -ItemType Directory -Path $sshProgramDataDir -Force | Out-Null
    }
    Assert-NoReparseScriptPath $AuthorizedKeysPath
    $mergedLines = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $AuthorizedKeysPath -PathType Leaf) {
        foreach ($existingLine in [IO.File]::ReadAllLines($AuthorizedKeysPath)) {
            $trimmed = $existingLine.TrimEnd("`r")
            if (-not [string]::IsNullOrWhiteSpace($trimmed) -and -not ($mergedLines -ccontains $trimmed)) {
                $mergedLines.Add($trimmed)
            }
        }
    }
    foreach ($key in @($NewKeys)) {
        if (-not ($mergedLines -ccontains $key)) {
            $mergedLines.Add($key)
        }
    }
    if ((Test-Path -LiteralPath $AuthorizedKeysPath -PathType Leaf) -or $mergedLines.Count -gt 0) {
        $payload = if ($mergedLines.Count -gt 0) { ($mergedLines -join "`n") + "`n" } else { '' }
        [IO.File]::WriteAllText($AuthorizedKeysPath, $payload, $Utf8NoBom)

        $systemSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
        $adminsSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
        $acl = New-Object Security.AccessControl.FileSecurity
        $acl.SetAccessRuleProtection($true, $false)
        $acl.SetOwner($adminsSid)
        $fullControl = [Security.AccessControl.FileSystemRights]::FullControl
        $allow = [Security.AccessControl.AccessControlType]::Allow
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($systemSid, $fullControl, $allow)))
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($adminsSid, $fullControl, $allow)))
        Set-Acl -LiteralPath $AuthorizedKeysPath -AclObject $acl
    }
}

function Test-ProtectedAdministratorsAuthorizedKeysAcl([string]$AuthorizedKeysPath) {
    if (-not (Test-Path -LiteralPath $AuthorizedKeysPath -PathType Leaf)) {
        return [pscustomobject]@{ Present = $false; Compliant = $true; Detail = 'not present' }
    }
    $acl = Get-Acl -LiteralPath $AuthorizedKeysPath
    if (-not $acl.AreAccessRulesProtected) {
        return [pscustomobject]@{ Present = $true; Compliant = $false; Detail = 'inheritance is still enabled' }
    }
    $allowedSids = @('S-1-5-18', 'S-1-5-32-544')
    foreach ($rule in $acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            -not ($allowedSids -ccontains $rule.IdentityReference.Value)) {
            return [pscustomobject]@{
                Present = $true
                Compliant = $false
                Detail = "unexpected principal granted access: $($rule.IdentityReference.Value)"
            }
        }
    }
    return [pscustomobject]@{ Present = $true; Compliant = $true; Detail = 'SYSTEM and Administrators only (inheritance disabled)' }
}

function Get-ServerTargetDeviceInstanceIds {
    $ids = @{}
    if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) { return $ids }
    $devices = @(Get-CimInstance -Namespace 'root\cimv2' -ClassName 'Win32_PnPEntity' -ErrorAction SilentlyContinue)
    foreach ($device in $devices) {
        $pnpClass = [string]$device.PNPClass
        $deviceId = [string]$device.DeviceID
        if ([string]::IsNullOrWhiteSpace($deviceId)) { continue }
        if ($pnpClass -in @('USB', 'USBDevice', 'DiskDrive', 'SCSIAdapter', 'HDC', 'Net') -or
            $deviceId -match '^(USB|USBSTOR|UASPSTOR)\\') {
            $ids[$deviceId] = $true
        }
    }
    return $ids
}

function Normalize-WmiInstanceIdToPnP([string]$WmiInstanceName) {
    if ([string]::IsNullOrWhiteSpace($WmiInstanceName)) { return '' }
    return ($WmiInstanceName -replace '_\d+$', '').ToUpperInvariant()
}

function Invoke-DisableDevicePowerSaving([bool]$ApplyChanges) {
    $targetIds = Get-ServerTargetDeviceInstanceIds
    $totalMatched = 0
    $stillEnabled = 0
    $disabledNow = 0
    $accessErrors = 0
    $entries = @(Get-CimInstance -Namespace 'root\wmi' -ClassName 'MSPower_DeviceEnable' -ErrorAction SilentlyContinue)
    foreach ($entry in $entries) {
        $pnpId = Normalize-WmiInstanceIdToPnP ([string]$entry.InstanceName)
        if (-not $targetIds.ContainsKey($pnpId) -and $pnpId -notmatch '^(USB|USBSTOR|UASPSTOR)\\') {
            continue
        }
        $totalMatched++
        if ([bool]$entry.Enable) {
            if ($ApplyChanges) {
                try {
                    Set-CimInstance -InputObject $entry -Property @{ Enable = $false } -ErrorAction Stop | Out-Null
                    $disabledNow++
                } catch {
                    $accessErrors++
                    $stillEnabled++
                }
            } else {
                $stillEnabled++
            }
        }
    }
    if ($ApplyChanges -and (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue) -and
        (Get-Command Disable-NetAdapterPowerManagement -ErrorAction SilentlyContinue)) {
        $physicalAdapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
        foreach ($adapter in $physicalAdapters) {
            try {
                Disable-NetAdapterPowerManagement -Name $adapter.Name -NoRestart -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            } catch {
                # Virtual or vendor-locked drivers that reject advanced property writes remain non-fatal.
            }
        }
    }
    return [pscustomobject]@{
        TargetCapableDevices = $totalMatched
        DevicesAllowingPowerOff = $stillEnabled
        DisabledDuringApply = $disabledNow
        WriteErrors = $accessErrors
    }
}

$DockerAutoStartTaskName = 'OSCAR-DockerDesktop-AutoStart'

function Ensure-DockerDesktopAutoStartTask([bool]$ApplyChanges) {
    $dockerExe = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
    $installed = Test-Path -LiteralPath $dockerExe -PathType Leaf
    if (-not $installed) {
        return [pscustomobject]@{ Installed = $false; Registered = $false; Detail = 'Docker Desktop executable not present' }
    }
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Installed = $true; Registered = $false; Detail = 'ScheduledTasks module unavailable' }
    }
    $existing = Get-ScheduledTask -TaskName $DockerAutoStartTaskName -ErrorAction SilentlyContinue
    if ($ApplyChanges -and (Test-HostAdministrator)) {
        $currentUserName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $action = New-ScheduledTaskAction -Execute $dockerExe -Argument '-Autostart'
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUserName
        $principal = New-ScheduledTaskPrincipal -UserId $currentUserName -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $DockerAutoStartTaskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force | Out-Null
        $existing = Get-ScheduledTask -TaskName $DockerAutoStartTaskName -ErrorAction SilentlyContinue
    }
    $registered = ($null -ne $existing -and [string]$existing.State -ne 'Disabled')
    return [pscustomobject]@{
        Installed = $true
        Registered = $registered
        Detail = $(if ($registered) { "ARSO logon task=$DockerAutoStartTaskName" } else { 'ARSO logon task missing' })
    }
}

function Ensure-DockerDesktopAutoStart([bool]$ApplyChanges) {
    $appData = $env:APPDATA
    if ([string]::IsNullOrWhiteSpace($appData)) {
        return [pscustomobject]@{ Present = $false; AutoStart = $false; ResourceSaverOff = $false; Detail = 'APPDATA unavailable' }
    }
    $candidates = @(
        (Join-Path $appData 'Docker\settings-store.json'),
        (Join-Path $appData 'Docker\settings.json')
    )
    foreach ($settingsPath in $candidates) {
        if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) { continue }
        Assert-NoReparseScriptPath $settingsPath
        try {
            $raw = [IO.File]::ReadAllText($settingsPath)
            $jsonObj = $raw | ConvertFrom-Json
            $propName = if ($null -ne $jsonObj.PSObject.Properties['AutoStart']) {
                'AutoStart'
            } elseif ($null -ne $jsonObj.PSObject.Properties['autoStart']) {
                'autoStart'
            } else {
                'AutoStart'
            }
            $saverName = if ($null -ne $jsonObj.PSObject.Properties['UseResourceSaver']) {
                'UseResourceSaver'
            } elseif ($null -ne $jsonObj.PSObject.Properties['useResourceSaver']) {
                'useResourceSaver'
            } else {
                'UseResourceSaver'
            }
            $currentValue = $false
            if ($null -ne $jsonObj.PSObject.Properties[$propName]) {
                $currentValue = [bool]$jsonObj.$propName
            }
            $saverDisabled = $false
            if ($null -ne $jsonObj.PSObject.Properties[$saverName]) {
                $saverDisabled = (-not [bool]$jsonObj.$saverName)
            }
            if ($ApplyChanges -and (-not $currentValue -or -not $saverDisabled)) {
                if ($null -ne $jsonObj.PSObject.Properties[$propName]) {
                    $jsonObj.$propName = $true
                } else {
                    $jsonObj | Add-Member -NotePropertyName $propName -NotePropertyValue $true
                }
                if ($null -ne $jsonObj.PSObject.Properties[$saverName]) {
                    $jsonObj.$saverName = $false
                } else {
                    $jsonObj | Add-Member -NotePropertyName $saverName -NotePropertyValue $false
                }
                $serialized = $jsonObj | ConvertTo-Json -Depth 10
                [IO.File]::WriteAllText($settingsPath, "$serialized`n", $Utf8NoBom)
                $currentValue = $true
                $saverDisabled = $true
            }
            return [pscustomobject]@{
                Present = $true
                AutoStart = $currentValue
                ResourceSaverOff = $saverDisabled
                Detail = "$(Split-Path -Leaf $settingsPath): $propName=$currentValue, $saverName=$(-not $saverDisabled)"
            }
        } catch {
            return [pscustomobject]@{
                Present = $true
                AutoStart = $false
                ResourceSaverOff = $false
                Detail = "could not parse $(Split-Path -Leaf $settingsPath): $($_.Exception.Message)"
            }
        }
    }
    return [pscustomobject]@{ Present = $false; AutoStart = $false; ResourceSaverOff = $false; Detail = 'Docker Desktop user settings not yet initialized' }
}

function Get-HostNetworkSummary {
    $items = New-Object System.Collections.ArrayList
    if (-not (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue)) { return @() }
    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
    foreach ($adapter in $adapters) {
        $ips = @()
        if (Get-Command Get-NetIPAddress -ErrorAction SilentlyContinue) {
            $ips = @(Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
                ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" })
        }
        [void]$items.Add([pscustomobject]@{
            Name = [string]$adapter.Name
            Description = [string]$adapter.InterfaceDescription
            Physical = [bool]$adapter.HardwareInterface
            LinkSpeed = [string]$adapter.LinkSpeed
            MacAddress = [string]$adapter.MacAddress
            IPv4 = ($ips -join ', ')
        })
    }
    return $items.ToArray()
}

function Invoke-WindowsHostApply([string[]]$ResolvedSshKeys) {
    Assert-HostAdministrator
    $expectedVideoSecondsAc = $MonitorTimeoutMinutesAc * 60

    & powercfg.exe /change standby-timeout-ac 0 *> $null
    & powercfg.exe /change standby-timeout-dc 0 *> $null
    & powercfg.exe /change hibernate-timeout-ac 0 *> $null
    & powercfg.exe /change hibernate-timeout-dc 0 *> $null
    & powercfg.exe /change disk-timeout-ac 0 *> $null
    & powercfg.exe /change disk-timeout-dc 0 *> $null
    & powercfg.exe /change monitor-timeout-ac $MonitorTimeoutMinutesAc *> $null
    & powercfg.exe /change monitor-timeout-dc 0 *> $null

    [void](Set-PowerCfgSettingBoth $SubSleepGuid $SettingStandbyIdleGuid 0 0)
    [void](Set-PowerCfgSettingBoth $SubSleepGuid $SettingHibernateIdleGuid 0 0)
    [void](Set-PowerCfgSettingBoth $SubSleepGuid $SettingUnattendSleepGuid 0 0)
    [void](Set-PowerCfgSettingBoth $SubDiskGuid $SettingDiskIdleGuid 0 0)
    [void](Set-PowerCfgSettingBoth $SubVideoGuid $SettingVideoIdleGuid $expectedVideoSecondsAc 0)
    [void](Set-PowerCfgSettingBoth $SubButtonsGuid $SettingLidActionGuid 0 0)
    [void](Set-PowerCfgSettingBoth $SubUsbGuid $SettingUsbSelectiveSuspendGuid 0 0)
    [void](Set-PowerCfgSettingBoth $SubUsbGuid $SettingUsb3LinkPowerGuid 0 0)
    [void](Set-PowerCfgSettingBoth $SubPciExpressGuid $SettingPciExpressAspmGuid 0 0)
    [void](Set-PowerCfgSettingBoth $SubWirelessGuid $SettingWirelessPowerGuid 0 0)
    & powercfg.exe /setactive SCHEME_CURRENT *> $null

    if (-not $KeepHibernate) {
        & powercfg.exe /hibernate off *> $null
    }

    [void](Invoke-DisableDevicePowerSaving $true)

    $sshdService = Get-Service -Name 'sshd' -ErrorAction SilentlyContinue
    if ($null -ne $sshdService) {
        Set-Service -Name 'sshd' -StartupType Automatic
        if ($sshdService.Status -ne 'Running') {
            Start-Service -Name 'sshd'
        }
    }
    $authKeysPath = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
    if ($ResolvedSshKeys.Count -gt 0 -or (Test-Path -LiteralPath $authKeysPath -PathType Leaf)) {
        Set-ProtectedAdministratorsAuthorizedKeys $authKeysPath $ResolvedSshKeys
    }

    $timeService = Get-Service -Name 'w32time' -ErrorAction SilentlyContinue
    if ($null -ne $timeService) {
        Set-Service -Name 'w32time' -StartupType Automatic
        if ($timeService.Status -ne 'Running') {
            Start-Service -Name 'w32time'
        }
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & w32tm.exe /resync /nowait *> $null
        } finally {
            $ErrorActionPreference = $previousPreference
        }
    }

    $wuAuKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    if (-not (Test-Path -LiteralPath $wuAuKey)) {
        New-Item -Path $wuAuKey -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $wuAuKey -Name 'NoAutoRebootWithLoggedOnUsers' -Value 1 -Type DWord
    Set-ItemProperty -LiteralPath $wuAuKey -Name 'AlwaysAutoRebootAtScheduledTime' -Value 0 -Type DWord
    Set-ItemProperty -LiteralPath $wuAuKey -Name 'AUOptions' -Value 3 -Type DWord

    $fsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
    if (Test-Path -LiteralPath $fsKey) {
        Set-ItemProperty -LiteralPath $fsKey -Name 'LongPathsEnabled' -Value 1 -Type DWord
    }

    if ($ConfigureLanHttpsFirewall) {
        if ((Get-Command Get-NetAdapter -ErrorAction SilentlyContinue) -and
            (Get-Command Get-NetConnectionProfile -ErrorAction SilentlyContinue) -and
            (Get-Command Set-NetConnectionProfile -ErrorAction SilentlyContinue)) {
            $wiredAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue |
                Where-Object { $_.Status -eq 'Up' -and $_.HardwareInterface -and $_.MediaType -eq '802.3' })
            foreach ($nic in $wiredAdapters) {
                $netProfile = Get-NetConnectionProfile -InterfaceIndex $nic.InterfaceIndex -ErrorAction SilentlyContinue
                if ($null -ne $netProfile -and $netProfile.NetworkCategory -eq 'Public') {
                    Set-NetConnectionProfile -InterfaceIndex $nic.InterfaceIndex -NetworkCategory Private -ErrorAction SilentlyContinue
                }
            }
        }
        if (Get-Command New-NetFirewallRule -ErrorAction SilentlyContinue) {
            $existingRule = Get-NetFirewallRule -Name 'OSCAR-HTTPS-Gateway-In' -ErrorAction SilentlyContinue
            if ($null -eq $existingRule) {
                New-NetFirewallRule -Name 'OSCAR-HTTPS-Gateway-In' `
                    -DisplayName 'OSCAR HTTPS Gateway (LAN)' `
                    -Description 'Allow inbound HTTPS/HTTP to OSCAR gateway from Private/Domain LAN and Tailscale subnets' `
                    -Direction Inbound -Action Allow -Protocol TCP -LocalPort 443, 80 `
                    -Profile Private, Domain -RemoteAddress LocalSubnet, '100.64.0.0/10' | Out-Null
            } else {
                Set-NetFirewallRule -Name 'OSCAR-HTTPS-Gateway-In' -Enabled True -Action Allow `
                    -Profile Private, Domain -RemoteAddress LocalSubnet, '100.64.0.0/10' | Out-Null
            }
        }
    }

    $dockerService = Get-Service -Name 'com.docker.service' -ErrorAction SilentlyContinue
    if ($null -ne $dockerService) {
        Set-Service -Name 'com.docker.service' -StartupType Automatic
        if ($dockerService.Status -ne 'Running') {
            Start-Service -Name 'com.docker.service' -ErrorAction SilentlyContinue
        }
    }
    [void](Ensure-DockerDesktopAutoStart $true)
    $taskState = Ensure-DockerDesktopAutoStartTask $true
    if ($taskState.Registered -and (Get-Command docker -ErrorAction SilentlyContinue) -and
        (Get-Command Start-ScheduledTask -ErrorAction SilentlyContinue)) {
        $engineUp = $false
        $prevPref = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'SilentlyContinue'
            & docker info *> $null
            $engineUp = ($LASTEXITCODE -eq 0)
        } finally {
            $ErrorActionPreference = $prevPref
        }
        if (-not $engineUp) {
            try {
                Start-ScheduledTask -TaskName $DockerAutoStartTaskName -ErrorAction Stop
                $deadline = [DateTime]::UtcNow.AddSeconds(90)
                while ([DateTime]::UtcNow -lt $deadline) {
                    Start-Sleep -Seconds 3
                    $prevLoopPref = $ErrorActionPreference
                    try {
                        $ErrorActionPreference = 'SilentlyContinue'
                        & docker info *> $null
                        if ($LASTEXITCODE -eq 0) { break }
                    } finally {
                        $ErrorActionPreference = $prevLoopPref
                    }
                }
            } catch {
                # If no interactive user session is currently signed in on the console, Task Scheduler leaves startup for next logon.
            }
        }
    }
}

function Get-WindowsHostReadinessReport {
    $checks = New-Object System.Collections.ArrayList
    $addCheck = {
        param([string]$Id, [string]$Status, [string]$Summary)
        [void]$checks.Add([pscustomobject]@{
            Id = $Id
            Status = $Status
            Summary = $Summary
        })
    }

    $standby = Get-PowerCfgSettingValues $SubSleepGuid $SettingStandbyIdleGuid
    if ($null -eq $standby) {
        & $addCheck 'sleep-timeout' 'PASS' 'Standby idle timeout not exposed on this S0/desktop firmware'
    } elseif ($standby.AcValue -eq 0 -and ($null -eq $standby.DcValue -or $standby.DcValue -eq 0)) {
        & $addCheck 'sleep-timeout' 'PASS' "AC=$($standby.AcValue)s, DC=$($standby.DcValue)s (Never)"
    } else {
        & $addCheck 'sleep-timeout' 'FAIL' "AC=$($standby.AcValue)s, DC=$($standby.DcValue)s (expected 0/0)"
    }

    $unattend = Get-PowerCfgSettingValues $SubSleepGuid $SettingUnattendSleepGuid
    if ($null -eq $unattend) {
        & $addCheck 'unattended-sleep' 'PASS' 'Unattended sleep timeout not exposed on this platform'
    } elseif ($unattend.AcValue -eq 0 -and ($null -eq $unattend.DcValue -or $unattend.DcValue -eq 0)) {
        & $addCheck 'unattended-sleep' 'PASS' "AC=$($unattend.AcValue)s, DC=$($unattend.DcValue)s (Disabled)"
    } else {
        & $addCheck 'unattended-sleep' 'FAIL' "AC=$($unattend.AcValue)s, DC=$($unattend.DcValue)s (expected 0/0)"
    }

    $hibernateOn = Test-HibernateEnabled
    if ($KeepHibernate) {
        $hibIdle = Get-PowerCfgSettingValues $SubSleepGuid $SettingHibernateIdleGuid
        if ($null -eq $hibIdle -or ($hibIdle.AcValue -eq 0 -and ($null -eq $hibIdle.DcValue -or $hibIdle.DcValue -eq 0))) {
            & $addCheck 'hibernate' 'PASS' 'Hibernate retained by request; idle timeout is 0 (Never)'
        } else {
            & $addCheck 'hibernate' 'FAIL' "Hibernate idle timeout AC=$($hibIdle.AcValue)s, DC=$($hibIdle.DcValue)s (expected 0/0)"
        }
    } elseif (-not $hibernateOn) {
        & $addCheck 'hibernate' 'PASS' 'Hibernate and Fast Startup disabled (HibernateEnabled=0)'
    } else {
        & $addCheck 'hibernate' 'FAIL' 'Hibernate is enabled (run -Mode apply to disable hibernate and Fast Startup)'
    }

    $diskIdle = Get-PowerCfgSettingValues $SubDiskGuid $SettingDiskIdleGuid
    if ($null -eq $diskIdle) {
        & $addCheck 'disk-timeout' 'PASS' 'Disk idle timeout not exposed on this platform'
    } elseif ($diskIdle.AcValue -eq 0 -and ($null -eq $diskIdle.DcValue -or $diskIdle.DcValue -eq 0)) {
        & $addCheck 'disk-timeout' 'PASS' "AC=$($diskIdle.AcValue)s, DC=$($diskIdle.DcValue)s (Never spin down)"
    } else {
        & $addCheck 'disk-timeout' 'FAIL' "AC=$($diskIdle.AcValue)s, DC=$($diskIdle.DcValue)s (expected 0/0)"
    }

    $lidAction = Get-PowerCfgSettingValues $SubButtonsGuid $SettingLidActionGuid
    if ($null -eq $lidAction) {
        & $addCheck 'lid-close-action' 'PASS' 'No lid switch present on desktop/server chassis'
    } elseif ($lidAction.AcValue -eq 0 -and ($null -eq $lidAction.DcValue -or $lidAction.DcValue -eq 0)) {
        & $addCheck 'lid-close-action' 'PASS' 'Lid close action is Do Nothing (0) on AC and DC'
    } else {
        & $addCheck 'lid-close-action' 'WARN' "Lid close action AC=$($lidAction.AcValue), DC=$($lidAction.DcValue) (expected 0=Do Nothing)"
    }

    $usbSuspend = Get-PowerCfgSettingValues $SubUsbGuid $SettingUsbSelectiveSuspendGuid
    if ($null -eq $usbSuspend) {
        & $addCheck 'usb-selective-suspend' 'PASS' 'USB selective suspend setting not exposed by active power scheme'
    } elseif ($usbSuspend.AcValue -eq 0 -and ($null -eq $usbSuspend.DcValue -or $usbSuspend.DcValue -eq 0)) {
        & $addCheck 'usb-selective-suspend' 'PASS' 'USB selective suspend is Disabled (0) on AC and DC'
    } else {
        & $addCheck 'usb-selective-suspend' 'FAIL' "USB selective suspend AC=$($usbSuspend.AcValue), DC=$($usbSuspend.DcValue) (expected 0=Disabled)"
    }

    $usb3Lpm = Get-PowerCfgSettingValues $SubUsbGuid $SettingUsb3LinkPowerGuid
    if ($null -ne $usb3Lpm) {
        if ($usb3Lpm.AcValue -eq 0 -and ($null -eq $usb3Lpm.DcValue -or $usb3Lpm.DcValue -eq 0)) {
            & $addCheck 'usb3-link-power' 'PASS' 'USB 3 Link Power Management is Off (0) on AC and DC'
        } else {
            & $addCheck 'usb3-link-power' 'WARN' "USB 3 Link Power Management AC=$($usb3Lpm.AcValue), DC=$($usb3Lpm.DcValue) (expected 0=Off)"
        }
    }

    $pcieAspm = Get-PowerCfgSettingValues $SubPciExpressGuid $SettingPciExpressAspmGuid
    if ($null -eq $pcieAspm) {
        & $addCheck 'pcie-aspm' 'PASS' 'PCIe Link State Power Management not exposed on this platform'
    } elseif ($pcieAspm.AcValue -eq 0 -and ($null -eq $pcieAspm.DcValue -or $pcieAspm.DcValue -eq 0)) {
        & $addCheck 'pcie-aspm' 'PASS' 'PCIe Link State Power Management is Off (0) on AC and DC'
    } else {
        & $addCheck 'pcie-aspm' 'WARN' "PCIe ASPM AC=$($pcieAspm.AcValue), DC=$($pcieAspm.DcValue) (expected 0=Off)"
    }

    if (Test-HostAdministrator) {
        $pnpSummary = Invoke-DisableDevicePowerSaving $false
        if ($pnpSummary.DevicesAllowingPowerOff -eq 0) {
            & $addCheck 'pnp-device-power-save' 'PASS' "0/$($pnpSummary.TargetCapableDevices) USB/storage/network PnP devices allow power-off"
        } else {
            & $addCheck 'pnp-device-power-save' 'FAIL' "$($pnpSummary.DevicesAllowingPowerOff)/$($pnpSummary.TargetCapableDevices) USB/storage/network PnP devices still allow Windows power-off"
        }
    } else {
        & $addCheck 'pnp-device-power-save' 'WARN' 'Run from an Administrator session to inspect WMI MSPower_DeviceEnable flags'
    }

    $sshdService = Get-Service -Name 'sshd' -ErrorAction SilentlyContinue
    if ($null -eq $sshdService) {
        & $addCheck 'openssh-server' 'WARN' 'Windows OpenSSH Server (sshd) is not installed'
    } elseif ($sshdService.Status -eq 'Running' -and $sshdService.StartType -eq 'Automatic') {
        $authKeysPath = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
        $aclCheck = Test-ProtectedAdministratorsAuthorizedKeysAcl $authKeysPath
        if ($aclCheck.Compliant) {
            & $addCheck 'openssh-server' 'PASS' "sshd Running (Automatic); administrators_authorized_keys: $($aclCheck.Detail)"
        } else {
            & $addCheck 'openssh-server' 'FAIL' "sshd Running, but administrators_authorized_keys ACL invalid: $($aclCheck.Detail)"
        }
    } else {
        & $addCheck 'openssh-server' 'FAIL' "sshd Status=$($sshdService.Status), StartType=$($sshdService.StartType) (expected Running/Automatic)"
    }

    $timeService = Get-Service -Name 'w32time' -ErrorAction SilentlyContinue
    if ($null -ne $timeService -and $timeService.Status -eq 'Running' -and $timeService.StartType -eq 'Automatic') {
        & $addCheck 'time-sync' 'PASS' 'Windows Time (w32time) is Running and Automatic'
    } elseif ($null -ne $timeService) {
        & $addCheck 'time-sync' 'WARN' "w32time Status=$($timeService.Status), StartType=$($timeService.StartType) (expected Running/Automatic)"
    } else {
        & $addCheck 'time-sync' 'WARN' 'Windows Time service (w32time) not found'
    }

    $wuAuKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    $wuProps = if (Test-Path -LiteralPath $wuAuKey) { Get-ItemProperty -LiteralPath $wuAuKey -ErrorAction SilentlyContinue } else { $null }
    if ($null -ne $wuProps -and
        $null -ne $wuProps.PSObject.Properties['NoAutoRebootWithLoggedOnUsers'] -and [int]$wuProps.NoAutoRebootWithLoggedOnUsers -eq 1 -and
        $null -ne $wuProps.PSObject.Properties['AlwaysAutoRebootAtScheduledTime'] -and [int]$wuProps.AlwaysAutoRebootAtScheduledTime -eq 0) {
        & $addCheck 'windows-update-reboot-guard' 'PASS' 'NoAutoRebootWithLoggedOnUsers=1, AlwaysAutoRebootAtScheduledTime=0 configured'
    } else {
        & $addCheck 'windows-update-reboot-guard' 'WARN' 'Windows Update auto-reboot suppression policy not fully applied (run -Mode apply)'
    }

    $fsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
    $fsProps = if (Test-Path -LiteralPath $fsKey) { Get-ItemProperty -LiteralPath $fsKey -ErrorAction SilentlyContinue } else { $null }
    if ($null -ne $fsProps -and $null -ne $fsProps.PSObject.Properties['LongPathsEnabled'] -and
        [int]$fsProps.LongPathsEnabled -eq 1) {
        & $addCheck 'win32-long-paths' 'PASS' 'Win32 LongPathsEnabled=1 configured'
    } else {
        & $addCheck 'win32-long-paths' 'WARN' 'LongPathsEnabled is not 1 (run -Mode apply so Windows tools handle >260-char paths)'
    }

    $publicWiredNames = @()
    if ((Get-Command Get-NetAdapter -ErrorAction SilentlyContinue) -and
        (Get-Command Get-NetConnectionProfile -ErrorAction SilentlyContinue)) {
        $wiredUp = @(Get-NetAdapter -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'Up' -and $_.HardwareInterface -and $_.MediaType -eq '802.3' })
        foreach ($nic in $wiredUp) {
            $prof = Get-NetConnectionProfile -InterfaceIndex $nic.InterfaceIndex -ErrorAction SilentlyContinue
            if ($null -ne $prof -and $prof.NetworkCategory -eq 'Public') {
                $publicWiredNames += [string]$nic.Name
            }
        }
    }
    $httpsRuleOk = $false
    if (Get-Command Get-NetFirewallRule -ErrorAction SilentlyContinue) {
        $oscarFw = Get-NetFirewallRule -Name 'OSCAR-HTTPS-Gateway-In' -ErrorAction SilentlyContinue
        if ($null -ne $oscarFw -and $oscarFw.Enabled -eq 'True' -and $oscarFw.Action -eq 'Allow') {
            $httpsRuleOk = $true
        }
    }
    if ($publicWiredNames.Count -gt 0) {
        & $addCheck 'lan-https-firewall' 'WARN' "Wired Ethernet ($($publicWiredNames -join ', ')) is on Public network profile; Windows Firewall blocks inbound Docker/HTTPS on Public (use -Mode apply -ConfigureLanHttpsFirewall on trusted LANs)"
    } elseif ($httpsRuleOk) {
        & $addCheck 'lan-https-firewall' 'PASS' 'Wired Ethernet uses Private/Domain profile and OSCAR-HTTPS-Gateway-In rule is enabled'
    } else {
        & $addCheck 'lan-https-firewall' 'WARN' 'Scoped OSCAR-HTTPS-Gateway-In firewall rule not yet configured (use -Mode apply -ConfigureLanHttpsFirewall if remote LAN browsers need HTTPS 443)'
    }

    $previousPreference = $ErrorActionPreference
    $wslOk = $false
    $dockerEngineOk = $false
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
            & wsl.exe --status *> $null
            $wslOk = ($LASTEXITCODE -eq 0)
        }
        if (Get-Command docker -ErrorAction SilentlyContinue) {
            & docker info *> $null
            $dockerEngineOk = ($LASTEXITCODE -eq 0)
        }
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($wslOk) {
        & $addCheck 'wsl2' 'PASS' 'WSL 2 is installed and ready'
    } else {
        & $addCheck 'wsl2' 'WARN' 'WSL 2 is not yet initialized (oscar.bat init can install bundled prerequisites)'
    }

    $dockerAutoStart = Ensure-DockerDesktopAutoStart $false
    $dockerTask = Ensure-DockerDesktopAutoStartTask $false
    $autoSummary = if ($dockerAutoStart.Present) {
        "$($dockerAutoStart.Detail); $($dockerTask.Detail)"
    } else {
        $dockerTask.Detail
    }
    if ($dockerEngineOk -and (-not $dockerTask.Installed -or $dockerTask.Registered) -and (-not $dockerAutoStart.Present -or $dockerAutoStart.ResourceSaverOff)) {
        & $addCheck 'docker-runtime' 'PASS' "Docker Engine reachable ($autoSummary)"
    } elseif ($dockerEngineOk) {
        & $addCheck 'docker-runtime' 'WARN' "Docker Engine reachable, but ARSO logon task or UseResourceSaver=False not yet applied ($autoSummary)"
    } else {
        & $addCheck 'docker-runtime' 'WARN' "Docker Engine not currently reachable ($autoSummary)"
    }

    $failCount = @($checks | Where-Object { $_.Status -eq 'FAIL' }).Count
    $warnCount = @($checks | Where-Object { $_.Status -eq 'WARN' }).Count
    $overall = if ($failCount -gt 0) { 'FAIL' } elseif ($warnCount -gt 0) { 'WARN' } else { 'PASS' }

    return [pscustomobject]@{
        Hostname = [Environment]::MachineName
        TimestampUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        Elevated = (Test-HostAdministrator)
        ActivePowerScheme = (Get-ActivePowerSchemeSummary)
        OverallStatus = $overall
        FailCount = $failCount
        WarnCount = $warnCount
        NetworkAdapters = @(Get-HostNetworkSummary)
        Checks = $checks.ToArray()
    }
}

try {
    if ($MyInvocation.InvocationName -ne '.') {
        Assert-NoReparseScriptPath $MyInvocation.MyCommand.Path
        if ($Mode -eq 'help') {
            Show-HostPrepHelp
            exit 0
        }
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
            throw 'configure-windows-host.ps1 supported execution requires Windows 11 x86-64.'
        }
        $resolvedSshKeys = @(Resolve-RequestedSshPublicKeys $AuthorizeSshPublicKey $AuthorizeSshPublicKeyFile)
        if ($Mode -eq 'apply') {
            Invoke-WindowsHostApply $resolvedSshKeys
        } elseif ($resolvedSshKeys.Count -gt 0) {
            throw 'Authorizing SSH public keys requires -Mode apply.'
        }
        $report = Get-WindowsHostReadinessReport
        if ($Json) {
            ($report | ConvertTo-Json -Depth 6) | Write-Output
        } else {
            Write-Host "`n== OSCAR Windows 11 Server Readiness ($($report.Hostname)) ==" -ForegroundColor Cyan
            Write-Host "Timestamp (UTC): $($report.TimestampUtc)"
            Write-Host "Administrator:   $($report.Elevated)"
            Write-Host "Power scheme:    $($report.ActivePowerScheme)"
            if ($report.NetworkAdapters.Count -gt 0) {
                Write-Host "`nActive network interfaces:" -ForegroundColor Cyan
                foreach ($nic in $report.NetworkAdapters) {
                    Write-Host ("  - {0} [{1}] {2} ({3})" -f $nic.Name, $nic.LinkSpeed, $nic.IPv4, $nic.Description)
                }
            }
            Write-Host "`nReadiness checks:" -ForegroundColor Cyan
            foreach ($item in $report.Checks) {
                $color = switch ($item.Status) {
                    'PASS' { 'Green' }
                    'WARN' { 'Yellow' }
                    default { 'Red' }
                }
                Write-Host ("  [{0}] {1}: {2}" -f $item.Status, $item.Id, $item.Summary) -ForegroundColor $color
            }
            Write-Host "`nOverall status: $($report.OverallStatus) (FAIL=$($report.FailCount), WARN=$($report.WarnCount))"
        }
        if ($report.FailCount -gt 0 -or ($Strict -and $report.WarnCount -gt 0)) {
            exit 1
        }
    }
} catch {
    Write-Error ("Line {0}: {1}" -f $_.InvocationInfo.ScriptLineNumber, $_.Exception.Message)
    exit 1
}
