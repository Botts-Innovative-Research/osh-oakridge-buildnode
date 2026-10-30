[CmdletBinding()]
param(
    [string]$OutputRoot,
    [ValidateSet('Full', 'ImagesOnly', 'Both')]
    [string]$BundleProfile = 'Both',
    [switch]$SkipConnectedBuild,
    [switch]$UseExistingExpandedRelease,
    [switch]$SkipDownloads,
    [switch]$SkipImageExport,
    [switch]$CreateArchive
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ToolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepositoryRoot = [IO.Path]::GetFullPath((Join-Path (Join-Path $ToolRoot '..') '..'))
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$DirectorySeparator = [IO.Path]::DirectorySeparatorChar
$RunningOnWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
if (-not $OutputRoot) { $OutputRoot = Join-Path $RepositoryRoot 'build/offline' }
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$ExpectedOutputRoot = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'build/offline'))
$isExpectedRoot = [String]::Equals($OutputRoot, $ExpectedOutputRoot, [StringComparison]::OrdinalIgnoreCase)
$isExpectedChild = $OutputRoot.StartsWith($ExpectedOutputRoot + $DirectorySeparator, [StringComparison]::OrdinalIgnoreCase)
if (-not $isExpectedRoot -and -not $isExpectedChild) {
    throw "OutputRoot must remain under $ExpectedOutputRoot"
}

function Invoke-Checked([string]$Program, [string[]]$Arguments, [string]$WorkingDirectory = $RepositoryRoot) {
    Push-Location $WorkingDirectory
    try {
        & $Program @Arguments
        if ($LASTEXITCODE -ne 0) { throw "$Program exited with code $LASTEXITCODE." }
    } finally { Pop-Location }
}

function Get-ReleaseVersion {
    $line = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'dist/release/.env.example') | Where-Object { $_ -match '^OSCAR_VERSION=' } | Select-Object -First 1
    if (-not $line) { throw 'OSCAR_VERSION is missing from dist/release/.env.example.' }
    return $line.Substring('OSCAR_VERSION='.Length)
}

function Assert-SafeOutputPath([string]$Path) {
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith($OutputRoot + $DirectorySeparator, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe offline output path: $fullPath"
    }
}

function Remove-OutputDirectory([string]$Path) {
    Assert-SafeOutputPath $Path
    for ($attempt = 1; $attempt -le 15; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force
            return
        } catch {
            if ($attempt -eq 15) { throw }
            Start-Sleep -Milliseconds 500
        }
    }
}

function Assert-Hash([string]$Path, [string]$ExpectedHash) {
    $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -cne $ExpectedHash.ToLowerInvariant()) {
        throw "SHA-256 mismatch for $Path. Expected $ExpectedHash; received $actualHash."
    }
}

function New-ZipArchive([string]$SourceDirectory, [string]$ArchivePath) {
    $bundleName = Split-Path -Leaf $SourceDirectory
    if ($RunningOnWindows) {
        Invoke-Checked 'tar.exe' @('-a', '-c', '-f', $ArchivePath, $bundleName) $OutputRoot
    } else {
        if (-not (Get-Command zip -ErrorAction SilentlyContinue)) { throw 'zip is required to create the offline release archives.' }
        Invoke-Checked 'zip' @('-q', '-r', $ArchivePath, $bundleName) $OutputRoot
    }
}

function Write-BundleChecksums([string]$StagingPath) {
    $checksumPath = Join-Path $StagingPath 'SHA256SUMS'
    $checksumLines = Get-ChildItem -LiteralPath $StagingPath -Recurse -File -Force |
        Where-Object { $_.FullName -ne $checksumPath -and $_.Name -ne '.bundle-verified' } |
        Sort-Object FullName |
        ForEach-Object {
            $relative = $_.FullName.Substring($StagingPath.Length + 1).Replace($DirectorySeparator, '/')
            $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            "$hash *$relative"
        }
    [IO.File]::WriteAllLines($checksumPath, $checksumLines, $Utf8NoBom)
}

$manifestPath = Join-Path $ToolRoot 'components.windows-x86_64.json'
$componentManifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$version = Get-ReleaseVersion
$expandedRelease = Join-Path $RepositoryRoot 'build/install/oscar'
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null

$gradleHome = Join-Path $RepositoryRoot '.gradle'
$previousGradleHome = $env:GRADLE_USER_HOME
try {
    $env:GRADLE_USER_HOME = $gradleHome
    if (-not $SkipConnectedBuild) {
        Write-Host "Building OSCAR connected release $version..." -ForegroundColor Cyan
        if ($RunningOnWindows) {
            Invoke-Checked 'cmd.exe' @('/d', '/c', (Join-Path $RepositoryRoot 'build-all.bat'))
        } else {
            Invoke-Checked 'bash' @((Join-Path $RepositoryRoot 'build-all.sh'))
        }
    }
    if (-not $UseExistingExpandedRelease) {
        Write-Host 'Preparing the expanded release for offline packaging...' -ForegroundColor Cyan
        $gradleExecutable = if ($RunningOnWindows) { Join-Path $RepositoryRoot 'gradlew.bat' } else { Join-Path $RepositoryRoot 'gradlew' }
        Invoke-Checked $gradleExecutable @('installRelDist')
    } else {
        Write-Host "Using existing expanded release at $expandedRelease..." -ForegroundColor Cyan
    }
} finally { $env:GRADLE_USER_HOME = $previousGradleHome }
if (-not (Test-Path -LiteralPath (Join-Path $expandedRelease 'compose.yaml') -PathType Leaf)) {
    throw "Expanded release was not produced at $expandedRelease"
}

$imageCacheDirectory = Join-Path $OutputRoot '.cache/images'
$archivePath = Join-Path $imageCacheDirectory "oscar-$version-windows-x86_64-offline-images.tar"
New-Item -ItemType Directory -Force -Path $imageCacheDirectory | Out-Null
if (-not $SkipImageExport) {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'Docker is required to build the offline image archive.' }
    $previousVersion = $env:OSCAR_VERSION
    $previousPostgisPlatform = $env:OSCAR_POSTGIS_PLATFORM
    try {
        $env:OSCAR_VERSION = $version
        $env:OSCAR_POSTGIS_PLATFORM = 'linux/amd64'
        Write-Host 'Building release application and PostGIS images...' -ForegroundColor Cyan
        Invoke-Checked 'docker' @('compose', '-f', (Join-Path $expandedRelease 'compose.yaml'), 'build', 'oscar', 'postgres') $expandedRelease
        Write-Host 'Fetching the pinned gateway image...' -ForegroundColor Cyan
        Invoke-Checked 'docker' @('pull', '--platform', 'linux/amd64', 'nginxinc/nginx-unprivileged:1.28.1-alpine')
        Write-Host 'Exporting container images for registry-free installation...' -ForegroundColor Cyan
        Invoke-Checked 'docker' @('save', '--output', $archivePath, "oscar:$version", "oscar-postgis:$version", 'nginxinc/nginx-unprivileged:1.28.1-alpine')
    } finally {
        $env:OSCAR_VERSION = $previousVersion
        $env:OSCAR_POSTGIS_PLATFORM = $previousPostgisPlatform
    }
} elseif (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
    throw "Missing cached image archive while -SkipImageExport is set: $archivePath"
}

$profiles = switch ($BundleProfile) {
    'Full' { @('Full') }
    'ImagesOnly' { @('ImagesOnly') }
    'Both' { @('Full', 'ImagesOnly') }
}

foreach ($profile in $profiles) {
    $suffix = if ($profile -eq 'Full') { 'offline-full' } else { 'offline-images' }
    $bundleName = "oscar-$version-windows-x86_64-$suffix"
    $stagingPath = Join-Path $OutputRoot $bundleName
    Assert-SafeOutputPath $stagingPath
    if (Test-Path -LiteralPath $stagingPath) { Remove-OutputDirectory $stagingPath }
    New-Item -ItemType Directory -Force -Path $stagingPath | Out-Null
    Copy-Item -Path (Join-Path $expandedRelease '*') -Destination $stagingPath -Recurse -Force
    Copy-Item -LiteralPath $archivePath -Destination (Join-Path $stagingPath 'offline-images.tar') -Force
    # The application distribution is already sealed inside the OSCAR image.
    # Keeping the duplicate Docker build context would add hundreds of MiB and
    # can push the full release past GitHub's per-asset limit. Offline setup
    # always loads the exported images and never builds from this directory.
    $applicationBuildContext = Join-Path $stagingPath 'osh-node-oscar'
    if (Test-Path -LiteralPath $applicationBuildContext) {
        Remove-Item -LiteralPath $applicationBuildContext -Recurse -Force
    }

    if ($profile -eq 'Full') {
        Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $stagingPath 'installers/components.windows-x86_64.json') -Force
        foreach ($component in $componentManifest.components) {
            $relativeComponentPath = $component.file -replace '/', $DirectorySeparator
            $destination = Join-Path $stagingPath $relativeComponentPath
            $destinationDirectory = Split-Path -Parent $destination
            New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
            $cachePath = Join-Path (Join-Path $OutputRoot '.cache') $relativeComponentPath
            $cacheDirectory = Split-Path -Parent $cachePath
            New-Item -ItemType Directory -Force -Path $cacheDirectory | Out-Null
            $requiresDownload = -not (Test-Path -LiteralPath $cachePath -PathType Leaf)
            if (-not $requiresDownload) {
                try { Assert-Hash $cachePath $component.sha256 } catch {
                    if ($SkipDownloads) { throw }
                    Remove-Item -LiteralPath $cachePath -Force
                    $requiresDownload = $true
                }
            }
            if ($requiresDownload) {
                if ($SkipDownloads) { throw "Missing cached component while -SkipDownloads is set: $cachePath" }
                Write-Host "Downloading $($component.name) $($component.version)..." -ForegroundColor Cyan
                $partialPath = "$cachePath.partial"
                if (Test-Path -LiteralPath $partialPath) { Remove-Item -LiteralPath $partialPath -Force }
                $previousProgressPreference = $ProgressPreference
                try {
                    $ProgressPreference = 'SilentlyContinue'
                    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                    Invoke-WebRequest -Uri $component.url -OutFile $partialPath -UseBasicParsing
                } finally {
                    $ProgressPreference = $previousProgressPreference
                }
                Assert-Hash $partialPath $component.sha256
                Move-Item -LiteralPath $partialPath -Destination $cachePath
            }
            Copy-Item -LiteralPath $cachePath -Destination $destination -Force
            Assert-Hash $destination $component.sha256
            Write-Host "Verified $($component.name): $($component.sha256)"
        }
    } else {
        $installerDirectory = Join-Path $stagingPath 'installers'
        if (Test-Path -LiteralPath $installerDirectory) { Remove-Item -LiteralPath $installerDirectory -Recurse -Force }
    }

    $bundleDescription = if ($profile -eq 'Full') {
        'Full installation media with approved Docker Desktop and WSL installers.'
    } else {
        'Application and container images only. A working Docker Desktop, WSL 2, and Docker Compose installation is required.'
    }
    $bundleInfo = @"
OSCAR offline installation bundle
Version: $version
Platform: Windows 11 x86-64
Profile: $profile
Contents: $bundleDescription
Generated UTC: $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))
Images: oscar:$version, oscar-postgis:$version, nginxinc/nginx-unprivileged:1.28.1-alpine

Copy this entire directory to a local NTFS folder on the target Windows host.
Run .\verify-bundle.ps1, then run .\oscar.bat init. The images-only profile
requires an existing, running Docker installation and never downloads images.
"@
    [IO.File]::WriteAllText((Join-Path $stagingPath 'BUNDLE-INFO.txt'), $bundleInfo, $Utf8NoBom)
    Write-BundleChecksums $stagingPath

    Write-Host "`nOffline bundle ready: $stagingPath" -ForegroundColor Green
    Write-Host "Bundle size: $([Math]::Round(((Get-ChildItem $stagingPath -Recurse -File | Measure-Object Length -Sum).Sum / 1GB), 2)) GiB"

    if ($CreateArchive) {
        $archiveOutput = Join-Path $OutputRoot "$bundleName.zip"
        $archiveChecksum = "$archiveOutput.sha256"
        foreach ($generatedPath in @($archiveOutput, $archiveChecksum)) {
            if (Test-Path -LiteralPath $generatedPath) { Remove-Item -LiteralPath $generatedPath -Force }
        }
        Write-Host "Creating $profile offline installation archive..." -ForegroundColor Cyan
        New-ZipArchive $stagingPath $archiveOutput
        $archiveHash = (Get-FileHash -LiteralPath $archiveOutput -Algorithm SHA256).Hash.ToLowerInvariant()
        [IO.File]::WriteAllText($archiveChecksum, "$archiveHash *$bundleName.zip`n", $Utf8NoBom)
        Write-Host "Archive ready: $archiveOutput" -ForegroundColor Green
        Write-Host "Archive SHA-256: $archiveHash"
    }
}
