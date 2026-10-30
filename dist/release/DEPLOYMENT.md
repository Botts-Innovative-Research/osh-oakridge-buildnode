# OSCAR Administrator Guide

OSCAR runs as three Docker Compose services: an HTTPS gateway, the non-root OSCAR application, and PostgreSQL/PostGIS. The selected HTTPS port is published to the host, and port 80 redirects requests to HTTPS. PostgreSQL has no host port.

Start with [QUICKSTART.md](QUICKSTART.md) for installation. This guide documents deployment choices and routine administration.

## Supported deployment and operation hosts

- Windows 11 x86-64 with Docker Desktop and WSL 2
- Ubuntu Server 24.04 x86-64 with Docker Engine and the Compose plugin

The 3.11.0 storage profile fails closed on macOS because Docker Desktop for Mac cannot satisfy this
release's tested bind-root ownership and recovery-media isolation contract. Use Ubuntu or Windows
for initialization and operation; a Mac may still be used for source inspection or non-deployment
development.

### Windows 11 unattended server preparation

Windows 11 desktops and mobile workstations ship with `Balanced` power defaults that can suspend
idle sessions, close-lid laptops, USB 3 buses, USB Gigabit Ethernet adapters, and external USB SSDs.
Before running a 24/7 OSCAR deployment on Windows 11, run `configure-windows-host.ps1` (directly or
through `oscar.bat`) from an Administrator Windows PowerShell 5.1 window:

```powershell
.\oscar.bat host-check
.\oscar.bat prepare-host
```

Standalone invocation supports JSON output, strict non-zero audit exit codes, and idempotent
OpenSSH `administrators_authorized_keys` public-key enrollment with `SYSTEM` + `Administrators`
ACLs (inheritance disabled):

```powershell
.\configure-windows-host.ps1 -Mode apply -ConfigureLanHttpsFirewall -AuthorizeSshPublicKeyFile C:\staging\operator.pub
.\configure-windows-host.ps1 -Mode check -Strict -Json
```

`-Mode apply` sets AC and DC sleep, unattended-sleep, hibernate, and disk spin-down timeouts to `0`
(Never), disables hibernation and Fast Startup unless `-KeepHibernate` is requested, sets laptop
lid-close action to `Do nothing`, disables USB selective suspend and USB 3 Link Power Management,
turns off PCIe Link State Power Management (ASPM), clears WMI `MSPower_DeviceEnable` power-off flags
across USB controllers/storage/network devices, disables physical network-adapter power saving with
`-NoRestart` so active SSH sessions stay connected, configures `sshd` and `w32time` for `Automatic`
startup, sets `NoAutoRebootWithLoggedOnUsers=1`, `AlwaysAutoRebootAtScheduledTime=0`, and
`AUOptions=3` for Windows Update, sets Win32 `LongPathsEnabled=1` for tools that inspect deep
retained-media paths, disables Docker Desktop idle Resource Saver (`UseResourceSaver=false`), and
registers an interactive `AtLogOn` Scheduled Task (`OSCAR-DockerDesktop-AutoStart`) alongside
`AutoStart=true`. Because Windows 11 Automatic Restart Sign-On (ARSO) signs the operator back in
behind a locked console after an unattended Windows Update or domain-GPO maintenance reboot while
deferring `HKCU\...\Run` GUI startups until manual screen unlock, the `AtLogOn` Scheduled Task
launches Docker Desktop immediately inside the locked interactive session so `restart: unless-stopped`
OSCAR containers recover automatically without human console intervention. On trusted site LANs where newly connected USB or PCIe Ethernet
adapters default to Windows' `Public` firewall profile (which blocks inbound Docker Desktop port
publishing on `443`), pass `-ConfigureLanHttpsFirewall` (or `.\oscar.bat prepare-host -ConfigureLanHttpsFirewall`)
to switch connected wired `802.3` Ethernet adapters to `Private` and configure a scoped
`OSCAR-HTTPS-Gateway-In` rule (`TCP 443,80`, `Private,Domain`, `LocalSubnet` and `100.64.0.0/10`).

Because Docker Desktop on Windows runs inside an interactive administrator desktop session rather
than as a pre-logon Session-0 service, sign in to the physical console after any host reboot so
Docker Desktop starts automatically, then lock the workstation (`Win+L`). Once Docker Desktop is
running in that signed-in desktop session, all routine `oscar.bat` administration, backups,
restores, and monitoring work normally over SSH.

## Administrative CLI

Use `oscar.bat` on Windows and `oscar.sh` on Ubuntu. The Windows launcher invokes Windows
PowerShell 5.1 (`powershell.exe`); PowerShell 7 is not required.

Opening either launcher with no arguments starts a persistent `oscar>` administration menu. On Windows, double-clicking `oscar.bat` requests UAC elevation automatically; an Administrator Windows PowerShell 5.1 window does not need to be opened first. On graphical Ubuntu, opening the executable `oscar.sh` starts the menu in a terminal. Desktop file-execution policy varies, so direct terminal commands remain the supported fallback. Ubuntu Server has no graphical launcher and is administered from its terminal.

The menu accepts the same command and options shown below. For example, enter `init`, `status`, `logs -Service postgres -Follow` on Windows, or `logs --service postgres --follow` on Ubuntu. Enter `exit` to close the menu. Supplying arguments directly bypasses the menu, preserving automation compatibility.

| Action | Windows | Ubuntu |
| --- | --- | --- |
| Initialize | `oscar.bat init` | `sudo bash oscar.sh init` |
| Check prerequisites | `oscar.bat check` | `sudo bash oscar.sh check` |
| Audit Windows 11 server power/USB readiness | `oscar.bat host-check` | Not applicable |
| Apply Windows 11 unattended server settings | `oscar.bat prepare-host` | Not applicable |
| Verify offline media | `oscar.bat verify` | Site-prepared bundles only: `sudo bash oscar.sh verify` |
| Start | `oscar.bat start` | `sudo bash oscar.sh start` |
| Stop | `oscar.bat stop` | `sudo bash oscar.sh stop` |
| Restart | `oscar.bat restart` | `sudo bash oscar.sh restart` |
| Status | `oscar.bat status` | `sudo bash oscar.sh status` |
| Logs | `oscar.bat logs` | `sudo bash oscar.sh logs` |
| Upgrade | `oscar.bat upgrade` | `sudo bash oscar.sh upgrade` |
| Coordinated backup | `oscar.bat backup` | `sudo bash oscar.sh backup` |
| Verify backup | `oscar.bat backup-verify -BackupId ID` | `sudo bash oscar.sh backup-verify ID` |
| Archive status | `oscar.bat archive status` | `sudo bash oscar.sh archive status` |
| Archive integrity | `oscar.bat archive verify` | `sudo bash oscar.sh archive verify` |
| Retention holds | `oscar.bat archive hold list` | `sudo bash oscar.sh archive hold list` |

Directly invoked mutating commands require an elevated Windows PowerShell 5.1 window on Windows or root privileges on Ubuntu. The Windows menu obtains elevation through UAC, and the Ubuntu menu invokes `sudo` when a selected command requires it.

`start`, `stop`, and `restart` never build or download images. `init` and `upgrade` may prepare missing images for a connected release. After building the local OSCAR/PostGIS images, setup rechecks the complete inventory and pulls the gateway only if it is still absent; an already-cached pinned gateway therefore does not create an unnecessary registry or credential-helper dependency. If `offline-images.tar` is present, every mutating setup run re-verifies the exact bundle inventory against the co-packaged `SHA256SUMS` and loads that checksum-verified archive even when same-version tags already exist locally. It never substitutes a stale local image for the selected bundle and fails if any required image remains unavailable afterward. Because the manifest is bundled and unsigned, this is an integrity check, not publisher or release-origin authentication. Sites that require origin authentication must verify the outer ZIP against an independently trusted detached signature or provenance attestation before offline transfer.

On Windows, connected setup builds the two release-local images with explicit
`docker build` contexts after validating the deployment paths. This avoids the
Docker Compose 5.6/Buildx 0.37 filesystem-entitlement regression that can
misclassify an in-tree Dockerfile and request an unavailable `fs.read` approval.
OSCAR does not disable Bake filesystem checks globally or grant wildcard host
filesystem access; the image tags, release version argument, and PostgreSQL
platform remain identical to `compose.yaml`.

Use the launchers for a complete stop or restart rather than issuing an unscoped multi-service
`docker compose stop` or `docker compose restart`. The supported launchers stop the gateway first,
wait for OSCAR to finish its bounded journal/module shutdown while PostgreSQL remains available,
and stop PostgreSQL last. Restore uses the same dependency-safe order before replacing state.

Offline releases are published in two Windows x86-64 profiles:

- `offline-full` contains OSCAR images plus the approved Docker Desktop and WSL installers.
- `offline-images` contains OSCAR images only and requires Docker Desktop, WSL 2, and Docker Compose to be installed and running already.

Initialization defaults to `-Prerequisites auto`, which uses a working existing Docker installation and only launches bundled installers when Docker is unavailable. Use `-Prerequisites existing` to prohibit prerequisite installation, or `-Prerequisites bundled` to explicitly permit the bundled fallback. Official offline release media and bundled prerequisites are Windows-only. Supported Ubuntu deployments use a connected release with Docker Engine/Compose already installed; Bash `--prerequisites bundled` support is only for a separately qualified, site-prepared `.deb` set and is not built, validated, or published by the release workflow.

## Initial setup options

The defaults are hostname `oscar.local`, HTTPS port `443`, and a self-signed certificate. Setup asks for an administrator password of at least 14 characters, generates unique database credentials, validates TLS, and starts the deployment. For a new self-signed installation, setup automatically adds active non-container LAN IPv4 addresses, active Tailscale IPv4/IPv6 addresses, and the connected Tailscale MagicDNS name (when discoverable) to the certificate. It prints every covered client URL when initialization completes. Ordinary SLAAC privacy IPv6 addresses are intentionally excluded because they rotate before the certificate expires; add a site-stable IPv6 address explicitly when required.

With the default HTTPS port, entering the configured hostname without a scheme is supported: the gateway redirects the browser from HTTP to HTTPS while preserving the requested path. Deployments using a nonstandard HTTPS port must include that port in the URL printed by setup.

Windows example with an imported certificate:

```powershell
.\oscar.bat init -Hostname oscar.example.org -Port 443 `
    -TlsMode import -CertificatePath C:\certs\server.crt `
    -PrivateKeyPath C:\certs\server.key
```

Windows self-signed LAN/Tailscale example with additional stable names:

```powershell
.\oscar.bat init -Hostname oscar-site.example.org -Port 443 `
    -TlsSan 192.168.0.61,oscar-site.example-tailnet.ts.net
```

Ubuntu equivalent:

```sh
sudo bash oscar.sh init --hostname oscar.example.org --port 443 \
    --tls-mode import --certificate /secure/server.crt \
    --private-key /secure/server.key
```

Ubuntu self-signed LAN/Tailscale example with additional stable names:

```sh
sudo bash oscar.sh init --hostname oscar-site.example.org --port 443 \
    --tls-san 192.168.0.57 \
    --tls-san oscar-site.example-tailnet.ts.net
```

`--tls-san` is repeatable on Ubuntu. `-TlsSan` accepts a comma-separated list on Windows. Automatic
network SAN discovery is enabled only for newly generated self-signed certificates. Use
`--no-auto-network-sans` or `-NoAutoNetworkSans` when a deliberately hostname-only certificate is
required. Container bridge, Docker, WSL, loopback, and link-local addresses are excluded. If
Tailscale is enabled after initialization, replace the certificate through the controlled
certificate-renewal process or initialize with the expected stable Tailscale IP/MagicDNS name
explicitly; do not edit a certificate in place.

By default, setup maps the hostname only on the OSCAR host. Use `-SkipHostsEntry` or `--skip-hosts-entry` to leave local host resolution unchanged. Site DNS or a hosts entry is still required on every workstation that connects to OSCAR.

`server.crt` must be a PEM certificate or chain. `server.key` must be its matching unencrypted PEM private key. The certificate subject alternative names must contain every DNS name or IP address used to reach OSCAR.

For an isolated deployment, administrators may use a deployment-specific certificate authority and install only its public certificate on workstations. Never place the certificate-authority private key in this release directory, a container, or a diagnostic bundle.

### LAN and Tailscale client trust

The generated self-signed `tls/server.crt` is public and may be copied to operator workstations. An
imported certificate already chaining to a workstation-trusted issuer needs no additional import. Verify the certificate's
SHA-256 fingerprint against the value obtained directly from the OSCAR host before trusting it.
Never copy `tls/server.key`. Installing the public certificate trusts only this deployment's
self-signed identity; it does not make an unlisted hostname or IP valid.

- Windows client, from an elevated PowerShell window:
  `certutil -addstore -f Root .\server.crt`
- Ubuntu client: copy it to `/usr/local/share/ca-certificates/oscar-site.crt`, then run
  `sudo update-ca-certificates`. A browser configured with a separate certificate store must also
  import the public certificate there.
- macOS client: use Keychain Access to add `server.crt` to the System keychain and mark it trusted,
  after verifying the fingerprint.

For ordinary LAN operation, create a site DNS record pointing the configured hostname at the
OSCAR host's static address. A per-workstation hosts entry is an acceptable isolated-test fallback,
but it does not scale and must map the same hostname that appears in the certificate. Direct access
such as `https://192.168.0.57/` requires that exact IP SAN; accepting a warning for a certificate
issued only to `oscar.local` is not a supported substitute.

The gateway publishes the configured HTTPS port on the host interfaces by default. Scope the host
and upstream firewalls to permit that TCP port from authorized LAN subnets and, when used, the
Tailscale interface/tailnet only; do not expose it through a WAN port-forward. TCP port 80 is used
only for the hostname-to-HTTPS redirect and may remain blocked when clients use the printed HTTPS
URLs directly. On Windows, approve Docker Desktop access only for the intended network profile.

For Tailscale access, prefer the stable MagicDNS name and include it explicitly when it is not
discoverable during setup. Direct Tailscale-IP access is supported when the printed certificate
URL contains that IP. Tailscale connectivity does not distribute OSCAR's certificate trust: each
client must still trust `server.crt`, or the deployment must import a certificate already trusted
by those clients. Restrict Tailscale ACLs separately so only authorized operators can reach the
OSCAR HTTPS port.

## Windows offline installation

Extract the offline ZIP into a local NTFS directory. From an Administrator Windows PowerShell 5.1
(`powershell.exe`) window:

```powershell
.\verify-bundle.ps1
.\oscar.bat init
```

The equivalent CLI command is `oscar.bat verify`. Verification requires the exact bundle inventory:
every allowed regular payload file appears once in `SHA256SUMS`, every listed digest matches, only
OSCAR's closed non-executable runtime state paths (`.env`, `.oscar-init-state`,
`.oscar-volume-adoption`, the four `secrets/*.txt` files, `tls/server.{crt,key}`, and
`pre-restore-<id>` credential backups) may exist outside `SHA256SUMS` after initialization, and no
extra, linked, reparse-point, aliased, or prefix-colliding path is accepted. OSCAR records a receipt
for audit, but every later mutating `init` or `upgrade` repeats the full pass before it can execute a
bundle payload. Routine non-setup commands do not perform full bundle verification; run `verify`
explicitly whenever post-installation tampering is suspected.

The full artifact can launch only the unique, allowlisted and checksum-covered installer paths named by its manifest
when WSL or Docker Desktop is missing. An extra wildcard-matching installer is rejected rather than
selected. The images-only artifact must be initialized with a working existing runtime:

```powershell
.\oscar.bat init -Prerequisites existing
```

If an installer requires a restart, restart Windows and run `oscar.bat init` again. When `init` runs
with `-NonInteractive` or from an OpenSSH Session-0 shell, OSCAR passes `--quiet` (never
`--accept-license`) to the bundled Docker Desktop installer so it cannot block on an unseen
Session-0 completion dialog, then stops cleanly whenever a Windows feature restart or interactive
desktop Docker Desktop launch/license acceptance is required.

The offline CLI does not contact package repositories or container registries. Docker Desktop
licensing must be reviewed and accepted independently by the deploying organization; OSCAR does not
accept that agreement. A required installer restart is also an explicit administrator acceptance
step before setup is resumed.

## Logs

The default displays the last 200 lines from all services and exits:

```powershell
.\oscar.bat logs
```

Select a service and optionally follow it:

```powershell
.\oscar.bat logs -Service oscar -Tail 500
.\oscar.bat logs -Service postgres -Follow
.\oscar.bat logs -Service gateway
```

Ubuntu uses `--service`, `--tail`, and `--follow`.

## Persistent state and secrets

Initialization creates:

```text
.env
secrets/oscar-admin-password.txt
secrets/oscar-db-password.txt
secrets/postgres-bootstrap-password.txt
secrets/backup-key.txt
tls/server.crt
tls/server.key
```

Docker Compose mounts secrets read-only. On Ubuntu, the setup CLI makes `secrets` and `tls` mode `0700`, with contained files readable by the deliberately non-root services. On Windows, it restricts the directories to the installing administrator and `SYSTEM` while preserving container-readable, read-only mounts.

The application configuration is copied into the `oscar_state` volume on first startup. Runtime configuration saves update only that persistent copy. Application libraries and viewer assets remain read-only in the image. PostgreSQL data is stored in the `postgres_data` volume. OSCAR 3.11.0 uses a long-lived host bind for the primary Parquet cold tier (`OSCAR_ARCHIVE_DIR`). PostgreSQL runs with `archive_mode=off`, no external archive command, and no WAL bind. An existing `OSCAR_WAL_ARCHIVE_DIR` is preserved only to avoid deleting legacy data; current schema-v1/v2 restore does not use it. Fresh deployments set `OSCAR_BACKUP_MODE=disabled`; after explicit `single` opt-in, `OSCAR_BACKUP_DIR` is an operator-selected safe absolute host path that does not overlap the release or archive roots and is never mounted into a long-running service. A separate physical drive is recommended for failure isolation but is not required. A Docker named-volume backup or Parquet copy alone is incomplete.

The OSCAR service keeps the general-purpose `/tmp` tmpfs `noexec`. Embedded Java native libraries,
including DuckDB JDBC and JavaCPP/FFmpeg, are extracted instead to a separate 256 MiB tmpfs at
`/run/oscar-native`. That mount is executable only because the JVM must map shared objects; it is
still ephemeral, `nosuid`, `nodev`, owned by the non-root OSCAR user, and mode `0700`. The entrypoint
forces `java.io.tmpdir` to that path after `OSCAR_JAVA_OPTS` and refuses to start unless `/tmp` is a
dedicated `noexec` tmpfs and the native mount has the expected type, ownership, permissions, and
execution behavior. User-supplied multipart and spectrum-conversion temporary files remain on
`/tmp` through the separately managed `oscar.data.tmpdir` property, so they never enter the
executable native directory. Do not override either mount or add `-Djava.io.tmpdir` or
`-Dorg.bytedeco.javacpp.cachedir` or `-Doscar.data.tmpdir` to `OSCAR_JAVA_OPTS`. The entrypoint
also rejects `_JAVA_OPTIONS`, which OpenJDK applies after command-line options; custom launchers
must reproduce this two-mount contract.

DuckDB query scratch is separate from both temporary mounts and the immutable archive. Every
archive connection is limited by the persisted database-module settings (shipping defaults:
256 MiB memory, two threads, and 4 GiB spill) and gets a private child below
`/var/lib/oscar/duckdb-tmp` in `oscar_state`. Normal connection close removes the child; coordinated
backups exclude this scratch parent. OSCAR holds an operating-system lease in the persistent
`.oscar-duckdb.lock` file for its process/classloader lifetime, so a second owner cannot clean live
spill. The first session after a crash, while holding the lease, automatically removes only direct
children matching the canonical `<operation>-<lowercase UUID>` form; it preserves unrelated entries
and never follows symbolic links. Streaming archive reads check shutdown cancellation between rows
as well as cancelling an active JDBC statement. The scratch and archive roots must be disjoint. In
the Linux container (on either Ubuntu or Windows hosts), OSCAR requires POSIX mode `0700` on the
parent and each operation child, and a real regular non-link lease with mode `0600`; broader or
unsafe existing permissions are rejected. A non-container/non-POSIX embedding must provide
equivalent owner-only ACLs. Manual cleanup is a fallback only: stop OSCAR first and remove only
confirmed abandoned canonical operation children, never the lease or unrelated entries while a
process may be active.
The backup exclusion is intentionally limited to the reserved `/var/lib/oscar/duckdb-tmp` path.
OSCAR therefore rejects any other scratch path inside `/var/lib/oscar`; a custom path must be
outside that persistent state tree and disjoint from the archive.

The backup key encrypts `.env`, deployment secrets, and TLS private material inside coordinated backups. The encrypted `secrets/` payload contains a recovery copy of the key file, but there is no usable plaintext key in the backup: store an external protected copy in an independent secret escrow or failure domain.

The gateway gives content-hashed Viewer files under `/_next/static/` a private, one-year immutable browser cache policy, while `/sw.js` is always revalidated. This prevents repeated full-route navigations from downloading the same application bundles again without allowing a shared proxy to cache an authenticated response. HTML and API responses keep their normal revalidation behavior.

`oscar stop` retains containers, named data volumes, the archive bind, preserved legacy data, and the external
backup root. Do not use `docker compose down --volumes` as a records-destruction procedure: Compose
skips OSCAR's external named volumes, and neither that command nor container removal deletes the
archive, legacy-WAL, or backup roots. Authorized permanent destruction therefore requires the documented,
explicit removal of every retained data location.

WebID is disabled by default. Failure to reach an optional configured WebID endpoint must not prevent OSCAR from starting.

The OSCAR container health check is an application-readiness check, not merely an HTTP liveness
probe. It becomes healthy only after the web service and every top-level auto-start module are
`STARTED`, and after each nested RPM/camera member has completed its startup attempt. A device that
cannot connect may settle offline while OSCAR remains healthy so the Status of Health page can
report it. During a 50-lane startup,
`docker compose ps` may therefore show OSCAR as `starting` after the login endpoint begins to
respond. Do not chain another restart or storage-maintenance operation during that interval. The
launcher and storage commands wait for this stronger health signal automatically. An `unhealthy`
result means at least one required module failed to complete startup; inspect the OSCAR container
logs for that module.

## Security verification

After startup:

```sh
docker compose ps
docker compose exec -T postgres sh -eu -c '
  PGPASSWORD=$(cat /run/secrets/postgres_bootstrap_password)
  export PGPASSWORD
  exec psql --set=ON_ERROR_STOP=1 --username oscar_bootstrap --dbname gis "$@"
' psql-wrapper --command "SELECT rolname, rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls FROM pg_roles WHERE rolname = 'oscar_app';"
```

Every reported privilege flag for `oscar_app` must be false. A host scan must show port `80` and the configured HTTPS port, and must not show ports `8282` or `5432`. Port `80` must return only an HTTPS redirect.

## Upgrade

For a 3.11.0-or-newer same-storage-profile upgrade, create and verify a coordinated snapshot first when the site has explicitly selected `OSCAR_BACKUP_MODE=single`. A disabled site must use its separately approved protection procedure or opt in through `upgrade` before invoking backup or restore. A pre-3.11.0 release does not have this CLI; use that release's supported backup/export procedure and retain the old system read-only until the separately qualified migration is complete. Extract the new release into a clean sibling directory; do not overlay it on the previous release because removed files would otherwise remain in the image build context. Copy only `.env`, `secrets/`, and `tls/` from the existing deployment into the clean release directory. If the deployment has a `.oscar-volume-adoption` receipt, copy that file too. Preserve `OSCAR_BACKUP_MODE`, the absolute active `OSCAR_ARCHIVE_DIR` and `OSCAR_BACKUP_DIR` values, and any existing absolute `OSCAR_WAL_ARCHIVE_DIR` compatibility binding; setup must never delete legacy roots or data while changing modes. Before starting services, use `docker compose config` to confirm the archive bind and the absence of a PostgreSQL WAL bind, then inspect the single mode and backup-root entries in `.env`. Compose attaches the exact external volumes `oscar_oscar_state` and `oscar_postgres_data`; setup owns their creation and validates deployment identity. Then run:

```powershell
.\oscar.bat upgrade
```

```sh
sudo bash oscar.sh upgrade
```

The command preserves existing settings and data while normalizing the required 3.11.0 managed
bindings: deployment identity, exact backup mode, absolute external storage roots, and the canonical backup-key
binding. A legacy deployment may also receive a generated backup key plus explicit volume/root
adoption metadata when the corresponding adoption options are supplied. After those guarded
normalizations it updates `OSCAR_VERSION`, validates Compose, prepares the versioned images,
stops the application tier, and runs the new image's restartable offline daily-file lifecycle-index
migration using the Daily File Journal root, journal directory, and calendar zone from the persisted
`/var/lib/oscar/config.json`. If that module is absent the narrow migration is skipped. An already
indexed journal creates no new work markers; an empty configured journal may receive its durable
metadata. Completion metadata is committed last, so a crash or validation failure may leave only
idempotent work markers plus an explicit restart marker. OSCAR remains stopped and the same
`upgrade` command is safe to retry. The deployment-scoped storage lock excludes backup, restore,
and archive-administration commands from the ordered stop through migration and the force-recreated,
health-checked restart. The workflow retains the fixed `oscar_state`
and `postgres_data` volumes plus the exact external archive and preserved legacy/backup roots. Recreating every
container is required even when an image and service model are unchanged: release-local secret,
certificate, and gateway-config bind sources and the Compose `working_dir`/`config_files` provenance
must point to the new clean release directory. It never removes volumes or external storage roots.
OSCAR health includes complete recursive module readiness, so a successful command cannot return
while lane RPM or camera initialization is still in flight.

Confirm the result with `oscar.bat status`
(Windows) or `sudo bash oscar.sh status` (Ubuntu).

Retire the previous extracted release directory only after all upgraded services are healthy and
`docker inspect` confirms that every container's release-local bind sources and Compose
`working_dir`/`config_files` labels refer to the new directory. The absolute archive and backup
roots intentionally continue to refer to the persistent paths copied in `.env`; a legacy-WAL
binding only preserves the location of existing compatibility data. Do not remove a
previous release's parent or sibling storage directory merely because its service containers were
replaced.

Setup creates both named volumes with an `OSCAR_DEPLOYMENT_ID` label and refuses missing, mixed, or
foreign ownership. Compose treats those exact names as external resources and never creates or
relabels them. For a pre-label deployment only, first verify from the old release and Docker
metadata that **both** `oscar_oscar_state` and `oscar_postgres_data` belong together. Then acknowledge
that one-time adoption with `oscar.bat upgrade -AdoptLegacyVolumes` or
`sudo bash oscar.sh upgrade --adopt-legacy-volumes`. Setup records both immutable Docker volume
creation times and the deployment ID in `.oscar-volume-adoption`; later mismatches fail closed.
Never use this switch to combine volumes from different installations, and preserve the receipt on
every subsequent clean-directory upgrade.

Storage-root ownership is a separate gate. New roots receive an administrator-owned
`.oscar-storage-root` version-1 identity bound to `OSCAR_DEPLOYMENT_ID` and the exact root kind. A
nonempty pre-3.11.0 active archive or backup root without that marker requires a one-time, reviewed
`oscar.bat upgrade -AdoptLegacyStorageRoots` or
`sudo bash oscar.sh upgrade --adopt-legacy-storage-roots`. The marker records the adoption time and
actor. Setup rejects a foreign UUID, swapped kind, unsafe marker, or unacknowledged nonempty root
before claiming any path. Backups exclude these host-local markers, and restore preserves and
revalidates the target markers instead of accepting identities from backup media. A retired
legacy-WAL tree is neither claimed nor mutated by current setup.

The OSCAR application libraries and exported Viewer are part of the `oscar:<version>` image. A restart does not rebuild that image. To test OSCAR 3.11.0 from a connected release artifact, prepare the clean release directory as described above. Use `init` and fresh state for the complete 3.11.0 storage profile; use `upgrade` only when intentionally retaining the existing storage/configuration profile. Confirm that `docker compose images` reports `oscar:3.11.0` before accepting the test result.

Release image tags are immutable once published. Connected `init` and `upgrade` rebuild both local image contexts (`oscar:3.11.0` and `oscar-postgis:3.11.0`) before recreating services, even when those tags already exist, so a pre-release same-tag iteration cannot silently retain an older application or restore helper. On Ubuntu this is equivalent to `OSCAR_VERSION=3.11.0 docker compose build oscar postgres`. The Windows setup performs two bounded `docker build` operations, including `docker build --platform linux/amd64 --build-arg OSCAR_VERSION=3.11.0 --tag oscar-postgis:3.11.0 --file postgis/Dockerfile postgis`; this avoids Docker Compose 5.6's in-tree Dockerfile entitlement regression without granting wildcard filesystem access. The regression platform check requires each packaged helper to match its deployed image byte-for-byte. Never replace a published `oscar:3.11.0` image with different contents.

The default configuration for a new installation is labeled `OSCAR 3.11.0`. An upgrade preserves `/var/lib/oscar/config.json`, including a customized deployment name, so the Admin UI may continue to display the prior or site-specific label. Do not overwrite that value merely to display a version number. Use `OSCAR_VERSION` in `.env` and `docker compose images` to verify the running release. The OSCAR image also stamps that value into the OCI `org.opencontainers.image.version` label; inspect it on PowerShell or a POSIX shell with `docker image inspect oscar:3.11.0 --format '{{json .Config.Labels}}'` and require the label value `3.11.0` before accepting the image.

On Windows, setup and storage administration stream every bounded shell body and direct `psql`
statement into the one-shot container over UTF-8 standard input. The direct `docker run` adapter owns
the required `--interactive` attachment, while Compose execution remains non-TTY with `exec -T`.
Setup relays storage-command parameters to its child PowerShell process through a bounded,
allowlisted Base64/JSON environment envelope and a fixed encoded command; operator text is never
forwarded as native executable arguments. These rules preserve multiline checks, SQL, paths, and
quoted values exactly under Windows PowerShell 5.1 native argument handling. A failed initialization
check leaves the receipt in `INITIALIZING`; correct the reported problem and rerun `oscar.bat init`
from the same release and protected runtime state rather than deleting the volumes.

### 3.11.0 storage migration boundary

OSCAR 3.11.0 changes the default database module, write path, daily-file source capture, media-retention format, and PostgreSQL initialization. `upgrade` deliberately does not overwrite the saved module configuration or recreate the PostgreSQL cluster, so an upgraded pre-3.11.0 system does not automatically gain the complete 3.11.0 storage profile or data checksums.

Initialize the current test systems and new production systems with a fresh 3.11.0 database/configuration. If existing production history must be retained, keep the old system read-only after a verified backup and use a separately designed and tested migration. Do not delete production volumes merely to make the new module start. Follow the parity, restore-drill, and bounded hot-deletion validation in [`../../docs/STORAGE_OPERATIONS.md`](../../docs/STORAGE_OPERATIONS.md).

The OSCAR container keeps `/var/lib/oscar/config.json` readable and writable only by the OSCAR runtime user (`0600`) and repairs older read-only copies during startup. After importing a lane CSV, wait for every lane to appear under **Sensors**, select the global **Save** action, restart OSCAR, and confirm that the same lanes reload. Historical systems in PostgreSQL are not proof that runtime sensor modules were saved; an empty **Sensors** tree after restart indicates that the module configuration was not persisted.

On Windows, OSCAR grants the local `docker-users` group read-only access to the protected `secrets` and `tls` directories so Docker Desktop can mount them. This is required when setup is elevated with a different administrator account than the signed-in account running Docker Desktop. The group receives temporary write access only while `init` generates or imports the certificate.

## Storage administration

The release implements an opt-in one-current-snapshot backup/verification/restore workflow,
retention holds, and archive status, integrity, portable export, and restartable tokenized deletion
commands. `backup-prune` is retired and performs no deletion. The full procedures are in:

- [`../../docs/STORAGE_ARCHITECTURE.md`](../../docs/STORAGE_ARCHITECTURE.md)
- [`../../docs/DATA_LIFECYCLE.md`](../../docs/DATA_LIFECYCLE.md)
- [`../../docs/ARCHIVE_FORMAT.md`](../../docs/ARCHIVE_FORMAT.md)
- [`../../docs/BACKUP_RESTORE.md`](../../docs/BACKUP_RESTORE.md)
- [`../../docs/STORAGE_OPERATIONS.md`](../../docs/STORAGE_OPERATIONS.md)

The hold list and creation result include `resolution_mode`. A
`COLD_RANGE_CONSERVATIVE` observation hold protects matching generation ranges but is not proof that
the exact ID exists in sparse Parquet; verify the event or use an exact generation hold for legal
certainty. `LEGACY_UNKNOWN` is a protective migration-only label for pre-3.11.0 observation holds
whose exact-vs-range provenance cannot be reconstructed; the CLI never creates it. Active
observation and generation holds are enforced inside the same transaction as
hot/cold logical removal and tombstone creation. Single removal fails on a hold; filtered bulk
removal skips protected rows and counts only rows actually removed.

The same files are under `documentation/` in the packaged release. `backup` verifies the newly
created schema-v2 snapshot automatically and authenticates its checksum inventory with the separately stored
backup key. It rejects unsafe tar members and any v2 `wal-archive.tar.gz`, atomically marks the recovery point `VERIFIED`, and,
while OSCAR remains stopped, confirms only exact published daily-file/segment sets captured by the
accepted authenticated snapshot. After confirmation, an atomic HMAC-authenticated `CURRENT`
replacement commits the one logical snapshot; only then can the previous non-current fully accepted
schema-v2 snapshot be cleaned. Confirmation failure leaves the old pointer authoritative. PostgreSQL remains
online for `pg_basebackup --wal-method=stream`; there is no cumulative WAL snapshot.
`backup-verify` runs `pg_verifybackup` in a dependency-free utility container, so the
live database and its catalog receipt are not recovery dependencies. Use `backup-verify` to recheck
it before every upgrade or retention reduction. Schema-v1 snapshots remain explicitly verifiable
and restorable and require their historical WAL payload for authentication; restore ignores that
external payload because streamed `postgres/pg_wal` is sufficient. OSCAR does not provide PITR.
One logical snapshot is the steady state, not the peak capacity requirement. A replacement keeps
the old snapshot while the complete new candidate is built, verified, accepted, and committed
through `CURRENT`, so size the backup root for both. The next locked storage command uses the
authenticated pointer to reconcile any non-current snapshot or private staging debris left by a
crash. Cleanup removes only candidates that independently pass complete schema-v2 core and
acceptance verification; schema-v1, failed, partial, unauthenticated, unaccepted, and incomplete
deletion candidates are preserved with warnings. If no `CURRENT` exists, one uniquely accepted
schema-v2 candidate is adopted by reconstructing authenticated `CURRENT`; multiple accepted
candidates are preserved and stop for operator review.
All storage-administration commands share one nonblocking, crash-released deployment lock; a
concurrent invocation fails rather than racing backup/archive state. The lock is keyed by
`OSCAR_DEPLOYMENT_ID` in `/run/lock/oscar-storage` on Ubuntu or
`%ProgramData%\OSCAR\StorageLocks` on Windows, so it
continues to coordinate old and new extracted releases. Live commands validate every root identity
and both named-volume ownership identities; only offline-capable `backup-verify` is exempt from
those live dependencies. Verification is still an acceptance mutation: it publishes/replaces
`VERIFIED` and normalizes backup permissions, and may update the live catalog only after proving
volume ownership.
Fresh deployments default to backup mode `disabled`; backup, verification, restore, and the retired
prune command fail with opt-in guidance until setup changes the mode to `single`. For a fresh
database, the standard data lifecycle explicitly selects `PARQUET_PRIMARY`: five allowlisted
immutable high-volume outputs commit first to LOGGED, UTC-aligned 30-minute PostgreSQL staging
children. A one-minute worker makes a closed child eligible after a five-minute safety delay; a
detector timestamp more than five minutes ahead of the database receipt clock is rejected. After
manifest-last activation, object re-hash, and exact row/UUID parity, OSCAR transactionally detaches
and drops the complete child, retiring at most eight children per cycle. There is no three-day raw
PostgreSQL overlap in this mode. The normal staging budget is at most 60 minutes, but this is an
operational SLO rather than a hard deadline during backlog, failure, lock contention, or downtime.
Mutable events, adjudications, small metadata, and other non-allowlisted data remain in PostgreSQL;
fresh primary staging children omit generic payload and mutable-event indexes. After safe stage
retirement, Parquet and the independently published daily files are the durable long-term detector
representations; the compact staging-owner ledger is removed with its child.
Parquet is the primary cold tier, not a backup. Cold archive deletion always requires a reviewed
`archive dry-run` plan and its one-time token.

Certificate renewal and a site-specific migration of retained pre-3.11.0 history remain controlled administrator operations and must be validated before an upgrade is declared production-ready.

## Compatibility scripts

`setup.*`, `launch-all.*`, and `stop-all.*` remain as compatibility wrappers. New documentation and automation should use only `oscar.bat` or `oscar.sh`.

Offline map layers are not currently required. The CLI retains an explicit MBTiles import TODO for a future milestone.

## Local timezone and daily files

Initialization prompts for an IANA timezone such as `America/Chicago`, `America/New_York`, or `UTC`. Use `--timezone America/Chicago` on Linux/macOS or `-Timezone America/Chicago` on Windows to specify it on the command line. Windows timezone display names such as `Central Standard Time` are not accepted. Setup validates the name against the OSCAR image's timezone database.

The setting is saved as `OSCAR_TIMEZONE` in `.env`. A repeated initialization preserves the existing timezone by default; new deployments and non-interactive initialization without a timezone default to `UTC`.

OSCAR uses this timezone as its Java default, including dailyfile local timestamps and local-midnight file rollover. Daylight-saving transitions follow the selected region. Dailyfile UTC timestamps remain UTC. Other application features using the Java default timezone also follow this setting.

For an existing deployment, set `OSCAR_TIMEZONE=America/Chicago` in `.env` and run `docker compose up -d --no-build --pull never oscar` from the release directory to recreate the application container. A plain container restart does not apply changed environment variables. The release image must include the updated entrypoint.

Rapiscan and Aspect both write `dailyfiles/<fileId>_<YYYY-MM-DD>.csv`, using the final segment of the sensor UID as the file ID. Rows contain device-specific message values followed by local and UTC times in `HH-mm-ss.SSS` format, with CRLF line endings and no header. Their SWE output names are both `dailyFile` (label `Daily File`), with `samplingTime` as the first field. Their second field is `rpmMessage` (label `RPM Message`) for both drivers. These datastream messages contain the device payload; the appended local and UTC columns belong to the stored CSV files.

The `rpmMessage` field replaces `rapiscanMessage` and `aspectMessage`. External consumers selecting either old JSON property must use `rpmMessage` for new observations and retain support for the old names when reading historical data. On driver registration, OSH creates a new datastream version if the prior schema has observations; an empty datastream is updated in place. Consumers caching datastream IDs should rediscover the current `dailyFile` stream after upgrading. Stored CSV files have no field-name headers and are unaffected. The historical `test/staging-test-db.sql` snapshot retains its original field names.
