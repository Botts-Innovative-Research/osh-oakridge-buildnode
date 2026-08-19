[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$checksumFile = Join-Path $root 'SHA256SUMS'
if (-not (Test-Path -LiteralPath $checksumFile -PathType Leaf)) {
    Write-Error 'SHA256SUMS is missing. This is not a complete offline bundle.'
    exit 1
}

$verified = 0
foreach ($line in [IO.File]::ReadAllLines($checksumFile)) {
    if (-not $line.Trim()) { continue }
    if ($line -notmatch '^([0-9a-fA-F]{64}) \*(.+)$') { throw "Invalid SHA256SUMS entry: $line" }
    $expected = $Matches[1].ToLowerInvariant()
    $relative = $Matches[2].Replace('/', [IO.Path]::DirectorySeparatorChar)
    $path = [IO.Path]::GetFullPath((Join-Path $root $relative))
    if (-not $path.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe bundle path: $relative" }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Bundle file is missing: $relative" }
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne $expected) { throw "Checksum mismatch: $relative" }
    $verified++
}

Write-Host "Bundle integrity verified: $verified files." -ForegroundColor Green
