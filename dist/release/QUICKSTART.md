# OSCAR Quick Start

OSCAR 3.9.2 deployment and storage operation are supported only on Windows 11 x86-64 with Docker
Desktop/WSL 2 and Ubuntu Server 24.04 x86-64 with Docker Engine/Compose. macOS is limited to source
inspection and non-deployment development; initialization, start, restart, upgrade, and storage
operations fail closed there.

## Windows 11

1. Choose `offline-full` when Docker Desktop or WSL may need installation. Choose `offline-images` when compatible Docker Desktop, WSL 2, and Docker Compose are already installed and running.
2. Extract the OSCAR ZIP to a local NTFS directory.
3. Double-click `oscar.bat`, approve the Windows administrator prompt, and enter `init` at the `oscar>` prompt. The launcher uses Windows PowerShell 5.1 (`powershell.exe`).
4. Alternatively, for scripted or terminal-based setup, run:

```powershell
.\oscar.bat init
```

5. Enter the deployment hostname and an OSCAR administrator password of at least 14 characters.
   New self-signed installations automatically include the host's active, non-container LAN IPv4
   and Tailscale IPv4/IPv6 addresses in the certificate. If clients will use a stable site-DNS or Tailscale
   MagicDNS name other than the primary hostname, add it with `--tls-san` on Ubuntu or `-TlsSan`
   on Windows during initialization.
6. Open the URL printed by setup, normally `https://oscar.local/sensorhub/admin`.

Setup creates deployment-specific database credentials, defaults `OSCAR_BACKUP_MODE` to `disabled`,
and persists the absolute archive path (and the backup path only when `single` mode is selected) under the sibling `oscar-storage` directory. The legacy-WAL
binding is retained only so an upgrade cannot lose track of already existing compatibility data.
It prepares only the storage required by the selected mode and writes administrator-protected `.oscar-storage-root` identities bound to the
deployment UUID and root kind, configures TLS, and starts OSCAR automatically. Keeping storage outside the
versioned release lets a clean-release upgrade reuse the same data when `.env` is copied. Do not
run a separate launch script after initialization. PostgreSQL runs with `archive_mode=off` and no
external WAL bind.

For offline media, verify it before initialization:

```powershell
.\verify-bundle.ps1
.\oscar.bat init
```

`init` and `upgrade` re-hash the exact bundle inventory on every mutating run before using any
payload; a prior receipt is audit evidence, not a cache that can authorize changed bytes. They also
load the checksum-verified image archive even if same-version tags already exist locally. This
integrity check proves agreement with the co-packaged `SHA256SUMS`, not publisher or release-origin
authenticity, because that manifest is bundled and unsigned. If origin authentication is required,
verify the outer ZIP against an independently trusted detached signature or provenance attestation
before offline transfer. You can run `oscar.bat verify` explicitly at any time. For the images-only
artifact, use `oscar.bat init -Prerequisites existing` to guarantee setup will not launch prerequisite
installers.

If a prerequisite installer requires a Windows restart, restart and run `oscar.bat init` again.
Docker Desktop license review and acceptance are administrator actions; OSCAR never accepts that
agreement on the organization's behalf.

## Ubuntu Server 24.04

Official offline bundles are Windows-only. Install Docker Engine and the Docker Compose plugin,
extract the connected Ubuntu release, and run:

```sh
sudo bash oscar.sh init
```

On a graphical Ubuntu installation, double-click the executable `oscar.sh` launcher to open the same interactive menu. Ubuntu Server administrators use the command above because the server has no desktop environment.

## Routine administration

Double-click/open `oscar.bat` or `oscar.sh` with no arguments to keep an administration window open. Enter commands such as `status`, `start`, `stop`, `restart`, `logs -Service oscar` (Windows), or `logs --service oscar` (Ubuntu). Enter `exit` to close it. Passing arguments directly continues to work for scripts and experienced administrators:

Windows:

```powershell
.\oscar.bat status
.\oscar.bat start
.\oscar.bat stop
.\oscar.bat restart
.\oscar.bat logs -Service oscar
```

Ubuntu:

```sh
sudo bash oscar.sh status
sudo bash oscar.sh start
sudo bash oscar.sh stop
sudo bash oscar.sh restart
sudo bash oscar.sh logs --service oscar
```

The launcher deliberately stops services in dependency order: gateway, OSCAR, then PostgreSQL.
This lets OSCAR finish its bounded journal and database-backed module shutdown before the database
is stopped. Do not replace the launcher command with a multi-service `docker compose restart`.

Fresh deployments cannot create, verify, or restore a coordinated snapshot until an administrator
selects the manual single-snapshot mode and a safe absolute backup path that does not overlap the
release or archive roots. A separate physical drive is recommended for failure isolation, but it is
not required. Opt in through setup:

```powershell
.\oscar.bat upgrade -BackupMode single -BackupDir D:\oscar-backups
```

```sh
sudo bash oscar.sh upgrade --backup-mode single --backup-dir /srv/oscar-backups
```

Protect `secrets/backup-key.txt` separately from snapshot media; it is required to restore encrypted
deployment credentials. Then create and verify the snapshot before an upgrade or retention change:

Windows:

```powershell
.\oscar.bat backup
.\oscar.bat backup-verify -BackupId <ID-printed-by-backup>
.\oscar.bat archive status
.\oscar.bat archive verify
```

Ubuntu:

```sh
sudo bash oscar.sh backup
sudo bash oscar.sh backup-verify <ID-printed-by-backup>
sudo bash oscar.sh archive status
sudo bash oscar.sh archive verify
```

Retention-hold creation prints and persists a resolution label. `GENERATION_EXACT` and `HOT_EXACT`
are exact catalog/row matches; `COLD_RANGE_CONSERVATIVE` protects candidate archive ranges but does
not prove that a possibly sparse observation ID exists. Confirm the event or hold its exact
generation when evidentiary certainty is required. A listed `LEGACY_UNKNOWN` mode is a protective
migration-only label for a pre-3.9.2 observation hold; it does not prove exact observation
existence. Active observation or generation holds also
block Viewer/API datastore removals: a single remove fails visibly and a bulk remove skips held
rows. See `documentation/STORAGE_OPERATIONS.md` before creating or releasing a hold.

`backup` keeps OSCAR quiesced, proves that every query-visible generation has exactly one active
Parquet, manifest, and schema object, verifies each against its catalog checksum,
requires the Parquet object path/checksum and manifest path to match the generation's authoritative
pointers, and rejects a catalog snapshot changed by concurrent activation or purge,
reconciles the archive filesystem, then verifies and HMAC-authenticates the new backup, rejects
unsafe tar members, atomically marks the recovery point `VERIFIED`, and then records protection for
only the exact published daily-file segments present in that accepted snapshot. It creates schema
v2 with required WAL streamed into `postgres/pg_wal` and no cumulative `wal-archive.tar.gz`.
After full acceptance it atomically replaces the HMAC-authenticated `CURRENT` pointer; only then can
the previous non-current fully accepted schema-v2 snapshot be removed. A confirmation failure
leaves the previous `CURRENT` authoritative. The explicit
`backup-verify` command can run with PostgreSQL stopped: it uses a one-shot utility container and
treats the live catalog receipt as optional. Restore additionally requires matching 3.9.2 backup,
current-release, and backed-up release-config identities plus every exact local Compose image.
Plan backup capacity for the old snapshot plus one complete replacement: one snapshot is the
steady-state logical result, not the peak space required while `CURRENT` is changing. If a crash
leaves a non-current published snapshot or private staging debris, the next locked storage command
requires a fully authenticated and accepted schema-v2 `CURRENT`, then removes only non-current
candidates that independently pass the same checks. Schema-v1, failed, partial, unauthenticated,
unaccepted, and incomplete deletion candidates are preserved with warnings. If no `CURRENT` has
ever committed, one uniquely accepted schema-v2 candidate is adopted by reconstructing
authenticated `CURRENT`; multiple accepted candidates are preserved for operator review.
Use `backup-verify` before an audit, copy, or restore. Schema-v1 backups remain explicitly
verifiable/restorable and require their historical WAL tar for authentication, but restore ignores
that external payload because streamed `postgres/pg_wal` is sufficient; v1 is never silently treated as v2.
`backup-prune` is retired, hidden from the menu, and performs no deletion. Keep independently
verified off-host copies under site policy. OSCAR does not provide point-in-time recovery.

Storage commands are mutually exclusive per deployment. A concurrent backup, verify, restore,
archive mutation, archive verification, or export fails immediately with a clear lock message;
wait for the active command rather than bypassing its crash-released, deployment-ID-keyed lock in
the host's administrator-owned runtime/program-data directory. Live commands also reject missing,
foreign, swapped, or unsafe archive identities, optional enabled-backup identities, and mismatched
Docker volumes. The sole
exception is offline-capable `backup-verify`, which does not depend on a running deployment or its
live roots. It is a core-verification operation, not a read-only command: it atomically publishes or
replaces the selected backup's `VERIFIED` marker and normalizes permissions. It does not create
`JOURNAL_CONFIRMED` or change `CURRENT`, so it cannot accept a core-only schema-v2 candidate or make
one restorable. An optional live catalog update occurs only after deployment-volume ownership is
proven.

OSCAR 3.9.2's full storage profile is initialized with a new database and standard configuration.
An upgrade preserves the old `config.json` and PostgreSQL volume, so it does not silently convert a
pre-3.9.2 system to the tiered archive or enable PostgreSQL data checksums. Use a fresh deployment
for the 3.9.2 test systems. Preserve and separately migrate any production history that policy
requires.

If a deliberately retained pre-label deployment uses unlabelled Docker volumes, follow the
one-time `-AdoptLegacyVolumes` (Windows) or `--adopt-legacy-volumes` (Ubuntu) procedure in the
Administrator Guide. Preserve its `.oscar-volume-adoption` receipt with `.env`, `secrets`, and
`tls` during later clean-directory upgrades; never use adoption to join unrelated volumes. Run
upgrades through `oscar.bat` or `oscar.sh`, not a direct `docker compose up`: setup validates the
exact external named volumes before Compose attaches them and force-recreates every service so no
container retains a secret/config bind or Compose provenance from the prior extracted release.
The supported `upgrade` command also stops the application tier and runs the restartable offline
daily-file lifecycle-index migration from the new image. It reads the retained `config.json`, skips
when no Daily File Journal module is configured, and creates no new work markers when the journal is
already indexed. An empty configured journal may receive its metadata. A failure leaves OSCAR
stopped; restart-safe markers created before the failure are retained so the same upgrade can resume.
The shared storage lock prevents a backup or restore from racing the stop, migration, or restart.
Correct the reported storage/permission problem and rerun rather than bypassing the migration.
The OSCAR container remains `starting` until its HTTP service and all top-level auto-start modules
are started and every nested lane RPM/camera has completed its startup attempt. Offline devices do
not prevent access to the Status of Health page; supported setup and storage commands wait only for
the attempt-complete application-readiness signal before returning.

Delete the prior extracted release only after health and container-mount verification, and never
delete a persistent archive, legacy WAL, or backup root preserved by `.env`.
If verified pre-3.9.2 archive or enabled-backup roots are nonempty and have no root marker, the
upgrade also requires the separate one-time `-AdoptLegacyStorageRoots` (Windows) or
`--adopt-legacy-storage-roots` (Ubuntu) switch. It records audited adoption metadata in each archive
or enabled-backup root; it must never be used to claim foreign data or silence a mismatched existing
marker. A retained legacy WAL path is not an active storage root and is neither claimed nor adopted.

The default deployment uses HTTPS port `443`. Setup maps `oscar.local` on the OSCAR host and prints
all LAN/Tailscale URLs covered by a newly generated certificate. Other connecting workstations must
either use one of the printed IP URLs or resolve a printed hostname through DNS/their own hosts
entry. Every workstation must trust the public `tls/server.crt` certificate before login; never
copy `tls/server.key` to a client. See [DEPLOYMENT.md](DEPLOYMENT.md) for certificate trust, DNS,
Tailscale, scoped host-firewall access, log filtering, security verification, and upgrades.
Entering the hostname without `https://` is supported on the default port; the gateway redirects port 80 to HTTPS.

The release's `documentation` directory contains the current deployment guide, operational-view and
Status of Health guides, storage architecture/data-lifecycle/archive/backup/operations guides, and
all four localized operator manuals. Read `documentation/STORAGE_OPERATIONS.md` before relying on
hot deletion or removing old cold generations. Official GitHub release artifacts also include the
generated, version-labeled PDF manuals.
