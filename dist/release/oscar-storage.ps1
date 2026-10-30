[CmdletBinding()]
param(
    [ValidateSet('backup', 'backup-verify', 'backup-prune', 'restore', 'prepare-directories', 'upgrade-state', 'archive', 'help')]
    [string]$Command = 'help',
    [string]$Action = 'status',
    [string]$HoldAction = 'list',
    [string]$BackupId,
    [string]$Confirm,
    [string]$Before,
    [string]$RequestedBy,
    [string]$Plan,
    [string]$Token,
    [string]$Generation,
    [string]$Destination,
    [string]$Observation,
    [string]$StoreKey,
    [string]$IdScope,
    [string]$HoldId,
    [string]$Reason,
    [string]$CreatedBy,
    [string]$ReleasedBy,
    [switch]$AdoptExistingStorageRoots,
    [ValidateRange(1, 10000)]
    [int]$Keep = 0
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$StorageScriptTestMode = ($MyInvocation.InvocationName -eq '.' -and $env:OSCAR_STORAGE_TEST_MODE -ceq '1')

function Fail([string]$Message) { throw $Message }

function Assert-NoReparseComponents([string]$FullPath, [switch]$AllowMissingLeaf) {
    $full = [IO.Path]::GetFullPath($FullPath)
    $volume = [IO.Path]::GetPathRoot($full)
    $current = $volume
    $parts = $full.Substring($volume.Length) -split '[\\/]'
    for ($index = 0; $index -lt $parts.Count; $index++) {
        if (-not $parts[$index]) { continue }
        $current = Join-Path $current $parts[$index]
        $isLeaf = $index -eq ($parts.Count - 1)
        if (-not (Test-Path -LiteralPath $current)) {
            if ($AllowMissingLeaf -and $isLeaf) { return }
            Fail "Path component is missing: $current"
        }
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Fail "Reparse points are not permitted in privileged storage paths: $current"
        }
    }
}

function Resolve-ExistingPhysicalPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        if (-not ('OscarStoragePathNative' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class OscarStoragePathNative {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint GetLongPathName(string shortPath, StringBuilder longPath, uint bufferLength);
}
'@
        }
        $buffer = New-Object Text.StringBuilder 32768
        $length = [OscarStoragePathNative]::GetLongPathName($full, $buffer, [uint32]$buffer.Capacity)
        if ($length -eq 0 -or $length -ge $buffer.Capacity) {
            $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            Fail "Could not canonicalize existing privileged path (Win32 $code): $Path"
        }
        return [IO.Path]::GetFullPath($buffer.ToString())
    }
    return [string](Resolve-Path -LiteralPath $full -ErrorAction Stop).ProviderPath
}

$StorageScriptPath = [IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
Assert-NoReparseComponents $StorageScriptPath
$StorageScriptPath = Resolve-ExistingPhysicalPath $StorageScriptPath
$storageScriptItem = Get-Item -LiteralPath $StorageScriptPath -Force
if ($storageScriptItem.PSIsContainer) { Fail "OSCAR storage launcher must be a regular file: $StorageScriptPath" }
$ScriptRoot = Resolve-ExistingPhysicalPath (Split-Path -Parent $storageScriptItem.FullName)
Assert-NoReparseComponents $ScriptRoot
if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and
    [IO.Path]::GetPathRoot($ScriptRoot) -notmatch '^[A-Za-z]:\\$') {
    Fail "OSCAR storage launcher must reside on a local Windows volume: $ScriptRoot"
}
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$MaxDockerInspectJsonBytes = 1048576
$releaseVersionLine = @([IO.File]::ReadAllLines((Join-Path $ScriptRoot '.env.example')) | Where-Object { $_ -match '^OSCAR_VERSION=' } | Select-Object -First 1)
if ($releaseVersionLine.Count -ne 1) { throw 'The packaged OSCAR release version is missing.' }
$RequiredReleaseVersion = $releaseVersionLine[0].Substring('OSCAR_VERSION='.Length)
if ($RequiredReleaseVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:[.-][0-9A-Za-z.-]+)?$') { throw 'The packaged OSCAR release version is invalid.' }
$MaxBackupArchiveGenerationIds = 1000000
$MaxBackupArchiveGenerationInventoryBytes = 37000000
$ArchiveAuditSortChunkLines = 4096
$ValidatorScratchTmpfs = '/tmp:rw,noexec,nosuid,nodev,size=256m,mode=0700,uid=0,gid=0'
$script:StorageAdminLock = $null

function Initialize-NativeStorageMethods {
    if ('OscarStorageNative' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
public static class OscarStorageNative {
    private const uint FILE_ATTRIBUTE_READONLY = 0x00000001;
    private const uint FILE_ATTRIBUTE_DIRECTORY = 0x00000010;
    private const uint FILE_ATTRIBUTE_DEVICE = 0x00000040;
    private const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;
    private const uint FILE_ATTRIBUTE_REPARSE_POINT = 0x00000400;
    private const uint INVALID_FILE_ATTRIBUTES = 0xFFFFFFFF;
    private const int ERROR_FILE_NOT_FOUND = 2;
    private const int ERROR_PATH_NOT_FOUND = 3;
    private const int ERROR_NO_MORE_FILES = 18;
    private static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WIN32_FIND_DATAW {
        public uint dwFileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME ftCreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME ftLastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME ftLastWriteTime;
        public uint nFileSizeHigh;
        public uint nFileSizeLow;
        public uint dwReserved0;
        public uint dwReserved1;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string cFileName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)]
        public string cAlternateFileName;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool MoveFileEx(string existingName, string newName, uint flags);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool FlushFileBuffers(IntPtr handle);
    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFileAttributesW(string lpFileName);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SetFileAttributesW(string lpFileName, uint dwFileAttributes);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr FindFirstFileW(string lpFileName, out WIN32_FIND_DATAW lpFindFileData);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool FindNextFileW(IntPtr hFindFile, out WIN32_FIND_DATAW lpFindFileData);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FindClose(IntPtr hFindFile);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool DeleteFileW(string lpFileName);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool RemoveDirectoryW(string lpPathName);

    public static string ToExtendedPath(string fullPath) {
        if (string.IsNullOrWhiteSpace(fullPath)) {
            throw new ArgumentException("Storage path must not be empty.");
        }
        if (fullPath.StartsWith(@"\\?\", StringComparison.Ordinal)) {
            return fullPath.TrimEnd('\\', '/');
        }
        string normalized = fullPath.Replace('/', '\\');
        if (normalized.Length < 248) {
            normalized = Path.GetFullPath(normalized);
        } else if (!Regex.IsMatch(normalized, @"^[A-Za-z]:\\") && !normalized.StartsWith(@"\\", StringComparison.Ordinal)) {
            throw new ArgumentException("Extended storage path must be rooted: " + fullPath);
        }
        normalized = normalized.TrimEnd('\\');
        if (normalized.StartsWith(@"\\", StringComparison.Ordinal)) {
            return @"\\?\UNC\" + normalized.Substring(2);
        }
        return @"\\?\" + normalized;
    }

    private static string StripExtendedPrefix(string extendedPath) {
        if (extendedPath.StartsWith(@"\\?\UNC\", StringComparison.Ordinal)) {
            return @"\\" + extendedPath.Substring(8);
        }
        if (extendedPath.StartsWith(@"\\?\", StringComparison.Ordinal)) {
            return extendedPath.Substring(4);
        }
        return extendedPath;
    }

    public static void AssertRegularDirectoryTree(string fullPath, string description) {
        string root = ToExtendedPath(fullPath);
        uint rootAttr = GetFileAttributesW(root);
        if (rootAttr == INVALID_FILE_ATTRIBUTES) {
            int err = Marshal.GetLastWin32Error();
            throw new IOException(string.Format("{0} is missing (Win32 {1}): {2}", description, err, StripExtendedPrefix(root)));
        }
        if ((rootAttr & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
            throw new InvalidOperationException(string.Format("{0} is a reparse point: {1}", description, StripExtendedPrefix(root)));
        }
        if ((rootAttr & FILE_ATTRIBUTE_DIRECTORY) == 0) {
            throw new InvalidOperationException(string.Format("{0} is not a directory: {1}", description, StripExtendedPrefix(root)));
        }
        Stack<string> pending = new Stack<string>();
        pending.Push(root);
        while (pending.Count > 0) {
            string current = pending.Pop();
            WIN32_FIND_DATAW data;
            IntPtr handle = FindFirstFileW(current + @"\*", out data);
            if (handle == INVALID_HANDLE_VALUE) {
                int err = Marshal.GetLastWin32Error();
                if (err == ERROR_FILE_NOT_FOUND) continue;
                throw new IOException(string.Format("Could not enumerate {0} (Win32 {1}): {2}", description, err, StripExtendedPrefix(current)));
            }
            try {
                do {
                    string name = data.cFileName;
                    if (name == "." || name == "..") continue;
                    string child = current + @"\" + name;
                    uint attr = data.dwFileAttributes;
                    if ((attr & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
                        throw new InvalidOperationException(string.Format("{0} contains a reparse point: {1}", description, StripExtendedPrefix(child)));
                    }
                    if ((attr & FILE_ATTRIBUTE_DEVICE) != 0) {
                        throw new InvalidOperationException(string.Format("{0} contains a non-regular entry: {1}", description, StripExtendedPrefix(child)));
                    }
                    if ((attr & FILE_ATTRIBUTE_DIRECTORY) != 0) {
                        pending.Push(child);
                    }
                } while (FindNextFileW(handle, out data));
                int lastErr = Marshal.GetLastWin32Error();
                if (lastErr != ERROR_NO_MORE_FILES) {
                    throw new IOException(string.Format("Directory enumeration failed in {0} (Win32 {1}): {2}", description, lastErr, StripExtendedPrefix(current)));
                }
            } finally {
                FindClose(handle);
            }
        }
    }

    public static void DeleteValidatedDirectoryTree(string fullPath, string description) {
        string root = ToExtendedPath(fullPath);
        uint rootAttr = GetFileAttributesW(root);
        if (rootAttr == INVALID_FILE_ATTRIBUTES) {
            int err = Marshal.GetLastWin32Error();
            if (err == ERROR_FILE_NOT_FOUND || err == ERROR_PATH_NOT_FOUND) return;
            throw new IOException(string.Format("Could not inspect {0} (Win32 {1}): {2}", description, err, StripExtendedPrefix(root)));
        }
        if ((rootAttr & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
            throw new InvalidOperationException(string.Format("{0} is a reparse point: {1}", description, StripExtendedPrefix(root)));
        }
        if ((rootAttr & FILE_ATTRIBUTE_DIRECTORY) == 0) {
            throw new InvalidOperationException(string.Format("{0} is not a directory: {1}", description, StripExtendedPrefix(root)));
        }
        List<string> files = new List<string>();
        List<string> directories = new List<string>();
        Stack<string> pending = new Stack<string>();
        pending.Push(root);
        while (pending.Count > 0) {
            string current = pending.Pop();
            directories.Add(current);
            WIN32_FIND_DATAW data;
            IntPtr handle = FindFirstFileW(current + @"\*", out data);
            if (handle == INVALID_HANDLE_VALUE) {
                int err = Marshal.GetLastWin32Error();
                if (err == ERROR_FILE_NOT_FOUND) continue;
                throw new IOException(string.Format("Could not enumerate {0} (Win32 {1}): {2}", description, err, StripExtendedPrefix(current)));
            }
            try {
                do {
                    string name = data.cFileName;
                    if (name == "." || name == "..") continue;
                    string child = current + @"\" + name;
                    uint attr = data.dwFileAttributes;
                    if ((attr & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
                        throw new InvalidOperationException(string.Format("{0} contains a reparse point: {1}", description, StripExtendedPrefix(child)));
                    }
                    if ((attr & FILE_ATTRIBUTE_DEVICE) != 0) {
                        throw new InvalidOperationException(string.Format("{0} contains a non-regular entry: {1}", description, StripExtendedPrefix(child)));
                    }
                    if ((attr & FILE_ATTRIBUTE_DIRECTORY) != 0) {
                        pending.Push(child);
                    } else {
                        files.Add(child);
                    }
                } while (FindNextFileW(handle, out data));
                int lastErr = Marshal.GetLastWin32Error();
                if (lastErr != ERROR_NO_MORE_FILES) {
                    throw new IOException(string.Format("Directory enumeration failed in {0} (Win32 {1}): {2}", description, lastErr, StripExtendedPrefix(current)));
                }
            } finally {
                FindClose(handle);
            }
        }
        foreach (string file in files) {
            uint attr = GetFileAttributesW(file);
            if (attr != INVALID_FILE_ATTRIBUTES && (attr & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
                throw new InvalidOperationException(string.Format("{0} contains a reparse point: {1}", description, StripExtendedPrefix(file)));
            }
            if (attr != INVALID_FILE_ATTRIBUTES && (attr & FILE_ATTRIBUTE_READONLY) != 0) {
                SetFileAttributesW(file, FILE_ATTRIBUTE_NORMAL);
            }
            if (!DeleteFileW(file)) {
                int err = Marshal.GetLastWin32Error();
                if (err != ERROR_FILE_NOT_FOUND && err != ERROR_PATH_NOT_FOUND) {
                    throw new IOException(string.Format("Could not delete file in {0} (Win32 {1}): {2}", description, err, StripExtendedPrefix(file)));
                }
            }
        }
        for (int i = directories.Count - 1; i >= 0; i--) {
            string dir = directories[i];
            uint attr = GetFileAttributesW(dir);
            if (attr != INVALID_FILE_ATTRIBUTES && (attr & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
                throw new InvalidOperationException(string.Format("{0} contains a reparse point: {1}", description, StripExtendedPrefix(dir)));
            }
            if (attr != INVALID_FILE_ATTRIBUTES && (attr & FILE_ATTRIBUTE_READONLY) != 0) {
                SetFileAttributesW(dir, FILE_ATTRIBUTE_DIRECTORY);
            }
            if (!RemoveDirectoryW(dir)) {
                int err = Marshal.GetLastWin32Error();
                if (err != ERROR_FILE_NOT_FOUND && err != ERROR_PATH_NOT_FOUND) {
                    throw new IOException(string.Format("Could not remove directory in {0} (Win32 {1}): {2}", description, err, StripExtendedPrefix(dir)));
                }
            }
        }
    }
}
'@
}

function Assert-RegularDirectoryTree([string]$FullPath, [string]$Description) {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        Initialize-NativeStorageMethods
        try {
            [OscarStorageNative]::AssertRegularDirectoryTree($FullPath, $Description)
        } catch {
            Fail $_.Exception.Message
        }
        return
    }
    $pending = New-Object 'Collections.Generic.Stack[string]'
    $pending.Push($FullPath)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($child in @(Get-ChildItem -LiteralPath $directory -Force)) {
            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Fail "$Description contains a reparse point: $($child.FullName)"
            }
            if ($child.PSIsContainer) { $pending.Push($child.FullName); continue }
            if ($child -isnot [IO.FileInfo]) { Fail "$Description contains a non-regular entry: $($child.FullName)" }
        }
    }
}

function Remove-DirectoryTreeLongPathSafe([string]$FullPath, [string]$Description, [switch]$IgnoreErrors) {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        Initialize-NativeStorageMethods
        try {
            [OscarStorageNative]::DeleteValidatedDirectoryTree($FullPath, $Description)
        } catch {
            if (-not $IgnoreErrors) {
                Fail $_.Exception.Message
            }
        }
        return
    }
    if ($IgnoreErrors) {
        Remove-Item -LiteralPath $FullPath -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Remove-Item -LiteralPath $FullPath -Recurse -Force
    }
}

function Sync-DurableMetadata([string]$Path) {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return }
    Initialize-NativeStorageMethods
    $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path)).TrimEnd('\')
    if ($root -notmatch '^[A-Za-z]:$') { Fail "Durable metadata flush requires a local Windows volume: $Path" }
    $volume = "\\.\$root"
    # Windows PowerShell 5.1 parses 0x80000000 as a negative Int32. Passing
    # that literal directly cannot bind to CreateFile's unsigned flags
    # parameter, so construct FILE_FLAG_WRITE_THROUGH from a positive Int64.
    $writeThroughFlag = [uint32]2147483648
    $handle = [OscarStorageNative]::CreateFile($volume, [uint32]0x40000000, [uint32]0x7, [IntPtr]::Zero, [uint32]3, $writeThroughFlag, [IntPtr]::Zero)
    if ($handle -eq [IntPtr](-1)) {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Fail "Could not open the storage volume for a durability barrier (Win32 $code): $volume"
    }
    try {
        if (-not [OscarStorageNative]::FlushFileBuffers($handle)) {
            $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            Fail "Could not flush storage metadata durably (Win32 $code): $Path"
        }
    } finally {
        [void][OscarStorageNative]::CloseHandle($handle)
    }
}

function Add-DurableLogLine([string]$Path, [string]$Line) {
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read, 4096, [IO.FileOptions]::WriteThrough)
    try {
        $bytes = $Utf8NoBom.GetBytes("$Line`n")
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally { $stream.Dispose() }
}

function Move-DurableNoReplace([string]$Source, [string]$Destination) {
    if (Test-Path -LiteralPath $Destination) { Fail "Refusing to replace an existing durable destination: $Destination" }
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        Initialize-NativeStorageMethods
        if (-not [OscarStorageNative]::MoveFileEx($Source, $Destination, 0x8)) {
            $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            Fail "Atomic durable no-replace move failed (Win32 $code): $Destination"
        }
    } else {
        if (Test-Path -LiteralPath $Source -PathType Container) {
            [IO.Directory]::Move($Source, $Destination)
        } else {
            [IO.File]::Move($Source, $Destination)
        }
    }
}

function Move-DurableReplace([string]$Source, [string]$Destination) {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        Initialize-NativeStorageMethods
        if (-not [OscarStorageNative]::MoveFileEx($Source, $Destination, 0x9)) {
            $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            Fail "Atomic durable replacement failed (Win32 $code): $Destination"
        }
    } else {
        [IO.File]::Move($Source, $Destination, $true)
    }
}

function Sync-DurableTree([string]$Root) {
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -File -Force -Recurse)) {
        $stream = [IO.FileStream]::new($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
        try { $stream.Flush($true) } finally { $stream.Dispose() }
    }
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Fail 'Run this command from an Administrator PowerShell window.'
    }
}

function Get-EnvValue([string]$Name, [string]$Fallback) {
    $source = Join-Path $ScriptRoot '.env'
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { $source = Join-Path $ScriptRoot '.env.example' }
    foreach ($line in [IO.File]::ReadAllLines($source)) {
        if ($line -match "^$([Regex]::Escape($Name))=(.*)$" -and $Matches[1]) { return $Matches[1] }
    }
    return $Fallback
}

function Get-ValidatedBackupMode {
    $source = Join-Path $ScriptRoot '.env'
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { Fail 'Run OSCAR init first.' }
    $matches = @([IO.File]::ReadAllLines($source) | Where-Object { $_.StartsWith('OSCAR_BACKUP_MODE=', [StringComparison]::Ordinal) })
    if ($matches.Count -ne 1) { Fail 'Deployment .env must contain exactly one literal OSCAR_BACKUP_MODE binding.' }
    $value = $matches[0].Substring('OSCAR_BACKUP_MODE='.Length)
    if ($value -cnotin @('disabled', 'single')) {
        Fail 'OSCAR_BACKUP_MODE must be the literal lowercase value disabled or single.'
    }
    return $value
}

function Assert-BackupModeEnabled {
    if ((Get-ValidatedBackupMode) -cne 'single') {
        Fail 'OSCAR backups are disabled. Re-run upgrade with -BackupMode single -BackupDir <safe-absolute-backup-path> before using backup, verification, pruning, or restore.'
    }
}

function Test-FullyQualifiedDeploymentPath([string]$Value) {
    if (-not $Value -or -not [IO.Path]::IsPathRooted($Value)) { return $false }
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        # Storage durability uses local-volume flush primitives. UNC roots cannot
        # provide the required acceptance/rename ordering and are rejected before
        # setup can create or apply ACLs to any directory.
        return $Value -cmatch '^[A-Za-z]:[\\/]'
    }
    return $Value.StartsWith('/', [StringComparison]::Ordinal)
}

function Assert-ManagedEnvironmentBindings {
    $source = Join-Path $ScriptRoot '.env'
    if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or
        ((Get-Item -LiteralPath $source -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail 'Deployment .env must be a regular, non-reparse-point file.'
    }
    $lines = [IO.File]::ReadAllLines($source)
    $mode = Get-ValidatedBackupMode
    $required = @('OSCAR_VERSION', 'OSCAR_DEPLOYMENT_ID', 'OSCAR_ARCHIVE_DIR', 'OSCAR_BACKUP_MODE', 'OSCAR_SECRETS_DIR', 'OSCAR_TLS_DIR')
    if ($mode -ceq 'single') { $required += @('OSCAR_BACKUP_DIR', 'OSCAR_BACKUP_KEY_FILE') }
    foreach ($name in $required) {
        $matches = @($lines | Where-Object { $_.StartsWith("$name=", [StringComparison]::Ordinal) })
        if ($matches.Count -ne 1) { Fail "Deployment .env must contain exactly one literal $name binding." }
        $value = $matches[0].Substring($name.Length + 1)
        $interpreted = $value.IndexOfAny([char[]]@('$', '#', '"', "'")) -ge 0
        if (-not $value -or $interpreted -or @($value.ToCharArray() | Where-Object { [char]::IsWhiteSpace($_) }).Count -ne 0) {
            Fail "Deployment .env contains a Compose-interpreted or nonliteral $name value."
        }
        if ($name -in @('OSCAR_ARCHIVE_DIR', 'OSCAR_BACKUP_DIR') -and
            -not (Test-FullyQualifiedDeploymentPath $value)) {
            Fail "$name must be an absolute stable storage-root path."
        }
    }
}

function Resolve-DeploymentPath([string]$Value) {
    if ([IO.Path]::IsPathRooted($Value)) { return [IO.Path]::GetFullPath($Value) }
    return [IO.Path]::GetFullPath((Join-Path $ScriptRoot $Value))
}

$ArchiveDirectory = Resolve-DeploymentPath (Get-EnvValue 'OSCAR_ARCHIVE_DIR' '..\oscar-storage\archive')
$BackupDirectory = Resolve-DeploymentPath (Get-EnvValue 'OSCAR_BACKUP_DIR' '..\oscar-storage\backups')
$WalArchiveDirectory = Resolve-DeploymentPath (Get-EnvValue 'OSCAR_WAL_ARCHIVE_DIR' '..\oscar-storage\wal-archive')
$BackupKeyFile = Resolve-DeploymentPath (Get-EnvValue 'OSCAR_BACKUP_KEY_FILE' '.\secrets\backup-key.txt')

function Test-PathContains([string]$Parent, [string]$Child) {
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd([char[]]@('\', '/'))
    $childFull = [IO.Path]::GetFullPath($Child).TrimEnd([char[]]@('\', '/'))
    return $childFull.Equals($parentFull, [StringComparison]::OrdinalIgnoreCase) -or
        $childFull.StartsWith($parentFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Resolve-PhysicalContainmentPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $cursor = $full
    $missing = New-Object 'System.Collections.Generic.List[string]'
    while (-not (Test-Path -LiteralPath $cursor)) {
        $leaf = Split-Path -Leaf $cursor
        $parent = Split-Path -Parent $cursor
        if (-not $leaf -or -not $parent -or $parent -ceq $cursor) {
            Fail "Cannot resolve an existing ancestor for privileged storage path: $Path"
        }
        $missing.Insert(0, $leaf)
        $cursor = $parent
    }
    Assert-NoReparseComponents $cursor
    $item = Get-Item -LiteralPath $cursor -Force
    if ($missing.Count -gt 0 -and -not $item.PSIsContainer) {
        Fail "Privileged storage path ancestor is not a directory: $cursor"
    }
    $resolved = Resolve-ExistingPhysicalPath $item.FullName
    foreach ($part in $missing) { $resolved = Join-Path $resolved $part }
    return [IO.Path]::GetFullPath($resolved)
}

function Assert-StorageRootShapes([switch]$IncludeBackup) {
    $releasePath = Resolve-PhysicalContainmentPath $ScriptRoot
    $roots = ,@('OSCAR_ARCHIVE_DIR', (Resolve-PhysicalContainmentPath $ArchiveDirectory))
    if ($IncludeBackup) { $roots += ,@('OSCAR_BACKUP_DIR', (Resolve-PhysicalContainmentPath $BackupDirectory)) }
    foreach ($entry in $roots) {
        $label = $entry[0]
        $path = [IO.Path]::GetFullPath($entry[1])
        $volumeRoot = [IO.Path]::GetPathRoot($path)
        $relative = $path.Substring($volumeRoot.Length).Trim('\', '/')
        $components = @($relative -split '[\\/]' | Where-Object { $_ })
        if ($components.Count -lt 2) {
            Fail "$label is too broad; configure a dedicated directory at least two components below its volume root: $path"
        }
        if (Test-PathContains $path $releasePath) {
            Fail "$label must not equal or contain the OSCAR release directory: $path"
        }
        if (Test-PathContains $releasePath $path) {
            Fail "$label must not be located inside the versioned OSCAR release directory: $path"
        }
        $profile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
        if ($profile) { $profile = Resolve-PhysicalContainmentPath $profile }
        if ($profile -and (Test-PathContains $path $profile)) {
            Fail "$label must not equal or contain the administrator profile directory: $path"
        }
    }
    for ($left = 0; $left -lt $roots.Count; $left++) {
        for ($right = $left + 1; $right -lt $roots.Count; $right++) {
            if ((Test-PathContains $roots[$left][1] $roots[$right][1]) -or
                (Test-PathContains $roots[$right][1] $roots[$left][1])) {
                Fail 'Archive and backup directories must be distinct and must not contain one another.'
            }
        }
    }
}

function Assert-StorageRootsReady([switch]$IncludeBackup) {
    Assert-StorageRootShapes -IncludeBackup:$IncludeBackup
    $paths = @($ArchiveDirectory)
    if ($IncludeBackup) { $paths += $BackupDirectory }
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            Fail 'Configured storage directories are missing; run OSCAR init/upgrade preparation first.'
        }
        Assert-NoReparseComponents $path
    }
}

function Protect-AdministratorFile([string]$Path) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $acl = New-Object Security.AccessControl.FileSecurity
    $acl.SetOwner($administrators)
    $acl.SetAccessRuleProtection($true, $false)
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $full = [Security.AccessControl.FileSystemRights]::FullControl
    foreach ($principal in @(
        $identity.User,
        ([Security.Principal.SecurityIdentifier]::new('S-1-5-18')),
        $administrators)) {
        [void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($principal, $full, $allow))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Test-ExactUtf8NoBomFile([string]$Path, [string]$ExpectedContent) {
    $expectedBytes = $Utf8NoBom.GetBytes($ExpectedContent)
    $stream = [IO.File]::Open(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read)
    try {
        if ($stream.Length -ne $expectedBytes.Length) { return $false }
        for ($index = 0; $index -lt $expectedBytes.Length; $index++) {
            if ($stream.ReadByte() -ne $expectedBytes[$index]) { return $false }
        }
        return $stream.ReadByte() -eq -1
    } finally {
        $stream.Dispose()
    }
}

function Get-DockerUsersSid {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return $null }
    foreach ($name in @("$env:COMPUTERNAME\docker-users", 'docker-users')) {
        try {
            return ([Security.Principal.NTAccount]::new($name)).Translate([Security.Principal.SecurityIdentifier])
        } catch {}
    }
    Fail 'The local docker-users group is required to protect and share OSCAR storage with Docker Desktop.'
}

function Assert-ProtectedAdministratorAcl(
    [string]$Path,
    [string]$Description,
    [string[]]$AllowedAdditionalWriteSids = @()
) {
    $acl = Get-Acl -LiteralPath $Path
    $ownerSid = ([Security.Principal.NTAccount]$acl.Owner).Translate([Security.Principal.SecurityIdentifier]).Value
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $administratorSids = @($currentSid, 'S-1-5-18', 'S-1-5-32-544')
    $allowedSids = @($administratorSids + $AllowedAdditionalWriteSids)
    if (-not $acl.AreAccessRulesProtected -or $ownerSid -notin $administratorSids) {
        Fail "$Description is not protected and owned by an administrator: $Path"
    }
    # Use only atomic mutating rights here. Composite values such as
    # FullControl/Modify also contain read bits and would misclassify a
    # docker-users ReadAndExecute grant as writable.
    $writeMask = [Security.AccessControl.FileSystemRights]::WriteData -bor
        [Security.AccessControl.FileSystemRights]::AppendData -bor
        [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership
    foreach ($rule in $acl.Access) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
        $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        if ($sid -notin $allowedSids -and ($rule.FileSystemRights -band $writeMask) -ne 0) {
            Fail "$Description grants write or ownership rights outside the administrator set: $Path"
        }
    }
}

function Assert-AdministratorFile([string]$Path, [string]$Description) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Fail "$Description is missing: $Path" }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Fail "$Description is a reparse point: $Path" }
    Assert-ProtectedAdministratorAcl $Path $Description
}

function Assert-AdministratorDirectory([string]$Path, [string]$Description) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Fail "$Description is missing: $Path" }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Fail "$Description is a reparse point: $Path" }
    Assert-ProtectedAdministratorAcl $Path $Description
}

function Assert-DockerStorageDirectory(
    [string]$Path,
    [string]$Description,
    [ValidateSet('ReadOnly', 'ReadWrite')][string]$DockerAccess
) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Fail "$Description is missing: $Path" }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Fail "$Description is a reparse point: $Path" }
    $dockerSid = Get-DockerUsersSid
    $additionalWriters = if ($DockerAccess -ceq 'ReadWrite') { @($dockerSid.Value) } else { @() }
    Assert-ProtectedAdministratorAcl $Path $Description $additionalWriters
    $rules = @((Get-Acl -LiteralPath $Path).Access | Where-Object {
        $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
        $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -ceq $dockerSid.Value
    })
    $required = if ($DockerAccess -ceq 'ReadWrite') {
        [Security.AccessControl.FileSystemRights]::Modify
    } else {
        [Security.AccessControl.FileSystemRights]::ReadAndExecute
    }
    if (-not ($rules | Where-Object { ($_.FileSystemRights -band $required) -eq $required })) {
        Fail "$Description does not grant the required Docker Desktop $DockerAccess access: $Path"
    }
}

function Read-StorageIdentity([string]$Marker) {
    $result = @{}
    foreach ($line in [IO.File]::ReadAllLines($Marker)) {
        $separator = $line.IndexOf('=')
        if ($separator -lt 1) { Fail "Storage root identity marker is malformed: $Marker" }
        $name = $line.Substring(0, $separator)
        if ($result.ContainsKey($name)) { Fail "Storage root identity marker contains duplicate fields: $Marker" }
        $result[$name] = $line.Substring($separator + 1)
    }
    return $result
}

function Assert-StorageRootIdentity(
    [string]$Path,
    [ValidateSet('archive', 'backup', 'wal-archive')][string]$Kind,
    [switch]$AllowDirectoryAclRepair
) {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and -not $AllowDirectoryAclRepair) {
        $dockerAccess = if ($Kind -ceq 'backup') { 'ReadOnly' } else { 'ReadWrite' }
        Assert-DockerStorageDirectory $Path "$Kind storage root" $dockerAccess
    }
    $marker = Join-Path $Path '.oscar-storage-root'
    Assert-AdministratorFile $marker 'Storage root identity marker'
    $lines = @([IO.File]::ReadAllLines($marker))
    $identity = Read-StorageIdentity $marker
    $deploymentId = Get-EnvValue 'OSCAR_DEPLOYMENT_ID' ''
    $expectedKeys = @('format','version','deployment_id','root_kind','adoption','claimed_at','adopted_at','adopted_by')
    if ($lines.Count -ne $expectedKeys.Count -or $identity.Count -ne $expectedKeys.Count -or
        @($expectedKeys | Where-Object { -not $identity.ContainsKey($_) }).Count -ne 0 -or
        $identity.format -cne 'oscar-storage-root-identity' -or $identity.version -cne '1' -or
        -not (Test-ValidDeploymentId $identity.deployment_id) -or $identity.deployment_id -cne $deploymentId -or
        $identity.root_kind -cne $Kind -or $identity.adoption -notin @('new','explicit-existing') -or
        $identity.claimed_at -notmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' -or
        $identity.adopted_at -notmatch '^(none|[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)$' -or
        $identity.adopted_by -notmatch '^(none|[A-Za-z0-9_.@-]{1,128})$') {
        Fail "Storage root identity is malformed, foreign, or has the wrong root kind: $Path"
    }
    if (($identity.adoption -ceq 'new' -and ($identity.adopted_at -cne 'none' -or $identity.adopted_by -cne 'none')) -or
        ($identity.adoption -ceq 'explicit-existing' -and ($identity.adopted_at -ceq 'none' -or $identity.adopted_by -ceq 'none'))) {
        Fail "Storage root identity has inconsistent adoption metadata: $marker"
    }
}

function Assert-StorageRootIdentities([switch]$IncludeBackup) {
    Assert-StorageRootIdentity $ArchiveDirectory 'archive'
    if ($IncludeBackup) { Assert-StorageRootIdentity $BackupDirectory 'backup' }
}

function Write-StorageRootIdentity([string]$Path, [string]$Kind, [string]$Adoption) {
    $deploymentId = Get-EnvValue 'OSCAR_DEPLOYMENT_ID' ''
    if (-not (Test-ValidDeploymentId $deploymentId)) { Fail 'OSCAR_DEPLOYMENT_ID is missing or invalid; storage roots cannot be claimed.' }
    $marker = Join-Path $Path '.oscar-storage-root'
    if (Test-Path -LiteralPath $marker) { Fail "Refusing to replace an existing storage root identity: $marker" }
    $temporary = Join-Path $Path ('.oscar-storage-root.tmp.' + [Guid]::NewGuid().ToString('N'))
    $now = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $actor = 'none'
    $adoptedAt = 'none'
    if ($Adoption -ceq 'explicit-existing') {
        $actor = [Environment]::UserName
        if ($actor -notmatch '^[A-Za-z0-9_.@-]{1,128}$') { $actor = 'administrator' }
        $adoptedAt = $now
    }
    $content = @(
        'format=oscar-storage-root-identity', 'version=1', "deployment_id=$deploymentId", "root_kind=$Kind",
        "adoption=$Adoption", "claimed_at=$now", "adopted_at=$adoptedAt", "adopted_by=$actor"
    ) -join "`n"
    try {
        $bytes = $Utf8NoBom.GetBytes("$content`n")
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        Protect-AdministratorFile $temporary
        Move-DurableNoReplace $temporary $marker
        Sync-DurableMetadata $Path
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
    Assert-StorageRootIdentity $Path $Kind
}

function Assert-OfflineBackupDirectory {
    Assert-StorageRootShapes -IncludeBackup
    if (-not (Test-Path -LiteralPath $BackupDirectory -PathType Container)) { Fail "Configured backup directory is missing: $BackupDirectory" }
    Assert-NoReparseComponents $BackupDirectory
}

function Assert-Configured {
    if (-not (Test-Path -LiteralPath (Join-Path $ScriptRoot '.env') -PathType Leaf)) { Fail 'Run OSCAR init first.' }
    Assert-ManagedEnvironmentBindings
}

function Assert-BackupKey {
    if (-not (Test-Path -LiteralPath $BackupKeyFile -PathType Leaf) -or (Get-Item -LiteralPath $BackupKeyFile).Length -eq 0) {
        Fail "Backup key is missing: $BackupKeyFile"
    }
}

function Enter-StorageAdminLock {
    if ($Command -eq 'help') { return }
    $deploymentId = Get-EnvValue 'OSCAR_DEPLOYMENT_ID' ''
    if (-not (Test-ValidDeploymentId $deploymentId)) { Fail 'OSCAR_DEPLOYMENT_ID is missing or invalid; a deployment-scoped storage lock cannot be acquired.' }
    $lockDirectory = if ($StorageScriptTestMode -and $env:OSCAR_STORAGE_LOCK_DIR) {
        [IO.Path]::GetFullPath($env:OSCAR_STORAGE_LOCK_DIR)
    } else {
        Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'OSCAR\StorageLocks'
    }
    Assert-SafeCreatableDirectoryPath $lockDirectory
    New-Item -ItemType Directory -Force -Path $lockDirectory | Out-Null
    Assert-NoReparseComponents $lockDirectory
    Protect-PrivateDirectory $lockDirectory
    $lockPath = Join-Path $lockDirectory "$deploymentId.lock"
    if (Test-Path -LiteralPath $lockPath) {
        $item = Get-Item -LiteralPath $lockPath -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Fail "Storage administration lock is not a regular, non-reparse-point file: $lockPath"
        }
        Assert-AdministratorFile $lockPath 'Storage administration lock'
    } else {
        [IO.File]::WriteAllBytes($lockPath, [byte[]]@())
        Protect-AdministratorFile $lockPath
    }
    try {
        $script:StorageAdminLock = [IO.File]::Open(
            $lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $owner = [Text.Encoding]::UTF8.GetBytes("pid=$PID acquired=$([DateTime]::UtcNow.ToString('o'))`n")
        $script:StorageAdminLock.SetLength(0)
        $script:StorageAdminLock.Write($owner, 0, $owner.Length)
        $script:StorageAdminLock.Flush($true)
    } catch {
        if ($script:StorageAdminLock) { $script:StorageAdminLock.Dispose(); $script:StorageAdminLock = $null }
        Fail "Another OSCAR storage administration command is already running, or the lock cannot be opened: $lockPath"
    }
}

function Exit-StorageAdminLock {
    if ($script:StorageAdminLock) {
        $script:StorageAdminLock.Dispose()
        $script:StorageAdminLock = $null
    }
}

function Invoke-External([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { Fail "$Program exited with code $LASTEXITCODE." }
}

function Get-ExternalOutput([string]$Program, [string[]]$Arguments) {
    $output = & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { Fail "$Program exited with code $LASTEXITCODE." }
    return @($output)
}

function ConvertTo-ShellStdin([string]$InputText) {
    if ([string]::IsNullOrWhiteSpace($InputText) -or $Utf8NoBom.GetByteCount($InputText) -gt 1048576 -or $InputText.IndexOf([char]0) -ge 0) {
        Fail 'Shell input must be nonempty, NUL-free, and at most 1048576 UTF-8 bytes.'
    }
    # PowerShell 5.1 appends CRLF when piping one scalar to a native process.
    # Put that CR on a final comment after normalizing every executable line.
    $normalized = $InputText.Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd([char[]]@([char]10))
    return "$normalized`n# oscar-powershell-stdin-terminator"
}

function Get-ExternalInputOutput([string]$InputText, [string]$Program, [string[]]$Arguments) {
    $previousErrorPreference = $ErrorActionPreference
    $previousOutputEncoding = $OutputEncoding
    try {
        $ErrorActionPreference = 'Continue'
        $OutputEncoding = $Utf8NoBom
        $output = @($InputText | & $Program @Arguments)
        if ($LASTEXITCODE -ne 0) { Fail "$Program exited with code $LASTEXITCODE." }
        return $output
    } finally {
        $OutputEncoding = $previousOutputEncoding
        $ErrorActionPreference = $previousErrorPreference
    }
}

function Get-DockerShellInputOutput([string]$InputText, [string[]]$Arguments) {
    if ($Arguments.Count -lt 2 -or $Arguments[0] -cne 'run' -or $Arguments -contains '--interactive' -or $Arguments -contains '-i') {
        Fail 'Docker shell-stdin execution requires one noninteractive run argument vector; the helper owns --interactive.'
    }
    $pinned = @('run', '--interactive') + @($Arguments[1..($Arguments.Count - 1)])
    return @(Get-ExternalInputOutput (ConvertTo-ShellStdin $InputText) 'docker' $pinned)
}

function Invoke-DockerShellInput([string]$InputText, [string[]]$Arguments) {
    [void](Get-DockerShellInputOutput $InputText $Arguments)
}

function Get-DockerInspectProperty([object]$Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertFrom-DockerInspectJson([string[]]$Lines, [ValidateSet('image', 'volume')][string]$Kind, [string]$Name) {
    $rawJson = $Lines -join "`n"
    $byteCount = $Utf8NoBom.GetByteCount($rawJson)
    if ($byteCount -gt $MaxDockerInspectJsonBytes) { Fail "Docker returned oversized $Kind inspection data for: $Name" }
    $json = $rawJson.Trim()
    if (-not $json) { Fail "Docker returned no $Kind inspection data for: $Name" }
    try { $parsed = $json | ConvertFrom-Json }
    catch { Fail "Docker returned invalid JSON while inspecting ${Kind}: $Name" }
    # Windows PowerShell 5.1 emits a top-level JSON array as one Object[]
    # pipeline object. Assign first, then enumerate exactly once so PS5 and
    # modern PowerShell enforce the same single-record contract.
    $records = @($parsed)
    if ($records.Count -ne 1) { Fail "Docker did not return exactly one $Kind inspection record for: $Name" }
    $record = $records[0]
    if ($Kind -ceq 'volume') {
        $actualName = [string](Get-DockerInspectProperty $record 'Name')
        if ($actualName -cne $Name) { Fail "Docker volume inspection identity mismatch for: $Name" }
    } else {
        $imageId = [string](Get-DockerInspectProperty $record 'Id')
        if ($imageId -cnotmatch '^sha256:[0-9a-f]{64}$') { Fail "Docker image inspection returned an invalid immutable ID for: $Name" }
    }
    return $record
}

function Get-DockerInspectObject([ValidateSet('image', 'volume')][string]$Kind, [string]$Name) {
    if (-not $Name -or $Name.Length -gt 512 -or $Name -match '[\x00-\x20]') { Fail "Invalid Docker $Kind inspection name." }
    $output = @(Get-ExternalOutput 'docker' @($Kind, 'inspect', $Name))
    return ConvertFrom-DockerInspectJson $output $Kind $Name
}

function Get-DockerInspectLabel([object]$Record, [bool]$Image, [string]$Key) {
    $labelOwner = $Record
    if ($Image) {
        $labelOwner = Get-DockerInspectProperty $Record 'Config'
        if ($null -eq $labelOwner) { Fail 'Docker image inspection omitted Config metadata.' }
    }
    $labels = Get-DockerInspectProperty $labelOwner 'Labels'
    if ($null -eq $labels) { return '' }
    $value = Get-DockerInspectProperty $labels $Key
    if ($null -eq $value) { return '' }
    $text = [string]$value
    if ($text.Length -gt 4096 -or $text -match '[\x00-\x1f]') { Fail "Docker inspection returned an invalid label value: $Key" }
    return $text
}

function Get-DockerVolumeCreatedAt([string]$Volume) {
    $record = Get-DockerInspectObject 'volume' $Volume
    $createdValue = Get-DockerInspectProperty $record 'CreatedAt'
    $createdAt = if ($createdValue -is [DateTime]) {
        $createdValue.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture).Replace('+00:00', 'Z')
    } else { [string]$createdValue }
    if (-not $createdAt -or $createdAt.Length -gt 128 -or $createdAt -notmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T') {
        Fail "Docker volume inspection returned an invalid creation identity for: $Volume"
    }
    return $createdAt
}

function Clear-ComposeOverrideEnvironment {
    $saved = @{}
    foreach ($name in @(
        'COMPOSE_FILE', 'COMPOSE_PROJECT_NAME', 'COMPOSE_ENV_FILES', 'COMPOSE_PROFILES',
        'OSCAR_VERSION', 'OSCAR_DEPLOYMENT_ID', 'OSCAR_ARCHIVE_DIR', 'OSCAR_BACKUP_MODE', 'OSCAR_BACKUP_DIR',
        'OSCAR_WAL_ARCHIVE_DIR', 'OSCAR_SECRETS_DIR', 'OSCAR_TLS_DIR', 'OSCAR_BACKUP_KEY_FILE',
        'OSCAR_HTTPS_PORT', 'OSCAR_TIMEZONE', 'OSCAR_JAVA_OPTS', 'OSCAR_POSTGIS_PLATFORM')) {
        if (Test-Path -LiteralPath "Env:$name") {
            $saved[$name] = (Get-Item -LiteralPath "Env:$name").Value
            Remove-Item -LiteralPath "Env:$name"
        }
    }
    return $saved
}

function Restore-ComposeOverrideEnvironment([hashtable]$Saved) {
    foreach ($name in $Saved.Keys) { Set-Item -LiteralPath "Env:$name" -Value $Saved[$name] }
}

function Invoke-Compose([string[]]$Arguments) {
    Push-Location $ScriptRoot
    $saved = Clear-ComposeOverrideEnvironment
    try {
        Invoke-External 'docker' (@(
            'compose', '--project-name', 'oscar', '--env-file', (Join-Path $ScriptRoot '.env'),
            '--file', (Join-Path $ScriptRoot 'compose.yaml')) + $Arguments)
    } finally {
        Restore-ComposeOverrideEnvironment $saved
        Pop-Location
    }
}

function Stop-DeploymentOrdered {
    # Keep PostgreSQL available until OSCAR finishes its bounded writer and
    # module shutdown. Compose otherwise signals all named services together.
    Invoke-Compose @('stop', 'gateway')
    Invoke-Compose @('stop', 'oscar')
    Invoke-Compose @('stop', 'postgres')
}

function Get-ComposeOutput([string[]]$Arguments) {
    Push-Location $ScriptRoot
    $saved = Clear-ComposeOverrideEnvironment
    try {
        $pinned = @(
            'compose', '--project-name', 'oscar', '--env-file', (Join-Path $ScriptRoot '.env'),
            '--file', (Join-Path $ScriptRoot 'compose.yaml')) + $Arguments
        $output = & docker @pinned
        if ($LASTEXITCODE -ne 0) { Fail "docker compose exited with code $LASTEXITCODE." }
        return @($output)
    } finally {
        Restore-ComposeOverrideEnvironment $saved
        Pop-Location
    }
}

function Get-ComposeInputOutput([string]$InputText, [string[]]$Arguments) {
    Push-Location $ScriptRoot
    $saved = Clear-ComposeOverrideEnvironment
    $previousErrorPreference = $ErrorActionPreference
    $previousOutputEncoding = $OutputEncoding
    try {
        $ErrorActionPreference = 'Continue'
        $OutputEncoding = $Utf8NoBom
        $pinned = @(
            'compose', '--project-name', 'oscar', '--env-file', (Join-Path $ScriptRoot '.env'),
            '--file', (Join-Path $ScriptRoot 'compose.yaml')) + $Arguments
        $output = @($InputText | & docker @pinned)
        if ($LASTEXITCODE -ne 0) { Fail "docker compose exited with code $LASTEXITCODE." }
        return $output
    } finally {
        $OutputEncoding = $previousOutputEncoding
        $ErrorActionPreference = $previousErrorPreference
        Restore-ComposeOverrideEnvironment $saved
        Pop-Location
    }
}

function Get-ComposeShellInputOutput([string]$InputText, [string[]]$Arguments) {
    return @(Get-ComposeInputOutput (ConvertTo-ShellStdin $InputText) $Arguments)
}

function Write-ComposeShellInputOutputToFile([string]$InputText, [string[]]$Arguments, [string]$Path) {
    Push-Location $ScriptRoot
    $saved = Clear-ComposeOverrideEnvironment
    $previousErrorPreference = $ErrorActionPreference
    $previousOutputEncoding = $OutputEncoding
    $writer = $null
    try {
        $ErrorActionPreference = 'Continue'
        $OutputEncoding = $Utf8NoBom
        $pinned = @(
            'compose', '--project-name', 'oscar', '--env-file', (Join-Path $ScriptRoot '.env'),
            '--file', (Join-Path $ScriptRoot 'compose.yaml')) + $Arguments
        $writer = [IO.StreamWriter]::new($Path, $false, $Utf8NoBom)
        $writer.NewLine = "`n"
        (ConvertTo-ShellStdin $InputText) | & docker @pinned | ForEach-Object { $writer.WriteLine(([string]$_).TrimEnd("`r")) }
        $exitCode = $LASTEXITCODE
        $writer.Flush()
        if ($exitCode -ne 0) { Fail "docker compose shell stream exited with code $exitCode." }
    } finally {
        if ($writer) { $writer.Dispose() }
        $OutputEncoding = $previousOutputEncoding
        $ErrorActionPreference = $previousErrorPreference
        Restore-ComposeOverrideEnvironment $saved
        Pop-Location
    }
}

function Resolve-ReleaseImages {
    $images = @(Get-ComposeOutput @('config', '--images') | Where-Object { $_ } | Sort-Object -Unique)
    $application = @($images | Where-Object { $_ -match '(^|/)oscar:' })
    $postgres = @($images | Where-Object { $_ -match '(^|/)oscar-postgis:' })
    $gateway = @($images | Where-Object { $_ -match 'nginx-unprivileged:' })
    if ($application.Count -ne 1 -or $postgres.Count -ne 1 -or $gateway.Count -ne 1) {
        Fail 'Could not resolve exactly one application, PostGIS, and gateway image from Compose.'
    }
    return [pscustomobject]@{ application = $application[0]; postgres = $postgres[0]; gateway = $gateway[0] }
}

function Get-ImageInspectValue(
    [string]$Image,
    [ValidateSet('Id', 'RepoDigests', 'org.opencontainers.image.version', 'com.botts.oscar.storage-profile')][string]$Field) {
    $record = Get-DockerInspectObject 'image' $Image
    switch ($Field) {
        'Id' { return [string](Get-DockerInspectProperty $record 'Id') }
        'RepoDigests' {
            $digests = Get-DockerInspectProperty $record 'RepoDigests'
            if ($null -eq $digests) { return 'null' }
            $items = @($digests)
            foreach ($digest in $items) {
                if ([string]$digest -notmatch '^[A-Za-z0-9][A-Za-z0-9._/@:+-]*$') {
                    Fail "Docker image inspection returned an invalid repository digest for: $Image"
                }
            }
            return ConvertTo-Json -InputObject $items -Compress
        }
        default { return Get-DockerInspectLabel $record $true $Field }
    }
}

function Write-ImageInventory([string]$Root) {
    $images = Resolve-ReleaseImages
    $appId = Get-ImageInspectValue $images.application 'Id'
    $postgresId = Get-ImageInspectValue $images.postgres 'Id'
    $gatewayId = Get-ImageInspectValue $images.gateway 'Id'
    $appDigests = Get-ImageInspectValue $images.application 'RepoDigests'
    $postgresDigests = Get-ImageInspectValue $images.postgres 'RepoDigests'
    $gatewayDigests = Get-ImageInspectValue $images.gateway 'RepoDigests'
    $appVersion = Get-ImageInspectValue $images.application 'org.opencontainers.image.version'
    $postgresVersion = Get-ImageInspectValue $images.postgres 'org.opencontainers.image.version'
    $postgresProfile = Get-ImageInspectValue $images.postgres 'com.botts.oscar.storage-profile'
    if ($appVersion -cne $RequiredReleaseVersion -or $postgresVersion -cne $RequiredReleaseVersion -or $postgresProfile -cne $RequiredReleaseVersion) {
        Fail 'Release images do not carry the required OSCAR version/storage-profile labels.'
    }
    $lines = @(
        'format=oscar-image-inventory', 'version=1',
        "application_name=$($images.application)", "application_id=$appId", "application_repo_digests=$appDigests", "application_version_label=$appVersion",
        "postgres_name=$($images.postgres)", "postgres_id=$postgresId", "postgres_repo_digests=$postgresDigests", "postgres_version_label=$postgresVersion", "postgres_storage_profile_label=$postgresProfile",
        "gateway_name=$($images.gateway)", "gateway_id=$gatewayId", "gateway_repo_digests=$gatewayDigests",
        "created_at=$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
    )
    [IO.File]::WriteAllLines((Join-Path $Root 'image-inventory.txt'), $lines, $Utf8NoBom)
}

function Read-ImageInventory([string]$Root) {
    $path = Join-Path $Root 'image-inventory.txt'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail 'Authenticated image inventory is missing or is a reparse point.'
    }
    $lines = @([IO.File]::ReadAllLines($path))
    if ($lines.Count -ne 15) { Fail 'Authenticated image inventory is malformed.' }
    $inventory = @{}
    foreach ($line in $lines) {
        $separator = $line.IndexOf('=')
        if ($separator -lt 1) { Fail 'Image inventory contains an invalid field.' }
        $key = $line.Substring(0, $separator); $value = $line.Substring($separator + 1)
        if ($inventory.ContainsKey($key)) { Fail "Image inventory contains duplicate field: $key" }
        $inventory[$key] = $value
    }
    $keys = @('format','version','application_name','application_id','application_repo_digests','application_version_label','postgres_name','postgres_id','postgres_repo_digests','postgres_version_label','postgres_storage_profile_label','gateway_name','gateway_id','gateway_repo_digests','created_at')
    foreach ($key in $keys) { if (-not $inventory.ContainsKey($key)) { Fail "Image inventory is missing field: $key" } }
    if ($inventory.format -cne 'oscar-image-inventory' -or $inventory.version -cne '1') { Fail 'Image inventory format/version is unsupported.' }
    foreach ($key in @('application_name','postgres_name','gateway_name')) { if ($inventory[$key] -notmatch '^[A-Za-z0-9][A-Za-z0-9._/@:-]*$') { Fail "Image inventory has an invalid $key." } }
    foreach ($key in @('application_id','postgres_id','gateway_id')) { if ($inventory[$key] -notmatch '^sha256:[0-9a-f]{64}$') { Fail "Image inventory has an invalid $key." } }
    foreach ($key in @('application_repo_digests','postgres_repo_digests','gateway_repo_digests')) { if ($inventory[$key] -notmatch '^(?:null|\[(?:"[A-Za-z0-9._/@:+-]+"(?:,"[A-Za-z0-9._/@:+-]+")*)?\])$') { Fail "Image inventory has an invalid $key." } }
    if ($inventory.application_version_label -cne $RequiredReleaseVersion -or $inventory.postgres_version_label -cne $RequiredReleaseVersion -or $inventory.postgres_storage_profile_label -cne $RequiredReleaseVersion) { Fail 'Image inventory release labels do not match this OSCAR release.' }
    if ($inventory.created_at -notmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$') { Fail 'Image inventory creation time is invalid.' }
    return $inventory
}

function Confirm-ImageInventory([string]$Root, [switch]$CompareCurrent) {
    $inventory = Read-ImageInventory $Root
    if (-not $CompareCurrent) { return }
    $images = Resolve-ReleaseImages
    foreach ($role in @('application','postgres','gateway')) {
        $name = [string]$images.$role
        if ($inventory["${role}_name"] -cne $name) { Fail "Restore image name mismatch for $role." }
        if ($inventory["${role}_id"] -cne (Get-ImageInspectValue $name 'Id')) { Fail "Restore image ID mismatch for $role." }
        # Registry RepoDigests are provenance metadata and docker save/load may
        # drop them. Exact content-addressed ID, name, and labels remain hard gates.
        $currentRepoDigests = Get-ImageInspectValue $name 'RepoDigests'
        if ($inventory["${role}_repo_digests"] -cne $currentRepoDigests) {
            Write-Warning "$role image repository-digest provenance differs after transport; exact image ID and required labels still match."
        }
    }
    if ($inventory.application_version_label -cne (Get-ImageInspectValue $images.application 'org.opencontainers.image.version')) { Fail 'Restore application OCI version label mismatch.' }
    if ($inventory.postgres_version_label -cne (Get-ImageInspectValue $images.postgres 'org.opencontainers.image.version') -or
        $inventory.postgres_storage_profile_label -cne (Get-ImageInspectValue $images.postgres 'com.botts.oscar.storage-profile')) { Fail 'Restore PostGIS OCI label mismatch.' }
}

function Test-DockerVolume([string]$Volume) {
    $previousErrorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        & docker volume inspect $Volume *> $null
        return $LASTEXITCODE -eq 0
    } finally { $ErrorActionPreference = $previousErrorPreference }
}

function Get-VolumeDeploymentLabel([string]$Volume) {
    $record = Get-DockerInspectObject 'volume' $Volume
    return Get-DockerInspectLabel $record $false 'com.botts.oscar.deployment-id'
}

function Test-ValidDeploymentId([string]$Value) {
    return $Value -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

function Get-AdoptionReceiptValue([string]$Name) {
    $receipt = Join-Path $ScriptRoot '.oscar-volume-adoption'
    if (-not (Test-Path -LiteralPath $receipt -PathType Leaf)) { return $null }
    $matches = @([IO.File]::ReadAllLines($receipt) | Where-Object { $_ -match "^$([Regex]::Escape($Name))=" })
    if ($matches.Count -ne 1) { return $null }
    return $matches[0].Substring($matches[0].IndexOf('=') + 1)
}

function Test-VolumeAdoptionReceipt([string]$DeploymentId) {
    $receipt = Join-Path $ScriptRoot '.oscar-volume-adoption'
    if (-not (Test-Path -LiteralPath $receipt -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $receipt
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    $lines = @([IO.File]::ReadAllLines($receipt))
    if ($lines.Count -ne 6 -or @($lines | Where-Object { $_ -ceq 'format=oscar-volume-adoption' }).Count -ne 1 -or
        @($lines | Where-Object { $_ -ceq 'version=1' }).Count -ne 1 -or
        @($lines | Where-Object { $_ -match '^adopted_at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' }).Count -ne 1 -or
        (Get-AdoptionReceiptValue 'deployment_id') -cne $DeploymentId) { return $false }
    $stateCreated = Get-DockerVolumeCreatedAt 'oscar_oscar_state'
    $postgresCreated = Get-DockerVolumeCreatedAt 'oscar_postgres_data'
    return $stateCreated -and $postgresCreated -and
        (Get-AdoptionReceiptValue 'oscar_state_created_at') -ceq $stateCreated -and
        (Get-AdoptionReceiptValue 'postgres_data_created_at') -ceq $postgresCreated
}

function Assert-DeploymentVolumeOwnership {
    $deploymentId = Get-EnvValue 'OSCAR_DEPLOYMENT_ID' ''
    if (-not (Test-ValidDeploymentId $deploymentId)) { Fail 'OSCAR_DEPLOYMENT_ID is missing or invalid; run the release upgrade ownership preflight before storage administration.' }
    foreach ($volume in @('oscar_oscar_state', 'oscar_postgres_data')) {
        if (-not (Test-DockerVolume $volume)) { Fail "Required Docker volume is missing: $volume." }
    }
    $stateLabel = Get-VolumeDeploymentLabel 'oscar_oscar_state'
    $postgresLabel = Get-VolumeDeploymentLabel 'oscar_postgres_data'
    if ($stateLabel -ceq $deploymentId -and $postgresLabel -ceq $deploymentId) { return }
    if ($stateLabel -ceq $postgresLabel -and (-not $stateLabel -or $stateLabel -ceq 'uninitialized') -and
        (Test-VolumeAdoptionReceipt $deploymentId)) { return }
    Fail 'OSCAR named volumes do not match this deployment identity. No storage operation was performed.'
}

function New-PsqlShellInput([string]$Sql, [switch]$Table) {
    if ([string]::IsNullOrWhiteSpace($Sql) -or $Utf8NoBom.GetByteCount($Sql) -gt 1048576 -or $Sql.IndexOf([char]0) -ge 0) {
        Fail 'PostgreSQL input must be nonempty, NUL-free, and at most 1048576 UTF-8 bytes.'
    }
    $normalizedSql = $Sql.Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd([char[]]@([char]10))
    do { $delimiter = 'OSCAR_SQL_' + [Guid]::NewGuid().ToString('N') }
    while ($normalizedSql -match "(?m)^$([Regex]::Escape($delimiter))$")
    $psqlFlags = if ($Table) { '' } else { ' --quiet --tuples-only --no-align' }
    $command = 'PGPASSWORD=$(cat /run/secrets/postgres_bootstrap_password); PGOPTIONS=-csearch_path=oscar,public; export PGPASSWORD PGOPTIONS; exec psql --set=ON_ERROR_STOP=1 --username oscar_bootstrap --dbname gis' + $psqlFlags + ' --file=-'
    return "$command <<'$delimiter'`n$normalizedSql`n$delimiter"
}

function Invoke-Psql([string]$Sql, [switch]$Table) {
    $shellInput = New-PsqlShellInput $Sql -Table:$Table
    $output = Get-ComposeShellInputOutput $shellInput @('exec', '-T', 'postgres', 'sh', '-seu')
    if ($Table) { $output | Out-Host; return }
    return (($output -join "`n").Trim())
}

function Invoke-PsqlScript([string]$Sql) {
    $output = Get-ComposeShellInputOutput (New-PsqlShellInput $Sql) @('exec', '-T', 'postgres', 'sh', '-seu')
    return (($output -join "`n").Trim())
}

function Invoke-PsqlLines([string]$Sql) {
    return @(Get-ComposeShellInputOutput (New-PsqlShellInput $Sql) @('exec', '-T', 'postgres', 'sh', '-seu') |
        ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ -ne '' })
}

function Write-PsqlLinesToFile([string]$Sql, [string]$Path) {
    Write-ComposeShellInputOutputToFile (New-PsqlShellInput $Sql) @('exec', '-T', 'postgres', 'sh', '-seu') $Path
}

function Test-FileContentEqual([string]$First, [string]$Second) {
    $firstInfo = Get-Item -LiteralPath $First
    $secondInfo = Get-Item -LiteralPath $Second
    if ($firstInfo.Length -ne $secondInfo.Length) { return $false }
    $left = [IO.File]::OpenRead($First)
    $right = [IO.File]::OpenRead($Second)
    try {
        $leftBuffer = New-Object byte[] 65536
        $rightBuffer = New-Object byte[] 65536
        while ($true) {
            $leftRead = $left.Read($leftBuffer, 0, $leftBuffer.Length)
            $rightRead = $right.Read($rightBuffer, 0, $rightBuffer.Length)
            if ($leftRead -ne $rightRead) { return $false }
            if ($leftRead -eq 0) { return $true }
            for ($index = 0; $index -lt $leftRead; $index++) {
                if ($leftBuffer[$index] -ne $rightBuffer[$index]) { return $false }
            }
        }
    } finally {
        $left.Dispose()
        $right.Dispose()
    }
}

function Get-OscarImage { return "oscar:$(Get-EnvValue 'OSCAR_VERSION' 'local')" }

function Invoke-ArchiveObjectHelper(
    [ValidateSet('verify', 'copy', 'delete')][string]$Operation,
    [string]$Relative,
    [string]$ExpectedSha256,
    [ValidateSet('ro', 'rw')][string]$ArchiveAccess,
    [string]$ExportRoot = ''
) {
    $arguments = @(
        'run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL',
        '--security-opt', 'no-new-privileges', '--user', '10001:10001',
        '--entrypoint', '/usr/local/bin/oscar-archive-object',
        '--volume', "${ArchiveDirectory}:/archive:${ArchiveAccess}"
    )
    if ($ExportRoot) { $arguments += @('--volume', "${ExportRoot}:/export") }
    $arguments += @((Get-OscarImage), $Operation, $Relative, $ExpectedSha256)
    $output = @(Get-ExternalOutput 'docker' $arguments)
    return (($output -join "`n").Trim())
}

function Get-ReleaseTemplateVersion {
    $source = Join-Path $ScriptRoot '.env.example'
    foreach ($line in [IO.File]::ReadAllLines($source)) {
        if ($line -match '^OSCAR_VERSION=(.*)$' -and $Matches[1]) { return $Matches[1] }
    }
    return ''
}

function Assert-LocalImage([string]$Image) {
    if (-not $Image) { Fail 'Compose resolved an empty container image name.' }
    & docker image inspect $Image *> $null
    if ($LASTEXITCODE -ne 0) { Fail "Required local container image is unavailable: $Image" }
}

function Get-PostgresImage {
    $images = @(Get-ComposeOutput @('config', '--images'))
    $image = @($images | Where-Object { $_ -match '(^|/)oscar-postgis:' } | Select-Object -First 1)
    if ($image.Count -ne 1) { Fail 'Could not resolve the PostgreSQL image from compose.yaml.' }
    return $image[0]
}
function Test-BackupId([string]$Value) { return $Value -match '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$' }
function Test-Uuid([string]$Value) { return $Value -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$' }
function Test-ObservationId([string]$Value) {
    if ($Value -notmatch '^[1-9][0-9]{0,18}$') { return $false }
    [long]$parsed = 0
    return [long]::TryParse($Value, [ref]$parsed) -and $parsed -gt 0
}
function Test-UtcCutoff([string]$Value) { return $Value -match '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' }
function Test-StoreKey([string]$Value) { return $Value -match '^[A-Za-z_][A-Za-z0-9_]{0,62}$' }
function Test-IdScope([string]$Value) {
    if ($Value -notmatch '^(?:0|-?[1-9][0-9]{0,9})$') { return $false }
    try {
        $number = [int64]$Value
        return $number -ge [int]::MinValue -and $number -le [int]::MaxValue
    } catch { return $false }
}
function Test-RelativeObjectPath([string]$Value) {
    return $Value -match '^[A-Za-z0-9][A-Za-z0-9._/+=-]*$' -and -not [IO.Path]::IsPathRooted($Value) -and
        $Value -notmatch '(^|/)\.\.(/|$)' -and $Value -notmatch '//'
}

function Test-ArchiveObjectPath([string]$Value) {
    return (Test-RelativeObjectPath $Value) -and
        $Value -cmatch '^datasets/observations/date=[0-9]{4}-[0-9]{2}-[0-9]{2}/profile=[A-Za-z0-9_-]+/generation-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\.(?:parquet|schemas\.json\.gz|manifest\.json)$'
}

function Assert-SafeCreatableDirectoryPath([string]$FullPath) {
    $full = [IO.Path]::GetFullPath($FullPath)
    $volume = [IO.Path]::GetPathRoot($full)
    $current = $volume
    foreach ($part in @($full.Substring($volume.Length) -split '[\\/]' | Where-Object { $_ })) {
        $current = Join-Path $current $part
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if (-not $item) { return }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Fail "Reparse points are not permitted in privileged storage paths: $current"
        }
        if (-not $item.PSIsContainer) { Fail "Privileged storage path component is not a directory: $current" }
    }
}

function Resolve-ConfinedStorageFile([string]$RootPath, [string]$Relative, [switch]$AllowMissing) {
    if (-not (Test-RelativeObjectPath $Relative)) { Fail "Catalog contains unsafe object path: $Relative" }
    Assert-NoReparseComponents $RootPath
    $root = [IO.Path]::GetFullPath($RootPath)
    $candidate = [IO.Path]::GetFullPath((Join-Path $root ($Relative.Replace('/', [IO.Path]::DirectorySeparatorChar))))
    $prefix = $root
    if (-not $prefix.EndsWith([string][IO.Path]::DirectorySeparatorChar)) { $prefix += [IO.Path]::DirectorySeparatorChar }
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        Fail "Storage object escapes the configured root: $Relative"
    }
    Assert-NoReparseComponents $candidate -AllowMissingLeaf:$AllowMissing
    if (Test-Path -LiteralPath $candidate) {
        $item = Get-Item -LiteralPath $candidate -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Fail "Archive object is not a regular, non-reparse-point file: $Relative"
        }
    } elseif (-not $AllowMissing) {
        Fail "Archive object is missing: $Relative"
    }
    return $candidate
}

function Resolve-ConfinedArchivePath([string]$Relative, [switch]$AllowMissing) {
    return Resolve-ConfinedStorageFile $ArchiveDirectory $Relative -AllowMissing:$AllowMissing
}

function Write-ArchiveAuditSortedChunk(
    [Collections.Generic.List[string]]$Lines,
    [string]$Path
) {
    [void]$Lines.Sort([StringComparer]::Ordinal)
    $writer = [IO.StreamWriter]::new($Path, $false, $Utf8NoBom)
    try {
        $previous = $null
        $hasPrevious = $false
        foreach ($line in $Lines) {
            if (-not $hasPrevious -or -not [StringComparer]::Ordinal.Equals($previous, $line)) {
                $writer.WriteLine($line)
                $previous = $line
                $hasPrevious = $true
            }
        }
    } finally { $writer.Dispose() }
}

function Merge-ArchiveAuditSortedFiles(
    [string]$LeftPath,
    [string]$RightPath,
    [string]$DestinationPath
) {
    $left = $null
    $right = $null
    $writer = $null
    try {
        $left = [IO.StreamReader]::new($LeftPath, $Utf8NoBom, $true, 65536)
        $right = [IO.StreamReader]::new($RightPath, $Utf8NoBom, $true, 65536)
        $writer = [IO.StreamWriter]::new($DestinationPath, $false, $Utf8NoBom, 65536)
        $leftLine = $left.ReadLine()
        $rightLine = $right.ReadLine()
        $previous = $null
        $hasPrevious = $false
        while ($null -ne $leftLine -or $null -ne $rightLine) {
            if ($null -eq $rightLine) {
                $selected = $leftLine
                $leftLine = $left.ReadLine()
            } elseif ($null -eq $leftLine) {
                $selected = $rightLine
                $rightLine = $right.ReadLine()
            } else {
                $comparison = [StringComparer]::Ordinal.Compare($leftLine, $rightLine)
                if ($comparison -lt 0) {
                    $selected = $leftLine
                    $leftLine = $left.ReadLine()
                } elseif ($comparison -gt 0) {
                    $selected = $rightLine
                    $rightLine = $right.ReadLine()
                } else {
                    $selected = $leftLine
                    $leftLine = $left.ReadLine()
                    $rightLine = $right.ReadLine()
                }
            }
            if (-not $hasPrevious -or -not [StringComparer]::Ordinal.Equals($previous, $selected)) {
                $writer.WriteLine($selected)
                $previous = $selected
                $hasPrevious = $true
            }
        }
    } finally {
        if ($writer) { $writer.Dispose() }
        if ($right) { $right.Dispose() }
        if ($left) { $left.Dispose() }
    }
}

function ConvertTo-ArchiveAuditSortedUniqueFile(
    [string]$InputPath,
    [string]$OutputPath,
    [int]$ChunkLineLimit = $ArchiveAuditSortChunkLines
) {
    if ($ChunkLineLimit -lt 1 -or $ChunkLineLimit -gt 65536) {
        Fail 'Archive audit sort chunk size must be between 1 and 65536 lines.'
    }
    $sortRoot = Join-Path (Split-Path -Parent $OutputPath) ('sort-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $sortRoot | Out-Null
    $reader = $null
    try {
        $buffer = New-Object 'Collections.Generic.List[string]'
        $chunkCount = 0
        $reader = [IO.StreamReader]::new($InputPath, $Utf8NoBom, $true, 65536)
        while (($line = $reader.ReadLine()) -ne $null) {
            if ($line.Length -eq 0) { continue }
            $buffer.Add($line)
            if ($buffer.Count -ge $ChunkLineLimit) {
                $chunk = Join-Path $sortRoot ('pass-0000-{0:D8}.txt' -f $chunkCount)
                Write-ArchiveAuditSortedChunk $buffer $chunk
                $buffer.Clear()
                $chunkCount++
            }
        }
        if ($buffer.Count -ne 0) {
            $chunk = Join-Path $sortRoot ('pass-0000-{0:D8}.txt' -f $chunkCount)
            Write-ArchiveAuditSortedChunk $buffer $chunk
            $buffer.Clear()
            $chunkCount++
        }
        $reader.Dispose()
        $reader = $null

        if ($chunkCount -eq 0) {
            [IO.File]::WriteAllText($OutputPath, '', $Utf8NoBom)
            return
        }

        $pass = 0
        while ($chunkCount -gt 1) {
            $nextCount = 0
            for ($index = 0; $index -lt $chunkCount; $index += 2) {
                $left = Join-Path $sortRoot ('pass-{0:D4}-{1:D8}.txt' -f $pass, $index)
                $destination = Join-Path $sortRoot ('pass-{0:D4}-{1:D8}.txt' -f ($pass + 1), $nextCount)
                if (($index + 1) -lt $chunkCount) {
                    $right = Join-Path $sortRoot ('pass-{0:D4}-{1:D8}.txt' -f $pass, ($index + 1))
                    Merge-ArchiveAuditSortedFiles $left $right $destination
                    Remove-Item -LiteralPath $right -Force
                } else {
                    [IO.File]::Move($left, $destination)
                }
                if (Test-Path -LiteralPath $left) { Remove-Item -LiteralPath $left -Force }
                $nextCount++
            }
            $pass++
            $chunkCount = $nextCount
        }

        $finalChunk = Join-Path $sortRoot ('pass-{0:D4}-00000000.txt' -f $pass)
        if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }
        [IO.File]::Move($finalChunk, $OutputPath)
    } finally {
        if ($reader) { $reader.Dispose() }
        if (Test-Path -LiteralPath $sortRoot) {
            Remove-Item -LiteralPath $sortRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-RegisteredArchivePaths([string]$Path) {
    $sql = "SELECT relative_path FROM oscar_archive_object WHERE state IN ('ACTIVE','DELETING') ORDER BY relative_path;"
    Write-PsqlLinesToFile $sql $Path
    foreach ($relative in [IO.File]::ReadLines($Path)) {
        if (-not (Test-ArchiveObjectPath $relative)) {
            Fail "Catalog contains an object path outside the approved archive layout: $relative"
        }
    }
}

function Compare-ArchiveAuditSortedFiles([string]$CandidatePath, [string]$CatalogPath) {
    $candidates = $null
    $catalog = $null
    $failures = 0
    try {
        $candidates = [IO.StreamReader]::new($CandidatePath, $Utf8NoBom, $true, 65536)
        $catalog = [IO.StreamReader]::new($CatalogPath, $Utf8NoBom, $true, 65536)
        $candidate = $candidates.ReadLine()
        $registered = $catalog.ReadLine()
        while ($null -ne $candidate) {
            while ($null -ne $registered -and
                [StringComparer]::Ordinal.Compare($registered, $candidate) -lt 0) {
                $registered = $catalog.ReadLine()
            }
            if ($null -eq $registered -or
                [StringComparer]::Ordinal.Compare($registered, $candidate) -gt 0) {
                Write-Error "Unregistered archive object: $candidate" -ErrorAction Continue
                $failures++
            }
            $candidate = $candidates.ReadLine()
        }
    } finally {
        if ($catalog) { $catalog.Dispose() }
        if ($candidates) { $candidates.Dispose() }
    }
    return $failures
}

function Test-ArchiveFilesystemRegistration([switch]$RejectPartials) {
    if (-not (Test-Path -LiteralPath $ArchiveDirectory -PathType Container)) { Fail "Archive root is unavailable: $ArchiveDirectory" }
    Assert-NoReparseComponents $ArchiveDirectory
    $root = [IO.Path]::GetFullPath($ArchiveDirectory).TrimEnd('\', '/')
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ('oscar-archive-audit-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $scratch | Out-Null
    $candidateWriter = $null
    try {
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { Protect-PrivateDirectory $scratch }
        $catalogFirstRaw = Join-Path $scratch 'catalog-first.raw'
        $catalogSecondRaw = Join-Path $scratch 'catalog-second.raw'
        $catalogFirst = Join-Path $scratch 'catalog-first.sorted'
        $catalogSecond = Join-Path $scratch 'catalog-second.sorted'
        $catalogMerged = Join-Path $scratch 'catalog-merged.sorted'
        $candidateRaw = Join-Path $scratch 'candidates.raw'
        $candidateSorted = Join-Path $scratch 'candidates.sorted'
        Write-RegisteredArchivePaths $catalogFirstRaw

        $candidateWriter = [IO.StreamWriter]::new($candidateRaw, $false, $Utf8NoBom, 65536)
        $pending = New-Object System.Collections.Generic.Stack[string]
        $pending.Push($root)
        $failures = 0
        $freshPartials = 0
        while ($pending.Count -gt 0) {
            $directory = $pending.Pop()
            $entries = [IO.Directory]::EnumerateFileSystemEntries($directory).GetEnumerator()
            try {
                while ($entries.MoveNext()) {
                    $item = Get-Item -LiteralPath ([string]$entries.Current) -Force
                    $relative = $item.FullName.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
                    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                        Write-Error "Unsafe reparse-point archive entry: $relative" -ErrorAction Continue
                        $failures++
                        continue
                    }
                    # The administrator-owned root identity is host metadata, not an
                    # archive object. The command dispatcher authenticates it before
                    # every live archive operation; only its exact root-level name is
                    # exempt from the intentionally narrower object-path grammar.
                    if ($relative -ceq '.oscar-storage-root') {
                        if ($item.PSIsContainer -or $item -isnot [IO.FileInfo]) {
                            Write-Error "Archive root identity marker is not a regular file: $relative" -ErrorAction Continue
                            $failures++
                        }
                        continue
                    }
                    if (-not (Test-RelativeObjectPath $relative)) {
                        Write-Error "Unsafe archive filesystem path: $relative" -ErrorAction Continue
                        $failures++
                        continue
                    }
                    $validDirectory = $relative -ceq 'datasets' -or $relative -ceq 'datasets/observations' -or
                        $relative -cmatch '^datasets/observations/date=[0-9]{4}-[0-9]{2}-[0-9]{2}$' -or
                        $relative -cmatch '^datasets/observations/date=[0-9]{4}-[0-9]{2}-[0-9]{2}/profile=[A-Za-z0-9_-]+$'
                    $validObject = Test-ArchiveObjectPath $relative
                    $validPartial = $relative -cmatch '^datasets/observations/date=[0-9]{4}-[0-9]{2}-[0-9]{2}/profile=[A-Za-z0-9_-]+/generation-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\.(?:parquet|schemas\.json\.gz|manifest\.json)\.partial.*$'
                    if ($item.Name.IndexOf('.partial', [StringComparison]::Ordinal) -ge 0) {
                        if (-not $validPartial) {
                            Write-Error "Archive partial is outside the approved generation-object layout: $relative" -ErrorAction Continue
                            $failures++
                            continue
                        }
                        if ($RejectPartials) {
                            Write-Error "Archive partial exists while writers are quiesced: $relative" -ErrorAction Continue
                            $failures++
                        } elseif (([DateTime]::UtcNow - $item.LastWriteTimeUtc).TotalSeconds -ge 7200) {
                            Write-Error "Stale archive partial (at least two hours old): $relative" -ErrorAction Continue
                            $failures++
                        } else {
                            Write-Warning "Archive partial is still within the two-hour in-progress window: $relative"
                            $freshPartials++
                        }
                        continue
                    }
                    if ($item.PSIsContainer) {
                        if (-not $validDirectory) {
                            Write-Error "Archive directory is outside the approved datasets layout: $relative" -ErrorAction Continue
                            $failures++
                        }
                        $pending.Push($item.FullName)
                    } elseif ($item -is [IO.FileInfo]) {
                        if (-not $validObject) {
                            Write-Error "Archive file is outside the approved generation-object layout: $relative" -ErrorAction Continue
                            $failures++
                        } else {
                            $candidateWriter.WriteLine($relative)
                        }
                    } else {
                        Write-Error "Unsafe non-regular archive entry: $relative" -ErrorAction Continue
                        $failures++
                    }
                }
            } finally {
                if ($entries -is [IDisposable]) { $entries.Dispose() }
            }
        }
        $candidateWriter.Dispose()
        $candidateWriter = $null

        # Merge a second catalog read so a generation activated during the scan is
        # not reported as an orphan merely because publication and catalog commit race.
        Write-RegisteredArchivePaths $catalogSecondRaw
        ConvertTo-ArchiveAuditSortedUniqueFile $catalogFirstRaw $catalogFirst
        ConvertTo-ArchiveAuditSortedUniqueFile $catalogSecondRaw $catalogSecond
        Merge-ArchiveAuditSortedFiles $catalogFirst $catalogSecond $catalogMerged
        ConvertTo-ArchiveAuditSortedUniqueFile $candidateRaw $candidateSorted
        $failures += Compare-ArchiveAuditSortedFiles $candidateSorted $catalogMerged
        if ($failures -ne 0) { Fail "$failures archive filesystem reconciliation failure(s); no files were changed" }
        if ($freshPartials -ne 0) { Write-Host "$freshPartials recent archive partial(s) reported but not treated as stale." }
    } finally {
        if ($candidateWriter) { $candidateWriter.Dispose() }
        if (Test-Path -LiteralPath $scratch) {
            Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Protect-PrivateDirectory([string]$Path) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetOwner($administrators)
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $full = [Security.AccessControl.FileSystemRights]::FullControl
    $principals = @(
        $identity.User,
        ([Security.Principal.SecurityIdentifier]::new('S-1-5-18')),
        $administrators
    )
    foreach ($principal in $principals) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($principal, $full, $inheritance, $propagation, $allow)
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Protect-DockerStorageDirectory(
    [string]$Path,
    [ValidateSet('ReadOnly', 'ReadWrite')][string]$DockerAccess
) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetOwner($administrators)
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $full = [Security.AccessControl.FileSystemRights]::FullControl
    foreach ($principal in @(
        $identity.User,
        ([Security.Principal.SecurityIdentifier]::new('S-1-5-18')),
        $administrators)) {
        [void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $principal, $full, $inheritance, $propagation, $allow))
    }
    $dockerRights = if ($DockerAccess -ceq 'ReadWrite') {
        [Security.AccessControl.FileSystemRights]::Modify
    } else {
        [Security.AccessControl.FileSystemRights]::ReadAndExecute
    }
    [void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        (Get-DockerUsersSid), $dockerRights, $inheritance, $propagation, $allow))
    Set-Acl -LiteralPath $Path -AclObject $acl
    Assert-DockerStorageDirectory $Path 'Docker-accessible OSCAR storage directory' $DockerAccess
}

function Protect-DockerReadableAdministratorFile([string]$Path) {
    Protect-AdministratorFile $Path
    $acl = Get-Acl -LiteralPath $Path
    [void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        (Get-DockerUsersSid),
        [Security.AccessControl.FileSystemRights]::ReadAndExecute,
        [Security.AccessControl.AccessControlType]::Allow))
    Set-Acl -LiteralPath $Path -AclObject $acl
    Assert-AdministratorFile $Path 'Docker-readable administrator file'
}

function Initialize-StorageDirectories([switch]$AdoptExisting) {
    Assert-Administrator
    $includeBackup = (Get-ValidatedBackupMode) -ceq 'single'
    Assert-StorageRootShapes -IncludeBackup:$includeBackup
    $paths = @($ArchiveDirectory)
    if ($includeBackup) { $paths += $BackupDirectory }
    foreach ($path in $paths) {
        Assert-SafeCreatableDirectoryPath $path
    }
    New-Item -ItemType Directory -Force -Path $paths | Out-Null
    Assert-StorageRootsReady -IncludeBackup:$includeBackup
    $roots = ,@($ArchiveDirectory, 'archive')
    if ($includeBackup) { $roots += ,@($BackupDirectory, 'backup') }
    # Preflight every root before claiming any one of them so a foreign/swapped
    # marker or an unacknowledged nonempty legacy root cannot cause a partial claim.
    foreach ($entry in $roots) {
        $marker = Join-Path $entry[0] '.oscar-storage-root'
        if (Test-Path -LiteralPath $marker) {
            # Authenticate the protected marker before normalizing a root ACL
            # left in the exact temporary state of an interrupted operation.
            Assert-StorageRootIdentity $entry[0] $entry[1] -AllowDirectoryAclRepair
        } elseif (@(Get-ChildItem -LiteralPath $entry[0] -Force).Count -gt 0 -and -not $AdoptExisting) {
            Fail "Nonempty $($entry[1]) storage root is unclaimed. Re-run setup with the explicit legacy-storage-root adoption option after verifying this path: $($entry[0])"
        }
    }
    foreach ($entry in $roots) {
        $dockerAccess = if ($entry[1] -ceq 'backup') { 'ReadOnly' } else { 'ReadWrite' }
        Protect-DockerStorageDirectory $entry[0] $dockerAccess
    }
    foreach ($entry in $roots) {
        $marker = Join-Path $entry[0] '.oscar-storage-root'
        if (-not (Test-Path -LiteralPath $marker)) {
            $isNonempty = @(Get-ChildItem -LiteralPath $entry[0] -Force).Count -gt 0
            Write-StorageRootIdentity $entry[0] $entry[1] $(if ($isNonempty) { 'explicit-existing' } else { 'new' })
            if ($isNonempty) { Write-Host "Adopted existing $($entry[1]) storage root for this deployment: $($entry[0])" -ForegroundColor Yellow }
        }
    }
    Assert-StorageRootIdentities -IncludeBackup:$includeBackup
}

function Invoke-UpgradePersistentState {
    # Keep the deployment-scoped storage-administration lock for the complete
    # offline transition. Backup/restore cannot enter after OSCAR stops but
    # before the index is durable and the application is running again.
    Write-Host "`n== Preparing persistent OSCAR state for this release ==" -ForegroundColor Cyan
    Invoke-Compose @('stop', 'gateway')
    Invoke-Compose @('stop', 'oscar')

    $legacyCleanup = @'
umask 077
if [ -e /state/backups ] || [ -L /state/backups ]; then
    [ -d /state/backups ] && [ ! -L /state/backups ] || {
        echo "Legacy embedded backup path is not a regular directory." >&2; exit 1;
    }
    rmdir -- /state/backups || {
        echo "Legacy embedded /var/lib/oscar/backups is nonempty. Preserve or export its contents, explicitly empty that non-authoritative volume path, then retry upgrade." >&2
        exit 1
    }
fi
'@
    [void](Get-DockerShellInputOutput $legacyCleanup @(
        'run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL',
        '--security-opt', 'no-new-privileges', '--user', '10001:10001',
        '--entrypoint', 'sh', '--volume', 'oscar_oscar_state:/state',
        (Get-OscarImage), '-seu'))

    Write-Host "`n== Migrating daily-file lifecycle index ==" -ForegroundColor Cyan
    $migration = @'
umask 077
exec java -cp '/opt/oscar/lib/*' com.botts.impl.service.dailyfile.DailyFileJournalIndexMigration --config /var/lib/oscar/config.json
'@
    [void](Get-ComposeShellInputOutput $migration @(
        'run', '--rm', '--no-deps', '--user', '10001:10001',
        '--entrypoint', 'sh', 'oscar', '-seu'))

    Invoke-Compose @('config', '--quiet')
    # Clean-directory upgrades change every release-local bind source. Recreate
    # all services without renewing named volumes while the lock is still held.
    Invoke-Compose @('up', '--detach', '--force-recreate', '--no-build', '--pull', 'never', '--wait', '--wait-timeout', '240')
}

function Write-Checksums([string]$Root) {
    $lines = New-Object System.Collections.Generic.List[string]
    Get-ChildItem -LiteralPath $Root -File -Recurse | Where-Object { $_.Name -notin @('SHA256SUMS', 'SHA256SUMS.hmac') } | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $lines.Add("$hash  ./$relative")
    }
    [IO.File]::WriteAllLines((Join-Path $Root 'SHA256SUMS'), $lines, $Utf8NoBom)
}

function Get-ChecksumHmac([string]$Root, [string]$Image, [switch]$ReadOnly) {
    $script = 'key=$(cat /backup-key.txt); openssl dgst -sha256 -hmac "$key" -binary /backup/SHA256SUMS | openssl base64 -A'
    $output = Get-DockerShellInputOutput $script @('run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--workdir', '/', '--user', '0', '--entrypoint', 'sh', '--volume', "${Root}:/backup:ro", '--volume', "${BackupKeyFile}:/backup-key.txt:ro", $Image, '-seu')
    $tag = (($output -join '').Trim())
    if ($tag -notmatch '^[A-Za-z0-9+/]{43}=$') { Fail 'Could not calculate a valid backup authentication tag.' }
    return $tag
}

function Write-ChecksumHmac([string]$Root, [string]$Image) {
    [IO.File]::WriteAllText((Join-Path $Root 'SHA256SUMS.hmac'), (Get-ChecksumHmac $Root $Image) + "`n", $Utf8NoBom)
}

function Confirm-ChecksumHmac([string]$Root, [string]$Image) {
    $path = Join-Path $Root 'SHA256SUMS.hmac'
    [void](Resolve-ConfinedStorageFile $Root 'SHA256SUMS')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Fail "Backup has no SHA256SUMS.hmac and cannot be accepted as an authenticated $RequiredReleaseVersion recovery point."
    }
    [void](Resolve-ConfinedStorageFile $Root 'SHA256SUMS.hmac')
    $expected = [IO.File]::ReadAllText($path).Trim()
    if ($expected -notmatch '^[A-Za-z0-9+/]{43}=$') { Fail 'Backup authentication tag is malformed.' }
    $actual = Get-ChecksumHmac $Root $Image -ReadOnly
    if ($actual -cne $expected) { Fail 'Backup authentication failed; SHA256SUMS or a backup payload may have been altered.' }
}

function Confirm-ReleaseConfigArchive([string]$Root, [string]$Image) {
    $validation = 'sh /validator/validate-storage-archive.sh release-config /backup/release-config.tar.gz'
    Invoke-DockerShellInput $validation @('run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--tmpfs', $ValidatorScratchTmpfs, '--env', 'TMPDIR=/tmp', '--workdir', '/', '--user', '0', '--entrypoint', 'sh', '--volume', "${Root}:/backup:ro", '--volume', "${ScriptRoot}:/validator:ro", $Image, '-seu')
}

function Confirm-BackupArchiveMembers([string]$Root, [string]$Image, [int]$SchemaVersion) {
    $walValidation = if ($SchemaVersion -eq 1) { "    wal-archive /backup/wal-archive.tar.gz \`n" } else { '' }
    $validation = @'
secret_archive=$(mktemp /tmp/oscar-secrets.XXXXXX.tar.gz)
trap 'rm -f -- "$secret_archive"' EXIT HUP INT TERM
openssl enc -d -aes-256-cbc -pbkdf2 -pass file:/backup-key.txt -in /backup/deployment-secrets.tar.gz.enc -out "$secret_archive"
sh /validator/validate-storage-archive.sh \
    oscar-state /backup/oscar-state.tar.gz \
    cold-archive /backup/archive.tar.gz \
__WAL_VALIDATION__    release-config /backup/release-config.tar.gz \
    deployment-secrets "$secret_archive"
'@
    $validation = $validation.Replace('__WAL_VALIDATION__', $walValidation)
    Invoke-DockerShellInput $validation @('run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--tmpfs', $ValidatorScratchTmpfs, '--env', 'TMPDIR=/tmp', '--workdir', '/', '--user', '0', '--entrypoint', 'sh', '--volume', "${Root}:/backup:ro", '--volume', "${BackupKeyFile}:/backup-key.txt:ro", '--volume', "${ScriptRoot}:/validator:ro", $Image, '-seu')
}

function Write-VerifiedMarker([string]$Root) {
    $marker = Join-Path $Root 'VERIFIED'
    $temporary = Join-Path $Root ('.VERIFIED.' + [Guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $marker) {
        $markerItem = Get-Item -LiteralPath $marker -Force
        if ($markerItem.PSIsContainer -or ($markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Fail "VERIFIED marker is not a regular, non-reparse-point file: $marker"
        }
    }
    try {
        $bytes = $Utf8NoBom.GetBytes([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') + "`n")
        $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        Protect-AdministratorFile $temporary
        Move-DurableReplace $temporary $marker
        Assert-AdministratorFile $marker 'VERIFIED marker'
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Get-JournalConfirmationHmac([string]$ReceiptPath, [string]$Image) {
    $item = Get-Item -LiteralPath $ReceiptPath -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail 'Journal-confirmation receipt payload is missing or unsafe.'
    }
    $script = 'key=$(cat /backup-key.txt); head -n 4 /journal-confirmation | openssl dgst -sha256 -hmac "$key" -binary | openssl base64 -A'
    $output = Get-DockerShellInputOutput $script @(
        'run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL',
        '--security-opt', 'no-new-privileges', '--workdir', '/', '--user', '0', '--entrypoint', 'sh',
        '--volume', "${ReceiptPath}:/journal-confirmation:ro", '--volume', "${BackupKeyFile}:/backup-key.txt:ro",
        $Image, '-seu')
    $tag = (($output -join '').Trim())
    if ($tag -notmatch '^[A-Za-z0-9+/]{43}=$') { Fail 'Could not authenticate the journal-confirmation receipt.' }
    return $tag
}

function Write-JournalConfirmationReceipt(
    [string]$Root,
    [string]$Id,
    [string]$OscarStateSha256,
    [string]$Image
) {
    if (-not (Test-BackupId $Id) -or $OscarStateSha256 -notmatch '^[0-9a-f]{64}$') {
        Fail 'Invalid journal-confirmation receipt identity.'
    }
    $receipt = Join-Path $Root 'JOURNAL_CONFIRMED'
    if (Test-Path -LiteralPath $receipt) { Fail "Journal confirmation receipt already exists: $receipt" }
    $temporary = Join-Path $Root ('.JOURNAL_CONFIRMED.' + [Guid]::NewGuid().ToString('N'))
    try {
        $content = "format=oscar-journal-backup-confirmation`nversion=2`nbackup_id=$Id`noscar_state_sha256=$OscarStateSha256`n"
        $initialBytes = $Utf8NoBom.GetBytes($content)
        $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
        try { $stream.Write($initialBytes, 0, $initialBytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        $tag = Get-JournalConfirmationHmac $temporary $Image
        $content += "hmac_sha256=$tag`n"
        $bytes = $Utf8NoBom.GetBytes($content)
        $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::Truncate, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        Protect-AdministratorFile $temporary
        Move-DurableNoReplace $temporary $receipt
        Assert-AdministratorFile $receipt 'journal-confirmation receipt'
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Confirm-JournalConfirmationReceipt(
    [string]$Root,
    [string]$Id,
    [string]$OscarStateSha256,
    [string]$Image
) {
    $receipt = Join-Path $Root 'JOURNAL_CONFIRMED'
    Assert-AdministratorFile $receipt 'authenticated journal-confirmation receipt'
    $lines = @([IO.File]::ReadAllLines($receipt))
    if ($lines.Count -ne 5 -or
        @($lines | Where-Object { $_ -ceq 'format=oscar-journal-backup-confirmation' }).Count -ne 1 -or
        @($lines | Where-Object { $_ -ceq 'version=2' }).Count -ne 1 -or
        @($lines | Where-Object { $_ -ceq "backup_id=$Id" }).Count -ne 1 -or
        @($lines | Where-Object { $_ -ceq "oscar_state_sha256=$OscarStateSha256" }).Count -ne 1 -or
        @($lines | Where-Object { $_ -cmatch '^hmac_sha256=[A-Za-z0-9+/]{43}=$' }).Count -ne 1) {
        Fail 'Authenticated journal confirmation receipt does not match this recovery point.'
    }
    $expected = $lines[4].Substring('hmac_sha256='.Length)
    $expectedRaw = "format=oscar-journal-backup-confirmation`nversion=2`nbackup_id=$Id`noscar_state_sha256=$OscarStateSha256`nhmac_sha256=$expected`n"
    if (-not (Test-ExactUtf8NoBomFile $receipt $expectedRaw)) {
        Fail 'Authenticated journal confirmation receipt is not canonically LF-terminated.'
    }
    if ((Get-JournalConfirmationHmac $receipt $Image) -cne $expected) {
        Fail 'Journal-confirmation receipt authentication failed.'
    }
}

function Get-CurrentPointerHmac([string]$PointerPath, [string]$Image) {
    $item = Get-Item -LiteralPath $PointerPath -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail 'CURRENT pointer payload is missing or unsafe.'
    }
    $script = 'key=$(cat /backup-key.txt); head -n 3 /current | openssl dgst -sha256 -hmac "$key" -binary | openssl base64 -A'
    $output = Get-DockerShellInputOutput $script @(
        'run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
        '--workdir', '/', '--user', '0', '--entrypoint', 'sh', '--volume', "${PointerPath}:/current:ro",
        '--volume', "${BackupKeyFile}:/backup-key.txt:ro", $Image, '-seu')
    $tag = (($output -join '').Trim())
    if ($tag -notmatch '^[A-Za-z0-9+/]{43}=$') { Fail 'Could not authenticate the CURRENT backup pointer.' }
    return $tag
}

function Read-CurrentBackupId([switch]$AllowMissing) {
    $pointer = Join-Path $BackupDirectory 'CURRENT'
    $nameComparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        [StringComparison]::OrdinalIgnoreCase
    } else {
        [StringComparison]::Ordinal
    }
    $pointerEntries = @(Get-ChildItem -LiteralPath $BackupDirectory -Force -ErrorAction Stop |
        Where-Object { $_.Name.Equals('CURRENT', $nameComparison) })
    if ($pointerEntries.Count -eq 0) {
        if ($AllowMissing) { return $null }
        Fail 'The authenticated CURRENT backup pointer is missing.'
    }
    if ($pointerEntries.Count -ne 1 -or $pointerEntries[0].Name -cne 'CURRENT') {
        Fail 'CURRENT backup pointer does not have the exact canonical direct-child name.'
    }
    $pointerItem = $pointerEntries[0]
    if (($pointerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail 'CURRENT backup pointer is a reparse point.'
    }
    if ($pointerItem.PSIsContainer -or $pointerItem -isnot [IO.FileInfo]) {
        Fail 'CURRENT backup pointer is not a regular file.'
    }
    Assert-AdministratorFile $pointerItem.FullName 'CURRENT backup pointer'
    $lines = @([IO.File]::ReadAllLines($pointer))
    if ($lines.Count -ne 4 -or $lines[0] -cne 'format=oscar-current-backup' -or $lines[1] -cne 'version=1' -or
        $lines[2] -cnotmatch '^backup_id=([0-9]{8}T[0-9]{6}Z-[0-9a-f]{8})$' -or
        $lines[3] -cnotmatch '^hmac_sha256=([A-Za-z0-9+/]{43}=)$') {
        Fail 'CURRENT backup pointer is malformed.'
    }
    $id = $lines[2].Substring('backup_id='.Length)
    $expectedRaw = "format=oscar-current-backup`nversion=1`nbackup_id=$id`nhmac_sha256=$($lines[3].Substring('hmac_sha256='.Length))`n"
    if (-not (Test-ExactUtf8NoBomFile $pointer $expectedRaw)) {
        Fail 'CURRENT backup pointer is not canonically LF-terminated.'
    }
    $expected = $lines[3].Substring('hmac_sha256='.Length)
    if ((Get-CurrentPointerHmac $pointer (Get-OscarImage)) -cne $expected) {
        Fail 'CURRENT backup pointer authentication failed.'
    }
    $snapshot = Join-Path $BackupDirectory $id
    if (-not (Test-Path -LiteralPath $snapshot -PathType Container) -or
        ((Get-Item -LiteralPath $snapshot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail "CURRENT points to a missing or unsafe backup snapshot: $id"
    }
    return $id
}

function Write-CurrentBackupPointer([string]$Id, [string]$Image) {
    if (-not (Test-BackupId $Id)) { Fail 'Cannot publish an invalid CURRENT backup ID.' }
    [void](Read-CurrentBackupId -AllowMissing)
    $pointer = Join-Path $BackupDirectory 'CURRENT'
    $temporary = Join-Path $BackupDirectory ('.CURRENT.tmp.' + [Guid]::NewGuid().ToString('N'))
    try {
        $prefix = "format=oscar-current-backup`nversion=1`nbackup_id=$Id`n"
        $bytes = $Utf8NoBom.GetBytes($prefix)
        $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        Protect-DockerReadableAdministratorFile $temporary
        $tag = Get-CurrentPointerHmac $temporary $Image
        $bytes = $Utf8NoBom.GetBytes("${prefix}hmac_sha256=$tag`n")
        $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::Truncate, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        Protect-DockerReadableAdministratorFile $temporary
        Move-DurableReplace $temporary $pointer
        Sync-DurableMetadata $BackupDirectory
        Protect-DockerReadableAdministratorFile $pointer
        Sync-DurableMetadata $BackupDirectory
        if ((Read-CurrentBackupId) -cne $Id) { Fail 'CURRENT backup pointer publication did not persist the requested backup ID.' }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Get-ArchiveGenerationInventory([string]$Root) {
    $path = Resolve-ConfinedStorageFile $Root 'archive-generation-ids.txt'
    $file = Get-Item -LiteralPath $path -Force
    if ($file.Length -gt $MaxBackupArchiveGenerationInventoryBytes) {
        Fail 'Authenticated archive-generation inventory exceeds its size limit.'
    }
    $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $hasher = [Security.Cryptography.SHA256]::Create()
    $buffer = New-Object byte[] 65536
    $lineBuffer = New-Object byte[] 36
    [long]$bytesRead = 0
    [long]$count = 0
    $lineLength = 0
    $previous = $null
    try {
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $bytesRead += $read
            if ($bytesRead -gt $MaxBackupArchiveGenerationInventoryBytes) {
                Fail 'Authenticated archive-generation inventory exceeds its size limit.'
            }
            [void]$hasher.TransformBlock($buffer, 0, $read, $buffer, 0)
            for ($index = 0; $index -lt $read; $index++) {
                $value = $buffer[$index]
                if ($value -eq 10) {
                    if ($lineLength -ne 36) {
                        Fail 'Authenticated archive-generation inventory has noncanonical record framing.'
                    }
                    $line = [Text.Encoding]::ASCII.GetString($lineBuffer)
                    if ($line -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$') {
                        Fail 'Authenticated archive-generation inventory contains a noncanonical UUID.'
                    }
                    if ($null -ne $previous -and [string]::CompareOrdinal($previous, $line) -ge 0) {
                        Fail 'Authenticated archive-generation inventory is unsorted or contains duplicates.'
                    }
                    $previous = $line
                    $count++
                    if ($count -gt $MaxBackupArchiveGenerationIds) {
                        Fail 'Authenticated archive-generation inventory exceeds its entry limit.'
                    }
                    $lineLength = 0
                    continue
                }
                if ($lineLength -ge 36) {
                    Fail 'Authenticated archive-generation inventory has noncanonical record framing.'
                }
                $lineBuffer[$lineLength] = $value
                $lineLength++
            }
        }
        [void]$hasher.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        if ($lineLength -ne 0) {
            Fail 'Authenticated archive-generation inventory is not canonically newline terminated.'
        }
        if ($bytesRead -ne $file.Length -or $bytesRead -ne ($count * 37)) {
            Fail 'Authenticated archive-generation inventory has noncanonical record framing.'
        }
        $sha256 = ([BitConverter]::ToString($hasher.Hash)).Replace('-', '').ToLowerInvariant()
        return [pscustomobject]@{
            Count = $count
            Sha256 = $sha256
            Bytes = $bytesRead
        }
    } finally {
        $stream.Dispose()
        $hasher.Dispose()
    }
}

function Write-ArchiveGenerationInventory([string]$Root) {
    $path = Join-Path $Root 'archive-generation-ids.txt'
    Write-PsqlLinesToFile "SELECT id::text FROM oscar_archive_generation WHERE state IN ('ACTIVE','SEALED') ORDER BY id LIMIT $($MaxBackupArchiveGenerationIds + 1);" $path
    [void](Get-ArchiveGenerationInventory $Root)
}

function Set-VerifiedBackupEpochReceipt(
    [string]$Root,
    [string]$Id,
    [string]$EpochId,
    [string]$PostgresLsn
) {
    if (-not (Test-BackupId $Id) -or -not (Test-Uuid $EpochId) -or $PostgresLsn -notmatch '^[0-9A-F]+/[0-9A-F]+$') {
        Fail 'Authenticated backup epoch fields are invalid for the live verification receipt.'
    }
    $epochHash = (Get-FileHash -LiteralPath (Join-Path $Root 'epoch.json') -Algorithm SHA256).Hash.ToLowerInvariant()
    $inventory = Get-ArchiveGenerationInventory $Root
    Assert-DeploymentVolumeOwnership
    $sql = @"
WITH upserted AS (
INSERT INTO oscar_backup_epoch(id,state,postgres_lsn,archive_generation_count,archive_generation_inventory_sha256,archive_generation_inventory_bytes,manifest_path,sha256,verified_at)
VALUES ('$EpochId','VERIFIED','$PostgresLsn',$($inventory.Count),'$($inventory.Sha256)',$($inventory.Bytes),'$Id/epoch.json','$epochHash',now())
ON CONFLICT (id) DO UPDATE SET
 state='VERIFIED',
 verified_at=CASE WHEN oscar_backup_epoch.state='VERIFIED' THEN oscar_backup_epoch.verified_at ELSE now() END
WHERE oscar_backup_epoch.state IN ('CREATED','VERIFIED')
  AND oscar_backup_epoch.postgres_lsn IS NOT DISTINCT FROM EXCLUDED.postgres_lsn
  AND oscar_backup_epoch.archive_generation_count IS NOT DISTINCT FROM EXCLUDED.archive_generation_count
  AND oscar_backup_epoch.archive_generation_inventory_sha256 IS NOT DISTINCT FROM EXCLUDED.archive_generation_inventory_sha256
  AND oscar_backup_epoch.archive_generation_inventory_bytes IS NOT DISTINCT FROM EXCLUDED.archive_generation_inventory_bytes
  AND oscar_backup_epoch.manifest_path IS NOT DISTINCT FROM EXCLUDED.manifest_path
  AND oscar_backup_epoch.sha256 IS NOT DISTINCT FROM EXCLUDED.sha256
RETURNING id::text||'|'||state
)
SELECT * FROM upserted;
"@
    $receipt = Invoke-PsqlScript $sql
    if ($receipt -cne "$EpochId|VERIFIED") {
        Fail 'Backup epoch UUID already exists with a foreign identity/state; no catalog row was changed.'
    }
}

function Get-ReleaseConfigVersion([string]$Root, [string]$Image) {
    $script = "tar -xOzf /backup/release-config.tar.gz .env.example | sed -n 's/^OSCAR_VERSION=//p' | head -n 1"
    $output = Get-DockerShellInputOutput $script @('run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--workdir', '/', '--user', '0', '--entrypoint', 'sh', '--volume', "${Root}:/backup:ro", $Image, '-seu')
    return (($output -join "`n").Trim())
}

function Assert-RestoreCompatibility([string]$Root) {
    $current = Get-EnvValue 'OSCAR_VERSION' 'unknown'
    $image = "oscar:$current"
    Assert-LocalImage $image
    Confirm-ReleaseConfigArchive $Root $image
    $releaseConfig = Get-ReleaseConfigVersion $Root $image
    $epoch = Get-Content -LiteralPath (Join-Path $Root 'epoch.json') -Raw | ConvertFrom-Json
    $backup = [string]$epoch.oscarVersion
    if ($current -cne $RequiredReleaseVersion -or $backup -cne $RequiredReleaseVersion -or $releaseConfig -cne $RequiredReleaseVersion) {
        Fail "Destructive restore requires exact $RequiredReleaseVersion identity (current=$current, backup=$backup, release-config=$releaseConfig)."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'SHA256SUMS.hmac') -PathType Leaf)) {
        Fail "OSCAR $RequiredReleaseVersion restore requires SHA256SUMS.hmac; this backup is legacy or incomplete."
    }
    foreach ($requiredImage in @(Get-ComposeOutput @('config', '--images') | Sort-Object -Unique)) {
        if ($requiredImage) { Assert-LocalImage $requiredImage }
    }
    Confirm-ImageInventory $Root -CompareCurrent
}

function Confirm-DailyJournalBackup([string]$Id, [string]$Root, [string]$Image, [string]$OscarStateSha256) {
    if ($OscarStateSha256 -notmatch '^[0-9a-f]{64}$') { Fail 'Authenticated oscar-state.tar.gz SHA-256 is missing.' }
    $snapshotVolume = "oscar_journal_confirm_$([Guid]::NewGuid().ToString('N'))"
    $volumeCreated = $false
    $running = @(Get-ComposeOutput @('ps', '--status', 'running', '--services'))
    $resumeOscar = $running -contains 'oscar'
    $resumeGateway = $running -contains 'gateway'
    $resumePostgres = $running -contains 'postgres'
    if (-not $resumePostgres) { Fail 'PostgreSQL must be running to create a coordinated backup.' }
    try {
        Invoke-External 'docker' @('volume', 'create', $snapshotVolume)
        $volumeCreated = $true
        if ($resumeGateway) { Invoke-Compose @('stop', 'gateway') }
        if ($resumeOscar) { Invoke-Compose @('stop', 'oscar') }
        $validation = 'exec sh /validate-storage-archive.sh oscar-state /oscar-state.tar.gz'
        Invoke-DockerShellInput $validation @('run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--tmpfs', $ValidatorScratchTmpfs, '--env', 'TMPDIR=/tmp', '--workdir', '/', '--user', '0', '--entrypoint', 'sh', '--volume', "$(Join-Path $Root 'oscar-state.tar.gz'):/oscar-state.tar.gz:ro", '--volume', "$(Join-Path $ScriptRoot 'validate-storage-archive.sh'):/validate-storage-archive.sh:ro", $Image, '-seu')
        $extract = 'umask 077; tar --no-same-owner -C /snapshot -xzf /oscar-state.tar.gz; find /snapshot -type d -exec chmod 0700 {} +; find /snapshot -type f -exec chmod 0600 {} +; chown -R 10001:10001 /snapshot'
        Invoke-DockerShellInput $extract @('run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--cap-add', 'CHOWN', '--security-opt', 'no-new-privileges', '--workdir', '/', '--user', '0', '--entrypoint', 'sh', '--volume', "$(Join-Path $Root 'oscar-state.tar.gz'):/oscar-state.tar.gz:ro", '--volume', "${snapshotVolume}:/snapshot", $Image, '-seu')
        Invoke-External 'docker' @('run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--tmpfs', '/tmp:rw,noexec,nosuid,nodev', '--user', '10001:10001', '--entrypoint', 'java', '--volume', 'oscar_oscar_state:/var/lib/oscar', '--volume', "${snapshotVolume}:/verified-snapshot:ro", $Image, '-cp', '/opt/oscar/lib/*', 'com.botts.impl.service.dailyfile.DailyFileBackupConfirmationCli', '/var/lib/oscar', '/verified-snapshot', $Id, $OscarStateSha256)
    } finally {
        if ($volumeCreated) {
            try { Invoke-External 'docker' @('volume', 'rm', '--force', $snapshotVolume) }
            catch { Write-Warning "Could not remove temporary daily-file journal confirmation volume ${snapshotVolume}: $($_.Exception.Message)" }
        }
        $services = @()
        if ($resumeOscar) { $services += 'oscar' }
        if ($resumeGateway) { $services += 'gateway' }
        if ($services.Count -gt 0) {
            try { Invoke-Compose (@('up', '--detach', '--no-build', '--pull', 'never', '--wait', '--wait-timeout', '300') + $services) }
            catch { Write-Warning "Could not resume services after daily-file backup confirmation: $($_.Exception.Message)"; throw }
        }
    }
}

function Complete-NewBackupAcceptance([string]$Id, [string]$Root, [string]$Image, [string]$OscarStateSha256) {
    # CURRENT publication is last. The immutable core first passes every
    # checksum/HMAC/archive/pg_verifybackup/image check and commits VERIFIED in
    # both the filesystem and live catalog. The post-verification journal audit
    # receipt is outside SHA256SUMS and authenticates itself with the backup key.
    Confirm-Backup $Id
    Confirm-DailyJournalBackup $Id $Root $Image $OscarStateSha256
    Write-JournalConfirmationReceipt $Root $Id $OscarStateSha256 $Image
    Confirm-JournalConfirmationReceipt $Root $Id $OscarStateSha256 $Image
}

function New-Backup {
    Assert-Administrator; Assert-Configured; Assert-BackupModeEnabled
    Assert-CanonicalCredentialBindings (Join-Path $ScriptRoot '.env')
    Assert-BackupKey; Assert-DeploymentVolumeOwnership; Initialize-StorageDirectories
    $version = Get-EnvValue 'OSCAR_VERSION' 'unknown'
    $templateVersion = Get-ReleaseTemplateVersion
    if ($version -cne $RequiredReleaseVersion -or $templateVersion -cne $RequiredReleaseVersion) {
        Fail "Backup requires OSCAR $RequiredReleaseVersion in both .env and .env.example (current=$version, release-config=$templateVersion)."
    }
    $image = "oscar:$version"
    $postgresImage = Get-PostgresImage
    Assert-LocalImage $image
    Assert-LocalImage $postgresImage
    Invoke-SingleBackupRecoveryCleanup
    $timestamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $randomBytes = New-Object byte[] 4
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($randomBytes) } finally { $rng.Dispose() }
    $suffix = ([BitConverter]::ToString($randomBytes)).Replace('-', '').ToLowerInvariant()
    $id = "$timestamp-$suffix"
    $work = Join-Path $BackupDirectory "$id.partial"
    $final = Join-Path $BackupDirectory $id
    if ((Test-Path -LiteralPath $work) -or (Test-Path -LiteralPath $final)) { Fail "Backup destination already exists: $id" }
    New-Item -ItemType Directory -Path $work | Out-Null
    Protect-DockerStorageDirectory $work 'ReadWrite'
    New-Item -ItemType Directory -Path (Join-Path $work 'postgres') | Out-Null
    foreach ($name in @('oscar-state.tar.gz', 'archive.tar.gz')) {
        [IO.File]::WriteAllBytes((Join-Path $work $name), [byte[]]@())
    }

    $running = @(Get-ComposeOutput @('ps', '--status', 'running', '--services'))
    $resumeOscar = $running -contains 'oscar'
    $resumeGateway = $running -contains 'gateway'
    $resumePostgres = $running -contains 'postgres'
    if (-not $resumePostgres) { Fail 'PostgreSQL must be running to create a coordinated backup.' }
    try {
        if ($resumeGateway) { Invoke-Compose @('stop', 'gateway') }
        if ($resumeOscar) { Invoke-Compose @('stop', 'oscar') }
        # Quiesce writers first, then require the catalog and every immutable
        # archive object to agree before either side is snapshotted.
        Confirm-ArchiveObjects -RejectPartials
        Write-ArchiveGenerationInventory $work
        $lsn = Invoke-Psql 'SELECT pg_current_wal_lsn();'
        $epochId = Invoke-Psql 'SELECT gen_random_uuid();'
        if (-not (Test-Uuid $epochId)) { Fail 'PostgreSQL did not return a valid backup epoch ID.' }
        $postgresContainers = @(Get-ComposeOutput @('ps', '--quiet', 'postgres'))
        if ($postgresContainers.Count -ne 1 -or $postgresContainers[0] -notmatch '^[0-9a-f]{12,64}$') {
            Fail 'Could not resolve the running PostgreSQL container for pg_basebackup.'
        }
        $postgresContainer = $postgresContainers[0]
        $basebackup = 'PGPASSWORD=$(cat /run/secrets/postgres_bootstrap_password); export PGPASSWORD; exec pg_basebackup --pgdata=/backup --username=oscar_bootstrap --dbname="host=127.0.0.1 port=5432 dbname=gis" --format=plain --wal-method=stream --checkpoint=fast'
        Invoke-DockerShellInput $basebackup @('run', '--rm', '--network', "container:$postgresContainer", '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--tmpfs', '/tmp:rw,noexec,nosuid,nodev', '--user', '999:999', '--entrypoint', 'sh', '--volume', "$(Join-Path $work 'postgres'):/backup", '--volume', "$(Join-Path $ScriptRoot 'secrets/postgres-bootstrap-password.txt'):/run/secrets/postgres_bootstrap_password:ro", $postgresImage, '-seu')
        Invoke-Compose @('stop', 'postgres')
        $stateArchive = @'
for entry in lib web rules documentation trusted_certificates config logback.xml; do
    if [ -L "/state/$entry" ]; then
        [ "$(readlink "/state/$entry")" = "/opt/oscar/$entry" ] || { echo "Unexpected OSCAR state symlink target: $entry" >&2; exit 1; }
    elif [ -e "/state/$entry" ]; then
        echo "Reserved OSCAR image-owned state path is not the expected symlink: $entry" >&2; exit 1
    fi
done
tar --exclude='./archive' --exclude='./backups' --exclude='./duckdb-tmp' --exclude='./lib' --exclude='./web' --exclude='./rules' --exclude='./documentation' --exclude='./trusted_certificates' --exclude='./config' --exclude='./logback.xml' -C /state -czf /output.tar.gz .
'@
        Invoke-DockerShellInput $stateArchive @('run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--user', '10001:10001', '--entrypoint', 'sh', '--volume', 'oscar_oscar_state:/state:ro', '--volume', "$(Join-Path $work 'oscar-state.tar.gz'):/output.tar.gz", $image, '-seu')
        Invoke-DockerShellInput "tar --exclude='./.oscar-storage-root' -C /archive -czf /output.tar.gz ." @('run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--user', '10001:10001', '--entrypoint', 'sh', '--volume', "${ArchiveDirectory}:/archive:ro", '--volume', "$(Join-Path $work 'archive.tar.gz'):/output.tar.gz", $image, '-seu')

    $encryptedSecrets = Join-Path $work 'deployment-secrets.tar.gz.enc'
    [IO.File]::WriteAllBytes($encryptedSecrets, [byte[]]@())
    $encryptSecrets = 'tar -C /deployment -czf - .env secrets tls | openssl enc -aes-256-cbc -pbkdf2 -salt -pass file:/backup-key.txt -out /deployment-secrets.tar.gz.enc'
    Invoke-DockerShellInput $encryptSecrets @('run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--workdir', '/', '--user', '0', '--entrypoint', 'sh', '--volume', "${ScriptRoot}:/deployment:ro", '--volume', "${encryptedSecrets}:/deployment-secrets.tar.gz.enc", '--volume', "${BackupKeyFile}:/backup-key.txt:ro", $image, '-seu')
    $releaseConfigFiles = @(
        '.dockerignore', '.env.example', 'DEPLOYMENT.md', 'QUICKSTART.md', 'compose.yaml',
        'docker/gateway/default.conf', 'docker/oscar/archive-object-helper.sh', 'docker/oscar/atomic-publish.c', 'docker/oscar/Dockerfile', 'docker/oscar/entrypoint.sh',
        'oscar-setup.ps1', 'oscar-setup.sh', 'oscar-storage.ps1', 'oscar-storage.sh', 'oscar.bat', 'oscar.sh',
        'postgis/Dockerfile', 'postgis/archive-wal.sh', 'postgis/merge-wal-restore.sh', 'postgis/prepare-restore.sh', 'postgis/init-app-role.sh', 'postgis/init-extensions.sql', 'validate-storage-archive.sh'
    )
    $releaseConfigArchive = Join-Path $work 'release-config.tar.gz'
    [IO.File]::WriteAllBytes($releaseConfigArchive, [byte[]]@())
    Invoke-External 'docker' (@('run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--workdir', '/', '--user', '0', '--entrypoint', 'tar', '--volume', "${ScriptRoot}:/deployment:ro", '--volume', "${releaseConfigArchive}:/release-config.tar.gz", $image, '-C', '/deployment', '-czf', '/release-config.tar.gz') + $releaseConfigFiles)

    $epoch = [ordered]@{
        format = 'oscar-backup-epoch'; version = 2; backupEpochId = $epochId; backupId = $id
        createdAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); oscarVersion = $version
        postgresLsn = $lsn; archiveRoot = '/var/lib/oscar/archive'; secrets = 'AES-256-CBC/PBKDF2 with HMAC-SHA-256 manifest authentication; key stored separately'; state = 'CREATED'
    }
    [IO.File]::WriteAllText((Join-Path $work 'epoch.json'), ($epoch | ConvertTo-Json) + "`n", $Utf8NoBom)
    Write-ImageInventory $work
    $oscarStateSha256 = (Get-FileHash -LiteralPath (Join-Path $work 'oscar-state.tar.gz') -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Checksums $work
    Write-ChecksumHmac $work $image
    Confirm-Backup $id -ReadOnly -RootOverride $work
    Protect-DockerStorageDirectory $work 'ReadOnly'
    Sync-DurableTree $work
    Move-DurableNoReplace $work $final
    if ($resumePostgres) {
        Invoke-Compose @('up', '--detach', '--no-deps', '--no-build', '--pull', 'never', '--wait', '--wait-timeout', '300', 'postgres')
        $resumePostgres = $false
    }
    $epochHash = (Get-FileHash -LiteralPath (Join-Path $final 'epoch.json') -Algorithm SHA256).Hash.ToLowerInvariant()
    $inventory = Get-ArchiveGenerationInventory $final
    try {
        Assert-DeploymentVolumeOwnership
        Invoke-PsqlScript "INSERT INTO oscar_backup_epoch(id,state,postgres_lsn,archive_generation_count,archive_generation_inventory_sha256,archive_generation_inventory_bytes,manifest_path,sha256) VALUES ('$epochId','CREATED','$lsn',$($inventory.Count),'$($inventory.Sha256)',$($inventory.Bytes),'$id/epoch.json','$epochHash');" | Out-Null
    } catch {
        Write-Warning "Backup payload is complete, but its live catalog receipt could not be inserted: $($_.Exception.Message)"
    }
    Complete-NewBackupAcceptance $id $final $image $oscarStateSha256
    Write-CurrentBackupPointer $id $image
    Invoke-SingleBackupRecoveryCleanup
    Write-Host "Backup created and committed as CURRENT: $final" -ForegroundColor Green
    Write-Host "Store $BackupKeyFile separately from the backup media; it is required to restore encrypted credentials."
    } finally {
        $services = @()
        if ($resumePostgres) { $services += 'postgres' }
        if ($resumeOscar) { $services += 'oscar' }
        if ($resumeGateway) { $services += 'gateway' }
        if ($services.Count -gt 0) { Invoke-Compose (@('up', '--detach', '--no-build', '--pull', 'never', '--wait', '--wait-timeout', '300') + $services) }
    }
}

function Confirm-BackupManifestInventory([string]$Root, [string[]]$ManifestPaths) {
    if (@($ManifestPaths | Sort-Object -Unique).Count -ne $ManifestPaths.Count) {
        Fail 'Authenticated checksum manifest contains duplicate paths.'
    }
    $actual = New-Object System.Collections.Generic.List[string]
    foreach ($item in @(Get-ChildItem -LiteralPath $Root -Force -Recurse)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Fail "Backup contains a reparse point: $($item.FullName)"
        }
        $relative = $item.FullName.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/')
        if ($relative.StartsWith('.VERIFIED.', [StringComparison]::Ordinal) -or
            $relative.StartsWith('.JOURNAL_CONFIRMED.', [StringComparison]::Ordinal)) {
            if ($relative -cnotmatch '^\.(VERIFIED|JOURNAL_CONFIRMED)\.[0-9a-f]{32}$') {
                Fail "Malformed backup acceptance temporary was preserved: $($item.FullName)"
            }
            if ($item.PSIsContainer -or $item -isnot [IO.FileInfo]) {
                Fail "Backup acceptance temporary is unsafe: $($item.FullName)"
            }
            Assert-BackupCleanupAcl $item.FullName 'backup acceptance temporary'
            continue
        }
        if ($item.PSIsContainer) { continue }
        if ($item -isnot [IO.FileInfo]) { Fail "Backup contains a non-regular entry: $($item.FullName)" }
        if ($relative -in @('VERIFIED','JOURNAL_CONFIRMED','SHA256SUMS','SHA256SUMS.hmac')) { continue }
        if (-not (Test-RelativeObjectPath $relative)) { Fail "Unsafe backup filesystem path: $relative" }
        $actual.Add($relative)
    }
    $expectedSorted = @($ManifestPaths | Sort-Object)
    $actualSorted = @($actual | Sort-Object)
    if ($expectedSorted.Count -ne $actualSorted.Count -or
        [string]::Join("`n", $expectedSorted) -cne [string]::Join("`n", $actualSorted)) {
        Fail 'Authenticated checksum manifest does not exactly cover every backup payload file.'
    }
}

function Confirm-PostgresBaseBackup([string]$Root, [string]$PostgresImage) {
    # The published backup is deliberately normalized to administrator-owned
    # mode-0600/0700 files. Docker Desktop can instead expose a freshly written
    # base backup as UID/GID 999. Use a networkless, read-only root verifier
    # with only DAC_READ_SEARCH so either private representation is readable
    # without granting write access or weakening the backup on the host.
    Invoke-External 'docker' @('run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--cap-add', 'DAC_READ_SEARCH', '--security-opt', 'no-new-privileges', '--workdir', '/', '--user', '0:0', '--entrypoint', 'pg_verifybackup', '--volume', "$(Join-Path $Root 'postgres'):/backup:ro", $PostgresImage, '/backup')
}

function Read-ValidatedBackupEpoch([string]$Root, [string]$Id) {
    $epochPath = Resolve-ConfinedStorageFile $Root 'epoch.json'
    $epochRaw = [IO.File]::ReadAllText($epochPath)
    if (@([IO.File]::ReadAllLines($epochPath)).Count -ne 12) {
        Fail 'Backup epoch must use the exact supported 12-line field shape.'
    }
    try { $epoch = $epochRaw | ConvertFrom-Json }
    catch { Fail 'Backup epoch manifest is not valid JSON.' }
    $epochKeys = @('format','version','backupEpochId','backupId','createdAt','oscarVersion','postgresLsn','archiveRoot','secrets','state')
    if (@($epoch.PSObject.Properties).Count -ne $epochKeys.Count) { Fail 'Backup epoch must contain exactly the version-1/version-2 field set.' }
    foreach ($epochKey in $epochKeys) {
        if (@($epoch.PSObject.Properties | Where-Object Name -CEQ $epochKey).Count -ne 1 -or
            ([regex]::Matches($epochRaw, '(?m)^\s*"' + [regex]::Escape($epochKey) + '"\s*:')).Count -ne 1) {
            Fail "Backup epoch must contain exactly one $epochKey field."
        }
    }
    [int]$schemaVersion = 0
    try { $schemaVersion = [int]$epoch.version } catch { Fail 'Backup epoch schema version is invalid.' }
    if (-not (Test-Uuid ([string]$epoch.backupEpochId)) -or
        [string]$epoch.format -cne 'oscar-backup-epoch' -or $schemaVersion -notin @(1, 2) -or
        [string]$epoch.backupId -cne $Id -or [string]$epoch.state -cne 'CREATED') {
        Fail 'Backup epoch identity, schema version, or creation state does not match this recovery-point directory.'
    }
    if ([string]$epoch.oscarVersion -cne $RequiredReleaseVersion) { Fail "Backup epoch must identify OSCAR $RequiredReleaseVersion." }
    if ([string]$epoch.postgresLsn -notmatch '^[0-9A-F]+/[0-9A-F]+$') { Fail 'Backup epoch PostgreSQL LSN is invalid.' }
    return [pscustomobject]@{ Epoch = $epoch; Raw = $epochRaw; SchemaVersion = $schemaVersion }
}

function Confirm-BackupAcceptanceSidecars(
    [string]$Root,
    [string]$Id,
    [string]$OscarStateSha256,
    [string]$Image
) {
    $marker = Join-Path $Root 'VERIFIED'
    Assert-AdministratorFile $marker 'VERIFIED marker'
    $markerRaw = [IO.File]::ReadAllText($marker)
    if ($markerRaw -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\n\z' -or
        -not (Test-ExactUtf8NoBomFile $marker $markerRaw)) {
        Fail 'VERIFIED marker is malformed.'
    }
    Confirm-JournalConfirmationReceipt $Root $Id $OscarStateSha256 $Image
}

function Confirm-Backup(
    [string]$Id,
    [switch]$ReadOnly,
    [string]$RootOverride,
    [switch]$RequireAcceptance
) {
    Assert-Administrator; Assert-Configured; Assert-BackupKey
    if (-not (Test-BackupId $Id)) { Fail 'A valid backup ID is required.' }
    $expectedFinal = [IO.Path]::GetFullPath((Join-Path $BackupDirectory $Id))
    $expectedPartial = [IO.Path]::GetFullPath((Join-Path $BackupDirectory "$Id.partial"))
    $expectedDeleting = [IO.Path]::GetFullPath((Join-Path $BackupDirectory ".deleting-$Id"))
    $root = if ($RootOverride) { [IO.Path]::GetFullPath($RootOverride) } else { $expectedFinal }
    if ($root -cne $expectedFinal -and $root -cne $expectedPartial -and
        (-not $ReadOnly -or $root -cne $expectedDeleting)) {
        Fail 'Backup verification root is not a confined final, staging, or read-only deletion snapshot path.'
    }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { Fail "Backup does not exist: $root" }
    $rootItem = Get-Item -LiteralPath $root -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Fail "Backup root is a reparse point: $root" }
    Assert-NoReparseComponents $root
    $checksumFile = Join-Path $root 'SHA256SUMS'
    if (-not (Test-Path -LiteralPath $checksumFile -PathType Leaf)) { Fail "Backup is incomplete: $root" }
    $image = Get-OscarImage
    $postgresImage = Get-PostgresImage
    Assert-LocalImage $image
    Assert-LocalImage $postgresImage
    Confirm-ChecksumHmac $root $image
    $epochInfo = Read-ValidatedBackupEpoch $root $Id
    $schemaVersion = [int]$epochInfo.SchemaVersion
    $manifestPaths = New-Object System.Collections.Generic.List[string]
    $oscarStateSha256 = $null
    $oscarStateEntries = 0
    $requiredPayloadCounts = @{
        'archive.tar.gz' = 0; 'archive-generation-ids.txt' = 0; 'deployment-secrets.tar.gz.enc' = 0; 'epoch.json' = 0
        'image-inventory.txt' = 0; 'oscar-state.tar.gz' = 0; 'release-config.tar.gz' = 0
    }
    if ($schemaVersion -eq 1) { $requiredPayloadCounts['wal-archive.tar.gz'] = 0 }
    foreach ($line in [IO.File]::ReadAllLines($checksumFile)) {
        if ($line -notmatch '^([0-9a-f]{64})  \./(.+)$') { Fail "Invalid checksum entry: $line" }
        $manifestPaths.Add($Matches[2])
        $path = Resolve-ConfinedStorageFile $root $Matches[2]
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -cne $Matches[1]) { Fail "Backup checksum mismatch: $($Matches[2])" }
        if ($Matches[2] -ceq 'oscar-state.tar.gz') {
            $oscarStateSha256 = $Matches[1]
            $oscarStateEntries++
        }
        if ($requiredPayloadCounts.ContainsKey($Matches[2])) { $requiredPayloadCounts[$Matches[2]]++ }
    }
    foreach ($payload in $requiredPayloadCounts.Keys) {
        if ($requiredPayloadCounts[$payload] -ne 1) { Fail "Authenticated checksum manifest must contain $payload exactly once." }
    }
    if ($schemaVersion -eq 2 -and
        (($manifestPaths -contains 'wal-archive.tar.gz') -or (Test-Path -LiteralPath (Join-Path $root 'wal-archive.tar.gz')))) {
        Fail 'Schema-version-2 backups must not contain wal-archive.tar.gz.'
    }
    [void](Get-ArchiveGenerationInventory $root)
    Confirm-BackupManifestInventory $root $manifestPaths
    Confirm-PostgresBaseBackup $root $postgresImage
    Confirm-ReleaseConfigArchive $root $image
    Confirm-BackupArchiveMembers $root $image $schemaVersion
    Confirm-ImageInventory $root
    $epoch = $epochInfo.Epoch
    if ($RequireAcceptance) {
        if ($schemaVersion -ne 2) { Fail 'Single-backup acceptance requires schema version 2.' }
        Confirm-BackupAcceptanceSidecars $root $Id $oscarStateSha256 $image
    } else {
        $journalReceipt = Join-Path $root 'JOURNAL_CONFIRMED'
        if (Test-Path -LiteralPath $journalReceipt) {
            try { Confirm-JournalConfirmationReceipt $root $Id $oscarStateSha256 $image }
            catch { Write-Warning "Post-verification journal-confirmation audit sidecar is invalid; the authenticated recovery core remains usable: $($_.Exception.Message)" }
        }
    }
    if (-not $ReadOnly) {
        $postgresRunning = $false
        try { $postgresRunning = @(Get-ComposeOutput @('ps', '--status', 'running', '--services')) -contains 'postgres' }
        catch { Write-Warning "Could not query the optional live backup-verification catalog: $($_.Exception.Message)" }
        if ($postgresRunning) {
            # Offline verification is allowed, but a discovered fixed-name
            # project must prove deployment ownership before either acceptance
            # state or the live catalog can be changed.
            Assert-DeploymentVolumeOwnership
        }
        Write-VerifiedMarker $root
        if ($postgresRunning) {
            try {
                Set-VerifiedBackupEpochReceipt $root $Id ([string]$epoch.backupEpochId) ([string]$epoch.postgresLsn)
            } catch {
                Remove-Item -LiteralPath (Join-Path $root 'VERIFIED') -Force -ErrorAction SilentlyContinue
                Sync-DurableMetadata $root
                Fail "The live backup-verification catalog receipt could not be committed; VERIFIED was removed: $($_.Exception.Message)"
            }
        }
        Protect-DockerStorageDirectory $root 'ReadOnly'
        Write-Host "Backup verified: $root" -ForegroundColor Green
    }
}

function Get-BackupCleanupDisposition([string]$Id, [string]$Root) {
    try {
        $null = Confirm-Backup $Id -ReadOnly -RootOverride $Root -WarningAction SilentlyContinue
    } catch {
        return [pscustomobject]@{ State = 'Preserve'; Reason = "incomplete or unauthenticated core: $($_.Exception.Message)" }
    }
    $epochInfo = Read-ValidatedBackupEpoch $Root $Id
    if ([int]$epochInfo.SchemaVersion -eq 1) {
        return [pscustomobject]@{ State = 'Legacy'; Reason = 'legacy schema-version-1 recovery point' }
    }
    if ([int]$epochInfo.SchemaVersion -ne 2) {
        return [pscustomobject]@{ State = 'Preserve'; Reason = 'unsupported authenticated backup schema' }
    }

    $stateLines = @([IO.File]::ReadAllLines((Join-Path $Root 'SHA256SUMS')) |
        Where-Object { $_ -cmatch '^[0-9a-f]{64}  \./oscar-state\.tar\.gz$' })
    if ($stateLines.Count -ne 1) {
        return [pscustomobject]@{ State = 'Preserve'; Reason = 'authenticated OSCAR-state checksum is missing' }
    }
    try {
        Confirm-BackupAcceptanceSidecars $Root $Id $stateLines[0].Substring(0, 64) (Get-OscarImage)
    } catch {
        return [pscustomobject]@{ State = 'Preserve'; Reason = "schema-version-2 acceptance is invalid: $($_.Exception.Message)" }
    }
    return [pscustomobject]@{ State = 'Accepted'; Reason = 'authenticated accepted schema-version-2 recovery point' }
}

function Assert-BackupCleanupAcl([string]$Path, [string]$Description) {
    $acl = Get-Acl -LiteralPath $Path
    $ownerSid = ([Security.Principal.NTAccount]$acl.Owner).Translate([Security.Principal.SecurityIdentifier]).Value
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $dockerSid = Get-DockerUsersSid
    $administratorSids = @($currentSid, 'S-1-5-18', 'S-1-5-32-544')
    $allowedSids = @($administratorSids + $dockerSid.Value)
    if ($ownerSid -notin $administratorSids) { Fail "$Description is not administrator-owned: $Path" }
    $writeMask = [Security.AccessControl.FileSystemRights]::WriteData -bor
        [Security.AccessControl.FileSystemRights]::AppendData -bor
        [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership
    foreach ($rule in $acl.Access) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
        $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        if ($sid -notin $allowedSids -and ($rule.FileSystemRights -band $writeMask) -ne 0) {
            Fail "$Description grants unsafe write or ownership rights: $Path"
        }
    }
}

function Assert-SafeBackupCleanupDirectory([string]$Path, [string]$ExpectedName, [string]$Description) {
    $expected = [IO.Path]::GetFullPath((Join-Path $BackupDirectory $ExpectedName))
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
        Fail "$Description is not a direct child of the authenticated backup root: $Path"
    }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { Fail "$Description is missing: $full" }
    $item = Get-Item -LiteralPath $full -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Fail "$Description is a reparse point: $full" }
    Assert-BackupCleanupAcl $full $Description
    Assert-RegularDirectoryTree $full $Description
}

function Remove-SafeBackupCleanupDirectory([string]$Path, [string]$ExpectedName, [string]$Description) {
    Assert-SafeBackupCleanupDirectory $Path $ExpectedName $Description
    Remove-DirectoryTreeLongPathSafe $Path $Description
    Sync-DurableMetadata $BackupDirectory
}

function Remove-BackupAcceptanceTemporaries([string]$Root, [string]$ExpectedName) {
    Assert-SafeBackupCleanupDirectory $Root $ExpectedName 'backup snapshot'
    $temporaries = New-Object System.Collections.Generic.List[object]
    foreach ($item in @(Get-ChildItem -LiteralPath $Root -Force)) {
        if ($item.Name.StartsWith('.VERIFIED.', [StringComparison]::Ordinal) -or
            $item.Name.StartsWith('.JOURNAL_CONFIRMED.', [StringComparison]::Ordinal)) {
            if ($item.Name -cnotmatch '^\.(VERIFIED|JOURNAL_CONFIRMED)\.[0-9a-f]{32}$') {
                Fail "Malformed backup acceptance temporary was preserved: $($item.FullName)"
            }
            if ($item.PSIsContainer -or $item -isnot [IO.FileInfo] -or
                ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Fail "Backup acceptance temporary is unsafe: $($item.FullName)"
            }
            Assert-BackupCleanupAcl $item.FullName 'backup acceptance temporary'
            $temporaries.Add($item)
        }
    }
    foreach ($item in $temporaries) {
        Remove-Item -LiteralPath $item.FullName -Force
        Sync-DurableMetadata $Root
    }
}

function Invoke-SingleBackupRecoveryCleanup {
    Assert-BackupModeEnabled
    Assert-StorageRootIdentity $BackupDirectory 'backup'
    $currentId = Read-CurrentBackupId -AllowMissing
    if ($currentId) {
        $currentRoot = Join-Path $BackupDirectory $currentId
        Confirm-Backup $currentId -ReadOnly -RequireAcceptance
        Remove-BackupAcceptanceTemporaries $currentRoot $currentId
    }

    $pointerTemps = New-Object System.Collections.Generic.List[object]
    $partialDirectories = New-Object System.Collections.Generic.List[object]
    $deletingPartialDirectories = New-Object System.Collections.Generic.List[object]
    $scratchDirectories = New-Object System.Collections.Generic.List[object]
    $deletingSnapshots = New-Object System.Collections.Generic.List[object]
    $deletingUncommittedV2Snapshots = New-Object System.Collections.Generic.List[object]
    $snapshotCandidates = New-Object System.Collections.Generic.List[object]
    $deletingSnapshotsToRemove = New-Object System.Collections.Generic.List[object]
    $deletingSnapshotsToRestore = New-Object System.Collections.Generic.List[object]
    $snapshotCandidatesToRemove = New-Object System.Collections.Generic.List[object]
    $acceptedWithoutCurrent = New-Object System.Collections.Generic.List[object]
    $deletingPartialIds = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $deletingSnapshotIds = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $deletingUncommittedV2Ids = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)

    foreach ($item in @(Get-ChildItem -LiteralPath $BackupDirectory -Force)) {
        $name = $item.Name
        if ($name -cmatch '^\.CURRENT\.tmp\.[0-9a-f]{32}$') {
            if ($item.PSIsContainer -or $item -isnot [IO.FileInfo]) { Fail "CURRENT temporary pointer is not a regular file: $($item.FullName)" }
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Fail "CURRENT temporary pointer is a reparse point: $($item.FullName)" }
            Assert-BackupCleanupAcl $item.FullName 'CURRENT temporary pointer'
            $pointerTemps.Add($item)
            continue
        }
        if ($name.StartsWith('.CURRENT.tmp.', [StringComparison]::Ordinal)) {
            Fail "Malformed CURRENT temporary pointer was preserved: $($item.FullName)"
        }
        if ($name -cmatch '^([0-9]{8}T[0-9]{6}Z-[0-9a-f]{8})\.partial$') {
            if (-not $item.PSIsContainer) { Fail "Backup partial is not a directory: $($item.FullName)" }
            $partialDirectories.Add([pscustomobject]@{ Item = $item; Id = $Matches[1] })
            continue
        }
        if ($name -cmatch '^\.deleting-partial-([0-9]{8}T[0-9]{6}Z-[0-9a-f]{8})$') {
            if (-not $item.PSIsContainer) { Fail "Deleting backup partial is not a directory: $($item.FullName)" }
            [void]$deletingPartialIds.Add($Matches[1])
            $deletingPartialDirectories.Add([pscustomobject]@{ Item = $item; Id = $Matches[1] })
            continue
        }
        if ($name -cmatch '^\.(journal-confirm|restore-payload)-([0-9]{8}T[0-9]{6}Z-[0-9a-f]{8})-([0-9a-f]{32})$') {
            if (-not $item.PSIsContainer) { Fail "Backup recovery scratch entry is not a directory: $($item.FullName)" }
            $scratchDirectories.Add($item)
            continue
        }
        if ($name -cmatch '^\.deleting-uncommitted-v2-([0-9]{8}T[0-9]{6}Z-[0-9a-f]{8})$') {
            if (-not $item.PSIsContainer) { Fail "Deleting uncommitted schema-version-2 snapshot is not a directory: $($item.FullName)" }
            [void]$deletingUncommittedV2Ids.Add($Matches[1])
            $deletingUncommittedV2Snapshots.Add([pscustomobject]@{ Item = $item; Id = $Matches[1] })
            continue
        }
        if ($name -cmatch '^\.deleting-([0-9]{8}T[0-9]{6}Z-[0-9a-f]{8})$') {
            if (-not $item.PSIsContainer) { Fail "Deleting backup snapshot is not a directory: $($item.FullName)" }
            [void]$deletingSnapshotIds.Add($Matches[1])
            $deletingSnapshots.Add([pscustomobject]@{ Item = $item; Id = $Matches[1] })
            continue
        }
        if (Test-BackupId $name) {
            if (-not $item.PSIsContainer) { Fail "Backup snapshot is not a directory: $($item.FullName)" }
            if ($name -cne $currentId) { $snapshotCandidates.Add($item) }
            continue
        }
        if ($name -cmatch '^[0-9]{8}T' -or $name.StartsWith('.deleting-', [StringComparison]::Ordinal) -or
            $name.StartsWith('.journal-confirm-', [StringComparison]::Ordinal) -or
            $name.StartsWith('.restore-payload-', [StringComparison]::Ordinal)) {
            Fail "Malformed OSCAR backup recovery directory was preserved: $($item.FullName)"
        }
    }

    foreach ($partial in $partialDirectories) {
        if ($deletingPartialIds.Contains([string]$partial.Id)) {
            Fail "Both live and deleting partial directories exist for backup $($partial.Id)."
        }
        Assert-SafeBackupCleanupDirectory $partial.Item.FullName $partial.Item.Name 'backup partial'
        Write-Warning "Preserving incomplete backup staging candidate for operator review: $($partial.Item.FullName)"
    }
    foreach ($partial in $deletingPartialDirectories) {
        Assert-SafeBackupCleanupDirectory $partial.Item.FullName $partial.Item.Name 'deleting backup partial'
        Write-Warning "Preserving interrupted partial-backup deletion tombstone for operator review: $($partial.Item.FullName)"
    }
    foreach ($scratch in $scratchDirectories) {
        Assert-SafeBackupCleanupDirectory $scratch.FullName $scratch.Name 'backup recovery scratch directory'
    }
    foreach ($candidate in $snapshotCandidates) {
        if ($deletingSnapshotIds.Contains([string]$candidate.Name) -or
            $deletingUncommittedV2Ids.Contains([string]$candidate.Name)) {
            Fail "Both live and deleting snapshots exist for backup $($candidate.Name)."
        }
    }
    foreach ($deleting in $deletingSnapshots) {
        if ($deletingUncommittedV2Ids.Contains([string]$deleting.Id)) {
            Fail "Both legacy and uncommitted schema-version-2 deletion tombstones exist for backup $($deleting.Id)."
        }
    }
    foreach ($deleting in $deletingUncommittedV2Snapshots) {
        if ($deleting.Id -ceq $currentId) { Fail 'Refusing to delete an uncommitted tombstone whose ID matches CURRENT.' }
        Assert-SafeBackupCleanupDirectory $deleting.Item.FullName $deleting.Item.Name 'deleting uncommitted schema-version-2 snapshot'
        Write-Warning "Preserving legacy uncommitted schema-version-2 deletion tombstone for operator review: $($deleting.Item.FullName)"
    }
    foreach ($deleting in $deletingSnapshots) {
        Assert-SafeBackupCleanupDirectory $deleting.Item.FullName $deleting.Item.Name 'deleting backup snapshot'
        $disposition = Get-BackupCleanupDisposition $deleting.Id $deleting.Item.FullName
        if ($currentId) {
            if ($deleting.Id -ceq $currentId) { Fail 'Refusing to delete the authenticated CURRENT backup tombstone.' }
            if ($disposition.State -ceq 'Accepted') {
                $deletingSnapshotsToRemove.Add($deleting)
            } else {
                Write-Warning "Preserving backup deletion tombstone for operator review ($($disposition.Reason)): $($deleting.Item.FullName)"
            }
            continue
        }
        if ($disposition.State -ceq 'Legacy') {
            $deletingSnapshotsToRestore.Add($deleting)
        } elseif ($disposition.State -ceq 'Accepted') {
            $acceptedWithoutCurrent.Add([pscustomobject]@{ Item = $deleting.Item; Id = $deleting.Id; IsTombstone = $true })
        } else {
            Write-Warning "Preserving backup deletion tombstone for operator review ($($disposition.Reason)): $($deleting.Item.FullName)"
        }
    }
    foreach ($candidate in $snapshotCandidates) {
        Assert-SafeBackupCleanupDirectory $candidate.FullName $candidate.Name 'non-current backup snapshot'
        $disposition = Get-BackupCleanupDisposition $candidate.Name $candidate.FullName
        if ($disposition.State -ceq 'Accepted') {
            if ($currentId) {
                $snapshotCandidatesToRemove.Add($candidate)
            } else {
                $acceptedWithoutCurrent.Add([pscustomobject]@{ Item = $candidate; Id = $candidate.Name; IsTombstone = $false })
            }
        } elseif ($disposition.State -ceq 'Legacy') {
            Write-Warning "Preserving legacy schema-version-1 recovery point: $($candidate.FullName)"
        } else {
            Write-Warning "Preserving backup candidate for operator review ($($disposition.Reason)): $($candidate.FullName)"
        }
    }

    if (-not $currentId -and $acceptedWithoutCurrent.Count -gt 1) {
        Write-Warning 'Preserving multiple authenticated accepted schema-version-2 recovery points because CURRENT is missing.'
        Fail 'Cannot reconstruct CURRENT unambiguously; operator review is required.'
    }

    foreach ($pointerTemp in $pointerTemps) {
        Remove-Item -LiteralPath $pointerTemp.FullName -Force
        Sync-DurableMetadata $BackupDirectory
    }
    foreach ($scratch in $scratchDirectories) {
        Remove-SafeBackupCleanupDirectory $scratch.FullName $scratch.Name 'backup recovery scratch directory'
    }
    foreach ($deleting in $deletingSnapshotsToRestore) {
        if ($null -ne (Read-CurrentBackupId -AllowMissing)) { Fail 'CURRENT appeared during serialized snapshot cleanup.' }
        $destination = Join-Path $BackupDirectory $deleting.Id
        if (Test-Path -LiteralPath $destination) { Fail "Refusing to overwrite a restored legacy backup: $destination" }
        Move-DurableNoReplace $deleting.Item.FullName $destination
        Sync-DurableMetadata $BackupDirectory
        Write-Host "Restored authenticated legacy schema-version-1 backup: $($deleting.Id)"
    }
    if (-not $currentId) {
        if ($acceptedWithoutCurrent.Count -eq 1) {
            $accepted = $acceptedWithoutCurrent[0]
            Remove-BackupAcceptanceTemporaries $accepted.Item.FullName $accepted.Item.Name
            if ($accepted.IsTombstone) {
                $destination = Join-Path $BackupDirectory $accepted.Id
                if (Test-Path -LiteralPath $destination) { Fail "Refusing to overwrite a live backup while restoring accepted recovery point: $destination" }
                Move-DurableNoReplace $accepted.Item.FullName $destination
                Sync-DurableMetadata $BackupDirectory
            }
            Write-CurrentBackupPointer $accepted.Id (Get-OscarImage)
            Write-Host "Recovered authenticated CURRENT pointer for accepted schema-version-2 backup: $($accepted.Id)"
        }
    }
    foreach ($deleting in $deletingSnapshotsToRemove) {
        $observedCurrentId = Read-CurrentBackupId -AllowMissing
        if (($currentId -and $observedCurrentId -cne $currentId) -or
            (-not $currentId -and $null -ne $observedCurrentId)) {
            Fail 'CURRENT changed during serialized snapshot cleanup.'
        }
        Remove-SafeBackupCleanupDirectory $deleting.Item.FullName $deleting.Item.Name 'deleting backup snapshot'
    }
    foreach ($candidate in $snapshotCandidatesToRemove) {
        $observedCurrentId = Read-CurrentBackupId -AllowMissing
        if (($currentId -and $observedCurrentId -cne $currentId) -or
            (-not $currentId -and $null -ne $observedCurrentId)) {
            Fail 'CURRENT changed during serialized snapshot cleanup.'
        }
        $tombstoneName = ".deleting-$($candidate.Name)"
        $tombstone = Join-Path $BackupDirectory $tombstoneName
        Move-DurableNoReplace $candidate.FullName $tombstone
        Sync-DurableMetadata $BackupDirectory
        Remove-SafeBackupCleanupDirectory $tombstone $tombstoneName 'deleting backup snapshot'
        Write-Host "Removed authenticated accepted schema-version-2 non-current backup: $($candidate.Name)"
    }
}

function Remove-ExpiredBackups([int]$RequestedKeep) {
    Assert-BackupModeEnabled
    Fail 'backup-prune is retired in OSCAR_BACKUP_MODE=single; a successful backup atomically commits CURRENT and then removes only authenticated non-current snapshots.'
}

function Get-RestoreLocalEnvironmentKeys {
    return @(
        'OSCAR_DEPLOYMENT_ID',
        'OSCAR_POSTGIS_PLATFORM',
        'OSCAR_HTTPS_PORT',
        'OSCAR_HOSTNAME',
        'OSCAR_SECRETS_DIR',
        'OSCAR_TLS_DIR',
        'OSCAR_ARCHIVE_DIR',
        'OSCAR_BACKUP_MODE',
        'OSCAR_BACKUP_DIR',
        'OSCAR_BACKUP_KEY_FILE'
    )
}

function Assert-CanonicalCredentialBindings([string]$EnvironmentFile) {
    if (-not (Test-Path -LiteralPath $EnvironmentFile -PathType Leaf) -or
        ((Get-Item -LiteralPath $EnvironmentFile -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail "Deployment environment is not a regular file: $EnvironmentFile"
    }
    $lines = [IO.File]::ReadAllLines($EnvironmentFile)
    $expectedBindings = [ordered]@{
        OSCAR_SECRETS_DIR = './secrets'
        OSCAR_TLS_DIR = './tls'
        OSCAR_BACKUP_KEY_FILE = './secrets/backup-key.txt'
    }
    foreach ($entry in $expectedBindings.GetEnumerator()) {
        $matches = @($lines | Where-Object { $_ -match "^$([Regex]::Escape($entry.Key))=" })
        $value = if ($matches.Count -eq 1) { $matches[0].Substring($entry.Key.Length + 1) } else { $null }
        if ($matches.Count -ne 1 -or $value -cne $entry.Value) {
            Fail "$($entry.Key) must use the canonical supported binding $($entry.Value); no storage data or credentials were changed."
        }
    }
}

function Merge-RestoredEnvironment([string]$Restored, [string]$Target) {
    foreach ($path in @($Restored, $Target)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
            ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Fail "Restore environment is not a regular file: $path"
        }
    }
    Assert-CanonicalCredentialBindings $Target
    $targetLines = [IO.File]::ReadAllLines($Target)
    $bindings = New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    foreach ($name in @(Get-RestoreLocalEnvironmentKeys)) {
        $matches = @($targetLines | Where-Object { $_ -match "^$([Regex]::Escape($name))=" })
        if ($matches.Count -ne 1) { Fail "Target .env must contain exactly one $name binding before restore." }
        $value = $matches[0].Substring($name.Length + 1)
        if (-not $value) { Fail "Target .env has an empty $name binding; restore was not installed." }
        if ($name -ceq 'OSCAR_BACKUP_MODE' -and $value -cnotin @('disabled', 'single')) {
            Fail 'Target OSCAR_BACKUP_MODE must remain the literal lowercase value disabled or single.'
        }
        if ($name -in @('OSCAR_ARCHIVE_DIR', 'OSCAR_BACKUP_DIR') -and
            -not [IO.Path]::IsPathRooted($value)) {
            Fail "Target $name must be an absolute path before restore: $value"
        }
        $bindings.Add($name, $matches[0])
    }
    # The retired WAL root is not required by either backup schema. Preserve a
    # legacy target binding when one exists, but never import the source
    # deployment's path into a target that has already removed it.
    $optionalWalName = 'OSCAR_WAL_ARCHIVE_DIR'
    $optionalWalMatches = @($targetLines | Where-Object { $_ -match "^$optionalWalName=" })
    if ($optionalWalMatches.Count -gt 1) { Fail "Target .env contains duplicate $optionalWalName bindings before restore." }
    if ($optionalWalMatches.Count -eq 1) {
        $optionalWalValue = $optionalWalMatches[0].Substring($optionalWalName.Length + 1)
        if (-not $optionalWalValue -or -not [IO.Path]::IsPathRooted($optionalWalValue)) {
            Fail "Target $optionalWalName must be an absolute path before restore: $optionalWalValue"
        }
        $bindings.Add($optionalWalName, $optionalWalMatches[0])
    }
    $deploymentId = $bindings['OSCAR_DEPLOYMENT_ID'].Substring('OSCAR_DEPLOYMENT_ID='.Length)
    if (-not (Test-ValidDeploymentId $deploymentId)) {
        Fail 'Target OSCAR_DEPLOYMENT_ID is invalid; restore was not installed.'
    }
    $merged = New-Object 'Collections.Generic.List[string]'
    $written = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($line in [IO.File]::ReadAllLines($Restored)) {
        $equals = $line.IndexOf('=')
        $name = if ($equals -gt 0) { $line.Substring(0, $equals) } else { '' }
        if ($bindings.ContainsKey($name)) {
            if ($written.Add($name)) { $merged.Add($bindings[$name]) }
        } elseif ($name -ceq $optionalWalName) {
            continue
        } else {
            $merged.Add($line)
        }
    }
    foreach ($name in @(Get-RestoreLocalEnvironmentKeys)) {
        if ($written.Add($name)) { $merged.Add($bindings[$name]) }
    }
    if ($bindings.ContainsKey($optionalWalName) -and $written.Add($optionalWalName)) {
        $merged.Add($bindings[$optionalWalName])
    }
    [IO.File]::WriteAllLines($Restored, $merged, $Utf8NoBom)
    Assert-CanonicalCredentialBindings $Restored
}

function Assert-RestoredDeploymentCredentials([string]$Source) {
    $sourceItem = Get-Item -LiteralPath $Source -Force -ErrorAction Stop
    if (-not $sourceItem.PSIsContainer -or
        ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail "Restored credential staging directory is invalid: $Source"
    }

    $environmentFile = Join-Path $Source '.env'
    $secretDirectory = Join-Path $Source 'secrets'
    $tlsDirectory = Join-Path $Source 'tls'
    if (-not (Test-Path -LiteralPath $environmentFile -PathType Leaf) -or
        ((Get-Item -LiteralPath $environmentFile -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail 'Restored credentials do not contain a regular .env file.'
    }
    foreach ($directory in @($secretDirectory, $tlsDirectory)) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container) -or
            ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Fail "Restored credentials do not contain a regular $((Split-Path -Leaf $directory)) directory."
        }
        foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force -Recurse)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Fail 'Restored credential trees contain a reparse point.'
            }
        }
    }
}

function Prepare-RestoredDeploymentCredentials([string]$Source, [string]$Destination) {
    $destinationItem = Get-Item -LiteralPath $Destination -Force -ErrorAction Stop
    if (-not $destinationItem.PSIsContainer -or
        ($destinationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail "Deployment directory is invalid: $Destination"
    }
    Merge-RestoredEnvironment (Join-Path $Source '.env') (Join-Path $Destination '.env')
    Assert-RestoredDeploymentCredentials $Source
}

function Install-PreparedDeploymentCredentials([string]$Source, [string]$Destination) {
    $destinationItem = Get-Item -LiteralPath $Destination -Force -ErrorAction Stop
    if (-not $destinationItem.PSIsContainer -or
        ($destinationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail "Deployment directory is invalid: $Destination"
    }
    Assert-CanonicalCredentialBindings (Join-Path $Destination '.env')
    Assert-RestoredDeploymentCredentials $Source
    Assert-CanonicalCredentialBindings (Join-Path $Source '.env')
    $environmentFile = Join-Path $Source '.env'
    $secretDirectory = Join-Path $Source 'secrets'
    $tlsDirectory = Join-Path $Source 'tls'

    # Stage every validated replacement beside the live paths before deleting
    # anything. A failed install deliberately leaves this private directory and
    # the pre-restore safety copy available for operator recovery.
    $stage = Join-Path $Destination ".credential-install-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $stage | Out-Null
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        Protect-PrivateDirectory $stage
    }
    $complete = $false
    try {
        Move-Item -LiteralPath $environmentFile, $secretDirectory, $tlsDirectory -Destination $stage
        foreach ($name in @('.env', 'secrets', 'tls')) {
            $live = Join-Path $Destination $name
            if (Test-Path -LiteralPath $live) {
                Remove-Item -LiteralPath $live -Recurse -Force
            }
        }
        Move-Item -LiteralPath (Join-Path $stage '.env'), (Join-Path $stage 'secrets'), (Join-Path $stage 'tls') -Destination $Destination
        $complete = $true
    } finally {
        if ($complete -and (Test-Path -LiteralPath $stage)) {
            Remove-Item -LiteralPath $stage -Recurse -Force
        }
    }
}

function Clear-RestoreRecoverySettings {
    foreach ($setting in @('restore_command', 'recovery_target', 'recovery_target_timeline', 'recovery_target_action')) {
        [void](Invoke-Psql "ALTER SYSTEM RESET $setting;")
    }
    [void](Invoke-Psql 'SELECT pg_reload_conf();')
}

function Assert-RestoreSettingsRemovedFromDataVolume {
    $script = 'test ! -e /data/recovery.signal; test ! -e /data/standby.signal; test ! -e /data/postgresql.auto.conf || ! grep -Eq "^[[:space:]]*(restore_command|recovery_target|recovery_target_timeline|recovery_target_action)[[:space:]]*=" /data/postgresql.auto.conf'
    Invoke-DockerShellInput $script @(
        'run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL',
        '--security-opt', 'no-new-privileges', '--user', '999:999', '--entrypoint', 'sh',
        '--volume', 'oscar_postgres_data:/data:ro', (Get-PostgresImage), '-seu')
}

function Confirm-CleanRestoredPostgresRuntime([UInt64]$ExpectedTimeline, [string]$ExpectedEpochId) {
    $status = @((Invoke-Psql "SELECT CASE WHEN pg_is_in_recovery() THEN '1' ELSE '0' END||'|'||timeline_id FROM pg_control_checkpoint();") -split '\|')
    [UInt64]$timeline = 0
    if ($status.Count -ne 2 -or $status[0] -cne '0' -or
        -not [UInt64]::TryParse($status[1], [ref]$timeline) -or $timeline -ne $ExpectedTimeline) {
        Fail "Restored PostgreSQL did not retain its promoted timeline across recovery cleanup (expected=$ExpectedTimeline, status=$($status -join '|'))."
    }

    $settings = Invoke-Psql "SELECT count(*) FILTER (WHERE (name='restore_command' AND setting='') OR (name='recovery_target' AND setting='') OR (name='recovery_target_timeline' AND setting='latest') OR (name='recovery_target_action' AND setting='pause'))||'|'||CASE WHEN bool_and(NOT pending_restart) THEN '1' ELSE '0' END FROM pg_settings WHERE name IN ('restore_command','recovery_target','recovery_target_timeline','recovery_target_action');"
    if ($settings -cne '4|1') {
        Fail "Restored PostgreSQL retained recovery settings after its cleanup restart: $settings"
    }

    if ((Invoke-Psql 'SHOW archive_mode;') -cne 'off') {
        Fail 'Restored PostgreSQL enabled external WAL archiving after its clean restart.'
    }
    $receipt = Invoke-Psql "SELECT state FROM oscar_backup_epoch WHERE id='$ExpectedEpochId'::uuid;"
    if ($receipt -cne 'VERIFIED') {
        Fail 'The post-promotion VERIFIED receipt did not survive checkpoint and clean restart.'
    }
}

function Confirm-RestoredPostgresTimeline(
    [UInt64]$SourceTimeline,
    [string]$Root,
    [string]$Id,
    [object]$Epoch
) {
    $status = Invoke-Psql "SELECT CASE WHEN pg_is_in_recovery() THEN '1' ELSE '0' END||'|'||timeline_id FROM pg_control_checkpoint();"
    $fields = @($status -split '\|')
    [UInt64]$currentTimeline = 0
    if ($fields.Count -ne 2 -or $fields[0] -cne '0' -or
        -not [UInt64]::TryParse($fields[1], [ref]$currentTimeline) -or $currentTimeline -le $SourceTimeline) {
        Fail "Restored PostgreSQL did not promote onto a fresh timeline (source=$SourceTimeline, status=$status)."
    }

    if ((Invoke-Psql 'SHOW archive_mode;') -cne 'off') {
        Fail 'Restored PostgreSQL must keep archive_mode off; external WAL archives are not part of schema-v1 or schema-v2 restore.'
    }

    # Recreate the authenticated VERIFIED row missing from the historical base
    # backup. This is the post-promotion semantic write whose durability is
    # proved by a checkpoint and the clean restart below.
    Set-VerifiedBackupEpochReceipt $Root $Id ([string]$Epoch.backupEpochId) ([string]$Epoch.postgresLsn)
    if ((Invoke-Psql "SELECT state FROM oscar_backup_epoch WHERE id='$([string]$Epoch.backupEpochId)'::uuid;") -cne 'VERIFIED') {
        Fail 'Restored PostgreSQL did not commit the post-promotion VERIFIED receipt.'
    }
    [void](Invoke-Psql 'CHECKPOINT;')
    Clear-RestoreRecoverySettings
    return [pscustomobject]@{
        Timeline = $currentTimeline
        EpochId = [string]$Epoch.backupEpochId
    }
}

function Restore-Backup([string]$Id, [string]$Confirmation) {
    Assert-Administrator; Assert-Configured; Assert-BackupModeEnabled; Assert-BackupKey
    if (-not (Test-BackupId $Id) -or $Confirmation -cne $Id) { Fail "Restore is destructive. Supply -BackupId ID -Confirm ID with the same valid backup ID." }
    Assert-DeploymentVolumeOwnership
    $root = Join-Path $BackupDirectory $Id
    $currentId = Read-CurrentBackupId -AllowMissing
    if ($currentId -and $currentId -cne $Id) {
        Fail "Restore target $Id is not the authenticated CURRENT backup ($currentId)."
    }
    Invoke-SingleBackupRecoveryCleanup
    $currentId = Read-CurrentBackupId -AllowMissing
    if ($currentId -and $currentId -cne $Id) {
        Fail "Restore target $Id is not the authenticated CURRENT backup ($currentId)."
    }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { Fail "Backup does not exist: $root" }
    Assert-RestoreCompatibility $root
    Confirm-Backup $Id -ReadOnly
    $restoreEpochInfo = Read-ValidatedBackupEpoch $root $Id
    if ([int]$restoreEpochInfo.SchemaVersion -eq 2) {
        if ($currentId -cne $Id) { Fail 'Schema-version-2 restore requires its authenticated CURRENT pointer.' }
        Confirm-Backup $Id -ReadOnly -RequireAcceptance
    } else {
        # Legacy schema-v1 recovery points predate CURRENT. Preserve explicit
        # verification/restore compatibility while never merging their external
        # WAL tar; pg_basebackup --wal-method=stream is the recovery source.
        Confirm-Backup $Id
    }
    Assert-RestoreCompatibility $root
    Assert-DeploymentVolumeOwnership
    $restoreTemp = Join-Path $ScriptRoot ".restore-secrets-$([Guid]::NewGuid().ToString('N'))"
    $restoreStage = Join-Path $BackupDirectory ".restore-payload-$Id-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $restoreTemp | Out-Null
    New-Item -ItemType Directory -Path $restoreStage | Out-Null
    Protect-DockerStorageDirectory $restoreTemp 'ReadWrite'
    Protect-PrivateDirectory $restoreStage
    Copy-Item -LiteralPath (Join-Path $root 'postgres') -Destination $restoreStage -Recurse
    foreach ($name in @('oscar-state.tar.gz', 'archive.tar.gz')) {
        Copy-Item -LiteralPath (Join-Path $root $name) -Destination (Join-Path $restoreStage $name)
    }
    Protect-DockerStorageDirectory $restoreStage 'ReadOnly'
    try {
        $image = "oscar:$RequiredReleaseVersion"
        $decryptSecrets = 'openssl enc -d -aes-256-cbc -pbkdf2 -pass file:/backup-key.txt -in /backup/deployment-secrets.tar.gz.enc | tar -C /restore -xzf -'
        Invoke-DockerShellInput $decryptSecrets @('run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--workdir', '/', '--user', '0:0', '--entrypoint', 'sh', '--volume', "${root}:/backup:ro", '--volume', "${restoreTemp}:/restore", '--volume', "${BackupKeyFile}:/backup-key.txt:ro", $image, '-seu')
        Prepare-RestoredDeploymentCredentials $restoreTemp $ScriptRoot
        Assert-StorageRootIdentities -IncludeBackup
    } catch {
        if (Test-Path -LiteralPath $restoreTemp) { Remove-DirectoryTreeLongPathSafe $restoreTemp 'restore credential staging directory' -IgnoreErrors }
        if (Test-Path -LiteralPath $restoreStage) { Remove-DirectoryTreeLongPathSafe $restoreStage 'restore payload staging directory' -IgnoreErrors }
        throw
    }
    try {
        $safety = Join-Path $ScriptRoot "pre-restore-$Id"
        if (Test-Path -LiteralPath $safety) { Fail "Pre-restore safety directory already exists; preserve or move it before retrying: $safety" }
        New-Item -ItemType Directory -Path $safety | Out-Null
        Protect-PrivateDirectory $safety
        Copy-Item -LiteralPath (Join-Path $ScriptRoot '.env'), (Join-Path $ScriptRoot 'secrets'), (Join-Path $ScriptRoot 'tls') -Destination $safety -Recurse -Force
        Assert-DeploymentVolumeOwnership
        Stop-DeploymentOrdered
        $preparePostgres = 'find /data -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; cp -a /restore-source/. /data/; exec /usr/local/bin/oscar-prepare-restore /data'
        $sourceTimelineOutput = Get-DockerShellInputOutput $preparePostgres @('run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--user', '999:999', '--entrypoint', 'sh', '--volume', 'oscar_postgres_data:/data', '--volume', "$(Join-Path $restoreStage 'postgres'):/restore-source:ro", (Get-PostgresImage), '-seu')
        $sourceTimelineText = (($sourceTimelineOutput -join '').Trim())
        [UInt64]$sourceTimeline = 0
        if (-not [UInt64]::TryParse($sourceTimelineText, [ref]$sourceTimeline) -or $sourceTimeline -eq 0) {
            Fail 'PostgreSQL restore preparation did not emit the authenticated source timeline.'
        }
        $restoreState = 'find /state -mindepth 1 -maxdepth 1 ! -name archive -exec rm -rf -- {} +; tar --no-same-owner --no-overwrite-dir --strip-components=1 -C /state -xzf /restore-state.tar.gz'
        Invoke-DockerShellInput $restoreState @('run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--user', '10001:10001', '--entrypoint', 'sh', '--volume', 'oscar_oscar_state:/state', '--volume', "$(Join-Path $restoreStage 'oscar-state.tar.gz'):/restore-state.tar.gz:ro", $image, '-seu')
        $restoreArchive = 'find /archive -mindepth 1 -maxdepth 1 ! -name .oscar-storage-root -exec rm -rf -- {} +; tar --no-same-owner --no-overwrite-dir --strip-components=1 -C /archive -xzf /restore-archive.tar.gz'
        Invoke-DockerShellInput $restoreArchive @('run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--user', '10001:10001', '--entrypoint', 'sh', '--volume', "${ArchiveDirectory}:/archive", '--volume', "$(Join-Path $restoreStage 'archive.tar.gz'):/restore-archive.tar.gz:ro", $image, '-seu')
        Assert-StorageRootIdentities -IncludeBackup
        Install-PreparedDeploymentCredentials $restoreTemp $ScriptRoot
        Assert-DeploymentVolumeOwnership
    } finally {
        if (Test-Path -LiteralPath $restoreTemp) { Remove-DirectoryTreeLongPathSafe $restoreTemp 'restore credential staging directory' -IgnoreErrors }
        if (Test-Path -LiteralPath $restoreStage) { Remove-DirectoryTreeLongPathSafe $restoreStage 'restore payload staging directory' -IgnoreErrors }
    }
    $restoredPostgresRunning = $false
    try {
        Invoke-Compose @('up', '--detach', '--no-deps', '--no-build', '--pull', 'never', '--wait', '--wait-timeout', '300', 'postgres')
        $restoredPostgresRunning = $true
        $restoreEpoch = $restoreEpochInfo.Epoch
        if (-not (Test-Uuid ([string]$restoreEpoch.backupEpochId)) -or
            ([string]$restoreEpoch.postgresLsn) -notmatch '^[0-9A-F]+/[0-9A-F]+$') {
            Fail 'Authenticated restore epoch fields are invalid.'
        }
        $restoreProof = Confirm-RestoredPostgresTimeline $sourceTimeline $root $Id $restoreEpoch
        Invoke-Compose @('stop', 'postgres')
        $restoredPostgresRunning = $false
        Assert-RestoreSettingsRemovedFromDataVolume
        Invoke-Compose @('up', '--detach', '--no-deps', '--no-build', '--pull', 'never', '--wait', '--wait-timeout', '300', 'postgres')
        $restoredPostgresRunning = $true
        Confirm-CleanRestoredPostgresRuntime ([UInt64]$restoreProof.Timeline) ([string]$restoreProof.EpochId)
        $restoredPostgresRunning = $false
        Invoke-Compose @('up', '--detach', '--no-deps', '--no-build', '--pull', 'never', '--wait', '--wait-timeout', '300', 'oscar', 'gateway')
    } catch {
        if ($restoredPostgresRunning) {
            try { Invoke-Compose @('stop', 'postgres') } catch { Write-Warning "Could not stop PostgreSQL after restore validation failed: $($_.Exception.Message)" }
        }
        throw
    }
    Write-Host "Restore complete. Pre-restore credentials were preserved at $safety" -ForegroundColor Green
}

function Show-ArchiveStatus {
    Assert-Configured
    Invoke-Psql "SELECT g.store_key,g.id_scope,g.state,g.profile,count(*) generations,coalesce(sum(g.row_count),0) rows,pg_size_pretty(coalesce(sum(o.bytes),0)) bytes FROM oscar_archive_generation g LEFT JOIN oscar_archive_object o ON o.generation_id=g.id AND o.kind='OBSERVATIONS_PARQUET' GROUP BY g.store_key,g.id_scope,g.state,g.profile ORDER BY g.store_key,g.id_scope,g.state,g.profile;" -Table
    Invoke-Psql "SELECT store_key,id_scope,count(*) active_holds FROM oscar_retention_hold WHERE released_at IS NULL GROUP BY store_key,id_scope ORDER BY store_key,id_scope;" -Table
    Test-ArchiveFilesystemRegistration
}

function Invoke-RetentionHold([string]$Mode) {
    Assert-Administrator; Assert-Configured
    switch ($Mode) {
        'list' {
            Invoke-Psql "SELECT id,store_key,id_scope,subject_type,subject_id,resolution_mode,reason,created_by,created_at,released_at,released_by FROM oscar_retention_hold ORDER BY (released_at IS NULL) DESC,store_key,id_scope,created_at DESC;" -Table
        }
        'create' {
            $subjectType = $null
            $subjectId = $null
            if ($Generation -and -not $Observation) { $subjectType = 'ARCHIVE_GENERATION'; $subjectId = $Generation }
            if ($Observation -and -not $Generation) { $subjectType = 'OBSERVATION'; $subjectId = $Observation }
            if (($subjectType -eq 'ARCHIVE_GENERATION' -and -not (Test-Uuid $subjectId)) -or
                ($subjectType -eq 'OBSERVATION' -and -not (Test-ObservationId $subjectId)) -or -not $subjectType) {
                Fail 'Specify exactly one valid -Generation UUID or -Observation numeric ID.'
            }
            if (-not (Test-StoreKey $StoreKey)) { Fail '-StoreKey must be the archive store/table identifier shown by archive status.' }
            if (-not (Test-IdScope $IdScope)) { Fail '-IdScope must be a signed 32-bit integer shown by archive status.' }
            if (-not $Reason -or $Reason -notmatch '^[A-Za-z0-9][A-Za-z0-9\s._,:/@+()=-]{0,255}$') { Fail 'Reason contains unsupported characters or exceeds 256 characters.' }
            $creator = if ($CreatedBy) { $CreatedBy } else { [Environment]::UserName }
            if ($creator -notmatch '^[A-Za-z0-9_.@-]{1,128}$') { Fail 'Invalid creator.' }
            $safeReason = $Reason.Replace("'", "''")
            $numericSubject = if ($subjectType -eq 'OBSERVATION') { $subjectId } else { '0' }
            $generationSubject = if ($subjectType -eq 'ARCHIVE_GENERATION') { $subjectId } else { '00000000-0000-4000-8000-000000000000' }
            # ID blocks are coarse for sparse/interleaved generations. An
            # exact hot row is authoritative; ranges are a cold-only fallback.
            $sql = @"
BEGIN;
LOCK TABLE oscar_retention_hold IN SHARE ROW EXCLUSIVE MODE;
WITH eligible AS (
    SELECT CASE
        WHEN '$subjectType'='ARCHIVE_GENERATION' AND EXISTS (
            SELECT 1 FROM oscar_archive_generation
             WHERE id='$generationSubject' AND store_key='$StoreKey' AND id_scope=$IdScope
               AND state IN ('ACTIVE','SEALED')
        ) THEN 'GENERATION_EXACT'
        WHEN '$subjectType'='OBSERVATION' AND NOT EXISTS (
                SELECT 1 FROM oscar_tombstone
                 WHERE subject_type='OBSERVATION' AND store_key='$StoreKey' AND id_scope=$IdScope
                   AND subject_id='$subjectId'
            ) THEN CASE
                WHEN EXISTS (
                    SELECT 1 FROM "$StoreKey" any_hot_row
                     WHERE any_hot_row.id='$numericSubject'::bigint
                ) THEN CASE WHEN EXISTS (
                        SELECT 1 FROM "$StoreKey" exact_hot_row
                         WHERE exact_hot_row.id='$numericSubject'::bigint
                           AND (exact_hot_row.archivegenerationid IS NULL OR EXISTS (
                               SELECT 1 FROM oscar_archive_generation exact_owner
                                WHERE exact_owner.id=exact_hot_row.archivegenerationid
                                  AND exact_owner.store_key='$StoreKey' AND exact_owner.id_scope=$IdScope
                                  AND exact_owner.state IN ('ACTIVE','SEALED')
                           ))
                    ) THEN 'HOT_EXACT' END
                WHEN EXISTS (
                        SELECT 1 FROM oscar_archive_id_block active_block
                        JOIN oscar_archive_generation active_generation ON active_generation.id=active_block.generation_id
                         WHERE '$numericSubject'::bigint BETWEEN active_block.min_id AND active_block.max_id
                           AND active_generation.store_key='$StoreKey' AND active_generation.id_scope=$IdScope
                           AND active_generation.state IN ('ACTIVE','SEALED')
                    ) AND NOT EXISTS (
                        SELECT 1 FROM oscar_archive_id_block retired_block
                        JOIN oscar_archive_generation retired_generation ON retired_generation.id=retired_block.generation_id
                         WHERE '$numericSubject'::bigint BETWEEN retired_block.min_id AND retired_block.max_id
                           AND retired_generation.store_key='$StoreKey' AND retired_generation.id_scope=$IdScope
                           AND retired_generation.state IN ('DELETING','PURGED')
                    ) THEN 'COLD_RANGE_CONSERVATIVE'
            END
    END AS resolution_mode
), inserted AS (
    INSERT INTO oscar_retention_hold(id,store_key,id_scope,subject_type,subject_id,resolution_mode,reason,created_by)
    SELECT gen_random_uuid(),'$StoreKey',$IdScope,'$subjectType','$subjectId',resolution_mode,'$safeReason','$creator'
      FROM eligible WHERE resolution_mode IS NOT NULL
    RETURNING id,resolution_mode
)
SELECT coalesce((SELECT id::text||chr(9)||resolution_mode FROM inserted),'REJECTED');
COMMIT;
"@
            $result = Invoke-Psql $sql
            if ($result -ceq 'REJECTED') { Fail 'The hold target is unknown, already purged/tombstoned, or currently being deleted.' }
            $fields = $result -split "`t", 2
            if ($fields.Count -ne 2 -or -not (Test-Uuid $fields[0]) -or
                $fields[1] -cnotin @('GENERATION_EXACT','HOT_EXACT','COLD_RANGE_CONSERVATIVE')) {
                Fail 'PostgreSQL did not return a valid hold ID and resolution mode.'
            }
            Write-Host "Retention hold created: $($fields[0]) (store=$StoreKey, id-scope=$IdScope, resolution=$($fields[1]))" -ForegroundColor Green
        }
        'release' {
            if (-not (Test-Uuid $HoldId)) { Fail 'A valid -HoldId UUID is required.' }
            $releaser = if ($ReleasedBy) { $ReleasedBy } else { [Environment]::UserName }
            if ($releaser -notmatch '^[A-Za-z0-9_.@-]{1,128}$') { Fail 'Invalid releaser.' }
            $changed = Invoke-Psql "BEGIN; LOCK TABLE oscar_retention_hold IN SHARE ROW EXCLUSIVE MODE; WITH changed AS (UPDATE oscar_retention_hold SET released_at=now(),released_by='$releaser' WHERE id='$HoldId' AND released_at IS NULL RETURNING 1) SELECT count(*) FROM changed; COMMIT;"
            if ($changed -ne '1') { Fail 'Hold is unknown or already released.' }
            Write-Host "Retention hold released: $HoldId" -ForegroundColor Green
        }
        default { Fail "Unknown archive hold action: $Mode" }
    }
}

function Confirm-ArchiveObjects([switch]$RejectPartials) {
    Assert-Configured
    $sql = @"
WITH required(kind) AS (
    VALUES ('OBSERVATIONS_PARQUET'),('GENERATION_MANIFEST'),('DATASTREAM_SCHEMAS')
), required_rows AS (
    SELECT 'REQUIRED'::text row_type,g.id::text generation_id,required.kind,
           count(o.generation_id)::text object_count,coalesce(min(o.state),'') object_state,
           coalesce(min(o.relative_path),'') relative_path,coalesce(min(o.sha256),'') object_sha,
           coalesce(g.object_path,'') generation_object_path,coalesce(g.sha256,'') generation_sha,
           coalesce(g.manifest_path,'') generation_manifest_path
      FROM oscar_archive_generation g CROSS JOIN required
      LEFT JOIN oscar_archive_object o ON o.generation_id=g.id AND o.kind=required.kind
     WHERE g.state IN ('ACTIVE','SEALED')
     GROUP BY g.id,required.kind,g.object_path,g.sha256,g.manifest_path
), additional_rows AS (
    SELECT 'ADDITIONAL'::text,g.id::text,coalesce(o.kind,''),'1'::text,coalesce(o.state,''),
           coalesce(o.relative_path,''),coalesce(o.sha256,''),
           coalesce(g.object_path,''),coalesce(g.sha256,''),coalesce(g.manifest_path,'')
      FROM oscar_archive_object o JOIN oscar_archive_generation g ON g.id=o.generation_id
     WHERE o.state='ACTIVE'
       AND g.state IN ('ACTIVE','SEALED')
       AND (o.kind IS NULL OR o.kind NOT IN ('OBSERVATIONS_PARQUET','GENERATION_MANIFEST','DATASTREAM_SCHEMAS'))
), invalid_owner_rows AS (
    SELECT 'INVALID_OWNER'::text,g.id::text,coalesce(o.kind,''),'1'::text,coalesce(o.state,''),
           coalesce(o.relative_path,''),coalesce(o.sha256,''),
           coalesce(g.object_path,''),coalesce(g.sha256,''),coalesce(g.manifest_path,'')
      FROM oscar_archive_object o JOIN oscar_archive_generation g ON g.id=o.generation_id
     WHERE o.state='ACTIVE' AND g.state NOT IN ('ACTIVE','SEALED')
), integrity_rows AS (
    SELECT 'RELATIONAL'::text,g.id::text,'ID_BLOCK_AND_SCHEMAS'::text,
           (SELECT count(*)::text FROM oscar_archive_id_block block
             WHERE block.generation_id=g.id),
           CASE WHEN (SELECT count(*) FROM oscar_archive_id_block block
                       WHERE block.generation_id=g.id)=1
                     AND EXISTS (SELECT 1 FROM oscar_archive_id_block block
                                  WHERE block.generation_id=g.id
                                    AND block.min_id=g.min_id AND block.max_id=g.max_id)
                THEN 'MATCH' ELSE 'MISMATCH' END,
           (SELECT count(*)::text FROM oscar_archive_schema schema_row
             WHERE schema_row.generation_id=g.id),
           ''::text,coalesce(g.object_path,''),coalesce(g.sha256,''),coalesce(g.manifest_path,'')
      FROM oscar_archive_generation g
     WHERE g.state IN ('ACTIVE','SEALED')
)
SELECT row_type||chr(31)||generation_id||chr(31)||kind||chr(31)||object_count||chr(31)||
       object_state||chr(31)||relative_path||chr(31)||object_sha||chr(31)||
       generation_object_path||chr(31)||generation_sha||chr(31)||generation_manifest_path
  FROM (SELECT * FROM required_rows UNION ALL SELECT * FROM additional_rows
        UNION ALL SELECT * FROM invalid_owner_rows UNION ALL SELECT * FROM integrity_rows) snapshot
 ORDER BY generation_id,row_type,kind,relative_path,object_sha;
"@
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ("oscar-archive-verify-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $scratch | Out-Null
    try {
        Protect-PrivateDirectory $scratch
        $before = Join-Path $scratch 'catalog-before.tsv'
        $after = Join-Path $scratch 'catalog-after.tsv'
        Write-PsqlLinesToFile $sql $before
        foreach ($line in [IO.File]::ReadLines($before)) {
            if (-not $line) { continue }
            $fields = $line -split ([char]31), 10
            if ($fields.Count -ne 10 -or -not (Test-Uuid $fields[1])) {
                Fail "Unsafe archive catalog snapshot row: $line"
            }
            if ($fields[0] -ceq 'REQUIRED') {
                if ($fields[2] -cnotin @('OBSERVATIONS_PARQUET','GENERATION_MANIFEST','DATASTREAM_SCHEMAS') -or
                    $fields[3] -cne '1' -or $fields[4] -cne 'ACTIVE' -or
                    $fields[6] -cnotmatch '^[0-9a-f]{64}$' -or -not $fields[7] -or
                    $fields[8] -cnotmatch '^[0-9a-f]{64}$' -or -not $fields[9] -or
                    ($fields[2] -ceq 'OBSERVATIONS_PARQUET' -and
                        ($fields[5] -cne $fields[7] -or $fields[6] -cne $fields[8])) -or
                    ($fields[2] -ceq 'GENERATION_MANIFEST' -and $fields[5] -cne $fields[9])) {
                    Fail "Incomplete query-visible archive generation: $line"
                }
            } elseif ($fields[0] -ceq 'ADDITIONAL') {
                if (-not $fields[2] -or $fields[3] -cne '1' -or $fields[4] -cne 'ACTIVE' -or
                    $fields[6] -cnotmatch '^[0-9a-f]{64}$') {
                    Fail "Unsafe additional archive catalog row: $line"
                }
            } elseif ($fields[0] -ceq 'INVALID_OWNER') {
                Fail "Active archive object belongs to a non-query-visible generation: $line"
            } elseif ($fields[0] -ceq 'RELATIONAL') {
                if ($fields[2] -cne 'ID_BLOCK_AND_SCHEMAS' -or $fields[3] -cne '1' -or
                    $fields[4] -cne 'MATCH' -or $fields[5] -cnotmatch '^[1-9][0-9]*$') {
                    Fail "Invalid archive relational metadata: $line"
                }
                continue
            } else {
                Fail "Unsafe archive catalog snapshot row type: $line"
            }
            $path = Resolve-ConfinedArchivePath $fields[5]
            $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actual -cne $fields[6]) { Fail "Archive checksum mismatch: $($fields[5])" }
        }
        Test-ArchiveFilesystemRegistration -RejectPartials:$RejectPartials
        # Re-read the same canonical single-statement snapshot after hashing and
        # filesystem reconciliation. Background publication or concurrent purge
        # must make verification fail/retry rather than certify a mixed instant.
        Write-PsqlLinesToFile $sql $after
        if (-not (Test-FileContentEqual $before $after)) {
            Fail 'Archive catalog changed during verification; no stable result was certified. Re-run archive verify.'
        }
    } finally {
        if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
    }
    Write-Host 'Every query-visible generation has exact ID-block bounds, schema rows, one required active object of each kind, and valid checksums.' -ForegroundColor Green
}

function New-DeletionPlan([string]$Cutoff, [string]$Requester) {
    Assert-Administrator; Assert-Configured
    if (-not (Test-UtcCutoff $Cutoff)) { Fail '-Before must be UTC YYYY-MM-DDTHH:MM:SSZ.' }
    if (-not (Test-StoreKey $StoreKey)) { Fail '-StoreKey must be the archive store/table identifier shown by archive status.' }
    if (-not (Test-IdScope $IdScope)) { Fail '-IdScope must be a signed 32-bit integer shown by archive status.' }
    if (-not $Requester) { $Requester = [Environment]::UserName }
    if ($Requester -notmatch '^[A-Za-z0-9_.@-]{1,128}$') { Fail 'Invalid requester.' }
    $id = Invoke-Psql 'SELECT gen_random_uuid();'
    $tokenBytes = New-Object byte[] 24
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($tokenBytes) } finally { $rng.Dispose() }
    $confirmationToken = ([BitConverter]::ToString($tokenBytes)).Replace('-', '').ToLowerInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $tokenHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($confirmationToken)))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
    $sql = @"
BEGIN;
WITH candidate AS (
    SELECT g.id,g.row_count,coalesce(sum(o.bytes),0) bytes,
           EXISTS (SELECT 1 FROM oscar_retention_hold h
                    WHERE h.released_at IS NULL AND h.store_key=g.store_key AND h.id_scope=g.id_scope
                      AND ((h.subject_type='ARCHIVE_GENERATION' AND h.subject_id=g.id::text) OR
                           (h.subject_type='OBSERVATION' AND h.subject_id~'^[0-9]+$' AND EXISTS (
                               SELECT 1 FROM oscar_archive_id_block held_block
                                WHERE held_block.generation_id=g.id
                                  AND h.subject_id::bigint BETWEEN held_block.min_id AND held_block.max_id)))) held
      FROM oscar_archive_generation g
      LEFT JOIN oscar_archive_object o ON o.generation_id=g.id AND o.state='ACTIVE'
     WHERE g.store_key='$StoreKey' AND g.id_scope=$IdScope
       AND g.state='SEALED' AND g.window_end<'$Cutoff'::timestamptz
     GROUP BY g.id,g.store_key,g.id_scope,g.row_count
), inserted AS (
    INSERT INTO oscar_deletion_plan(id,store_key,id_scope,subject_type,subject_id,state,estimated_rows,estimated_bytes,hold_count,confirmation_hash,requested_by,expires_at)
    SELECT '$id','$StoreKey',$IdScope,'ARCHIVE_BEFORE','$Cutoff','PLANNED',
           coalesce(sum(row_count) FILTER (WHERE NOT held),0),
           coalesce(sum(bytes) FILTER (WHERE NOT held),0),
           count(*) FILTER (WHERE held),'$tokenHash','$Requester',now()+interval '24 hours'
      FROM candidate RETURNING id
)
INSERT INTO oscar_deletion_plan_item(plan_id,generation_id)
SELECT inserted.id,candidate.id FROM inserted CROSS JOIN candidate WHERE NOT candidate.held;
COMMIT;
"@
    Invoke-Psql $sql | Out-Null
    $summary = Invoke-Psql "SELECT estimated_rows||'|'||estimated_bytes||'|'||hold_count FROM oscar_deletion_plan WHERE id='$id';"
    $fields = $summary -split '\|'
    Write-Host "Deletion plan: $id`nStore: $StoreKey`nID scope: $IdScope`nEligible rows: $($fields[0])`nEligible bytes: $($fields[1])`nHeld generations: $($fields[2])"
    Write-Host "Confirmation token (shown once): $confirmationToken" -ForegroundColor Yellow
    Write-Host "Review this plan, then run: oscar.bat archive purge -StoreKey $StoreKey -IdScope $IdScope -Plan $id -Token <token>"
}

function Remove-ArchivePlan([string]$PlanId, [string]$ConfirmationToken) {
    Assert-Administrator; Assert-Configured
    if (-not (Test-StoreKey $StoreKey)) { Fail '-StoreKey must be the archive store/table identifier shown by archive status.' }
    if (-not (Test-IdScope $IdScope)) { Fail '-IdScope must be a signed 32-bit integer shown by archive status.' }
    if (-not (Test-Uuid $PlanId) -or $ConfirmationToken -notmatch '^[0-9a-f]{48}$') { Fail 'A valid plan ID and confirmation token are required.' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $tokenHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($ConfirmationToken)))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
    $planState = Invoke-Psql "SELECT subject_id||'|'||state||'|'||confirmation_hash FROM oscar_deletion_plan WHERE id='$PlanId' AND store_key='$StoreKey' AND id_scope=$IdScope AND (state='CONFIRMED' OR expires_at>now());"
    $planFields = $planState -split '\|'
    if ($planFields.Count -ne 3 -or $planFields[1] -notin @('PLANNED','CONFIRMED') -or $planFields[2] -cne $tokenHash) { Fail 'Plan is missing, expired, completed, or token does not match.' }
    $who = [Environment]::UserName
    if ($who -notmatch '^[A-Za-z0-9_.@-]{1,128}$') { $who = 'administrator' }

    $running = @(Get-ComposeOutput @('ps', '--status', 'running', '--services'))
    $resumeOscar = $running -contains 'oscar'
    try {
        if ($resumeOscar) { Invoke-Compose @('stop', 'oscar') }

        # Validate every currently active object before changing catalog visibility. The transaction
        # below rechecks holds under the same lock used by hold creation, then makes each complete
        # generation non-queryable before any file is removed. OSCAR remains stopped across the
        # verification/transition/delete sequence, closing the host path-swap window.
        $preflight = @(Invoke-PsqlLines "SELECT g.id||chr(9)||o.relative_path||chr(9)||o.sha256||chr(9)||o.state FROM oscar_deletion_plan_item i JOIN oscar_deletion_plan p ON p.id=i.plan_id JOIN oscar_archive_generation g ON g.id=i.generation_id AND g.store_key=p.store_key AND g.id_scope=p.id_scope JOIN oscar_archive_object o ON o.generation_id=g.id WHERE i.plan_id='$PlanId' AND p.store_key='$StoreKey' AND p.id_scope=$IdScope AND i.state='PLANNED' AND o.state IN ('ACTIVE','DELETING') ORDER BY g.id,o.relative_path;")
        foreach ($line in $preflight) {
            if (-not $line) { continue }
            $fields = $line -split "`t", 4
            if ($fields.Count -ne 4) { Fail "Unsafe catalog row: $line" }
            if ($fields[3] -ceq 'ACTIVE') {
                $null = Invoke-ArchiveObjectHelper 'verify' $fields[1] $fields[2] 'ro'
            } else {
                $path = Resolve-ConfinedArchivePath $fields[1] -AllowMissing
                if (Test-Path -LiteralPath $path) {
                    $null = Invoke-ArchiveObjectHelper 'verify' $fields[1] $fields[2] 'ro'
                }
            }
        }

        $transitionSql = @"
BEGIN;
LOCK TABLE oscar_retention_hold IN SHARE ROW EXCLUSIVE MODE;
UPDATE oscar_deletion_plan
   SET state='CONFIRMED',confirmed_by='$who',confirmed_at=coalesce(confirmed_at,now())
 WHERE id='$PlanId' AND store_key='$StoreKey' AND id_scope=$IdScope
   AND state='PLANNED' AND expires_at>now();
SELECT 1 / CASE WHEN EXISTS (SELECT 1 FROM oscar_deletion_plan WHERE id='$PlanId' AND store_key='$StoreKey' AND id_scope=$IdScope AND state='CONFIRMED') THEN 1 ELSE 0 END;
UPDATE oscar_deletion_plan_item i
   SET state='HELD',detail='A retention hold was active at purge time',updated_at=now()
  FROM oscar_archive_generation g, oscar_deletion_plan p
 WHERE i.plan_id='$PlanId' AND p.id=i.plan_id AND p.store_key='$StoreKey' AND p.id_scope=$IdScope
   AND i.generation_id=g.id AND g.store_key=p.store_key AND g.id_scope=p.id_scope
   AND i.state='PLANNED' AND g.state='SEALED'
   AND EXISTS (SELECT 1 FROM oscar_retention_hold h WHERE h.released_at IS NULL AND
       h.store_key=g.store_key AND h.id_scope=g.id_scope AND
       ((h.subject_type='ARCHIVE_GENERATION' AND h.subject_id=g.id::text) OR
        (h.subject_type='OBSERVATION' AND h.subject_id~'^[0-9]+$' AND EXISTS (
            SELECT 1 FROM oscar_archive_id_block held_block
             WHERE held_block.generation_id=g.id
               AND h.subject_id::bigint BETWEEN held_block.min_id AND held_block.max_id))));
SELECT 1 / CASE WHEN EXISTS (
    SELECT 1 FROM oscar_deletion_plan_item i
    JOIN oscar_deletion_plan p ON p.id=i.plan_id
    JOIN oscar_archive_generation g ON g.id=i.generation_id AND g.store_key=p.store_key AND g.id_scope=p.id_scope
     WHERE i.plan_id='$PlanId' AND p.store_key='$StoreKey' AND p.id_scope=$IdScope AND i.state='PLANNED'
       AND NOT (g.state='SEALED' OR (g.state='DELETING' AND EXISTS (
           SELECT 1 FROM oscar_deletion_ledger l
            WHERE l.plan_id='$PlanId' AND l.store_key=p.store_key AND l.id_scope=p.id_scope
              AND l.subject_type='ARCHIVE_GENERATION'
              AND l.subject_id=g.id::text AND l.object_path IS NULL AND l.outcome='DELETING'
       )))
) THEN 0 ELSE 1 END;
WITH changed AS (
    UPDATE oscar_archive_generation g SET state='DELETING'
      FROM oscar_deletion_plan_item i, oscar_deletion_plan p
     WHERE i.plan_id='$PlanId' AND p.id=i.plan_id AND p.store_key='$StoreKey' AND p.id_scope=$IdScope
       AND i.state='PLANNED' AND i.generation_id=g.id
       AND g.store_key=p.store_key AND g.id_scope=p.id_scope AND g.state='SEALED'
     RETURNING g.id
)
INSERT INTO oscar_deletion_ledger(plan_id,store_key,id_scope,subject_type,subject_id,object_path,outcome,detail)
SELECT '$PlanId','$StoreKey',$IdScope,'ARCHIVE_GENERATION',id::text,NULL,'DELETING','Generation made non-queryable before filesystem deletion' FROM changed;
WITH changed AS (
    UPDATE oscar_archive_object o SET state='DELETING'
      FROM oscar_deletion_plan_item i
      JOIN oscar_deletion_plan p ON p.id=i.plan_id
      JOIN oscar_archive_generation g ON g.id=i.generation_id AND g.store_key=p.store_key AND g.id_scope=p.id_scope
     WHERE i.plan_id='$PlanId' AND p.store_key='$StoreKey' AND p.id_scope=$IdScope
       AND i.state='PLANNED' AND o.generation_id=g.id
       AND g.state='DELETING' AND o.state='ACTIVE'
     RETURNING o.generation_id,o.relative_path
)
INSERT INTO oscar_deletion_ledger(plan_id,store_key,id_scope,subject_type,subject_id,object_path,outcome,detail)
SELECT '$PlanId','$StoreKey',$IdScope,'ARCHIVE_GENERATION',generation_id::text,relative_path,'DELETING','Checksum verified; deletion intent persisted' FROM changed;
COMMIT;
"@
        Invoke-Psql $transitionSql | Out-Null

        $objects = @(Invoke-PsqlLines "SELECT g.id||chr(9)||o.relative_path||chr(9)||o.sha256||chr(9)||o.state FROM oscar_deletion_plan_item i JOIN oscar_deletion_plan p ON p.id=i.plan_id JOIN oscar_archive_generation g ON g.id=i.generation_id AND g.store_key=p.store_key AND g.id_scope=p.id_scope JOIN oscar_archive_object o ON o.generation_id=g.id WHERE i.plan_id='$PlanId' AND p.store_key='$StoreKey' AND p.id_scope=$IdScope AND i.state='PLANNED' AND g.state='DELETING' AND o.state='DELETING' ORDER BY g.id,o.relative_path;")
        foreach ($line in $objects) {
            if (-not $line) { continue }
            $fields = $line -split "`t", 4
            if ($fields.Count -ne 4) { Fail "Unsafe catalog row: $line" }
            $deleteOutcome = Invoke-ArchiveObjectHelper 'delete' $fields[1] $fields[2] 'rw'
            if ($deleteOutcome -notin @('DELETED', 'ALREADY_ABSENT')) {
                Fail "Archive deletion helper returned an invalid outcome for: $($fields[1])"
            }
            Invoke-Psql "WITH changed AS (UPDATE oscar_archive_object SET state='DELETED' WHERE generation_id='$($fields[0])' AND relative_path='$($fields[1])' AND state='DELETING' RETURNING 1) INSERT INTO oscar_deletion_ledger(plan_id,store_key,id_scope,subject_type,subject_id,object_path,outcome) SELECT '$PlanId','$StoreKey',$IdScope,'ARCHIVE_GENERATION','$($fields[0])','$($fields[1])','$deleteOutcome' FROM changed;" | Out-Null
        }
        $finalizeSql = @"
BEGIN;
UPDATE oscar_deletion_plan_item i SET state='COMPLETED',updated_at=now()
 FROM oscar_deletion_plan p, oscar_archive_generation g
 WHERE i.plan_id='$PlanId' AND p.id=i.plan_id AND p.store_key='$StoreKey' AND p.id_scope=$IdScope
   AND g.id=i.generation_id AND g.store_key=p.store_key AND g.id_scope=p.id_scope
   AND i.state='PLANNED'
   AND NOT EXISTS (SELECT 1 FROM oscar_archive_object o WHERE o.generation_id=i.generation_id AND o.state<>'DELETED');
UPDATE oscar_archive_generation g SET state='PURGED'
 FROM oscar_deletion_plan_item i, oscar_deletion_plan p
 WHERE i.plan_id='$PlanId' AND p.id=i.plan_id AND p.store_key='$StoreKey' AND p.id_scope=$IdScope
   AND i.generation_id=g.id AND g.store_key=p.store_key AND g.id_scope=p.id_scope
   AND i.state='COMPLETED' AND g.state='DELETING';
INSERT INTO oscar_tombstone(store_key,id_scope,subject_type,subject_id,reason,policy,generation_id)
SELECT p.store_key,p.id_scope,'ARCHIVE_GENERATION',i.generation_id::text,'Cold archive generation deleted through confirmed plan','RETENTION_POLICY',i.generation_id
  FROM oscar_deletion_plan_item i
  JOIN oscar_deletion_plan p ON p.id=i.plan_id
  JOIN oscar_archive_generation g ON g.id=i.generation_id AND g.store_key=p.store_key AND g.id_scope=p.id_scope
 WHERE i.plan_id='$PlanId' AND p.store_key='$StoreKey' AND p.id_scope=$IdScope AND i.state='COMPLETED'
ON CONFLICT (subject_type,store_key,id_scope,subject_id) DO NOTHING;
DELETE FROM oscar_obs_overlay overlay_row
 USING oscar_deletion_plan_item item, oscar_deletion_plan p, oscar_archive_generation g
 WHERE item.plan_id='$PlanId' AND p.id=item.plan_id AND p.store_key='$StoreKey' AND p.id_scope=$IdScope
   AND g.id=item.generation_id AND g.store_key=p.store_key AND g.id_scope=p.id_scope
   AND item.state='COMPLETED' AND overlay_row.store_key=p.store_key AND overlay_row.id_scope=p.id_scope
   AND overlay_row.generation_id=item.generation_id;
DELETE FROM oscar_tombstone observation_tombstone
 USING oscar_deletion_plan_item item, oscar_deletion_plan p, oscar_archive_generation g
 WHERE item.plan_id='$PlanId' AND p.id=item.plan_id AND p.store_key='$StoreKey' AND p.id_scope=$IdScope
   AND g.id=item.generation_id AND g.store_key=p.store_key AND g.id_scope=p.id_scope
   AND item.state='COMPLETED' AND observation_tombstone.store_key=p.store_key AND observation_tombstone.id_scope=p.id_scope
   AND observation_tombstone.subject_type='OBSERVATION'
   AND observation_tombstone.generation_id=item.generation_id;
UPDATE oscar_deletion_plan
   SET state=CASE WHEN EXISTS (SELECT 1 FROM oscar_deletion_plan_item WHERE plan_id='$PlanId' AND state='HELD') THEN 'COMPLETED_WITH_HOLDS' ELSE 'COMPLETED' END
 WHERE id='$PlanId' AND store_key='$StoreKey' AND id_scope=$IdScope
   AND NOT EXISTS (SELECT 1 FROM oscar_deletion_plan_item WHERE plan_id='$PlanId' AND state='PLANNED');
COMMIT;
"@
        Invoke-Psql $finalizeSql | Out-Null
        $finished = Invoke-Psql "SELECT state FROM oscar_deletion_plan WHERE id='$PlanId' AND store_key='$StoreKey' AND id_scope=$IdScope;"
        if ($finished -notmatch '^COMPLETED(_WITH_HOLDS)?$') { Fail "Deletion stopped with plan $PlanId in state $finished; rerun the same plan and token after correcting the reported problem." }
    } finally {
        if ($resumeOscar) {
            Invoke-Compose @('up', '--detach', '--no-deps', '--no-build', '--pull', 'never', '--wait', '--wait-timeout', '300', 'oscar')
        }
    }
    Write-Host "Archive deletion plan $PlanId completed. Minimal catalog and deletion-ledger records were retained." -ForegroundColor Green
}

function Export-ArchiveGeneration([string]$GenerationId, [string]$Target) {
    Assert-Configured
    if (-not (Test-StoreKey $StoreKey)) { Fail '-StoreKey must be the archive store/table identifier shown by archive status.' }
    if (-not (Test-IdScope $IdScope)) { Fail '-IdScope must be a signed 32-bit integer shown by archive status.' }
    if (-not (Test-Uuid $GenerationId) -or -not $Target) { Fail 'A valid -Generation and -Destination are required.' }
    $targetRoot = [IO.Path]::GetFullPath($Target)
    foreach ($managedRoot in @($ArchiveDirectory, $BackupDirectory, $WalArchiveDirectory, $ScriptRoot)) {
        if (Test-PathContains $managedRoot $targetRoot) {
            Fail "Archive export destination must be outside OSCAR managed and release roots: $targetRoot"
        }
    }
    if (Test-Path -LiteralPath $targetRoot) { Fail "Archive export destination already exists: $targetRoot" }
    $parent = Split-Path -Parent $targetRoot
    if (-not $parent) { $parent = (Get-Location).Path }
    $parent = [IO.Path]::GetFullPath($parent)
    Assert-SafeCreatableDirectoryPath $parent
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    Assert-NoReparseComponents $parent
    $targetRoot = Join-Path $parent ([IO.Path]::GetFileName($targetRoot))
    foreach ($managedRoot in @($ArchiveDirectory, $BackupDirectory, $WalArchiveDirectory, $ScriptRoot)) {
        if (Test-PathContains $managedRoot $targetRoot) {
            Fail "Archive export destination must be outside OSCAR managed and release roots: $targetRoot"
        }
    }
    $partial = Join-Path $parent ('.' + [IO.Path]::GetFileName($targetRoot) + '.partial-' + [Guid]::NewGuid().ToString('N'))
    $resumeOscar = $false
    try {
        New-Item -ItemType Directory -Path $partial | Out-Null
        Protect-DockerStorageDirectory $partial 'ReadWrite'
        Assert-NoReparseComponents $partial
        $running = @(Get-ComposeOutput @('ps', '--status', 'running', '--services'))
        $resumeOscar = $running -contains 'oscar'
        if ($resumeOscar) { Invoke-Compose @('stop', 'oscar') }
        $objects = @(Invoke-PsqlLines "SELECT o.relative_path||chr(9)||o.sha256 FROM oscar_archive_object o JOIN oscar_archive_generation g ON g.id=o.generation_id WHERE o.generation_id='$GenerationId' AND g.store_key='$StoreKey' AND g.id_scope=$IdScope AND g.state IN ('ACTIVE','SEALED') AND o.state='ACTIVE' AND NOT EXISTS (SELECT 1 FROM oscar_archive_object unsafe WHERE unsafe.generation_id=g.id AND unsafe.state<>'ACTIVE') ORDER BY o.relative_path;")
        $copied = 0
        foreach ($line in $objects) {
            if (-not $line) { continue }
            $fields = $line -split "`t", 2
            if ($fields.Count -ne 2) { Fail "Unsafe catalog row: $line" }
            $null = Invoke-ArchiveObjectHelper 'copy' $fields[0] $fields[1] 'ro' $partial
            $copied++
        }
        if ($copied -eq 0) { Fail "No active objects exist for archive generation $GenerationId" }
        Protect-PrivateDirectory $partial
        $catalog = Invoke-Psql "SELECT row_to_json(g) FROM oscar_archive_generation g WHERE id='$GenerationId' AND store_key='$StoreKey' AND id_scope=$IdScope AND state IN ('ACTIVE','SEALED');"
        $objectCatalog = Invoke-Psql "SELECT coalesce(json_agg(row_to_json(o) ORDER BY relative_path),'[]'::json) FROM oscar_archive_object o JOIN oscar_archive_generation g ON g.id=o.generation_id WHERE o.generation_id='$GenerationId' AND g.store_key='$StoreKey' AND g.id_scope=$IdScope;"
        [IO.File]::WriteAllText((Join-Path $partial "catalog-$GenerationId.json"), $catalog + "`n", $Utf8NoBom)
        [IO.File]::WriteAllText((Join-Path $partial "objects-$GenerationId.json"), $objectCatalog + "`n", $Utf8NoBom)
        if ($resumeOscar) {
            Invoke-Compose @('up', '--detach', '--no-deps', '--no-build', '--pull', 'never', '--wait', '--wait-timeout', '300', 'oscar')
            $resumeOscar = $false
        }
        [IO.File]::WriteAllLines((Join-Path $partial 'query.sql'), @(
            '-- OSCAR portable observation archive (DuckDB)',
            "SELECT * FROM read_parquet('datasets/observations/**/*.parquet', union_by_name=true)",
            'ORDER BY datastream_id, phenomenon_time, result_time, id_value;'
        ), $Utf8NoBom)
        [IO.File]::WriteAllText((Join-Path $partial 'README.md'), @'
# OSCAR portable archive export

This directory is self-contained. Verify every file with `Get-FileHash -Algorithm SHA256` against `SHA256SUMS` (or an equivalent SHA-256 tool), then query the Parquet data with DuckDB by running `duckdb < query.sql` from this directory.

The generation manifest defines column types, sort order, compression, row count, ID bounds, and the SHA-256 of each primary object. The gzip schema snapshot preserves the OSH datastream schema used to decode `result_json`. Catalog JSON is retained for provenance.
'@, $Utf8NoBom)
        Write-Checksums $partial
        Sync-DurableTree $partial
        Move-DurableNoReplace $partial $targetRoot
    } finally {
        if (Test-Path -LiteralPath $partial) { Remove-DirectoryTreeLongPathSafe $partial 'archive export partial' }
        if ($resumeOscar) {
            Invoke-Compose @('up', '--detach', '--no-deps', '--no-build', '--pull', 'never', '--wait', '--wait-timeout', '300', 'oscar')
        }
    }
    Write-Host "Portable archive generation exported to $targetRoot" -ForegroundColor Green
}

function Show-Help {
    @'
OSCAR storage administration (Administrator PowerShell)

  oscar.bat backup
  oscar.bat backup-verify -BackupId ID
  oscar.bat restore -BackupId ID -Confirm ID
  upgrade-state (internal upgrade workflow)
  oscar.bat archive status
  oscar.bat archive verify
  oscar.bat archive hold list
  oscar.bat archive hold create -StoreKey KEY -IdScope INT (-Generation UUID | -Observation ID) -Reason TEXT [-CreatedBy NAME]
  oscar.bat archive hold release -HoldId UUID [-ReleasedBy NAME]
  oscar.bat archive dry-run -StoreKey KEY -IdScope INT -Before YYYY-MM-DDTHH:MM:SSZ [-RequestedBy NAME]
  oscar.bat archive purge -StoreKey KEY -IdScope INT -Plan UUID -Token TOKEN
  oscar.bat archive export -StoreKey KEY -IdScope INT -Generation UUID -Destination PATH

Single-backup mode commits one authenticated CURRENT snapshot; backup-prune is retired.
Restore and archive purge are destructive and require explicit confirmation.
'@ | Write-Host
}

try {
    if ($Command -ne 'help') {
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
            Fail 'The PowerShell OSCAR storage launcher is supported only on Windows; use the Bash launcher on Ubuntu 24.04.'
        }
        Assert-Administrator; Assert-Configured
        if ($Command -in @('backup', 'backup-verify', 'backup-prune', 'restore')) { Assert-BackupModeEnabled }
        if ($Command -eq 'backup-prune') {
            Fail 'backup-prune is retired in OSCAR_BACKUP_MODE=single; a successful backup atomically commits CURRENT and then removes only authenticated non-current snapshots.'
        }
        Enter-StorageAdminLock
    }
    if ($Command -eq 'backup-verify') {
        Assert-OfflineBackupDirectory
        Assert-StorageRootIdentity $BackupDirectory 'backup'
    } elseif ($Command -in @('backup', 'restore')) {
        Assert-StorageRootsReady -IncludeBackup
        Assert-StorageRootIdentities -IncludeBackup
        Assert-DeploymentVolumeOwnership
    } elseif ($Command -eq 'archive') {
        Assert-StorageRootsReady
        Assert-StorageRootIdentities
        Assert-DeploymentVolumeOwnership
    } elseif ($Command -eq 'upgrade-state') {
        Assert-StorageRootsReady
        Assert-StorageRootIdentities
        Assert-DeploymentVolumeOwnership
    }
    switch ($Command) {
        'backup' { New-Backup }
        'backup-verify' { Confirm-Backup $BackupId }
        'backup-prune' { Remove-ExpiredBackups $Keep }
        'restore' { Restore-Backup $BackupId $Confirm }
        'prepare-directories' { Initialize-StorageDirectories -AdoptExisting:$AdoptExistingStorageRoots }
        'upgrade-state' { Invoke-UpgradePersistentState }
        'archive' {
            switch ($Action) {
                'status' { Show-ArchiveStatus }
                'verify' { Confirm-ArchiveObjects }
                'hold' { Invoke-RetentionHold $HoldAction }
                'dry-run' { New-DeletionPlan $Before $RequestedBy }
                'purge' { Remove-ArchivePlan $Plan $Token }
                'export' { Export-ArchiveGeneration $Generation $Destination }
                default { Fail "Unknown archive action: $Action" }
            }
        }
        default { Show-Help }
    }
} catch {
    Write-Error $_.Exception.Message
    exit 1
} finally {
    Exit-StorageAdminLock
}
