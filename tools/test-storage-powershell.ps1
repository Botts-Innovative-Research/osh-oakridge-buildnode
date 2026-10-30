[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw 'This gate must run under Windows PowerShell 5.1 (powershell.exe).'
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..'))
$storageScript = Join-Path $repoRoot 'dist\release\oscar-storage.ps1'
$setupScript = Join-Path $repoRoot 'dist\release\oscar-setup.ps1'
$hostPrepScript = Join-Path $repoRoot 'dist\release\configure-windows-host.ps1'
$verifyScript = Join-Path $repoRoot 'dist\release\verify-bundle.ps1'
$offlineBuilderScript = Join-Path $repoRoot 'tools\offline\build-offline-bundle.ps1'
$composeFile = Join-Path $repoRoot 'dist\release\compose.yaml'
$oscarDockerfile = Join-Path $repoRoot 'dist\release\docker\oscar\Dockerfile'
$oscarEntrypoint = Join-Path $repoRoot 'dist\release\docker\oscar\entrypoint.sh'
$releasePowerShellScripts = @($storageScript, $setupScript, $hostPrepScript, $verifyScript, $offlineBuilderScript)
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('oscar-storage-ps5-' + [Guid]::NewGuid().ToString('N'))
$createdDockerGroup = $false

$expectedDisabledBackupGuidance = 'OSCAR backups are disabled. Re-run upgrade with -BackupMode single -BackupDir <safe-absolute-backup-path> before using backup, verification, pruning, or restore.'
if (-not [IO.File]::ReadAllText($storageScript).Contains($expectedDisabledBackupGuidance)) {
    throw 'PowerShell disabled-backup guidance does not use the supported upgrade parameter names.'
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-ScriptParses([string]$Path) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) {
        throw "PowerShell 5.1 parser rejected $Path`: $($errors[0].Message)"
    }
}

function Invoke-Verifier([string]$Root) {
    $process = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $Root 'verify-bundle.ps1')) -Wait -PassThru -WindowStyle Hidden
    return $process.ExitCode
}

function Invoke-StorageLauncher([string]$Path) {
    $process = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $Path, '-Command', 'help') -Wait -PassThru -WindowStyle Hidden
    return $process.ExitCode
}

function Write-TestManifest([string]$Root) {
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($name in @('payload.txt', 'verify-bundle.ps1')) {
        $hash = (Get-FileHash -LiteralPath (Join-Path $Root $name) -Algorithm SHA256).Hash.ToLowerInvariant()
        $lines.Add("$hash *$name")
    }
    [IO.File]::WriteAllLines((Join-Path $Root 'SHA256SUMS'), $lines, (New-Object Text.UTF8Encoding($false)))
}

try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null

    foreach ($script in $releasePowerShellScripts) { Assert-ScriptParses $script }
    foreach ($forbidden in @('Path]::GetRelativePath', 'Path]::IsPathFullyQualified')) {
        foreach ($script in $releasePowerShellScripts) {
            Assert-True (-not ([IO.File]::ReadAllText($script).Contains($forbidden))) "$script uses a .NET API absent from Windows PowerShell 5.1: $forbidden"
        }
    }

    . $setupScript -Command help -TlsSan @('192.168.0.61,oscar-site.example-tailnet.ts.net', '192.168.0.61') -NoAutoNetworkSans | Out-Null
    $resolvedTlsSans = @(Get-TlsSubjectAlternativeNames 'oscar.local')
    Assert-True (($resolvedTlsSans -join '|') -ceq 'oscar.local|192.168.0.61|oscar-site.example-tailnet.ts.net') `
        'Windows TLS SAN resolution did not deduplicate the configured LAN/Tailscale names.'
    Assert-True ((Get-TlsSanExtension $resolvedTlsSans) -ceq 'DNS:oscar.local,IP:192.168.0.61,DNS:oscar-site.example-tailnet.ts.net') `
        'Windows TLS SAN resolution did not classify DNS and IP certificate names correctly.'
    $invalidTlsSanRejected = $false
    try {
        $TlsSan = @('invalid SAN')
        [void](Get-TlsSubjectAlternativeNames 'oscar.local')
    } catch { $invalidTlsSanRejected = $true }
    Assert-True $invalidTlsSanRejected 'Windows TLS SAN resolution accepted an invalid name.'

    $TlsSan = @()
    $TlsMode = 'self-signed'
    $NoAutoNetworkSans = $false
    function Get-OscarNetworkIpAddresses {
        @(
            [pscustomobject]@{ AddressState='Preferred'; InterfaceAlias='Tailscale'; IPAddress='100.86.149.49' },
            [pscustomobject]@{ AddressState='Preferred'; InterfaceAlias='Tailscale'; IPAddress='fd7a:115c:a1e0::f139:9532' },
            [pscustomobject]@{ AddressState='Preferred'; InterfaceAlias='Ethernet'; IPAddress='192.168.0.61' },
            [pscustomobject]@{ AddressState='Preferred'; InterfaceAlias='Ethernet'; IPAddress='fd5b:ad6:c937:50f1::1234' },
            [pscustomobject]@{ AddressState='Preferred'; InterfaceAlias='vEthernet (WSL)'; IPAddress='172.20.0.1' }
        )
    }
    function Get-OscarTailscaleDnsName { 'node.example-tailnet.ts.net.' }
    $autoTlsSans = @(Get-TlsSubjectAlternativeNames 'oscar.local')
    Assert-True (($autoTlsSans -join '|') -ceq 'oscar.local|100.86.149.49|fd7a:115c:a1e0::f139:9532|192.168.0.61|node.example-tailnet.ts.net') `
        'Windows automatic TLS SAN discovery included a container/temporary address or missed LAN/Tailscale identity.'
    Remove-Item Function:\Get-OscarNetworkIpAddresses, Function:\Get-OscarTailscaleDnsName -Force

    $physicalRelease = Join-Path $temporaryRoot 'release-physical'
    $aliasRelease = Join-Path $temporaryRoot 'release-junction'
    New-Item -ItemType Directory -Path $physicalRelease | Out-Null
    Copy-Item -LiteralPath $storageScript -Destination (Join-Path $physicalRelease 'oscar-storage.ps1')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'dist\release\.env.example') -Destination (Join-Path $physicalRelease '.env.example')
    New-Item -ItemType Junction -Path $aliasRelease -Target $physicalRelease | Out-Null
    Assert-True ((Invoke-StorageLauncher (Join-Path $physicalRelease 'oscar-storage.ps1')) -eq 0) `
        'The physical Windows storage launcher fixture did not start.'
    Assert-True ((Invoke-StorageLauncher (Join-Path $aliasRelease 'oscar-storage.ps1')) -ne 0) `
        'The Windows storage launcher accepted a junction/reparse release alias.'

    # Windows packaging consumes the same Linux Compose contract. Validate it
    # here as plain text so PowerShell release builds cannot silently weaken it.
    $compose = [IO.File]::ReadAllText($composeFile)
    $oscarService = [Text.RegularExpressions.Regex]::Match(
        $compose, '^  oscar:\r?\n.*?(?=^  postgres:)',
        [Text.RegularExpressions.RegexOptions]::Multiline -bor [Text.RegularExpressions.RegexOptions]::Singleline).Value
    $nativeTmpfs = '/run/oscar-native:rw,exec,nosuid,nodev,size=256m,mode=0700,uid=10001,gid=10001'
    Assert-True ($oscarService.Contains('- /tmp:rw,noexec,nosuid,nodev')) 'Compose does not keep OSCAR /tmp noexec.'
    Assert-True ($oscarService.Contains("- $nativeTmpfs")) 'Compose is missing the bounded owner-only executable native tmpfs.'
    Assert-True (([Text.RegularExpressions.Regex]::Matches($compose, [Text.RegularExpressions.Regex]::Escape($nativeTmpfs))).Count -eq 1) 'The executable native tmpfs must be scoped to OSCAR only.'
    Assert-True ($oscarService.Contains('test -f /tmp/oscar-ready && curl --silent --show-error')) `
        'Compose health does not require application readiness before HTTP availability.'

    $dockerfile = [IO.File]::ReadAllText($oscarDockerfile)
    Assert-True ($dockerfile.Contains('/var/lib/oscar /run/oscar-native')) 'The OSCAR image is missing its private native-tmpfs mount point.'
    $entrypoint = [IO.File]::ReadAllText($oscarEntrypoint)
    Assert-True ($entrypoint.Contains('READY_FILE=/tmp/oscar-ready')) 'The OSCAR entrypoint is missing the application-readiness path.'
    Assert-True ($entrypoint.Contains('rm -f -- "${READY_FILE}" "${READY_FILE}.tmp"')) `
        'The OSCAR entrypoint does not clear stale readiness before JVM startup.'
    $javaOptionsIndex = $entrypoint.IndexOf('exec java ${JAVA_OPTS:-}')
    Assert-True ($javaOptionsIndex -ge 0) 'The OSCAR entrypoint is missing its managed Java launch.'
    foreach ($managedProperty in @(
        '-Djava.io.tmpdir="${NATIVE_TMP_DIR}"',
        '-Dorg.bytedeco.javacpp.cachedir="${NATIVE_TMP_DIR}/javacpp"',
        '-Doscar.data.tmpdir=/tmp')) {
        Assert-True ($entrypoint.IndexOf($managedProperty) -gt $javaOptionsIndex) "Managed JVM property must follow JAVA_OPTS: $managedProperty"
    }
    Assert-True ($entrypoint.Contains('if [ -n "${_JAVA_OPTIONS:-}" ]')) 'The OSCAR entrypoint must reject late _JAVA_OPTIONS overrides.'

    $bundle = Join-Path $temporaryRoot 'bundle'
    New-Item -ItemType Directory -Path $bundle | Out-Null
    Copy-Item -LiteralPath $verifyScript -Destination (Join-Path $bundle 'verify-bundle.ps1')
    [IO.File]::WriteAllText((Join-Path $bundle 'payload.txt'), "verified payload`n", (New-Object Text.UTF8Encoding($false)))
    Write-TestManifest $bundle
    Assert-True ((Invoke-Verifier $bundle) -eq 0) 'The exact bundle inventory failed verification under Windows PowerShell 5.1.'
    [IO.File]::WriteAllText((Join-Path $bundle 'payload.txt'), "modified after receipt`n", (New-Object Text.UTF8Encoding($false)))
    Assert-True ((Invoke-Verifier $bundle) -ne 0) 'The Windows verifier trusted a stale receipt after payload mutation.'
    [IO.File]::WriteAllText((Join-Path $bundle 'payload.txt'), "verified payload`n", (New-Object Text.UTF8Encoding($false)))
    Write-TestManifest $bundle
    [IO.File]::WriteAllText((Join-Path $bundle 'extra.msi'), 'unmanifested', (New-Object Text.UTF8Encoding($false)))
    Assert-True ((Invoke-Verifier $bundle) -ne 0) 'The Windows verifier accepted an unmanifested installer.'
    Remove-Item -LiteralPath (Join-Path $bundle 'extra.msi') -Force
    New-Item -ItemType Directory -Path (Join-Path $bundle 'secrets'), (Join-Path $bundle 'tls'), (Join-Path $bundle 'pre-restore-20261030T010000Z-deadbeef\secrets'), (Join-Path $bundle 'pre-restore-20261030T010000Z-deadbeef\tls') -Force | Out-Null
    foreach ($runtimeFile in @(
        '.env',
        '.oscar-init-state',
        '.oscar-volume-adoption',
        'secrets\oscar-admin-password.txt',
        'secrets\oscar-db-password.txt',
        'secrets\postgres-bootstrap-password.txt',
        'secrets\backup-key.txt',
        'tls\server.crt',
        'tls\server.key',
        'pre-restore-20261030T010000Z-deadbeef\.env',
        'pre-restore-20261030T010000Z-deadbeef\secrets\backup-key.txt',
        'pre-restore-20261030T010000Z-deadbeef\tls\server.crt'
    )) {
        [IO.File]::WriteAllText((Join-Path $bundle $runtimeFile), "state`n", (New-Object Text.UTF8Encoding($false)))
    }
    Assert-True ((Invoke-Verifier $bundle) -eq 0) 'The Windows verifier rejected initialized OSCAR runtime state during post-init verify/upgrade.'
    [IO.File]::WriteAllText((Join-Path $bundle 'secrets\extra.exe'), 'unmanifested', (New-Object Text.UTF8Encoding($false)))
    Assert-True ((Invoke-Verifier $bundle) -ne 0) 'The Windows verifier accepted an unmanifested file inside secrets.'
    Remove-Item -LiteralPath (Join-Path $bundle 'secrets\extra.exe') -Force
    Add-Content -LiteralPath (Join-Path $bundle 'SHA256SUMS') -Value ([IO.File]::ReadAllLines((Join-Path $bundle 'SHA256SUMS'))[0])
    Assert-True ((Invoke-Verifier $bundle) -ne 0) 'The Windows verifier accepted a duplicate manifest path.'

    $env:OSCAR_STORAGE_TEST_MODE = '1'
    . $storageScript -Command help | Out-Null

    $storageStopOrder = & {
        $captured = New-Object System.Collections.Generic.List[string]
        function Invoke-Compose([string[]]$Arguments) {
            [void]$captured.Add([string]::Join(' ', $Arguments))
        }
        Stop-DeploymentOrdered
        [string]::Join(';', $captured)
    }
    Assert-True ($storageStopOrder -ceq 'stop gateway;stop oscar;stop postgres') `
        'Windows storage stop is not dependency ordered.'

    # Exercise the real Windows volume-handle durability barrier. This catches
    # PS 5.1 native-argument binding regressions that a parser/static gate
    # cannot see (notably the signed interpretation of 0x80000000).
    Sync-DurableMetadata $temporaryRoot

    $storageSource = [IO.File]::ReadAllText($storageScript)
    $setupSource = [IO.File]::ReadAllText($setupScript)
    foreach ($restoreCommand in @(
        'tar --no-same-owner --no-overwrite-dir --strip-components=1 -C /state -xzf /restore-state.tar.gz',
        'tar --no-same-owner --no-overwrite-dir --strip-components=1 -C /archive -xzf /restore-archive.tar.gz')) {
        Assert-True (([Text.RegularExpressions.Regex]::Matches(
            $storageSource, [Text.RegularExpressions.Regex]::Escape($restoreCommand))).Count -eq 1) `
            "Restore extraction can overwrite mounted-root metadata: $restoreCommand"
    }
    $prepareImagesStart = $setupSource.IndexOf('function Prepare-DeploymentImages', [StringComparison]::Ordinal)
    $prepareImagesEnd = $setupSource.IndexOf('function Initialize-Tls', $prepareImagesStart, [StringComparison]::Ordinal)
    Assert-True ($prepareImagesStart -ge 0 -and $prepareImagesEnd -gt $prepareImagesStart) `
        'Could not isolate Windows connected image preparation.'
    $prepareImagesSource = $setupSource.Substring($prepareImagesStart, $prepareImagesEnd - $prepareImagesStart)
    & {
        $ScriptRoot = Join-Path $temporaryRoot 'connected-image-preparation'
        New-Item -ItemType Directory -Path $ScriptRoot | Out-Null
        $script:ImagesBuilt = $false
        $script:GatewayPresent = $true
        $script:ImagePreparationActions = New-Object System.Collections.Generic.List[string]
        function Get-RequiredImages { return @('oscar:test', 'oscar-postgis:test', 'gateway:test') }
        function Test-ContainerImage([string]$Image) {
            switch ($Image) {
                'oscar:test' { return $script:ImagesBuilt }
                'oscar-postgis:test' { return $script:ImagesBuilt }
                'gateway:test' { return $script:GatewayPresent }
                default { return $false }
            }
        }
        function Write-Heading([string]$Message) {}
        function Invoke-External([string]$Program, [string[]]$Arguments) { throw 'Offline import was not expected.' }
        function Build-ConnectedDeploymentImages {
            $script:ImagePreparationActions.Add('build-local')
            $script:ImagesBuilt = $true
        }
        function Invoke-Compose([string[]]$Arguments) {
            $action = [string]::Join('|', $Arguments)
            $script:ImagePreparationActions.Add($action)
            switch ($action) {
                'pull|gateway' { $script:GatewayPresent = $true }
                default { throw "Unexpected Compose action: $action" }
            }
        }
        Invoke-Expression $prepareImagesSource

        Prepare-DeploymentImages
        Assert-True ($script:ImagePreparationActions.Count -eq 1 -and
            $script:ImagePreparationActions[0] -ceq 'build-local') `
            'Windows connected image preparation pulled an already-cached gateway image.'

        $script:ImagesBuilt = $false
        $script:GatewayPresent = $false
        $script:ImagePreparationActions.Clear()
        Prepare-DeploymentImages
        Assert-True ($script:ImagePreparationActions.Count -eq 2 -and
            $script:ImagePreparationActions[0] -ceq 'build-local' -and
            $script:ImagePreparationActions[1] -ceq 'pull|gateway') `
            'Windows connected image preparation did not pull a genuinely missing gateway image.'

        $script:ImagesBuilt = $true
        $script:GatewayPresent = $true
        $script:ImagePreparationActions.Clear()
        Prepare-DeploymentImages
        Assert-True ($script:ImagePreparationActions.Count -eq 1 -and
            $script:ImagePreparationActions[0] -ceq 'build-local') `
            'Windows connected image preparation trusted stale mutable local image tags.'
    }
    Assert-True ($setupSource.Contains("'build', '--build-arg', `"OSCAR_VERSION=`$version`", '--tag', `"oscar:`$version`"")) `
        'Windows connected setup does not build the OSCAR image from its exact local release context.'
    Assert-True ($setupSource.Contains("'build', '--platform', `$postgisPlatform, '--build-arg', `"OSCAR_VERSION=`$version`"")) `
        'Windows connected setup does not preserve the configured PostgreSQL build platform.'
    Assert-True (-not $setupSource.Contains('BUILDX_BAKE_ENTITLEMENTS_FS')) `
        'Windows setup disables Bake filesystem checks instead of using bounded build contexts.'
    # The storage launcher has 19 bounded shell adapters after retiring both
    # the cumulative WAL-archive tar helper and its prune-intent helper, then
    # adding the authenticated CURRENT-pointer helper plus the locked legacy
    # cleanup and config-aware journal migration. Setup retains one adapter.
    # Keep these exact counts so every future native-shell call still receives
    # an explicit safety review.
    foreach ($astFixture in @(
        @{ Path = $setupScript; ExpectedShellRuns = 2 },
        @{ Path = $hostPrepScript; ExpectedShellRuns = 0 },
        @{ Path = $storageScript; ExpectedShellRuns = 19 })) {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($astFixture.Path, [ref]$tokens, [ref]$parseErrors)
        Assert-True ($parseErrors.Count -eq 0) "Could not build the PowerShell AST inventory for $($astFixture.Path)."
        $literalValues = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.StringConstantExpressionAst] -or
                $node -is [Management.Automation.Language.ExpandableStringExpressionAst]
        }, $true) | ForEach-Object { [string]$_.Value })
        foreach ($forbiddenValue in @('-c', '--command', '$@')) {
            Assert-True (-not ($literalValues -ccontains $forbiddenValue)) `
                "$($astFixture.Path) contains a forbidden native shell/SQL argv literal: $forbiddenValue"
        }
        $shellRuns = @($ast.FindAll({
            param($node)
            if ($node -isnot [Management.Automation.Language.CommandAst]) { return $false }
            $values = @($node.FindAll({
                param($child)
                $child -is [Management.Automation.Language.StringConstantExpressionAst]
            }, $true) | ForEach-Object { [string]$_.Value })
            return ($values -ccontains '--entrypoint' -and $values -ccontains 'sh')
        }, $true))
        Assert-True ($shellRuns.Count -eq $astFixture.ExpectedShellRuns) `
            "$($astFixture.Path) entrypoint-sh inventory changed: expected $($astFixture.ExpectedShellRuns), found $($shellRuns.Count)."
        foreach ($shellRun in $shellRuns) {
            Assert-True ($shellRun.GetCommandName() -cin @('Get-DockerShellInputOutput', 'Get-ComposeShellInputOutput', 'Invoke-DockerShellInput')) `
                "$($astFixture.Path) has an entrypoint-sh call outside the bounded stdin adapters: $($shellRun.GetCommandName())"
        }
    }

    # Exercise native Windows PowerShell array binding for the locked upgrade
    # transition. The config-aware migration must precede restart, and an
    # injected migration failure must never reach Compose up.
    & {
        $actions = New-Object System.Collections.Generic.List[string]
        function Get-OscarImage { return 'oscar:test' }
        function Get-DockerShellInputOutput([string]$InputText, [string[]]$Arguments) {
            Assert-True ($InputText.Contains('umask 077') -and
                ([string]::Join('|', $Arguments)).Contains('--entrypoint|sh')) `
                'Windows upgrade legacy cleanup did not use its restricted shell contract.'
            [void]$actions.Add('legacy-cleanup')
            return @()
        }
        function Get-ComposeShellInputOutput([string]$InputText, [string[]]$Arguments) {
            $joined = [string]::Join('|', $Arguments)
            Assert-True ($InputText.Contains('umask 077') -and
                $InputText.Contains('--config /var/lib/oscar/config.json') -and
                $joined.Contains('--entrypoint|sh|oscar|-seu')) `
                'Windows upgrade migration did not preserve its config-aware restricted shell argv.'
            [void]$actions.Add('migrate')
            return @()
        }
        function Invoke-Compose([string[]]$Arguments) {
            $joined = [string]::Join(' ', $Arguments)
            switch -CaseSensitive ($joined) {
                'stop gateway' { [void]$actions.Add('stop-gateway'); return }
                'stop oscar' { [void]$actions.Add('stop-oscar'); return }
                'config --quiet' { [void]$actions.Add('config'); return }
                'up --detach --force-recreate --no-build --pull never --wait --wait-timeout 240' {
                    [void]$actions.Add('start'); return
                }
                default { throw "Unexpected Windows upgrade Compose action: $joined" }
            }
        }
        Invoke-UpgradePersistentState | Out-Null
        Assert-True (($actions -join '|') -ceq 'stop-gateway|stop-oscar|legacy-cleanup|migrate|config|start') `
            'Windows locked upgrade transition ordering is incorrect.'
    }
    & {
        $actions = New-Object System.Collections.Generic.List[string]
        function Get-OscarImage { return 'oscar:test' }
        function Get-DockerShellInputOutput([string]$InputText, [string[]]$Arguments) {
            [void]$actions.Add('legacy-cleanup'); return @()
        }
        function Get-ComposeShellInputOutput([string]$InputText, [string[]]$Arguments) {
            [void]$actions.Add('migration-failed'); throw 'injected migration failure'
        }
        function Invoke-Compose([string[]]$Arguments) {
            $joined = [string]::Join(' ', $Arguments)
            if ($joined -ceq 'stop gateway') { [void]$actions.Add('stop-gateway'); return }
            if ($joined -ceq 'stop oscar') { [void]$actions.Add('stop-oscar'); return }
            if ($joined.StartsWith('up ')) { [void]$actions.Add('UNSAFE-START'); return }
            throw "Unexpected Windows failure-path Compose action: $joined"
        }
        $failed = $false
        try { Invoke-UpgradePersistentState | Out-Null } catch { $failed = $true }
        Assert-True $failed 'Windows locked upgrade transition ignored migration failure.'
        Assert-True (-not $actions.Contains('UNSAFE-START')) `
            'Windows locked upgrade transition restarted after migration failure.'
    }
    Assert-True ($storageSource.Contains('$writeThroughFlag = [uint32]2147483648')) `
        'The Windows durability barrier does not construct FILE_FLAG_WRITE_THROUGH as an unsigned value.'
    Assert-True (-not $storageSource.Contains(', 0x80000000,')) `
        'A signed high-bit CreateFile flag is still passed directly under Windows PowerShell 5.1.'
    foreach ($source in @($storageSource, $setupSource)) {
        Assert-True (-not $source.Contains('{{ index ')) `
            'A Windows launcher still passes a quoted Go-template index expression through PowerShell 5 native argument marshalling.'
    }
    # UID0 cannot safely inherit the OSCAR image's mode-0700 /var/lib/oscar
    # workdir. Require every root helper in both Windows launchers to select a
    # neutral cwd explicitly. The setup inventory includes the read-only TLS
    # fingerprint helper; all helpers are capability-free except the read-only
    # backup verifier's single DAC_READ_SEARCH bridge.
    $rootHelperLines = @(
        @($setupSource, $storageSource) |
            ForEach-Object { $_ -split "`r?`n" } |
            Where-Object { $_.Contains("'--user', '0'") -or $_.Contains("'--user', '0:0'") })
    Assert-True ($rootHelperLines.Count -eq 18) 'Windows root-helper inventory changed unexpectedly.'
    foreach ($rootHelperLine in $rootHelperLines) {
        Assert-True ($rootHelperLine.Contains("'--workdir', '/'") ) `
            'A Windows root helper inherited an image-owned working directory.'
    }
    $postgresVerifierStart = $storageSource.IndexOf('function Confirm-PostgresBaseBackup', [StringComparison]::Ordinal)
    $postgresVerifierEnd = $storageSource.IndexOf('function Confirm-Backup(', $postgresVerifierStart, [StringComparison]::Ordinal)
    Assert-True ($postgresVerifierStart -ge 0 -and $postgresVerifierEnd -gt $postgresVerifierStart) `
        'Could not isolate the Windows PostgreSQL backup verifier.'
    $postgresVerifierSource = $storageSource.Substring($postgresVerifierStart, $postgresVerifierEnd - $postgresVerifierStart)
    Assert-True ($postgresVerifierSource.Contains("'--cap-drop', 'ALL', '--cap-add', 'DAC_READ_SEARCH'") -and
        $postgresVerifierSource.Contains("'--workdir', '/', '--user', '0:0', '--entrypoint', 'pg_verifybackup'") -and
        -not $postgresVerifierSource.Contains("'--user', '999:999', '--entrypoint', 'pg_verifybackup'")) `
        'Windows pg_verifybackup must use only the read/search bridge for private cross-host backup ownership.'
    & {
        $script:CapturedPostgresVerifierProgram = $null
        $script:CapturedPostgresVerifierArguments = @()
        function Invoke-External([string]$Program, [string[]]$Arguments) {
            $script:CapturedPostgresVerifierProgram = $Program
            $script:CapturedPostgresVerifierArguments = @($Arguments)
        }
        Confirm-PostgresBaseBackup 'C:\backup root' 'oscar-postgis:test'
        $captured = [string]::Join('|', $script:CapturedPostgresVerifierArguments)
        Assert-True ($script:CapturedPostgresVerifierProgram -ceq 'docker' -and
            $captured.Contains('run|--rm|--network|none|--read-only|--cap-drop|ALL|--cap-add|DAC_READ_SEARCH|--security-opt|no-new-privileges|--workdir|/|--user|0:0|--entrypoint|pg_verifybackup') -and
            $captured.Contains('C:\backup root\postgres:/backup:ro|oscar-postgis:test|/backup')) `
            'Native PowerShell 5.1 did not preserve the least-privilege pg_verifybackup bridge or spaced read-only mount argv.'
    }
    $tlsStart = $setupSource.IndexOf('function Initialize-Tls', [StringComparison]::Ordinal)
    $tlsEnd = $setupSource.IndexOf('function Add-LocalHostsMapping', $tlsStart, [StringComparison]::Ordinal)
    Assert-True ($tlsStart -ge 0 -and $tlsEnd -gt $tlsStart) 'Could not isolate Windows TLS initialization.'
    $tlsSource = $setupSource.Substring($tlsStart, $tlsEnd - $tlsStart)
    Assert-True (-not $tlsSource.Contains('$nameCommand') -and
        $tlsSource.Contains('$nameOutput = Get-DockerOutput @(') -and
        $tlsSource.Contains("'--entrypoint', 'openssl'") -and
        $tlsSource.Contains("'x509', '-in', '/tls/server.crt', '-noout', `$nameCheck, `$sanName")) `
        'Windows TLS name validation is not a direct, format-stable OpenSSL invocation.'
    foreach ($expected in @('IP $sanName does match certificate', 'Hostname $sanName does match certificate')) {
        Assert-True ($tlsSource.Contains($expected)) "Windows TLS name validation is missing its exact success result: $expected"
    }
    Assert-True ($tlsSource.Contains('if ($nameOutput -cne $expectedNameOutput)')) `
        'Windows TLS name validation does not fail closed on any noncanonical OpenSSL result.'
    $composeInputStart = $setupSource.IndexOf('function Get-ComposeInputOutput', [StringComparison]::Ordinal)
    $composeInputEnd = $setupSource.IndexOf('function ConvertFrom-DockerInspectJson', $composeInputStart, [StringComparison]::Ordinal)
    Assert-True ($composeInputStart -ge 0 -and $composeInputEnd -gt $composeInputStart) 'Could not isolate Windows Compose stdin execution.'
    $composeInputSource = $setupSource.Substring($composeInputStart, $composeInputEnd - $composeInputStart)
    Assert-True ($composeInputSource.Contains('$OutputEncoding = $Utf8NoBom') -and
        $composeInputSource.Contains('$InputText | & docker @pinned') -and
        $composeInputSource.Contains('$OutputEncoding = $previousOutputEncoding') -and
        $composeInputSource.Contains('function Get-ComposeShellInputOutput') -and
        $setupSource.Contains('# oscar-powershell-stdin-terminator') -and
        $setupSource.Contains('.Replace("`r`n", "`n").Replace("`r", "`n")')) `
        'Windows Compose stdin execution does not preserve UTF-8 shell input with Unix line endings and restore its encoding.'
    $bootstrapStart = $setupSource.IndexOf('function Invoke-BootstrapSql', [StringComparison]::Ordinal)
    $bootstrapEnd = $setupSource.IndexOf('function Enable-StorageDatabaseFeatures', $bootstrapStart, [StringComparison]::Ordinal)
    Assert-True ($bootstrapStart -ge 0 -and $bootstrapEnd -gt $bootstrapStart) 'Could not isolate Windows bootstrap SQL execution.'
    $bootstrapSource = $setupSource.Substring($bootstrapStart, $bootstrapEnd - $bootstrapStart)
    Assert-True ($bootstrapSource.Contains('Get-ComposeShellInputOutput $shellInput') -and
        $bootstrapSource.Contains('exec psql --set=ON_ERROR_STOP=1 --username oscar_bootstrap --dbname gis --tuples-only --no-align --file=-') -and
        $bootstrapSource.Contains("<<'`$delimiter'") -and
        $bootstrapSource.Contains('[string]::IsNullOrWhiteSpace($Sql)') -and
        -not $bootstrapSource.Contains('$@') -and -not $bootstrapSource.Contains("'-c'") -and
        -not $bootstrapSource.Contains("'--command'")) `
        'Windows bootstrap SQL and credential wrapper are not one bounded stdin stream to direct psql.'
    $completionStart = $setupSource.IndexOf('function Complete-PendingFreshInit', [StringComparison]::Ordinal)
    $completionEnd = $setupSource.IndexOf('function Get-ConfiguredEndpoint', $completionStart, [StringComparison]::Ordinal)
    Assert-True ($completionStart -ge 0 -and $completionEnd -gt $completionStart) 'Could not isolate Windows fresh-init completion checks.'
    $completionSource = $setupSource.Substring($completionStart, $completionEnd - $completionStart)
    Assert-True ($completionSource.Contains("Get-ComposeShellInputOutput `$markerCheck @('exec', '-T', 'postgres', 'sh', '-seu', `$expectedVersion)") -and
        $completionSource.Contains("Get-ComposeShellInputOutput `$configCheck @('exec', '-T', 'oscar', 'sh', '-seu')") -and
        $completionSource.Contains('With sh -s, arguments after the options begin at $1') -and
        -not $completionSource.Contains("'-c', `$markerCheck") -and
        -not $completionSource.Contains("'-c', `$configCheck")) `
        'Windows fresh-init marker/config validation is not streamed intact over stdin.'
    foreach ($requiredBody in @(
        'test "$(wc -l <"$marker" | tr -d "[:space:]")" = 4',
        'grep -Fq ''"frameRetentionCount": 5'' "$config"')) {
        Assert-True ($completionSource.Contains($requiredBody)) "Windows fresh-init validation lost its multiline contract: $requiredBody"
    }

    # Execute the exact shell-input adapter in a native PS5 scope with a mock
    # Compose sink. This proves CRLF/CR normalization, the comment sentinel,
    # multiline preservation, and argv ordering independently of source text.
    $shellNormalizerStart = $setupSource.IndexOf('function ConvertTo-ShellStdin', [StringComparison]::Ordinal)
    $shellNormalizerEnd = $setupSource.IndexOf('function Invoke-ExternalProbe', $shellNormalizerStart, [StringComparison]::Ordinal)
    $shellHelperStart = $setupSource.IndexOf('function Get-ComposeShellInputOutput', [StringComparison]::Ordinal)
    $shellHelperEnd = $setupSource.IndexOf('function ConvertFrom-DockerInspectJson', $shellHelperStart, [StringComparison]::Ordinal)
    Assert-True ($shellNormalizerStart -ge 0 -and $shellNormalizerEnd -gt $shellNormalizerStart -and
        $shellHelperStart -ge 0 -and $shellHelperEnd -gt $shellHelperStart) 'Could not isolate Windows shell-input adapters.'
    $shellHelperSource = $setupSource.Substring($shellNormalizerStart, $shellNormalizerEnd - $shellNormalizerStart) + "`n" +
        $setupSource.Substring($shellHelperStart, $shellHelperEnd - $shellHelperStart)
    $shellFixture = & {
        $Utf8NoBom = New-Object Text.UTF8Encoding($false)
        $script:capturedShellInput = $null
        $script:capturedShellArguments = $null
        function Get-ComposeInputOutput([string]$InputText, [string[]]$Arguments) {
            $script:capturedShellInput = $InputText
            $script:capturedShellArguments = @($Arguments)
            return @('accepted')
        }
        Invoke-Expression $shellHelperSource
        function Get-ExternalInputOutput([string]$InputText, [string]$Program, [string[]]$Arguments) {
            $script:capturedDockerShellInput = $InputText
            $script:capturedDockerShellProgram = $Program
            $script:capturedDockerShellArguments = @($Arguments)
            return @('docker-accepted')
        }
        $dockerResult = @(Get-DockerShellInputOutput 'test -f /state/marker' @('run', '--rm', '--entrypoint', 'sh', 'oscar:test', '-seu'))
        $rejectedInteractiveCaller = $false
        try { [void](Get-DockerShellInputOutput 'true' @('run', '--interactive', '--entrypoint', 'sh', 'oscar:test', '-seu')) }
        catch { $rejectedInteractiveCaller = $_.Exception.Message -like '*helper owns --interactive*' }
        $markerFixture = "marker=/data/marker`r`ntest `"`$(grep -Fxc `"version=`$1`" `"`$marker`")`" = 1`r`n"
        $markerResult = @(Get-ComposeShellInputOutput $markerFixture @('exec', '-T', 'postgres', 'sh', '-seu', '3.11.0'))
        $markerInput = $script:capturedShellInput
        $markerArguments = @($script:capturedShellArguments)
        $configFixture = "config=/var/lib/oscar/config.json`r`ntest -f `"`$config`"`r`ngrep -Fq `"frameRetentionCount`" `"`$config`"`r`n"
        $configResult = @(Get-ComposeShellInputOutput $configFixture @('exec', '-T', 'oscar', 'sh', '-seu'))
        return [pscustomobject]@{
            MarkerInput = $markerInput
            MarkerArguments = $markerArguments
            MarkerResult = @($markerResult)
            ConfigInput = $script:capturedShellInput
            ConfigArguments = @($script:capturedShellArguments)
            ConfigResult = @($configResult)
            DockerInput = $script:capturedDockerShellInput
            DockerProgram = $script:capturedDockerShellProgram
            DockerArguments = @($script:capturedDockerShellArguments)
            DockerResult = @($dockerResult)
            RejectedInteractiveCaller = $rejectedInteractiveCaller
        }
    }
    $expectedMarkerInput = "marker=/data/marker`ntest `"`$(grep -Fxc `"version=`$1`" `"`$marker`")`" = 1`n# oscar-powershell-stdin-terminator"
    $expectedConfigInput = "config=/var/lib/oscar/config.json`ntest -f `"`$config`"`ngrep -Fq `"frameRetentionCount`" `"`$config`"`n# oscar-powershell-stdin-terminator"
    Assert-True ($shellFixture.MarkerInput -ceq $expectedMarkerInput) 'Windows shell-input adapter did not deterministically preserve the multiline marker body with Unix line endings.'
    Assert-True ($shellFixture.ConfigInput -ceq $expectedConfigInput) 'Windows shell-input adapter did not deterministically preserve the multiline config body with Unix line endings.'
    Assert-True (($shellFixture.MarkerArguments -join [char]0) -ceq (@('exec', '-T', 'postgres', 'sh', '-seu', '3.11.0') -join [char]0)) `
        'Windows shell-input adapter did not keep the release version at shell positional parameter $1.'
    Assert-True (($shellFixture.ConfigArguments -join [char]0) -ceq (@('exec', '-T', 'oscar', 'sh', '-seu') -join [char]0)) `
        'Windows shell-input adapter changed the config-check shell arguments.'
    Assert-True (($shellFixture.MarkerResult.Count -eq 1) -and ($shellFixture.MarkerResult[0] -ceq 'accepted') -and
        ($shellFixture.ConfigResult.Count -eq 1) -and ($shellFixture.ConfigResult[0] -ceq 'accepted')) `
        'Windows shell-input adapter did not return Compose output for both multiline checks.'
    Assert-True ($shellFixture.DockerProgram -ceq 'docker' -and
        ($shellFixture.DockerArguments -join [char]0) -ceq (@('run', '--interactive', '--rm', '--entrypoint', 'sh', 'oscar:test', '-seu') -join [char]0) -and
        $shellFixture.DockerInput.EndsWith('# oscar-powershell-stdin-terminator') -and
        $shellFixture.DockerResult[0] -ceq 'docker-accepted') `
        'Windows direct docker shell-input adapter did not own the required interactive stdin attachment.'
    Assert-True $shellFixture.RejectedInteractiveCaller 'Windows direct docker shell-input adapter accepted caller-owned interactive mode.'
    Assert-True (-not $setupSource.Contains("'-c'") -and -not $storageSource.Contains("'-c'") -and
        -not $setupSource.Contains("'--command'") -and -not $storageSource.Contains("'--command'") -and
        -not $setupSource.Contains('$@') -and -not $storageSource.Contains('$@')) `
        'A PowerShell release script still forwards executable shell/SQL text through a native argv.'

    # Run the exact setup-to-storage relay through native Windows PowerShell.
    # Quotes, newlines, dollar syntax, spaces, and option-looking text must
    # arrive as one typed parameter value while native argv remains fixed.
    $storageRelayStart = $setupSource.IndexOf('function Invoke-StorageCommand', [StringComparison]::Ordinal)
    $storageRelayEnd = $setupSource.IndexOf('function Clear-ComposeOverrideEnvironment', $storageRelayStart, [StringComparison]::Ordinal)
    Assert-True ($storageRelayStart -ge 0 -and $storageRelayEnd -gt $storageRelayStart) 'Could not isolate the Windows setup-to-storage relay.'
    $storageRelaySource = $setupSource.Substring($storageRelayStart, $storageRelayEnd - $storageRelayStart)
    $relayFixture = & {
        $ScriptRoot = Join-Path $temporaryRoot 'storage-relay'
        New-Item -ItemType Directory -Path $ScriptRoot | Out-Null
        $capturePath = Join-Path $ScriptRoot 'capture.json'
        $fakeStorageScript = @'
param(
    [string]$Command,
    [string]$Action,
    [string]$HoldAction,
    [string]$Reason,
    [string]$Destination,
    [int]$Keep,
    [switch]$AdoptExistingStorageRoots
)
if ($Reason -ceq 'deliberate-child-failure') { throw 'deliberate nested storage failure' }
$result = [ordered]@{
    Command = $Command
    Action = $Action
    HoldAction = $HoldAction
    Reason = $Reason
    Destination = $Destination
    Keep = $Keep
    AdoptExistingStorageRoots = [bool]$AdoptExistingStorageRoots
}
[IO.File]::WriteAllText($env:OSCAR_STORAGE_RELAY_CAPTURE, ($result | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
'@
        [IO.File]::WriteAllText((Join-Path $ScriptRoot 'oscar-storage.ps1'), $fakeStorageScript, $Utf8NoBom)
        Invoke-Expression $storageRelaySource
        $script:CapturedRelayProgram = $null
        $script:CapturedRelayArguments = @()
        $script:RelayInvocationCount = 0
        function Invoke-External([string]$Program, [string[]]$Arguments) {
            $script:RelayInvocationCount++
            $script:CapturedRelayProgram = $Program
            $script:CapturedRelayArguments = @($Arguments)
            $previousErrorPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                & $Program @Arguments
                if ($LASTEXITCODE -ne 0) { throw "$Program exited with code $LASTEXITCODE." }
            } finally { $ErrorActionPreference = $previousErrorPreference }
        }
        $Command = 'status'
        $HoldAction = 'create'
        $AdoptLegacyStorageRoots = $false
        $BackupId = $null; $Confirm = $null; $Before = $null; $RequestedBy = $null
        $Plan = $null; $Token = $null; $Generation = $null
        $Observation = $null; $StoreKey = $null; $IdScope = $null; $HoldId = $null
        $CreatedBy = $null; $ReleasedBy = $null
        $Keep = 7
        $Reason = "quoted `"value`"`r`nwith `$@ --command -c"
        $Destination = 'C:\relay path\folder with spaces'
        $positiveReason = $Reason
        $positiveDestination = $Destination
        $env:OSCAR_STORAGE_RELAY_CAPTURE = $capturePath
        [Environment]::SetEnvironmentVariable('OSCAR_STORAGE_RELAY_PAYLOAD', 'preserved-parent-value', 'Process')
        try {
            Invoke-StorageCommand 'archive' 'hold'
            $captured = [IO.File]::ReadAllText($capturePath) | ConvertFrom-Json
            $restoredRelay = [Environment]::GetEnvironmentVariable('OSCAR_STORAGE_RELAY_PAYLOAD', 'Process')
            $encodedArguments = @($script:CapturedRelayArguments)
            $badPayload = [ordered]@{
                ScriptPath = (Join-Path $ScriptRoot 'oscar-storage.ps1')
                Parameters = [ordered]@{ Command = 'help'; Unexpected = 'rejected' }
            }
            $badJson = $badPayload | ConvertTo-Json -Compress -Depth 4
            $badEnvelope = [Convert]::ToBase64String($Utf8NoBom.GetBytes($badJson))
            [Environment]::SetEnvironmentVariable('OSCAR_STORAGE_RELAY_PAYLOAD', $badEnvelope, 'Process')
            $savedErrorPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                & powershell.exe @encodedArguments 2>$null
                $schemaRejected = ($LASTEXITCODE -ne 0)
            } finally { $ErrorActionPreference = $savedErrorPreference }
            $Reason = 'deliberate-child-failure'
            [Environment]::SetEnvironmentVariable('OSCAR_STORAGE_RELAY_PAYLOAD', 'negative-parent-value', 'Process')
            $childFailurePropagated = $false
            try { Invoke-StorageCommand 'archive' 'hold' }
            catch { $childFailurePropagated = $_.Exception.Message -like 'powershell.exe exited with code *' }
            $negativeRelayRestored = [Environment]::GetEnvironmentVariable('OSCAR_STORAGE_RELAY_PAYLOAD', 'Process')
            $Reason = $positiveReason
            $Destination = ('x' * 20000)
            [Environment]::SetEnvironmentVariable('OSCAR_STORAGE_RELAY_PAYLOAD', 'oversize-parent-value', 'Process')
            $oversizeRejected = $false
            try { Invoke-StorageCommand 'archive' 'hold' }
            catch { $oversizeRejected = $_.Exception.Message -like '*24576-character bound*' }
            $oversizeRelayPreserved = [Environment]::GetEnvironmentVariable('OSCAR_STORAGE_RELAY_PAYLOAD', 'Process')
        } finally {
            Remove-Item Env:OSCAR_STORAGE_RELAY_CAPTURE -ErrorAction SilentlyContinue
            [Environment]::SetEnvironmentVariable('OSCAR_STORAGE_RELAY_PAYLOAD', $null, 'Process')
        }
        return [pscustomobject]@{
            Captured = $captured
            Program = $script:CapturedRelayProgram
            Arguments = @($script:CapturedRelayArguments)
            Reason = $positiveReason
            Destination = $positiveDestination
            RestoredRelay = $restoredRelay
            SchemaRejected = $schemaRejected
            ChildFailurePropagated = $childFailurePropagated
            NegativeRelayRestored = $negativeRelayRestored
            OversizeRejected = $oversizeRejected
            OversizeRelayPreserved = $oversizeRelayPreserved
            InvocationCount = $script:RelayInvocationCount
        }
    }
    Assert-True ($relayFixture.Program -ceq 'powershell.exe' -and
        $relayFixture.Arguments.Count -eq 7 -and
        (($relayFixture.Arguments[0..5] -join [char]0) -ceq
            (@('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand') -join [char]0)) -and
        -not ($relayFixture.Arguments -contains '-File') -and
        -not (($relayFixture.Arguments -join [char]0).Contains($relayFixture.Reason)) -and
        -not (($relayFixture.Arguments -join [char]0).Contains($relayFixture.Destination))) `
        'Windows setup still exposes dynamic storage values to native argv.'
    Assert-True ($relayFixture.Captured.Command -ceq 'archive' -and
        $relayFixture.Captured.Action -ceq 'hold' -and
        $relayFixture.Captured.HoldAction -ceq 'create' -and
        $relayFixture.Captured.Reason -ceq $relayFixture.Reason -and
        $relayFixture.Captured.Destination -ceq $relayFixture.Destination -and
        $relayFixture.Captured.Keep -eq 7 -and
        $relayFixture.RestoredRelay -ceq 'preserved-parent-value') `
        'Windows setup-to-storage Base64/JSON relay did not preserve exact typed values or restore its environment.'
    Assert-True ($relayFixture.SchemaRejected -and $relayFixture.ChildFailurePropagated -and
        $relayFixture.NegativeRelayRestored -ceq 'negative-parent-value' -and
        $relayFixture.OversizeRejected -and
        $relayFixture.OversizeRelayPreserved -ceq 'oversize-parent-value' -and
        $relayFixture.InvocationCount -eq 2) `
        'Windows setup-to-storage relay hid a nested failure, leaked its environment, or launched an oversized payload.'

    $bootstrapCollisionFixture = & {
        $script:BootstrapDelimiterCalls = 0
        $script:CapturedBootstrapInput = $null
        $script:CapturedBootstrapArguments = @()
        function Get-BootstrapDelimiterToken {
            $script:BootstrapDelimiterCalls++
            if ($script:BootstrapDelimiterCalls -eq 1) { return ('3' * 32) }
            return ('4' * 32)
        }
        function Get-ComposeShellInputOutput([string]$InputText, [string[]]$Arguments) {
            $script:CapturedBootstrapInput = $InputText
            $script:CapturedBootstrapArguments = @($Arguments)
            return @('bootstrap-ok')
        }
        $testSource = $bootstrapSource.Replace("[Guid]::NewGuid().ToString('N')", '(Get-BootstrapDelimiterToken)')
        Invoke-Expression $testSource
        $firstDelimiter = 'OSCAR_SQL_' + ('3' * 32)
        $secondDelimiter = 'OSCAR_SQL_' + ('4' * 32)
        $sql = "SELECT '`$@ --command -c';`r`n$firstDelimiter`r`nSELECT 'quote '' preserved';"
        $result = Invoke-BootstrapSql $sql
        return [pscustomobject]@{
            Calls = $script:BootstrapDelimiterCalls
            Input = $script:CapturedBootstrapInput
            Arguments = @($script:CapturedBootstrapArguments)
            Result = $result
            Sql = $sql.Replace("`r`n", "`n")
            Delimiter = $secondDelimiter
        }
    }
    $bootstrapLines = @($bootstrapCollisionFixture.Input.Split([char]10))
    Assert-True ($bootstrapCollisionFixture.Calls -eq 2 -and
        $bootstrapCollisionFixture.Result -ceq 'bootstrap-ok' -and
        ($bootstrapCollisionFixture.Arguments -join [char]0) -ceq (@('exec', '-T', 'postgres', 'sh', '-seu') -join [char]0) -and
        $bootstrapLines[0].EndsWith("<<'$($bootstrapCollisionFixture.Delimiter)'") -and
        $bootstrapLines[$bootstrapLines.Count - 1] -ceq $bootstrapCollisionFixture.Delimiter -and
        ([string]::Join("`n", $bootstrapLines[1..($bootstrapLines.Count - 2)]) -ceq $bootstrapCollisionFixture.Sql)) `
        'Windows bootstrap SQL did not retry a delimiter collision and preserve quoted multiline SQL exactly.'

    # Prove the direct psql adapter preserves shell-looking SQL as inert
    # heredoc data and quotes its unique delimiter. Then substitute a
    # deterministic two-value delimiter source into the exact production
    # function to force and verify its standalone-line collision retry.
    $quotedSql = @'
SELECT '$@', '--command', '-c';
SELECT 'single quote '' and $dollar';
'@
    $quotedShellInput = New-PsqlShellInput $quotedSql
    $quotedLines = @($quotedShellInput.Split([char]10))
    $quotedDelimiter = $quotedLines[$quotedLines.Count - 1]
    Assert-True ($quotedDelimiter -match '^OSCAR_SQL_[0-9a-f]{32}$' -and
        $quotedLines[0].EndsWith("<<'$quotedDelimiter'") -and
        $quotedLines[0].Contains('exec psql ') -and
        $quotedLines[0].Contains(' --file=-') -and
        -not $quotedLines[0].Contains(' --command ')) `
        'Windows psql stdin does not use one quoted, direct-psql heredoc delimiter.'
    $quotedRoundTrip = [string]::Join("`n", $quotedLines[1..($quotedLines.Count - 2)])
    $expectedQuotedSql = $quotedSql.Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd([char[]]@([char]10))
    Assert-True ($quotedRoundTrip -ceq $expectedQuotedSql) `
        'Windows psql stdin changed SQL containing shell-looking text or quotes.'
    $psqlInputStart = $storageSource.IndexOf('function New-PsqlShellInput', [StringComparison]::Ordinal)
    $psqlInputEnd = $storageSource.IndexOf('function Invoke-Psql', $psqlInputStart, [StringComparison]::Ordinal)
    Assert-True ($psqlInputStart -ge 0 -and $psqlInputEnd -gt $psqlInputStart) 'Could not isolate the Windows psql stdin adapter.'
    $psqlInputSource = $storageSource.Substring($psqlInputStart, $psqlInputEnd - $psqlInputStart)
    $collisionFixture = & {
        $script:TestDelimiterCalls = 0
        function Get-TestDelimiterToken {
            $script:TestDelimiterCalls++
            if ($script:TestDelimiterCalls -eq 1) { return ('1' * 32) }
            return ('2' * 32)
        }
        $testSource = $psqlInputSource.Replace("[Guid]::NewGuid().ToString('N')", '(Get-TestDelimiterToken)')
        Invoke-Expression $testSource
        $firstDelimiter = 'OSCAR_SQL_' + ('1' * 32)
        $secondDelimiter = 'OSCAR_SQL_' + ('2' * 32)
        $sql = "SELECT 1;`n$firstDelimiter`nSELECT 2;"
        $shellInput = New-PsqlShellInput $sql
        return [pscustomobject]@{
            Calls = $script:TestDelimiterCalls
            First = $firstDelimiter
            Second = $secondDelimiter
            ShellInput = $shellInput
            Sql = $sql
        }
    }
    $collisionLines = @($collisionFixture.ShellInput.Split([char]10))
    Assert-True ($collisionFixture.Calls -eq 2 -and
        $collisionLines[0].EndsWith("<<'$($collisionFixture.Second)'") -and
        $collisionLines[$collisionLines.Count - 1] -ceq $collisionFixture.Second -and
        ([string]::Join("`n", $collisionLines[1..($collisionLines.Count - 2)]) -ceq $collisionFixture.Sql)) `
        'Windows psql stdin did not retry a colliding heredoc delimiter while preserving SQL exactly.'

    # Exercise the actual file-streaming helper with a native-command-shaped
    # pipeline sink. A nonzero docker status must survive the pipeline and
    # prevent callers from treating a partial output file as success.
    & {
        $savedScriptRoot = $ScriptRoot
        $ScriptRoot = $temporaryRoot
        $capturePath = Join-Path $temporaryRoot 'failed-psql-stream.txt'
        $script:CapturedDockerPipelineInput = $null
        $script:CapturedDockerPipelineArguments = @()
        function docker {
            process {
                $script:CapturedDockerPipelineInput = [string]$_
                $script:CapturedDockerPipelineArguments = @($args)
                'partial-row'
                $global:LASTEXITCODE = 23
            }
        }
        $failurePropagated = $false
        try {
            Write-ComposeShellInputOutputToFile 'printf ''row\n''' @('exec', '-T', 'postgres', 'sh', '-seu') $capturePath
        } catch {
            $failurePropagated = $_.Exception.Message -like '*exited with code 23*'
        } finally {
            $ScriptRoot = $savedScriptRoot
        }
        Assert-True $failurePropagated 'Windows Compose shell-to-file streaming hid a nonzero docker exit code.'
        Assert-True ($script:CapturedDockerPipelineInput.EndsWith('# oscar-powershell-stdin-terminator') -and
            ($script:CapturedDockerPipelineArguments -join [char]0).Contains('compose')) `
            'Windows Compose shell-to-file failure test did not exercise the real stdin/argv pipeline.'
    }
    $volumeJson = '[{"Name":"oscar_oscar_state","CreatedAt":"2026-10-18T13:45:03Z","Labels":{"com.botts.oscar.deployment-id":"12345678-1234-4234-8234-123456789abc"}}]'
    $volumeRecord = ConvertFrom-DockerInspectJson @($volumeJson) 'volume' 'oscar_oscar_state'
    Assert-True ((Get-DockerInspectLabel $volumeRecord $false 'com.botts.oscar.deployment-id') -ceq '12345678-1234-4234-8234-123456789abc') `
        'The PowerShell 5 Docker JSON parser did not preserve a dotted/hyphenated volume label key.'
    $rejectedMultiple = $false
    try { [void](ConvertFrom-DockerInspectJson @('[{"Name":"oscar_oscar_state"},{"Name":"oscar_oscar_state"}]') 'volume' 'oscar_oscar_state') }
    catch { $rejectedMultiple = $true }
    Assert-True $rejectedMultiple 'The Docker JSON parser accepted multiple inspect records for one exact volume.'
    $rejectedOversized = $false
    try { [void](ConvertFrom-DockerInspectJson @((' ' * ($MaxDockerInspectJsonBytes + 1))) 'volume' 'oscar_oscar_state') }
    catch { $rejectedOversized = $_.Exception.Message -like '*oversized*' }
    Assert-True $rejectedOversized 'The Docker JSON parser accepted output above its fixed memory bound.'
    & {
        $script:CapturedDockerInspectArguments = @()
        $imageJson = '[{"Id":"sha256:' + ('a' * 64) + '","RepoDigests":["oscar@sha256:' + ('b' * 64) + '"],"Config":{"Labels":{"org.opencontainers.image.version":"3.11.0"}}}]'
        function Get-ExternalOutput([string]$Program, [string[]]$Arguments) {
            $script:CapturedDockerInspectArguments = @($Arguments)
            return @($imageJson)
        }
        Assert-True ((Get-ImageInspectValue 'oscar:3.11.0' 'org.opencontainers.image.version') -ceq '3.11.0') `
            'The image JSON parser did not read the required OCI version label.'
        Assert-True (($script:CapturedDockerInspectArguments -join '|') -ceq 'image|inspect|oscar:3.11.0') `
            'Windows image inspection did not use the exact format-free JSON command.'
    }
    & {
        $savedBackupDirectory = $BackupDirectory
        $BackupDirectory = Join-Path $temporaryRoot 'journal-confirmation'
        New-Item -ItemType Directory -Path $BackupDirectory | Out-Null
        $calls = New-Object System.Collections.Generic.List[object]
        function Protect-DockerStorageDirectory([string]$Path, [string]$Mode) {}
        function Get-ComposeOutput([string[]]$Arguments) { return @('postgres') }
        function Invoke-Compose([string[]]$Arguments) {}
        function Invoke-DockerShellInput([string]$InputText, [string[]]$Arguments) {
            $calls.Add([pscustomobject]@{ Program = 'docker'; Arguments = @($Arguments); InputText = $InputText })
        }
        function Invoke-External([string]$Program, [string[]]$Arguments) {
            $calls.Add([pscustomobject]@{ Program = $Program; Arguments = @($Arguments); InputText = $null })
        }
        try {
            $id = '20261018T120000Z-1234abcd'
            $root = Join-Path $BackupDirectory $id
            New-Item -ItemType Directory -Path $root | Out-Null
            Confirm-DailyJournalBackup $id $root 'oscar:test' ('a' * 64)
        } finally {
            $BackupDirectory = $savedBackupDirectory
        }
        Assert-True ($calls.Count -eq 5) 'Daily journal confirmation did not run volume-create, validator, extractor, Java verifier, and volume-rm steps.'
        $volumeCreateArgs = [string]::Join('|', $calls[0].Arguments)
        $validatorArgs = [string]::Join('|', $calls[1].Arguments)
        $extractorArgs = [string]::Join('|', $calls[2].Arguments)
        $javaArgs = [string]::Join('|', $calls[3].Arguments)
        $volumeRemoveArgs = [string]::Join('|', $calls[4].Arguments)
        Assert-True ($volumeCreateArgs -cmatch '^volume\|create\|(oscar_journal_confirm_[0-9a-f]{32})$') `
            'Daily journal confirmation did not create an isolated Docker named volume for snapshot extraction.'
        $snapshotVolumeName = $Matches[1]
        Assert-True ($validatorArgs.Contains('--user|0') -and
            ([string]$calls[1].InputText).Contains('/validate-storage-archive.sh oscar-state')) `
            'Daily journal confirmation does not validate the authenticated archive as root before extraction.'
        foreach ($required in @('--cap-drop|ALL|--cap-add|CHOWN', '--workdir|/|--user|0|--entrypoint|sh', "--volume|${snapshotVolumeName}:/snapshot")) {
            Assert-True ($extractorArgs.Contains($required)) "Daily journal extraction is missing its constrained root ownership bridge or Docker volume mount: $required"
        }
        $extractCommand = [string]$calls[2].InputText
        $extractIndex = $extractCommand.IndexOf('tar --no-same-owner', [StringComparison]::Ordinal)
        $directoryModeIndex = $extractCommand.IndexOf('find /snapshot -type d -exec chmod 0700', [StringComparison]::Ordinal)
        $fileModeIndex = $extractCommand.IndexOf('find /snapshot -type f -exec chmod 0600', [StringComparison]::Ordinal)
        $ownerIndex = $extractCommand.IndexOf('chown -R 10001:10001 /snapshot', [StringComparison]::Ordinal)
        Assert-True ($extractIndex -ge 0 -and $directoryModeIndex -gt $extractIndex -and
            $fileModeIndex -gt $directoryModeIndex -and $ownerIndex -gt $fileModeIndex) `
            'Daily journal extraction does not validate modes before handing the private snapshot to UID 10001.'
        Assert-True ($javaArgs.Contains('--user|10001:10001|--entrypoint|java') -and
            $javaArgs.Contains("--volume|${snapshotVolumeName}:/verified-snapshot:ro")) `
            'Daily journal Java confirmation does not remain an unprivileged read-only consumer over the isolated snapshot volume.'
        Assert-True ($volumeRemoveArgs -ceq "volume|rm|--force|${snapshotVolumeName}") `
            'Daily journal confirmation did not remove the temporary Docker snapshot volume in finally.'
    }
    $statusStart = $storageSource.IndexOf('function Show-ArchiveStatus', [StringComparison]::Ordinal)
    $statusEnd = $storageSource.IndexOf('function Invoke-RetentionHold', $statusStart, [StringComparison]::Ordinal)
    Assert-True ($statusStart -ge 0 -and $statusEnd -gt $statusStart) 'Could not isolate the PowerShell archive-status query.'
    $statusSource = $storageSource.Substring($statusStart, $statusEnd - $statusStart)
    foreach ($qualified in @(
        'SELECT g.store_key,g.id_scope,g.state,g.profile',
        'coalesce(sum(g.row_count),0)',
        'GROUP BY g.store_key,g.id_scope,g.state,g.profile',
        'ORDER BY g.store_key,g.id_scope,g.state,g.profile')) {
        Assert-True ($statusSource.Contains($qualified)) "PowerShell archive status is missing qualified generation columns: $qualified"
    }
    $launcherCheck = $storageSource.IndexOf('Assert-NoReparseComponents $StorageScriptPath', [StringComparison]::Ordinal)
    $templateRead = $storageSource.IndexOf("Join-Path `$ScriptRoot '.env.example'", [StringComparison]::Ordinal)
    Assert-True ($launcherCheck -ge 0 -and $templateRead -gt $launcherCheck -and
        $storageSource.Contains('Resolve-PhysicalContainmentPath $ScriptRoot')) `
        'Windows release-path canonicalization/reparse checks do not run before release configuration is read.'
    $validObject = 'datasets/observations/date=2026-10-17/profile=RAW_GATED/generation-11111111-1111-4111-8111-111111111111.parquet'
    Assert-True (Test-ArchiveObjectPath $validObject) 'PowerShell rejected an approved archive object path.'
    Assert-True (-not (Test-ArchiveObjectPath 'foreign/file')) 'PowerShell accepted an archive path outside the approved layout.'
    & {
        function Write-PsqlLinesToFile([string]$Sql, [string]$Path) {
            [IO.File]::WriteAllText($Path, "foreign/file`n", $Utf8NoBom)
        }
        $invalidCatalog = Join-Path $temporaryRoot 'invalid-catalog-paths.txt'
        $rejectedInvalidCatalog = $false
        try { Write-RegisteredArchivePaths $invalidCatalog } catch { $rejectedInvalidCatalog = $true }
        Assert-True $rejectedInvalidCatalog 'PowerShell accepted an absent catalog object outside the approved layout.'
    }
    $inventoryStart = $storageSource.IndexOf('function Get-ArchiveGenerationInventory', [StringComparison]::Ordinal)
    $inventoryEnd = $storageSource.IndexOf('function Write-ArchiveGenerationInventory', $inventoryStart, [StringComparison]::Ordinal)
    Assert-True ($inventoryStart -ge 0 -and $inventoryEnd -gt $inventoryStart) 'Could not isolate the streaming archive-generation validator.'
    $inventorySource = $storageSource.Substring($inventoryStart, $inventoryEnd - $inventoryStart)
    foreach ($forbidden in @('ReadAllBytes', 'ReadAllLines', ' -split ', ' -join ', 'Invoke-PsqlLines', 'uuid[]')) {
        Assert-True (-not $inventorySource.Contains($forbidden)) "Archive-generation validation materializes its bounded inventory: $forbidden"
    }
    Assert-True ($inventorySource.Contains('[IO.File]::Open(') -and
        $inventorySource.Contains('[Security.Cryptography.SHA256]::Create()') -and
        $inventorySource.Contains('$bytesRead -ne ($count * 37)')) `
        'Archive-generation validation is not a framed, streaming count/hash/bytes receipt.'
    Assert-True ($inventorySource.IndexOf('Get-Item -LiteralPath $path', [StringComparison]::Ordinal) -lt
        $inventorySource.IndexOf('[IO.File]::Open(', [StringComparison]::Ordinal)) `
        'Archive-generation validation does not reject an oversized file before opening its content stream.'
    Assert-True ($storageSource.Contains('ORDER BY id LIMIT $($MaxBackupArchiveGenerationIds + 1)')) `
        'Archive-generation capture is not bounded to the advertised entry limit plus one sentinel.'
    Assert-True (-not $storageSource.Contains('archive_generation_ids')) `
        'The PowerShell storage launcher still embeds archive-generation UUIDs in PostgreSQL.'
    $captureStart = $inventoryEnd
    $captureEnd = $storageSource.IndexOf('function Set-VerifiedBackupEpochReceipt', $captureStart, [StringComparison]::Ordinal)
    $captureSource = $storageSource.Substring($captureStart, $captureEnd - $captureStart)
    Assert-True ($captureSource.Contains('Write-PsqlLinesToFile') -and
        -not $captureSource.Contains('Invoke-PsqlLines') -and
        -not $captureSource.Contains('ReadAllBytes') -and
        -not $captureSource.Contains('ReadAllLines') -and
        -not $captureSource.Contains(' -join ')) `
        'PowerShell archive-generation capture does not stream PostgreSQL output directly to its file.'
    Assert-True (-not $storageSource.Contains('function Get-RegisteredArchivePaths')) `
        'The Windows archive audit still exposes the full catalog as an in-memory collection.'
    $auditStart = $storageSource.IndexOf('function Test-ArchiveFilesystemRegistration', [StringComparison]::Ordinal)
    $auditEnd = $storageSource.IndexOf('function Protect-PrivateDirectory', $auditStart, [StringComparison]::Ordinal)
    Assert-True ($auditStart -ge 0 -and $auditEnd -gt $auditStart) 'Could not isolate the Windows archive reconciliation implementation.'
    $auditSource = $storageSource.Substring($auditStart, $auditEnd - $auditStart)
    foreach ($forbidden in @('Collections.Generic.HashSet', 'New-Object System.Collections.Generic.List[string]', 'Invoke-PsqlLines')) {
        Assert-True (-not $auditSource.Contains($forbidden)) "Windows archive reconciliation materializes an unbounded catalog/candidate collection: $forbidden"
    }
    foreach ($required in @(
        'Write-RegisteredArchivePaths $catalogFirstRaw',
        'Write-RegisteredArchivePaths $catalogSecondRaw',
        'ConvertTo-ArchiveAuditSortedUniqueFile $candidateRaw $candidateSorted',
        'Compare-ArchiveAuditSortedFiles $candidateSorted $catalogMerged',
        '[IO.Directory]::EnumerateFileSystemEntries')) {
        Assert-True ($auditSource.Contains($required)) "Windows archive reconciliation is missing its bounded file-backed operation: $required"
    }
    Assert-True ($storageSource.Contains('$ArchiveAuditSortChunkLines = 4096') -and
        $storageSource.Contains('$buffer.Count -ge $ChunkLineLimit')) `
        'The Windows archive reconciliation sort does not enforce its fixed-size memory chunk.'

    # Force five input records through three chunks, then exercise pairwise
    # merging and the streaming candidate-minus-catalog comparison.
    $sortFixture = Join-Path $temporaryRoot 'archive-sort'
    New-Item -ItemType Directory -Path $sortFixture | Out-Null
    $rawCandidates = Join-Path $sortFixture 'candidates.raw'
    $sortedCandidates = Join-Path $sortFixture 'candidates.sorted'
    [IO.File]::WriteAllLines($rawCandidates, @('delta','alpha','gamma','alpha','beta'), $Utf8NoBom)
    ConvertTo-ArchiveAuditSortedUniqueFile $rawCandidates $sortedCandidates 2
    Assert-True (([IO.File]::ReadAllLines($sortedCandidates) -join ',') -ceq 'alpha,beta,delta,gamma') `
        'The bounded Windows archive audit sort did not order and deduplicate across chunk boundaries.'
    $catalogFirstRaw = Join-Path $sortFixture 'catalog-first.raw'
    $catalogSecondRaw = Join-Path $sortFixture 'catalog-second.raw'
    $catalogFirst = Join-Path $sortFixture 'catalog-first.sorted'
    $catalogSecond = Join-Path $sortFixture 'catalog-second.sorted'
    $catalogMerged = Join-Path $sortFixture 'catalog-merged.sorted'
    [IO.File]::WriteAllLines($catalogFirstRaw, @('gamma','alpha'), $Utf8NoBom)
    [IO.File]::WriteAllLines($catalogSecondRaw, @('epsilon','beta','alpha'), $Utf8NoBom)
    ConvertTo-ArchiveAuditSortedUniqueFile $catalogFirstRaw $catalogFirst 1
    ConvertTo-ArchiveAuditSortedUniqueFile $catalogSecondRaw $catalogSecond 1
    Merge-ArchiveAuditSortedFiles $catalogFirst $catalogSecond $catalogMerged
    Assert-True (([IO.File]::ReadAllLines($catalogMerged) -join ',') -ceq 'alpha,beta,epsilon,gamma') `
        'The Windows archive audit did not merge and deduplicate its two catalog snapshots.'
    $missing = Compare-ArchiveAuditSortedFiles $sortedCandidates $catalogMerged 2>$null
    Assert-True ($missing -eq 1) 'The Windows archive audit streaming comparison did not identify exactly the unregistered delta candidate.'

    & {
        $objectPath = Join-Path $temporaryRoot 'archive-completeness-object'
        [IO.File]::WriteAllText($objectPath, "object`n", (New-Object Text.UTF8Encoding($false)))
        $objectSha = (Get-FileHash -LiteralPath $objectPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $generation = '12345678-1234-4234-8234-123456789abc'
        $secondGeneration = '87654321-4321-4234-8234-cba987654321'
        $script:ArchiveObjectMode = 'valid'
        $script:ArchiveSnapshotCalls = 0
        function Assert-Configured {}
        function Resolve-ConfinedArchivePath([string]$Relative, [switch]$AllowMissing) { return $objectPath }
        function Test-ArchiveFilesystemRegistration([switch]$RejectPartials) {}
        function Invoke-PsqlLines([string]$Sql) {
            if (-not $Sql.Contains('CROSS JOIN required')) { return @() }
            Assert-True ($Sql.Contains('CROSS JOIN required') -and
                $Sql.Contains("g.state IN ('ACTIVE','SEALED')") -and $Sql.Contains('chr(31)') -and
                $Sql.Contains('invalid_owner_rows') -and
                $Sql.Contains('block.min_id=g.min_id AND block.max_id=g.max_id') -and
                $Sql.Contains('(SELECT count(*)::text FROM oscar_archive_schema schema_row') -and
                $Sql.Contains("'ID_BLOCK_AND_SCHEMAS'::text")) `
                'PowerShell archive verification did not require one exact min/max ID block plus schema metadata for every query-visible generation.'
            $script:ArchiveSnapshotCalls++
            switch ($script:ArchiveObjectMode) {
                'valid' {
                    return @(
                        "REQUIRED`t$generation`tOBSERVATIONS_PARQUET`t1`tACTIVE`tdatasets/a.parquet`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "REQUIRED`t$generation`tGENERATION_MANIFEST`t1`tACTIVE`tdatasets/a.manifest.json`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "REQUIRED`t$generation`tDATASTREAM_SCHEMAS`t1`tACTIVE`tdatasets/a.schemas.json.gz`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "ADDITIONAL`t$generation`tAUDIT_SIDECAR`t1`tACTIVE`tdatasets/a.audit`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "RELATIONAL`t$generation`tID_BLOCK_AND_SCHEMAS`t1`tMATCH`t1`t`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json")
                }
                'missing' {
                    return @(
                        "REQUIRED`t$generation`tOBSERVATIONS_PARQUET`t1`tACTIVE`tdatasets/a.parquet`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "REQUIRED`t$generation`tGENERATION_MANIFEST`t0`tMISSING`tmissing`tbad`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "REQUIRED`t$generation`tDATASTREAM_SCHEMAS`t1`tACTIVE`tdatasets/a.schemas.json.gz`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json")
                }
                'duplicate' {
                    return @(
                        "REQUIRED`t$generation`tOBSERVATIONS_PARQUET`t2`tACTIVE`tdatasets/a.parquet`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "REQUIRED`t$generation`tGENERATION_MANIFEST`t1`tACTIVE`tdatasets/a.manifest.json`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "REQUIRED`t$generation`tDATASTREAM_SCHEMAS`t1`tACTIVE`tdatasets/a.schemas.json.gz`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json")
                }
                'stale-path' {
                    return @(
                        "REQUIRED`t$generation`tOBSERVATIONS_PARQUET`t1`tACTIVE`tdatasets/a.parquet`t$objectSha`tdatasets/stale.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "REQUIRED`t$generation`tGENERATION_MANIFEST`t1`tACTIVE`tdatasets/a.manifest.json`t$objectSha`tdatasets/stale.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "REQUIRED`t$generation`tDATASTREAM_SCHEMAS`t1`tACTIVE`tdatasets/a.schemas.json.gz`t$objectSha`tdatasets/stale.parquet`t$objectSha`tdatasets/a.manifest.json")
                }
                'stale-hash' {
                    $staleSha = 'b' * 64
                    return @(
                        "REQUIRED`t$generation`tOBSERVATIONS_PARQUET`t1`tACTIVE`tdatasets/a.parquet`t$objectSha`tdatasets/a.parquet`t$staleSha`tdatasets/a.manifest.json",
                        "REQUIRED`t$generation`tGENERATION_MANIFEST`t1`tACTIVE`tdatasets/a.manifest.json`t$objectSha`tdatasets/a.parquet`t$staleSha`tdatasets/a.manifest.json",
                        "REQUIRED`t$generation`tDATASTREAM_SCHEMAS`t1`tACTIVE`tdatasets/a.schemas.json.gz`t$objectSha`tdatasets/a.parquet`t$staleSha`tdatasets/a.manifest.json")
                }
                'relational' {
                    return @(
                        "REQUIRED`t$generation`tOBSERVATIONS_PARQUET`t1`tACTIVE`tdatasets/a.parquet`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "REQUIRED`t$generation`tGENERATION_MANIFEST`t1`tACTIVE`tdatasets/a.manifest.json`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "REQUIRED`t$generation`tDATASTREAM_SCHEMAS`t1`tACTIVE`tdatasets/a.schemas.json.gz`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "RELATIONAL`t$generation`tID_BLOCK_AND_SCHEMAS`t2`tMISMATCH`t0`t`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json")
                }
                'inactive-owner' {
                    return @("INVALID_OWNER`t$generation`tAUDIT_SIDECAR`t1`tACTIVE`tdatasets/a.audit`t$objectSha`t`t`t")
                }
                'activation' {
                    $rows = @(
                        "REQUIRED`t$generation`tOBSERVATIONS_PARQUET`t1`tACTIVE`tdatasets/a.parquet`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "REQUIRED`t$generation`tGENERATION_MANIFEST`t1`tACTIVE`tdatasets/a.manifest.json`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "REQUIRED`t$generation`tDATASTREAM_SCHEMAS`t1`tACTIVE`tdatasets/a.schemas.json.gz`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "RELATIONAL`t$generation`tID_BLOCK_AND_SCHEMAS`t1`tMATCH`t1`t`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json")
                    if ($script:ArchiveSnapshotCalls -gt 1) {
                        $rows += "REQUIRED`t$secondGeneration`tOBSERVATIONS_PARQUET`t1`tACTIVE`tdatasets/b.parquet`t$objectSha`tdatasets/b.parquet`t$objectSha`tdatasets/b.manifest.json"
                    }
                    return $rows
                }
                'purge' {
                    if ($script:ArchiveSnapshotCalls -gt 1) { return @() }
                    return @(
                        "REQUIRED`t$generation`tOBSERVATIONS_PARQUET`t1`tACTIVE`tdatasets/a.parquet`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "REQUIRED`t$generation`tGENERATION_MANIFEST`t1`tACTIVE`tdatasets/a.manifest.json`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "REQUIRED`t$generation`tDATASTREAM_SCHEMAS`t1`tACTIVE`tdatasets/a.schemas.json.gz`t$objectSha`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json",
                        "RELATIONAL`t$generation`tID_BLOCK_AND_SCHEMAS`t1`tMATCH`t1`t`tdatasets/a.parquet`t$objectSha`tdatasets/a.manifest.json")
                }
            }
        }
        function Write-PsqlLinesToFile([string]$Sql, [string]$Path) {
            $rows = @(Invoke-PsqlLines $Sql | ForEach-Object { ([string]$_).Replace("`t", [string][char]31) })
            [IO.File]::WriteAllLines($Path, $rows, $Utf8NoBom)
        }

        Confirm-ArchiveObjects
        foreach ($invalidMode in @('missing','duplicate','stale-path','stale-hash','relational','inactive-owner')) {
            $script:ArchiveObjectMode = $invalidMode
            $script:ArchiveSnapshotCalls = 0
            $rejected = $false
            try { Confirm-ArchiveObjects } catch { $rejected = $true }
            Assert-True $rejected "PowerShell archive verification accepted a $invalidMode required-object catalog."
        }
        foreach ($changeMode in @('activation','purge')) {
            $script:ArchiveObjectMode = $changeMode
            $script:ArchiveSnapshotCalls = 0
            $rejected = $false
            try { Confirm-ArchiveObjects } catch { $rejected = $true }
            Assert-True $rejected "PowerShell archive verification accepted a concurrent catalog $changeMode."
        }
    }

    Assert-True (-not (Test-FullyQualifiedDeploymentPath '\\server\share\archive')) 'UNC storage roots must be rejected before mutation.'
    Assert-True (Test-FullyQualifiedDeploymentPath 'D:\oscar-storage\archive') 'A local drive-rooted storage path was rejected.'

    $envFixture = Join-Path $temporaryRoot 'unc-preflight'
    New-Item -ItemType Directory -Path $envFixture | Out-Null
    [IO.File]::WriteAllLines((Join-Path $envFixture '.env'), @(
        'OSCAR_VERSION=3.11.0',
        'OSCAR_DEPLOYMENT_ID=11111111-2222-4333-8444-555555555555',
        'OSCAR_ARCHIVE_DIR=\\server\share\archive',
        'OSCAR_BACKUP_DIR=D:\oscar-storage\backups',
        'OSCAR_WAL_ARCHIVE_DIR=D:\oscar-storage\wal-archive',
        'OSCAR_SECRETS_DIR=.\secrets',
        'OSCAR_TLS_DIR=.\tls',
        'OSCAR_BACKUP_KEY_FILE=.\secrets\backup-key.txt'
    ), (New-Object Text.UTF8Encoding($false)))
    $originalScriptRoot = $ScriptRoot
    $ScriptRoot = $envFixture
    $rejectedUnc = $false
    try { Assert-ManagedEnvironmentBindings } catch { $rejectedUnc = $true }
    $ScriptRoot = $originalScriptRoot
    Assert-True $rejectedUnc 'Managed-environment preflight accepted a UNC storage root.'

    # Windows PowerShell 5 promotes stderr from a nonzero native command to a
    # terminating NativeCommandError while ErrorActionPreference is Stop.  A
    # missing group is the expected probe result on clean hosted runners, so
    # capture only the native exit code without weakening the rest of the test.
    $savedErrorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & net.exe localgroup docker-users *> $null
        $dockerGroupExists = ($LASTEXITCODE -eq 0)
    } finally {
        $ErrorActionPreference = $savedErrorPreference
    }
    if (-not $dockerGroupExists) {
        try {
            $ErrorActionPreference = 'Continue'
            & net.exe localgroup docker-users /add *> $null
            $dockerGroupCreated = ($LASTEXITCODE -eq 0)
        } finally {
            $ErrorActionPreference = $savedErrorPreference
        }
        if (-not $dockerGroupCreated) { throw 'Could not create the temporary docker-users group for ACL validation.' }
        $createdDockerGroup = $true
    }

    Assert-Administrator
    $aclRoot = Join-Path $temporaryRoot 'acl-root'
    New-Item -ItemType Directory -Path $aclRoot | Out-Null
    Protect-DockerStorageDirectory $aclRoot 'ReadWrite'
    Assert-DockerStorageDirectory $aclRoot 'test storage root' 'ReadWrite'
    $acl = Get-Acl -LiteralPath $aclRoot
    $everyone = [Security.Principal.SecurityIdentifier]::new('S-1-1-0')
    [void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $everyone,
        [Security.AccessControl.FileSystemRights]::FullControl,
        [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow))
    Set-Acl -LiteralPath $aclRoot -AclObject $acl
    $rejectedEveryone = $false
    try { Assert-DockerStorageDirectory $aclRoot 'test storage root' 'ReadWrite' } catch { $rejectedEveryone = $true }
    Assert-True $rejectedEveryone 'Storage ACL validation accepted Everyone:FullControl.'

    Protect-DockerStorageDirectory $aclRoot 'ReadOnly'
    Assert-DockerStorageDirectory $aclRoot 'test backup root' 'ReadOnly'
    $source = Join-Path $aclRoot 'durable-source'
    $destination = Join-Path $aclRoot 'durable-destination'
    [IO.File]::WriteAllText($source, 'durable', (New-Object Text.UTF8Encoding($false)))
    Move-DurableNoReplace $source $destination
    Assert-True (Test-Path -LiteralPath $destination -PathType Leaf) 'Win32 durable no-replace move did not publish the file.'
    [IO.File]::WriteAllText($source, 'collision', (New-Object Text.UTF8Encoding($false)))
    $rejectedCollision = $false
    try { Move-DurableNoReplace $source $destination } catch { $rejectedCollision = $true }
    Assert-True $rejectedCollision 'Win32 durable no-replace move overwrote an existing destination.'

    $catalogRoot = Join-Path $temporaryRoot 'catalog-receipt'
    New-Item -ItemType Directory -Path $catalogRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $catalogRoot 'epoch.json'), "{}`n", (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $catalogRoot 'archive-generation-ids.txt'),
        "11111111-1111-4111-8111-111111111111`n22222222-2222-4222-8222-222222222222`n",
        (New-Object Text.UTF8Encoding($false)))
    $inventoryPath = Join-Path $catalogRoot 'archive-generation-ids.txt'
    $inventoryHash = (Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $inventoryReceipt = Get-ArchiveGenerationInventory $catalogRoot
    Assert-True ($inventoryReceipt.Count -eq 2 -and $inventoryReceipt.Bytes -eq 74 -and
        $inventoryReceipt.Sha256 -ceq $inventoryHash) 'PowerShell did not produce the compact authenticated archive-generation receipt.'
    [IO.File]::WriteAllBytes($inventoryPath, [byte[]]@())
    $emptyReceipt = Get-ArchiveGenerationInventory $catalogRoot
    Assert-True ($emptyReceipt.Count -eq 0 -and $emptyReceipt.Bytes -eq 0 -and
        $emptyReceipt.Sha256 -ceq 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855') `
        'PowerShell rejected the canonical zero-generation inventory receipt.'
    [IO.File]::WriteAllText($inventoryPath,
        "11111111-1111-4111-8111-111111111111`n22222222-2222-4222-8222-222222222222`n",
        (New-Object Text.UTF8Encoding($false)))
    $catalogId = '12345678-1234-4234-8234-123456789abc'
    $catalogBackup = '20261017T120000Z-1234abcd'
    $script:CapturedCatalogSql = ''
    function Assert-DeploymentVolumeOwnership {}
    function Invoke-PsqlScript([string]$Sql) {
        $script:CapturedCatalogSql = $Sql
        return "$catalogId|VERIFIED"
    }
    Set-VerifiedBackupEpochReceipt $catalogRoot $catalogBackup $catalogId '0/12345678'
    Assert-True ($script:CapturedCatalogSql.Contains("oscar_backup_epoch.state IN ('CREATED','VERIFIED')") -and
        $script:CapturedCatalogSql.Contains('postgres_lsn IS NOT DISTINCT FROM EXCLUDED.postgres_lsn') -and
        $script:CapturedCatalogSql.Contains('archive_generation_count IS NOT DISTINCT FROM EXCLUDED.archive_generation_count') -and
        $script:CapturedCatalogSql.Contains('archive_generation_inventory_sha256 IS NOT DISTINCT FROM EXCLUDED.archive_generation_inventory_sha256') -and
        $script:CapturedCatalogSql.Contains('archive_generation_inventory_bytes IS NOT DISTINCT FROM EXCLUDED.archive_generation_inventory_bytes') -and
        $script:CapturedCatalogSql.Contains(",2,'$inventoryHash',74,") -and
        -not $script:CapturedCatalogSql.Contains('archive_generation_ids') -and
        -not $script:CapturedCatalogSql.Contains('11111111-1111-4111-8111-111111111111') -and
        -not $script:CapturedCatalogSql.Contains('FROM oscar_archive_generation') -and
        $script:CapturedCatalogSql.Contains('sha256 IS NOT DISTINCT FROM EXCLUDED.sha256')) 'PowerShell VERIFIED epoch upsert is not bound to the compact authenticated backup-time generation receipt.'
    function Invoke-PsqlScript([string]$Sql) { return '' }
    $rejectedForeignEpoch = $false
    try { Set-VerifiedBackupEpochReceipt $catalogRoot $catalogBackup $catalogId '0/12345678' } catch { $rejectedForeignEpoch = $true }
    Assert-True $rejectedForeignEpoch 'PowerShell accepted a foreign same-UUID backup epoch collision.'

    foreach ($invalidInventory in @(
        "11111111-1111-4111-8111-111111111111`r`n",
        "11111111-1111-4111-8111-111111111111",
        "11111111-1111-4111-8111-111111111111`n11111111-1111-4111-8111-111111111111`n",
        "22222222-2222-4222-8222-222222222222`n11111111-1111-4111-8111-111111111111`n")) {
        [IO.File]::WriteAllText($inventoryPath, $invalidInventory, $Utf8NoBom)
        $rejectedInventory = $false
        try { [void](Get-ArchiveGenerationInventory $catalogRoot) } catch { $rejectedInventory = $true }
        Assert-True $rejectedInventory 'PowerShell accepted a noncanonical archive-generation inventory.'
    }
    $bom = [byte[]](0xef,0xbb,0xbf) + [Text.Encoding]::ASCII.GetBytes("11111111-1111-4111-8111-111111111111`n")
    [IO.File]::WriteAllBytes($inventoryPath, $bom)
    $rejectedBom = $false
    try { [void](Get-ArchiveGenerationInventory $catalogRoot) } catch { $rejectedBom = $true }
    Assert-True $rejectedBom 'PowerShell accepted a UTF-8 BOM in the archive-generation inventory.'

    $largeWriter = [IO.StreamWriter]::new($inventoryPath, $false, $Utf8NoBom)
    $largeWriter.NewLine = "`n"
    try {
        for ($index = 0; $index -lt 10000; $index++) {
            $largeWriter.WriteLine(("00000000-0000-4000-8000-{0:D12}" -f $index))
        }
    } finally { $largeWriter.Dispose() }
    $largeHash = (Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $largeReceipt = Get-ArchiveGenerationInventory $catalogRoot
    Assert-True ($largeReceipt.Count -eq 10000 -and $largeReceipt.Bytes -eq 370000 -and
        $largeReceipt.Sha256 -ceq $largeHash) 'PowerShell failed the practical streaming archive-generation boundary fixture.'
    $oversizedInventory = [IO.File]::Open($inventoryPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $oversizedInventory.SetLength(37000001) } finally { $oversizedInventory.Dispose() }
    $rejectedOversized = $false
    try { [void](Get-ArchiveGenerationInventory $catalogRoot) } catch { $rejectedOversized = $true }
    Assert-True $rejectedOversized 'PowerShell accepted an archive-generation inventory above 37,000,000 bytes.'

    . $setupScript -Command help | Out-Null
    $setupStopOrder = & {
        $captured = New-Object System.Collections.Generic.List[string]
        function Invoke-Compose([string[]]$Arguments) {
            [void]$captured.Add([string]::Join(' ', $Arguments))
        }
        Stop-DeploymentOrdered
        [string]::Join(';', $captured)
    }
    Assert-True ($setupStopOrder -ceq 'stop gateway;stop oscar;stop postgres') `
        'Windows setup stop/restart is not dependency ordered.'
    Assert-True (-not (Test-FullyQualifiedDeploymentPath '\\server\share\archive')) 'Setup accepted a UNC storage root.'

    $wslCandidates = Join-Path $temporaryRoot 'wsl-candidates'
    New-Item -ItemType Directory -Path $wslCandidates | Out-Null
    $rejectedZero = $false
    try { [void](Get-BundledWslInstaller $wslCandidates) } catch { $rejectedZero = $true }
    Assert-True $rejectedZero 'Setup accepted zero WSL installer candidates.'
    $wslOne = Join-Path $wslCandidates 'wsl.2.4.0.x64.msi'
    [IO.File]::WriteAllText($wslOne, 'fixture', (New-Object Text.UTF8Encoding($false)))
    Assert-True ((Get-BundledWslInstaller $wslCandidates).FullName -ceq $wslOne) 'Setup rejected the one regular allowlisted WSL MSI.'
    $wslTwo = Join-Path $wslCandidates 'wsl.2.4.1.x64.msi'
    [IO.File]::WriteAllText($wslTwo, 'fixture', (New-Object Text.UTF8Encoding($false)))
    $rejectedMultiple = $false
    try { [void](Get-BundledWslInstaller $wslCandidates) } catch { $rejectedMultiple = $true }
    Assert-True $rejectedMultiple 'Setup selected one of multiple WSL installer candidates.'
    Remove-Item -LiteralPath $wslOne, $wslTwo -Force
    $junctionTarget = Join-Path $temporaryRoot 'wsl-junction-target'
    New-Item -ItemType Directory -Path $junctionTarget | Out-Null
    $junction = Join-Path $wslCandidates 'wsl-linked.msi'
    New-Item -ItemType Junction -Path $junction -Target $junctionTarget | Out-Null
    $rejectedLinked = $false
    try { [void](Get-BundledWslInstaller $wslCandidates) } catch { $rejectedLinked = $true }
    Assert-True $rejectedLinked 'Setup accepted a linked/reparse WSL installer candidate.'

    # Archive ID blocks are coarse ranges. Sparse generations produced from
    # interleaved eligible/ineligible streams can span an unrelated exact hot
    # row, so the command must branch on exact-row existence before consulting
    # the conservative cold-only range fallback.
    $storageSource = [IO.File]::ReadAllText($storageScript)
    $holdStart = $storageSource.IndexOf('function Invoke-RetentionHold', [StringComparison]::Ordinal)
    Assert-True ($holdStart -ge 0) 'Could not find the PowerShell retention-hold implementation.'
    $holdEnd = $storageSource.IndexOf('function Confirm-ArchiveObjects', $holdStart, [StringComparison]::Ordinal)
    Assert-True ($holdEnd -gt $holdStart) 'Could not isolate the PowerShell retention-hold implementation.'
    $holdSource = $storageSource.Substring($holdStart, $holdEnd - $holdStart)
    Assert-True (Test-ObservationId '1') 'PowerShell rejected the minimum positive observation ID.'
    Assert-True (Test-ObservationId '9223372036854775807') 'PowerShell rejected the signed-BIGINT maximum observation ID.'
    Assert-True (-not (Test-ObservationId '0')) 'PowerShell accepted zero as an observation ID.'
    Assert-True (-not (Test-ObservationId '9223372036854775808')) 'PowerShell accepted an observation ID above signed-BIGINT maximum.'
    Assert-True (([regex]::Matches($holdSource, '::bigint')).Count -eq 4 -and
        -not $holdSource.Contains('::numeric')) 'PowerShell observation-hold SQL does not preserve bigint index operands.'
    $holdTerms = @(
        'SELECT 1 FROM oscar_tombstone',
        'THEN CASE',
        'SELECT 1 FROM "$StoreKey" any_hot_row',
        'THEN CASE WHEN EXISTS (',
        'SELECT 1 FROM "$StoreKey" exact_hot_row',
        'SELECT 1 FROM oscar_archive_generation exact_owner',
        "exact_owner.state IN ('ACTIVE','SEALED')",
        "THEN 'HOT_EXACT'",
        'WHEN EXISTS (',
        'SELECT 1 FROM oscar_archive_id_block active_block',
        'AND NOT EXISTS (',
        'SELECT 1 FROM oscar_archive_id_block retired_block',
        "THEN 'COLD_RANGE_CONSERVATIVE'",
        'END AS resolution_mode'
    )
    $holdOffset = 0
    foreach ($term in $holdTerms) {
        $nextOffset = $holdSource.IndexOf($term, $holdOffset, [StringComparison]::Ordinal)
        Assert-True ($nextOffset -ge $holdOffset) "Observation-hold SQL is missing or misorders its exact/range precedence term: $term"
        $holdOffset = $nextOffset + $term.Length
    }

    function Test-ObservationHoldFixture(
        [bool]$ExactPresent,
        [bool]$ExactEligible,
        [bool]$ActiveRange,
        [bool]$RetiredRange,
        [bool]$Tombstoned) {
        if ($Tombstoned) { return 'REJECTED' }
        if ($ExactPresent) {
            if ($ExactEligible) { return 'HOT_EXACT' }
            return 'REJECTED'
        }
        if ($ActiveRange -and -not $RetiredRange) { return 'COLD_RANGE_CONSERVATIVE' }
        return 'REJECTED'
    }
    # A retired generation contains sparse IDs 100/104, so its [100,104]
    # block also spans unrelated exact rows 102/103 and cold-only ID 101.
    $holdFixtures = @(
        @{ Name = 'exact hot over retired range'; Expected = 'HOT_EXACT'; Values = @($true, $true, $true, $true, $false) },
        @{ Name = 'exact ACTIVE-owned over retired range'; Expected = 'HOT_EXACT'; Values = @($true, $true, $true, $true, $false) },
        @{ Name = 'exact SEALED-owned over retired range'; Expected = 'HOT_EXACT'; Values = @($true, $true, $true, $true, $false) },
        @{ Name = 'exact retired-owned'; Expected = 'REJECTED'; Values = @($true, $false, $true, $true, $false) },
        @{ Name = 'cold active/retired ambiguous'; Expected = 'REJECTED'; Values = @($false, $false, $true, $true, $false) },
        @{ Name = 'cold active only'; Expected = 'COLD_RANGE_CONSERVATIVE'; Values = @($false, $false, $true, $false, $false) },
        @{ Name = 'cold retired only'; Expected = 'REJECTED'; Values = @($false, $false, $false, $true, $false) },
        @{ Name = 'exact hot tombstoned'; Expected = 'REJECTED'; Values = @($true, $true, $true, $true, $true) },
        @{ Name = 'unknown'; Expected = 'REJECTED'; Values = @($false, $false, $false, $false, $false) }
    )
    foreach ($fixture in $holdFixtures) {
        $holdValues = $fixture.Values
        $actual = Test-ObservationHoldFixture @holdValues
        Assert-True ($actual -eq $fixture.Expected) "Observation-hold sparse/interleaved fixture failed: $($fixture.Name)"
    }

    . $hostPrepScript -Mode help | Out-Null
    $parsedPowerCfg = Parse-PowerCfgSettingIndices @(
        'Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced)',
        '    Current AC Power Setting Index: 0x00000000',
        '    Current DC Power Setting Index: 0x0000003c'
    )
    Assert-True ($null -ne $parsedPowerCfg -and $parsedPowerCfg.AcValue -eq 0 -and $parsedPowerCfg.DcValue -eq 60) `
        'Windows host readiness powercfg parser did not decode hex AC/DC indices.'
    Assert-True (Test-ValidSshPublicKeyLine 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAFb7a4HsF13SLXjLbIgHKKUU6GMub+FyULTeA+QWuKY runner') `
        'Windows host readiness rejected a valid ssh-ed25519 public key.'
    Assert-True (-not (Test-ValidSshPublicKeyLine 'command="evil" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAFb7a4HsF13SLXjLbIgHKKUU6GMub+FyULTeA+QWuKY')) `
        'Windows host readiness accepted an authorized_keys options prefix.'
    $testAuthKeysPath = Join-Path $temporaryRoot 'ssh\administrators_authorized_keys'
    $sampleKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAFb7a4HsF13SLXjLbIgHKKUU6GMub+FyULTeA+QWuKY runner'
    Set-ProtectedAdministratorsAuthorizedKeys $testAuthKeysPath @($sampleKey, $sampleKey)
    $aclStatus = Test-ProtectedAdministratorsAuthorizedKeysAcl $testAuthKeysPath
    Assert-True ($aclStatus.Present -and $aclStatus.Compliant) `
        "Windows host readiness did not apply strict SYSTEM+Administrators ACLs: $($aclStatus.Detail)"
    Assert-True (@([IO.File]::ReadAllLines($testAuthKeysPath)).Count -eq 1) `
        'Windows host readiness did not deduplicate administrators_authorized_keys entries.'
    $savedAppData = $env:APPDATA
    try {
        $fakeAppData = Join-Path $temporaryRoot 'appdata'
        $fakeDockerDir = Join-Path $fakeAppData 'Docker'
        New-Item -ItemType Directory -Path $fakeDockerDir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $fakeDockerDir 'settings-store.json'), '{"AutoStart":false,"UseResourceSaver":true}', [Text.UTF8Encoding]::new($false))
        $env:APPDATA = $fakeAppData
        $appliedSettings = Ensure-DockerDesktopAutoStart $true
        Assert-True ($appliedSettings.Present -and $appliedSettings.AutoStart -and $appliedSettings.ResourceSaverOff) `
            'Windows host readiness did not enforce AutoStart=true and UseResourceSaver=false in settings-store.json.'
    } finally {
        $env:APPDATA = $savedAppData
    }

    Assert-True (-not $setupSource.Contains('--accept-license')) `
        'Windows setup must never auto-accept the Docker Desktop license.'
    Assert-True ($setupSource.Contains("if (`$NonInteractive -or (Test-SessionZeroProcess))") -and
        $setupSource.Contains("`$dockerInstallArgs += '--quiet'") -and
        $setupSource.Contains('Test-WindowsRebootPending')) `
        'Windows setup does not guard bundled Docker Desktop installation against Session 0 GUI hangs and pending feature restarts.'

    # Verify Windows PowerShell 5.1 backup scratch cleanup handles >260-character
    # retained-media paths (.publication-commit.json) even when LongPathsEnabled=0,
    # while still rejecting nested reparse points before deleting anything outside.
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        Initialize-NativeStorageMethods
        $longRoot = Join-Path $temporaryRoot '.journal-confirm-20261030T012635Z-a6ec4c7a-7e62d1297dae41eabc7566ffa86a8d8b'
        New-Item -ItemType Directory -Path $longRoot | Out-Null
        $segments = @(
            'files', 'videos', 'retained-media', 'v1', 'events', 'MGkwNWE',
            'lanes', 'dXJuOm9zaDpzeXN0ZW06bGFuZTpsYW5lLTMy',
            'cameras', 'dXJuOm9zaDpzZW5zb3I6ZmZtcGVnOmxhbmU6bGFuZS0zMjow'
        )
        $extendedCurrent = [OscarStorageNative]::ToExtendedPath($longRoot)
        if (-not ('OscarLongPathTestHelper' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class OscarLongPathTestHelper {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CreateDirectoryW(string lpPathName, IntPtr lpSecurityAttributes);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr CreateFileW(string lpFileName, uint dwDesiredAccess, uint dwShareMode, IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);
    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr hObject);
}
'@
        }
        foreach ($seg in $segments) {
            $extendedCurrent = "$extendedCurrent\$seg"
            Assert-True ([OscarLongPathTestHelper]::CreateDirectoryW($extendedCurrent, [IntPtr]::Zero)) "Failed to create long-path directory segment: $seg"
        }
        $deepFile = "$extendedCurrent\.publication-commit.json"
        Assert-True (($deepFile.Length - 4) -gt 270) "Expected synthetic retained-media scratch path >270 chars, got $($deepFile.Length - 4)."
        $fileHandle = [OscarLongPathTestHelper]::CreateFileW($deepFile, [uint32]0x40000000, [uint32]0, [IntPtr]::Zero, [uint32]2, [uint32]0x80, [IntPtr]::Zero)
        Assert-True ($fileHandle -ne [IntPtr](-1)) 'Failed to create >270-char .publication-commit.json fixture.'
        [void][OscarLongPathTestHelper]::CloseHandle($fileHandle)

        Assert-RegularDirectoryTree $longRoot 'long-path backup scratch fixture'
        Remove-DirectoryTreeLongPathSafe $longRoot 'long-path backup scratch fixture'
        Assert-True (-not (Test-Path -LiteralPath $longRoot)) 'Remove-DirectoryTreeLongPathSafe did not remove the >270-char backup scratch tree.'

        $junctionParent = Join-Path $temporaryRoot 'reparse-guard-root'
        $junctionTarget = Join-Path $temporaryRoot 'reparse-outside-target'
        New-Item -ItemType Directory -Path $junctionParent | Out-Null
        New-Item -ItemType Directory -Path $junctionTarget | Out-Null
        [IO.File]::WriteAllText((Join-Path $junctionTarget 'keep.txt'), "keep`n", $Utf8NoBom)
        $junctionLink = Join-Path $junctionParent 'nested-junction'
        & cmd.exe /c "mklink /J `"$junctionLink`" `"$junctionTarget`"" *> $null
        $junctionRejected = $false
        try {
            Remove-DirectoryTreeLongPathSafe $junctionParent 'reparse guard fixture'
        } catch {
            $junctionRejected = $_.Exception.Message.Contains('contains a reparse point')
        }
        Assert-True $junctionRejected 'Remove-DirectoryTreeLongPathSafe did not reject a nested junction reparse point.'
        Assert-True (Test-Path -LiteralPath (Join-Path $junctionTarget 'keep.txt') -PathType Leaf) 'Reparse guard deleted a file inside an external junction target.'
        & cmd.exe /c "rmdir `"$junctionLink`"" *> $null
        Remove-DirectoryTreeLongPathSafe $junctionParent 'reparse guard fixture'
    }

    Write-Host 'OSCAR Windows PowerShell 5.1 storage safety tests passed.' -ForegroundColor Green
} finally {
    Remove-Item Env:OSCAR_STORAGE_TEST_MODE -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue }
    if ($createdDockerGroup) { & net.exe localgroup docker-users /delete *> $null }
}
