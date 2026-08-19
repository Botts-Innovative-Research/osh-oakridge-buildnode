[CmdletBinding()]
param(
    [ValidateSet('init', 'check', 'start', 'stop', 'restart', 'status', 'logs', 'upgrade', 'help')]
    [string]$Command = 'help',
    [string]$Hostname,
    [ValidateRange(1, 65535)]
    [int]$Port = 443,
    [ValidateSet('self-signed', 'import')]
    [string]$TlsMode = 'self-signed',
    [string]$CertificatePath,
    [string]$PrivateKeyPath,
    [switch]$AddHostsEntry,
    [switch]$NonInteractive,
    [switch]$SkipStart,
    [ValidateSet('all', 'oscar', 'postgres', 'gateway')]
    [string]$Service = 'all',
    [ValidateRange(1, 10000)]
    [int]$Tail = 200,
    [switch]$Follow
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Heading([string]$Text) {
    Write-Host "`n== $Text ==" -ForegroundColor Cyan
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Administrator {
    if (-not (Test-Administrator)) {
        throw 'Run this command from an Administrator PowerShell window.'
    }
}

function Assert-OfflineBundleIntegrity {
    $checksumPath = Join-Path $ScriptRoot 'SHA256SUMS'
    if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) { return }
    Write-Heading 'Offline bundle integrity'
    $verifier = Join-Path $ScriptRoot 'verify-bundle.ps1'
    if (-not (Test-Path -LiteralPath $verifier -PathType Leaf)) { throw 'The offline bundle verifier is missing.' }
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $verifier
    if ($LASTEXITCODE -ne 0) { throw 'Offline bundle integrity verification failed.' }
}

function Invoke-External([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Program exited with code $LASTEXITCODE."
    }
}

function Invoke-ExternalProbe([scriptblock]$Action) {
    $previousErrorPreference = $ErrorActionPreference
    try {
        # Windows PowerShell can promote expected native stderr (such as an
        # image-inspect miss) into a terminating error when Stop is active.
        $ErrorActionPreference = 'SilentlyContinue'
        & $Action *> $null
        return ($LASTEXITCODE -eq 0)
    } finally {
        $ErrorActionPreference = $previousErrorPreference
    }
}

function Test-DockerReady {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
    if (-not (Invoke-ExternalProbe { docker compose version })) { return $false }
    return (Invoke-ExternalProbe { docker info })
}

function Test-WslReady {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return $false }
    return (Invoke-ExternalProbe { wsl.exe --status })
}

function Install-BundledPrerequisites {
    Write-Heading 'Docker and WSL prerequisites'
    $installerRoot = Join-Path $ScriptRoot 'installers\windows-x86_64'

    if (-not (Test-WslReady)) {
        foreach ($feature in @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')) {
            & dism.exe /Online /Enable-Feature "/FeatureName:$feature" /All /NoRestart | Out-Host
            if ($LASTEXITCODE -notin @(0, 3010)) { throw "Could not enable required Windows feature: $feature" }
        }
        $wslInstaller = Get-ChildItem -LiteralPath $installerRoot -Filter 'wsl*.msi' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $wslInstaller) {
            throw "WSL is unavailable. Place the official WSL x64 MSI in $installerRoot and run setup again."
        }
        Write-Host "Launching official WSL installer: $($wslInstaller.Name)"
        $process = Start-Process msiexec.exe -ArgumentList @('/i', "`"$($wslInstaller.FullName)`"", '/passive', '/norestart') -Wait -PassThru
        if ($process.ExitCode -notin @(0, 3010)) { throw "WSL installer exited with code $($process.ExitCode)." }
        if ($process.ExitCode -eq 3010 -or -not (Test-WslReady)) { throw 'WSL installation requires a restart. Restart Windows, then run this command again.' }
    }

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        $dockerInstaller = Join-Path $installerRoot 'Docker Desktop Installer.exe'
        if (-not (Test-Path -LiteralPath $dockerInstaller -PathType Leaf)) {
            throw "Docker is unavailable. Place the official Docker Desktop installer at '$dockerInstaller' and run setup again."
        }
        Write-Host 'Launching the official Docker Desktop installer. Setup will resume when it exits.'
        Write-Host 'The administrator must review and accept the Docker Desktop license in the official installer or application.'
        $process = Start-Process -FilePath $dockerInstaller -ArgumentList @('install', '--backend=wsl-2', '--no-windows-containers') -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw "Docker Desktop installer exited with code $($process.ExitCode)." }
        $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $env:Path = "$machinePath;$userPath"
    }

    if (-not (Test-DockerReady)) {
        $dockerDesktop = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
        if (Test-Path -LiteralPath $dockerDesktop) {
            Write-Host 'Starting Docker Desktop and waiting for its engine...'
            Start-Process -FilePath $dockerDesktop | Out-Null
            for ($attempt = 0; $attempt -lt 60; $attempt++) {
                Start-Sleep -Seconds 2
                if (Test-DockerReady) { return }
            }
        }
        throw 'Docker is installed but its engine is not ready. Start Docker Desktop, then run setup again.'
    }
}

function Assert-Docker {
    if (-not (Test-DockerReady)) { Install-BundledPrerequisites }
    if (-not (Test-DockerReady)) { throw 'Docker Engine and Docker Compose are required.' }
}

function Read-RequiredValue([string]$Prompt, [string]$Current) {
    if ($Current) { return $Current.Trim() }
    if ($NonInteractive) { throw "$Prompt is required in non-interactive mode." }
    do { $value = (Read-Host $Prompt).Trim() } until ($value)
    return $value
}

function Test-ValidHostname([string]$Value) {
    $parsedIp = $null
    if ([Net.IPAddress]::TryParse($Value, [ref]$parsedIp)) { return $true }
    return $Value -match '^(?=.{1,253}$)(?!-)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'
}

function Set-EnvValue([string]$Name, [string]$Value) {
    $envPath = Join-Path $ScriptRoot '.env'
    $lines = if (Test-Path -LiteralPath $envPath) { [IO.File]::ReadAllLines($envPath) } else { [IO.File]::ReadAllLines((Join-Path $ScriptRoot '.env.example')) }
    $replacement = "$Name=$Value"
    $found = $false
    for ($index = 0; $index -lt $lines.Length; $index++) {
        if ($lines[$index] -match "^$([Regex]::Escape($Name))=") { $lines[$index] = $replacement; $found = $true }
    }
    if (-not $found) { $lines += $replacement }
    [IO.File]::WriteAllLines($envPath, $lines, $Utf8NoBom)
}

function New-RandomPassword {
    $bytes = New-Object byte[] 32
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $generator.GetBytes($bytes) } finally { $generator.Dispose() }
    return [Convert]::ToBase64String($bytes)
}

function Read-AdminPassword {
    $fromEnvironment = [Environment]::GetEnvironmentVariable('OSCAR_SETUP_ADMIN_PASSWORD')
    if ($fromEnvironment) {
        if ($fromEnvironment.Length -lt 14) { throw 'OSCAR_SETUP_ADMIN_PASSWORD must contain at least 14 characters.' }
        return $fromEnvironment
    }
    if ($NonInteractive) { throw 'Set OSCAR_SETUP_ADMIN_PASSWORD for non-interactive initialization.' }
    Write-Host 'The administrator password must contain at least 14 characters. Input is hidden.'
    while ($true) {
        $first = Read-Host 'Initial OSCAR administrator password' -AsSecureString
        $second = Read-Host 'Confirm administrator password' -AsSecureString
        $firstPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($first)
        $secondPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($second)
        try {
            $firstText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($firstPtr)
            $secondText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($secondPtr)
            if ($firstText.Length -lt 14) { Write-Warning 'Use at least 14 characters.'; continue }
            if ($firstText -cne $secondText) { Write-Warning 'Passwords do not match.'; continue }
            return $firstText
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($firstPtr)
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secondPtr)
        }
    }
}

function Write-SecretFile([string]$Path, [string]$Value) {
    if (Test-Path -LiteralPath $Path) { return }
    [IO.File]::WriteAllText($Path, $Value, $Utf8NoBom)
}

function Protect-DeploymentFiles {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    foreach ($directory in @((Join-Path $ScriptRoot 'secrets'), (Join-Path $ScriptRoot 'tls'))) {
        Invoke-External 'icacls.exe' @($directory, '/inheritance:r', '/grant:r', "${identity}:(OI)(CI)F", 'SYSTEM:(OI)(CI)F', '/Q')
    }
}

function Get-OscarImage {
    $envPath = Join-Path $ScriptRoot '.env'
    $version = 'local'
    if (Test-Path -LiteralPath $envPath) {
        $match = [IO.File]::ReadAllLines($envPath) | Where-Object { $_ -match '^OSCAR_VERSION=' } | Select-Object -First 1
        if ($match) { $version = $match.Substring('OSCAR_VERSION='.Length) }
    }
    return "oscar:$version"
}

function Test-ContainerImage([string]$Image) {
    return (Invoke-ExternalProbe { docker image inspect $Image })
}

function Get-RequiredImages {
    return @((Get-OscarImage), 'oscar-postgis:16-3.5', 'nginxinc/nginx-unprivileged:1.28.1-alpine')
}

function Assert-DeploymentImagesAvailable {
    $missingImages = @(Get-RequiredImages | Where-Object { -not (Test-ContainerImage $_) })
    if ($missingImages.Count -gt 0) {
        throw "Required container images are unavailable: $($missingImages -join ', '). Run 'oscar init' or 'oscar upgrade'."
    }
}

function Prepare-DeploymentImages {
    $requiredImages = @(Get-RequiredImages)
    $missingImages = @($requiredImages | Where-Object { -not (Test-ContainerImage $_) })
    if ($missingImages.Count -eq 0) { return }

    $offlineArchive = Join-Path $ScriptRoot 'offline-images.tar'
    if (Test-Path -LiteralPath $offlineArchive -PathType Leaf) {
        Write-Heading 'Importing offline container images'
        Invoke-External 'docker' @('load', '--input', $offlineArchive)
    } else {
        Write-Heading 'Building deployment images'
        Push-Location $ScriptRoot
        try {
            Invoke-External 'docker' @('compose', 'build', 'oscar', 'postgres')
            Invoke-External 'docker' @('compose', 'pull', 'gateway')
        } finally { Pop-Location }
    }

    $missingImages = @($requiredImages | Where-Object { -not (Test-ContainerImage $_) })
    if ($missingImages.Count -gt 0) { throw "Required container images are unavailable: $($missingImages -join ', ')" }
}

function Initialize-Tls([string]$Name) {
    $tlsDirectory = Join-Path $ScriptRoot 'tls'
    $certificate = Join-Path $tlsDirectory 'server.crt'
    $privateKey = Join-Path $tlsDirectory 'server.key'
    $hasCertificate = Test-Path -LiteralPath $certificate
    $hasPrivateKey = Test-Path -LiteralPath $privateKey
    if ($hasCertificate -xor $hasPrivateKey) {
        throw 'TLS setup is incomplete. Remove the partial certificate/key pair or provide both files.'
    }

    if (-not $hasCertificate) {
        if ($TlsMode -eq 'import') {
            $sourceCertificate = Read-RequiredValue 'Certificate PEM path' $CertificatePath
            $sourceKey = Read-RequiredValue 'Unencrypted private-key PEM path' $PrivateKeyPath
            Copy-Item -LiteralPath $sourceCertificate -Destination $certificate
            Copy-Item -LiteralPath $sourceKey -Destination $privateKey
        } else {
            $parsedIp = $null
            $sanType = if ([Net.IPAddress]::TryParse($Name, [ref]$parsedIp)) { 'IP' } else { 'DNS' }
            $image = Get-OscarImage
            Invoke-External 'docker' @('run', '--rm', '--user', '0:0', '--entrypoint', 'openssl', '--volume', "${tlsDirectory}:/out", $image,
                'req', '-x509', '-newkey', 'rsa:3072', '-sha256', '-nodes', '-days', '365', '-subj', "/CN=$Name", '-addext', "subjectAltName=${sanType}:$Name", '-keyout', '/out/server.key', '-out', '/out/server.crt')
        }
    }

    $image = Get-OscarImage
    # OpenSSL creates private keys as root with mode 0600. Docker Compose file
    # secrets are consumed by deliberately non-root services, so normalize the
    # container-visible mode after generation or import. The protected Windows
    # parent-directory ACL still limits host access to the administrator and
    # Docker service.
    Invoke-External 'docker' @('run', '--rm', '--user', '0:0', '--entrypoint', 'chmod', '--volume', "${tlsDirectory}:/tls", $image,
        '0444', '/tls/server.crt', '/tls/server.key')
    Invoke-External 'docker' @('run', '--rm', '--entrypoint', 'sh', '--volume', "${tlsDirectory}:/tls:ro", $image, '-c',
        'openssl x509 -in /tls/server.crt -pubkey -noout >/tmp/cert.pub && openssl pkey -in /tls/server.key -pubout >/tmp/key.pub && cmp -s /tmp/cert.pub /tmp/key.pub')
    $parsedIp = $null
    $nameCheck = if ([Net.IPAddress]::TryParse($Name, [ref]$parsedIp)) { '-checkip' } else { '-checkhost' }
    Invoke-External 'docker' @('run', '--rm', '--entrypoint', 'openssl', '--volume', "${tlsDirectory}:/tls:ro", $image,
        'x509', '-in', '/tls/server.crt', '-noout', $nameCheck, $Name)
}

function Add-LocalHostsMapping([string]$Name) {
    $parsedIp = $null
    if ([Net.IPAddress]::TryParse($Name, [ref]$parsedIp)) { return }
    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $existing = [IO.File]::ReadAllText($hostsPath)
    if ($existing -match "(?m)^\s*127\.0\.0\.1\s+.*\b$([Regex]::Escape($Name))\b") { return }
    [IO.File]::AppendAllText($hostsPath, "`r`n127.0.0.1`t$Name`t# OSCAR setup`r`n", $Utf8NoBom)
}

function Assert-Configured {
    foreach ($relativePath in @('secrets\oscar-admin-password.txt', 'secrets\oscar-db-password.txt', 'secrets\postgres-bootstrap-password.txt', 'tls\server.crt', 'tls\server.key', '.env')) {
        $path = Join-Path $ScriptRoot $relativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -eq 0) { throw "Missing required setup file: $relativePath" }
    }
}

function Invoke-Compose([string[]]$Arguments) {
    Push-Location $ScriptRoot
    try { Invoke-External 'docker' (@('compose') + $Arguments) } finally { Pop-Location }
}

function Get-ConfiguredEndpoint {
    $hostnameValue = 'oscar.local'
    $portValue = '443'
    $envPath = Join-Path $ScriptRoot '.env'
    if (Test-Path -LiteralPath $envPath -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines($envPath)) {
            if ($line -match '^OSCAR_HOSTNAME=(.*)$' -and $Matches[1]) { $hostnameValue = $Matches[1] }
            if ($line -match '^OSCAR_HTTPS_PORT=(.*)$' -and $Matches[1]) { $portValue = $Matches[1] }
        }
    }
    return "https://${hostnameValue}:$portValue/sensorhub/admin"
}

function Show-Help {
    @'
OSCAR deployment administration

  .\oscar.bat init [-Hostname oscar.local] [-Port 443]
      [-TlsMode self-signed|import] [-CertificatePath FILE -PrivateKeyPath FILE]
      [-AddHostsEntry] [-SkipStart]
  .\oscar.bat check|start|stop|restart|status|upgrade
  .\oscar.bat logs [-Service all|oscar|postgres|gateway] [-Tail 200] [-Follow]

Run mutating commands from an Administrator PowerShell window. For automated setup,
use -NonInteractive and provide OSCAR_SETUP_ADMIN_PASSWORD in the process environment.
'@ | Write-Host
}

try {
    switch ($Command) {
        'help' { Show-Help }
        'check' {
            Write-Heading 'Prerequisite check'
            Write-Host "Administrator: $(Test-Administrator)"
            Write-Host "Docker CLI: $([bool](Get-Command docker -ErrorAction SilentlyContinue))"
            Write-Host "Docker ready: $(Test-DockerReady)"
            Write-Host "WSL ready: $(Test-WslReady)"
            Write-Host "Offline bundle: $(Test-Path -LiteralPath (Join-Path $ScriptRoot 'offline-images.tar') -PathType Leaf)"
            Write-Host "Configured: $(try { Assert-Configured; $true } catch { $false })"
            # TODO(offline-maps): add MBTiles validation/import after deployment requirements are defined.
        }
        'init' {
            Assert-Administrator
            Assert-OfflineBundleIntegrity
            Assert-Docker
            if (-not $Hostname) {
                if ($NonInteractive) { throw 'Hostname is required in non-interactive mode.' }
                $Hostname = (Read-Host 'Hostname or IP address [oscar.local]').Trim()
                if (-not $Hostname) { $Hostname = 'oscar.local' }
            }
            if (-not (Test-ValidHostname $Hostname)) { throw "Invalid hostname or IP address: $Hostname" }
            New-Item -ItemType Directory -Force -Path (Join-Path $ScriptRoot 'secrets'), (Join-Path $ScriptRoot 'tls') | Out-Null
            Set-EnvValue 'OSCAR_HTTPS_PORT' $Port
            Set-EnvValue 'OSCAR_HOSTNAME' $Hostname
            $adminSecretPath = Join-Path $ScriptRoot 'secrets\oscar-admin-password.txt'
            $databaseSecretPath = Join-Path $ScriptRoot 'secrets\oscar-db-password.txt'
            $bootstrapSecretPath = Join-Path $ScriptRoot 'secrets\postgres-bootstrap-password.txt'
            if (-not (Test-Path -LiteralPath $adminSecretPath)) { Write-SecretFile $adminSecretPath (Read-AdminPassword) }
            if (-not (Test-Path -LiteralPath $databaseSecretPath)) { Write-SecretFile $databaseSecretPath (New-RandomPassword) }
            if (-not (Test-Path -LiteralPath $bootstrapSecretPath)) { Write-SecretFile $bootstrapSecretPath (New-RandomPassword) }
            Prepare-DeploymentImages
            Initialize-Tls $Hostname
            Protect-DeploymentFiles
            if ($AddHostsEntry) { Add-LocalHostsMapping $Hostname }
            Assert-Configured
            if (-not $SkipStart) { Invoke-Compose @('up', '--detach', '--no-build', '--pull', 'never', '--wait', '--wait-timeout', '240') }
            Write-Host "`nOSCAR setup complete: https://${Hostname}:$Port/sensorhub/admin" -ForegroundColor Green
        }
        'start' {
            Assert-Administrator; Assert-Docker; Assert-Configured
            Assert-DeploymentImagesAvailable
            Invoke-Compose @('up', '--detach', '--no-build', '--pull', 'never', '--wait', '--wait-timeout', '240')
        }
        'stop' {
            Assert-Administrator; Assert-Docker; Assert-Configured
            Invoke-Compose @('stop')
            Write-Host 'OSCAR stopped. Persistent application and database data were retained.' -ForegroundColor Green
        }
        'restart' {
            Assert-Administrator; Assert-Docker; Assert-Configured; Assert-DeploymentImagesAvailable
            Invoke-Compose @('restart')
            Invoke-Compose @('up', '--detach', '--no-build', '--pull', 'never', '--wait', '--wait-timeout', '240')
        }
        'status' {
            Assert-Docker
            Invoke-Compose @('ps')
            $isConfigured = $true
            try { Assert-Configured } catch { $isConfigured = $false }
            if ($isConfigured) { Write-Host "OSCAR URL: $(Get-ConfiguredEndpoint)" }
        }
        'logs' {
            Assert-Docker; Assert-Configured
            $logArguments = @('logs', '--tail', "$Tail")
            if ($Follow) { $logArguments += '--follow' }
            if ($Service -ne 'all') { $logArguments += $Service }
            Invoke-Compose $logArguments
        }
        'upgrade' {
            Assert-Administrator; Assert-Docker; Assert-Configured
            Write-Heading 'Upgrade preflight'
            Invoke-Compose @('config', '--quiet')
            Prepare-DeploymentImages
            Invoke-Compose @('up', '--detach', '--no-build', '--pull', 'never', '--wait', '--wait-timeout', '240')
            Write-Host 'Upgrade deployment completed. Persistent OSCAR and PostgreSQL volumes were retained.' -ForegroundColor Green
        }
    }
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
