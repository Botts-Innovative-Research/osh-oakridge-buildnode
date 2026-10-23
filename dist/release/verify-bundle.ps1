[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Split-Path -Parent $MyInvocation.MyCommand.Path))
function Assert-NoReparseComponents([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $rootPart = [IO.Path]::GetPathRoot($full)
    $current = $rootPart
    foreach ($component in $full.Substring($rootPart.Length).Split([IO.Path]::DirectorySeparatorChar, [StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path $current $component
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or -not $item.PSIsContainer) {
            throw "Bundle path has an unsafe reparse/non-directory component: $current"
        }
    }
}
function Initialize-BundleReceiptMethods {
    if ('OscarVerifyBundleNative' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class OscarVerifyBundleNative {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool MoveFileEx(string existingName, string newName, uint flags);
}
'@
}
Assert-NoReparseComponents $root
$checksumFile = Join-Path $root 'SHA256SUMS'
$checksumItem = Get-Item -LiteralPath $checksumFile -Force -ErrorAction SilentlyContinue
if (-not $checksumItem -or $checksumItem.PSIsContainer -or ($checksumItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    Write-Error 'SHA256SUMS is missing. This is not a complete offline bundle.'
    exit 1
}
$manifestHash = (Get-FileHash -LiteralPath $checksumFile -Algorithm SHA256).Hash.ToLowerInvariant()

$verified = 0
$declared = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$entries = New-Object System.Collections.Generic.List[object]
foreach ($line in [IO.File]::ReadAllLines($checksumFile)) {
    if (-not $line.Trim()) { continue }
    if ($line -notmatch '^([0-9a-fA-F]{64}) \*(.+)$') { throw "Invalid SHA256SUMS entry: $line" }
    $expected = $Matches[1].ToLowerInvariant()
    $manifestRelative = $Matches[2]
    if (-not $manifestRelative -or $manifestRelative.StartsWith('/') -or $manifestRelative.Contains('\') -or
        $manifestRelative.Contains('//') -or $manifestRelative -match '(^|/)\.{1,2}(/|$)' -or
        $manifestRelative -in @('SHA256SUMS', '.bundle-verified') -or
        $manifestRelative.StartsWith('.bundle-verified.tmp.', [StringComparison]::Ordinal)) {
        throw "Unsafe or reserved SHA256SUMS path: $manifestRelative"
    }
    if (-not $declared.Add($manifestRelative)) { throw "Duplicate or case-colliding SHA256SUMS path: $manifestRelative" }
    $relative = $manifestRelative.Replace('/', [IO.Path]::DirectorySeparatorChar)
    $path = [IO.Path]::GetFullPath((Join-Path $root $relative))
    if (-not $path.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe bundle path: $relative" }
    $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if (-not $item -or $item.PSIsContainer -or $item -isnot [IO.FileInfo] -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Bundle file is missing or unsafe: $relative" }
    $entries.Add([pscustomobject]@{ Path = $path; Relative = $manifestRelative; Expected = $expected })
}
if ($declared.Count -eq 0) { throw 'SHA256SUMS is empty.' }

$actual = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$pending = New-Object System.Collections.Generic.Stack[string]
$pending.Push($root)
$rootPrefix = $root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
while ($pending.Count -gt 0) {
    $directory = $pending.Pop()
    foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force)) {
        $fullItemPath = [IO.Path]::GetFullPath($item.FullName)
        if (-not $fullItemPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Offline bundle entry escapes the package root: $fullItemPath"
        }
        $relative = $fullItemPath.Substring($rootPrefix.Length).Replace('\', '/')
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Offline bundle contains a reparse point: $relative"
        }
        if ($item.PSIsContainer) { $pending.Push($item.FullName); continue }
        if ($item -isnot [IO.FileInfo]) { throw "Offline bundle contains a non-regular entry: $relative" }
        if ($relative -in @('SHA256SUMS', '.bundle-verified') -or
            $relative.StartsWith('.bundle-verified.tmp.', [StringComparison]::Ordinal)) { continue }
        if (-not $actual.Add($relative)) { throw "Offline bundle contains case-colliding paths: $relative" }
    }
}
if ($actual.Count -ne $declared.Count -or @($actual | Where-Object { -not $declared.Contains($_) }).Count -ne 0) {
    throw 'SHA256SUMS does not exactly cover the offline bundle payload.'
}

foreach ($entry in $entries) {
    $actualHash = (Get-FileHash -LiteralPath $entry.Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -cne $entry.Expected) { throw "Checksum mismatch: $($entry.Relative)" }
    $verified++
}

$receiptPath = Join-Path $root '.bundle-verified'
$temporaryReceipt = Join-Path $root ('.bundle-verified.tmp.' + [Guid]::NewGuid().ToString('N'))
try {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $bytes = $utf8.GetBytes("$manifestHash`n")
    $stream = [IO.FileStream]::new($temporaryReceipt, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    $existing = Get-Item -LiteralPath $receiptPath -Force -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing.PSIsContainer -or ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Offline verification receipt is not a regular, non-reparse-point file: $receiptPath"
        }
    }
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        Initialize-BundleReceiptMethods
        $moveFlags = if ($existing) { 0x9 } else { 0x8 }
        if (-not [OscarVerifyBundleNative]::MoveFileEx($temporaryReceipt, $receiptPath, $moveFlags)) {
            $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "Durable offline-verification receipt publication failed (Win32 $code)."
        }
    } else {
        if ($existing) { [IO.File]::Move($temporaryReceipt, $receiptPath, $true) }
        else { [IO.File]::Move($temporaryReceipt, $receiptPath) }
    }
} finally {
    if (Test-Path -LiteralPath $temporaryReceipt) { Remove-Item -LiteralPath $temporaryReceipt -Force -ErrorAction SilentlyContinue }
}
Write-Host "Bundle integrity verified: $verified files." -ForegroundColor Green
