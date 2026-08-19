[CmdletBinding()]
param(
    [string]$OutputRoot,
    [switch]$SkipDownloads,
    [switch]$SkipImageExport,
    [switch]$CreateArchive
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ToolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $ToolRoot '..\..'))
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
if (-not $OutputRoot) { $OutputRoot = Join-Path $RepositoryRoot 'build\offline' }
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$ExpectedOutputRoot = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'build\offline'))
if (-not $OutputRoot.StartsWith($ExpectedOutputRoot, [StringComparison]::OrdinalIgnoreCase)) {
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
    $line = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'dist\release\.env.example') | Where-Object { $_ -match '^OSCAR_VERSION=' } | Select-Object -First 1
    if (-not $line) { throw 'OSCAR_VERSION is missing from dist/release/.env.example.' }
    return $line.Substring('OSCAR_VERSION='.Length)
}

function Assert-SafeStagingPath([string]$Path) {
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith($OutputRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe staging path: $fullPath"
    }
}

function Remove-StagingDirectory([string]$Path) {
    Assert-SafeStagingPath $Path
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

$manifestPath = Join-Path $ToolRoot 'components.windows-x86_64.json'
$componentManifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$version = Get-ReleaseVersion
$bundleName = "oscar-$version-windows-x86_64-offline"
$stagingPath = Join-Path $OutputRoot $bundleName
Assert-SafeStagingPath $stagingPath

Write-Host "Building OSCAR connected release $version with build-all.bat..." -ForegroundColor Cyan
$gradleHome = Join-Path $RepositoryRoot '.gradle'
$previousGradleHome = $env:GRADLE_USER_HOME
try {
    $env:GRADLE_USER_HOME = $gradleHome
    Invoke-Checked 'cmd.exe' @('/d', '/c', (Join-Path $RepositoryRoot 'build-all.bat'))
    Write-Host 'Preparing the expanded release for offline packaging...' -ForegroundColor Cyan
    Invoke-Checked (Join-Path $RepositoryRoot 'gradlew.bat') @('installRelDist')
} finally { $env:GRADLE_USER_HOME = $previousGradleHome }

if (Test-Path -LiteralPath $stagingPath) {
    Remove-StagingDirectory $stagingPath
}
New-Item -ItemType Directory -Force -Path $stagingPath | Out-Null
Copy-Item -Path (Join-Path $RepositoryRoot 'build\install\oscar\*') -Destination $stagingPath -Recurse -Force
Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $stagingPath 'installers\components.windows-x86_64.json') -Force

foreach ($component in $componentManifest.components) {
    $destination = Join-Path $stagingPath ($component.file -replace '/', [IO.Path]::DirectorySeparatorChar)
    $destinationDirectory = Split-Path -Parent $destination
    New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
    $cachePath = Join-Path $OutputRoot ('.cache\' + ($component.file -replace '/', [IO.Path]::DirectorySeparatorChar))
    $cacheDirectory = Split-Path -Parent $cachePath
    New-Item -ItemType Directory -Force -Path $cacheDirectory | Out-Null
    $requiresDownload = -not (Test-Path -LiteralPath $cachePath)
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
        Invoke-WebRequest -Uri $component.url -OutFile $partialPath -UseBasicParsing
        Assert-Hash $partialPath $component.sha256
        Move-Item -LiteralPath $partialPath -Destination $cachePath
    }
    Copy-Item -LiteralPath $cachePath -Destination $destination -Force
    Assert-Hash $destination $component.sha256
    Write-Host "Verified $($component.name): $($component.sha256)"
}

$archivePath = Join-Path $stagingPath 'offline-images.tar'
if (-not $SkipImageExport) {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'Docker is required to build the offline image archive.' }
    $previousVersion = $env:OSCAR_VERSION
    $previousPostgisVersion = $env:OSCAR_POSTGIS_VERSION
    $previousPostgisPlatform = $env:OSCAR_POSTGIS_PLATFORM
    try {
        $env:OSCAR_VERSION = $version
        $env:OSCAR_POSTGIS_VERSION = '16-3.5'
        $env:OSCAR_POSTGIS_PLATFORM = 'linux/amd64'
        Write-Host 'Building release application and PostGIS images...' -ForegroundColor Cyan
        Invoke-Checked 'docker' @('compose', '-f', (Join-Path $stagingPath 'compose.yaml'), 'build', 'oscar', 'postgres') $stagingPath
        Write-Host 'Fetching the pinned gateway image...' -ForegroundColor Cyan
        Invoke-Checked 'docker' @('pull', '--platform', 'linux/amd64', 'nginxinc/nginx-unprivileged:1.28.1-alpine')
        Write-Host 'Exporting container images for registry-free installation...' -ForegroundColor Cyan
        Invoke-Checked 'docker' @('save', '--output', $archivePath, "oscar:$version", 'oscar-postgis:16-3.5', 'nginxinc/nginx-unprivileged:1.28.1-alpine')
    } finally {
        $env:OSCAR_VERSION = $previousVersion
        $env:OSCAR_POSTGIS_VERSION = $previousPostgisVersion
        $env:OSCAR_POSTGIS_PLATFORM = $previousPostgisPlatform
    }
} elseif (-not (Test-Path -LiteralPath $archivePath)) {
    throw "Missing image archive while -SkipImageExport is set: $archivePath"
}

$bundleInfo = @"
OSCAR offline installation bundle
Version: $version
Platform: Windows 11 x86-64
Generated UTC: $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))
Docker Desktop: $($componentManifest.components[0].version)
WSL: $($componentManifest.components[1].version)
Images: oscar:$version, oscar-postgis:16-3.5, nginxinc/nginx-unprivileged:1.28.1-alpine

Copy this entire directory to a local NTFS folder on the target Windows host.
Open an Administrator PowerShell window, run .\verify-bundle.ps1, then run
.\oscar.bat init. See QUICKSTART.md and DEPLOYMENT.md for installation requirements.
"@
[IO.File]::WriteAllText((Join-Path $stagingPath 'BUNDLE-INFO.txt'), $bundleInfo, $Utf8NoBom)

$checksumPath = Join-Path $stagingPath 'SHA256SUMS'
$checksumLines = Get-ChildItem -LiteralPath $stagingPath -Recurse -File |
    Where-Object { $_.FullName -ne $checksumPath } |
    Sort-Object FullName |
    ForEach-Object {
        $relative = $_.FullName.Substring($stagingPath.Length + 1).Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash *$relative"
    }
[IO.File]::WriteAllLines($checksumPath, $checksumLines, $Utf8NoBom)

Write-Host "`nOffline bundle ready: $stagingPath" -ForegroundColor Green
Write-Host "Bundle size: $([Math]::Round(((Get-ChildItem $stagingPath -Recurse -File | Measure-Object Length -Sum).Sum / 1GB), 2)) GiB"

if ($CreateArchive) {
    $archiveOutput = Join-Path $OutputRoot "$bundleName.zip"
    $archiveChecksum = "$archiveOutput.sha256"
    foreach ($generatedPath in @($archiveOutput, $archiveChecksum)) {
        if (Test-Path -LiteralPath $generatedPath) { Remove-Item -LiteralPath $generatedPath -Force }
    }
    Write-Host 'Creating offline installation archive...' -ForegroundColor Cyan
    Invoke-Checked 'tar.exe' @('-a', '-c', '-f', $archiveOutput, $bundleName) $OutputRoot
    $archiveHash = (Get-FileHash -LiteralPath $archiveOutput -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($archiveChecksum, "$archiveHash *$bundleName.zip`n", $Utf8NoBom)
    Write-Host "Archive ready: $archiveOutput" -ForegroundColor Green
    Write-Host "Archive SHA-256: $archiveHash"
}
