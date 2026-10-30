# OSCAR 3.11.0 backup, restore, and recovery

OSCAR 3.11.0 can create one coordinated recovery snapshot of the PostgreSQL cluster, application
state, primary Parquet cold tier, release configuration, and encrypted deployment credentials.
Fresh installations default to `OSCAR_BACKUP_MODE=disabled`; backup creation, verification, restore,
and the retired prune command remain unavailable until an administrator explicitly changes the
deployment to `single` mode through `init` or `upgrade`. A checksum and `pg_verifybackup` pass is
required before a snapshot is accepted. With OSCAR quiesced, creation also requires every active
cold-tier object to exist, match its catalog checksum, and pass filesystem reconciliation.

This runbook uses only commands implemented by the release launchers. Read it completely and carry
out a restore drill on an isolated test host before relying on a deployment for production recovery.
Run it only on supported Ubuntu Server 24.04 x86-64 or Windows 11 x86-64 Docker Desktop/WSL 2
hosts; macOS deployment and storage operations fail closed.

## What a coordinated backup contains

The current snapshot is stored under `${OSCAR_BACKUP_DIR}/<backup-id>`, where the ID has the form
`YYYYMMDDTHHMMSSZ-<eight hex characters>`. Schema v2 is the format created by this release.

| Object | Contents |
| --- | --- |
| `postgres/` | Plain-format `pg_basebackup` of the complete PostgreSQL cluster, with required WAL streamed into the backup |
| `oscar-state.tar.gz` | Mutable `/var/lib/oscar` application state, including saved SensorHub configuration, journal, daily files, videos/JPEGs, reports, and adjudication artifacts; excludes the separately captured archive path, reproducible transient DuckDB scratch at `/var/lib/oscar/duckdb-tmp`, any legacy embedded backup mountpoint, and the verified image-owned links (`lib`, `web`, `rules`, `documentation`, `trusted_certificates`, `config`, and `logback.xml`) that the restored image recreates |
| `archive.tar.gz` | Complete configured `/var/lib/oscar/archive` data tree, excluding the host-local `.oscar-storage-root` identity |
| `deployment-secrets.tar.gz.enc` | `.env`, `secrets/`, and `tls/`, encrypted with AES-256-CBC and PBKDF2 using the external backup key |
| `release-config.tar.gz` | Non-secret Compose, image-build, sample environment, and release documentation files |
| `epoch.json` | Backup UUID, backup ID, UTC creation time, OSCAR version, PostgreSQL LSN, archive root, and creation state |
| `archive-generation-ids.txt` | Canonically sorted, duplicate-free UUIDs for the exact active/sealed archive generations captured by this backup; validation is streaming and bounded at 1,000,000 entries/37,000,000 bytes |
| `image-inventory.txt` | Exact Compose image names, immutable local image IDs, repository-digest provenance, and required OSCAR/PostGIS release labels used to create the recovery point |
| `SHA256SUMS` | SHA-256 of every authenticated core payload file present before verification (excludes itself, its authentication tag, the later `VERIFIED` marker, and the post-verification `JOURNAL_CONFIRMED` sidecar) |
| `SHA256SUMS.hmac` | HMAC-SHA-256 authentication of `SHA256SUMS`, using the external backup key; this authenticates the complete checksum inventory and every payload it names |
| `VERIFIED` | Atomically replaced UTC core-verification marker written only after quiesced live archive/catalog reconciliation, authenticated checksums, `pg_verifybackup`, strict archive-member validation, and epoch validation establish a valid authenticated core candidate |
| `JOURNAL_CONFIRMED` | Required schema-v2 acceptance sidecar written only after the exact `VERIFIED` core has authorized the stopped live daily-file journal; it binds the backup ID and state-archive hash with its own HMAC. It is intentionally outside `SHA256SUMS`: an absent or corrupt receipt only warns during read-only core verification, but the candidate cannot become `CURRENT` or be restored as an accepted schema-v2 recovery point without a valid receipt |

Schema v2 deliberately has no `wal-archive.tar.gz`. `pg_basebackup --wal-method=stream` places every
WAL file needed to reach the online-backup endpoint in `postgres/pg_wal`, and `pg_verifybackup`
checks that self-contained database payload. A schema-v2 checksum manifest containing
`wal-archive.tar.gz` is rejected. For compatibility, an authenticated schema-v1 recovery point must
contain its historical `wal-archive.tar.gz`; verification authenticates that exact format rather
than silently reinterpreting it as v2. Restore does not merge or read the external payload because
the base backup's streamed `postgres/pg_wal` is sufficient.

The backup root also contains `CURRENT`, the authenticated commit pointer for the one-snapshot
model. It has exactly these four LF-terminated lines:

```text
format=oscar-current-backup
version=1
backup_id=<backup-id>
hmac_sha256=<base64 HMAC-SHA-256>
```

The HMAC covers the first three lines, including each terminating LF, using
`${OSCAR_BACKUP_KEY_FILE}`. A snapshot directory is not current merely because it is newest or has a
`VERIFIED` marker; `CURRENT` is authoritative.

When PostgreSQL is available, its live catalog first receives a best-effort `CREATED`
`oscar_backup_epoch` receipt after the backup directory is finalized. Core verification then requires an
exact collision-safe `VERIFIED` receipt before the filesystem `VERIFIED` marker is allowed to
remain. The receipt binds the manifest path, epoch checksum, LSN, and the count, exact byte length,
and SHA-256 of the ordered generation set authenticated in `archive-generation-ids.txt`; later
catalog growth therefore cannot change an existing backup's identity. The exact UUIDs remain in the
HMAC-authenticated backup file and are not duplicated in a PostgreSQL `uuid[]` for every backup.
This keeps validation memory bounded and prevents backup receipts from adding multi-megabyte TOAST
rows to every later database backup. Offline verification omits the live catalog receipt, while a
running PostgreSQL service must first pass the deployment-volume ownership fence before either the
core-verification marker or catalog can be changed. Disaster recovery remains possible when the original
database is unavailable.

### Items to protect separately

The backup is intentionally not self-decrypting. Protect these outside its failure domain:

- `${OSCAR_BACKUP_KEY_FILE}` (default `secrets/backup-key.txt`), needed to decrypt deployment
  credentials;
- the exact OSCAR release artifact, any independently retained publisher signature or provenance
  attestation required by site policy, and all three container images recorded by
  `image-inventory.txt`; an offline bundle's co-packaged unsigned `SHA256SUMS` verifies integrity
  relative to that manifest but does not authenticate release origin, and restore deliberately
  rejects a tag that was rebuilt or retagged to a different content-addressed image ID even when its
  visible name and version label match;
- host DNS/hosts-file configuration and workstation trust installation;
- Docker/Desktop/Engine configuration and any host-level firewall policy; and
- portable exports or other data stored outside the configured OSCAR state/archive paths.

Losing the backup key makes the encrypted `.env`, application/database passwords, and TLS private
key unrecoverable. Storing the key beside the only backup defeats the separation. Use a managed
secret system, offline escrow, or two independently controlled encrypted copies.

## Recovery objectives and consistency

The backup command briefly stops the HTTPS gateway and OSCAR application while leaving PostgreSQL
online for a streamed, self-contained `pg_basebackup`. It then snapshots application state and the
Parquet cold tier, authenticates every payload, and verifies the staged recovery point read-only.
After the staged directory is durably published and receives its `VERIFIED` core marker, the
launcher authorizes backup protection only for immutable daily-file lane/days whose CSV, manifest,
and exact sealed-segment inventory are present in that authenticated core. It then writes and
validates `JOURNAL_CONFIRMED`; only that receipt completes schema-v2 acceptance. The launcher next
atomically replaces authenticated `CURRENT`; that pointer replacement is the commit point. Only
afterward may it remove a previous non-current fully accepted schema-v2 snapshot. Services that were
running are restarted after the acceptance gates. A failure before the pointer switch leaves the prior current
snapshot authoritative; a failure afterward leaves the new snapshot authoritative and defers stale
cleanup to a later locked command.

Every storage-administration invocation, including offline-capable `backup-verify`, takes one
nonblocking deployment-wide lock. A second backup, verification, restore, archive
purge/verification, hold change, or export fails clearly instead of racing the first operation.
`backup-verify` is exempt only from dependencies on live storage roots, volumes, and the live
catalog, so it can authenticate and verify a selected core while the deployment is offline; it is
not exempt from the deployment lock. Verification is a mutation: the command atomically publishes
or replaces `VERIFIED` and normalizes the verified backup's permissions. If
an owned live database is available, it also records the exact `VERIFIED` catalog row; ownership is
checked before that optional catalog write.
Ubuntu uses a crash-released kernel `flock`; Windows holds a `FileStream` with
`FileShare.None` for the process lifetime. The lock is keyed by `OSCAR_DEPLOYMENT_ID` in an administrator-owned location outside a versioned release:
`/run/lock/oscar-storage` on Ubuntu and `%ProgramData%\OSCAR\StorageLocks` on Windows. Never relocate it into an extracted release tree or
bypass a busy lock.

The outage duration depends mostly on application-state and archive size. Measure it at production
scale. The automated restore returns PostgreSQL to the consistent endpoint included by
`pg_basebackup` and restores the matching captured files/configuration.

Compose enables PostgreSQL data checksums for **new** clusters and WAL compression, but explicitly
runs PostgreSQL with `archive_mode=off`. It sets no external archive command or timeout and mounts no
host WAL directory. OSCAR 3.11.0 supports restore only to the consistency endpoint carried by the
selected base backup; it does not provide point-in-time recovery to an arbitrary timestamp or LSN.
The restore promotes the recovered cluster onto a fresh timeline without consulting an external WAL
archive.

Verification requires exactly one authenticated checksum entry for every top-level recovery
payload, including `epoch.json`, `archive-generation-ids.txt`, and `image-inventory.txt`. The
generation inventory must use one canonical lowercase UUID per LF-terminated line, be strictly
sorted without duplicates, have exactly 37 bytes per UUID record, and remain within its documented
entry/byte bounds. Both launchers stream this file while calculating its receipt; they do not read
the complete list into memory or construct an SQL UUID-array literal. A backup with no active or
sealed generations uses a valid empty file (count and bytes zero, with the standard SHA-256 of empty
content). The epoch must identify exactly OSCAR
3.11.0, not merely any semantic version. Before destructive restore, OSCAR also compares the current
application, PostgreSQL, and gateway image names, immutable IDs, and required release labels with
the authenticated inventory. Exact names, content-addressed IDs, and required labels are hard
gates. Repository digests are recorded as registry provenance, but a difference is only warned
because `docker save`/`docker load` may discard that transport metadata while preserving the exact
image ID and contents. Keep the original offline bundle or exported image archive with the backup
so those exact images can be reloaded after a host loss.

## Before the first backup

Fresh initialization leaves backup mode disabled. To opt in, select an operator-controlled safe
absolute path at least two path components below its drive or filesystem root that does not overlap
the release or archive roots, and run the supported setup workflow; do not hand-edit the mode around
setup validation. A separate physical drive is recommended for failure isolation, but it is not
required:

```sh
sudo bash oscar.sh upgrade --backup-mode single --backup-dir /srv/oscar-backups
```

```powershell
.\oscar.bat upgrade -BackupMode single -BackupDir D:\oscar-storage\backups
```

The workflow creates the external key and administrator-owned backup root. The backup root is never
mounted into a long-running service. PostgreSQL has no external WAL bind. A legacy
`OSCAR_WAL_ARCHIVE_DIR` value/root may be retained unchanged only to avoid deleting a previous
deployment's data; schema-v1 authentication uses the payload inside its snapshot and does not read
that host root. Disabled or v2 operation must not delete legacy data.
Confirm the selected mode, services, and durable paths:

```sh
sudo bash oscar.sh status
grep -E '^(OSCAR_BACKUP_MODE|OSCAR_ARCHIVE_DIR|OSCAR_WAL_ARCHIVE_DIR|OSCAR_BACKUP_DIR|OSCAR_BACKUP_KEY_FILE)=' .env
```

Windows:

```powershell
.\oscar.bat status
Get-Content .env | Select-String '^OSCAR_(BACKUP_MODE|ARCHIVE|WAL_ARCHIVE|BACKUP|BACKUP_KEY_FILE)'
```

The Ubuntu storage commands require root; Windows storage commands require Administrator Windows
PowerShell 5.1 (`powershell.exe`) or the elevated OSCAR menu. Ensure the backup filesystem has room for the PostgreSQL
base backup, application state, and Parquet cold tier at the same time. A backup on the
same physical disk protects against logical/operator failure, not loss of that disk.

Each active managed archive and backup root contains an administrator-owned, no-follow
`.oscar-storage-root` identity. Its exact version-1 fields bind the root kind and
`OSCAR_DEPLOYMENT_ID` and record whether setup created the root or explicitly adopted existing
data. On Ubuntu the archive root is root-owned, uses its assigned service group, and mode `1770`;
the sticky bit protects the root-owned marker. An existing legacy-WAL tree is preserved byte-for-byte
but is not created, claimed, mounted, or written by the current profile.
The backup root is root-owned mode `0700`. Windows rejects reparse points and protects the marker
with non-inherited administrator/SYSTEM/Administrators ACLs. Every live database/archive command
and backup operation validates the applicable identities and both deployment-owned Docker volumes first.
Only `backup-verify` is exempt from those live-root and live-volume dependencies because it is an
offline-capable core-verification operation against the selected backup directory. It still changes
the selected backup's `VERIFIED` marker and permissions; it changes the live catalog only after the
deployment-volume ownership gate succeeds.

Neither long-running service mounts the backup root. During creation, a network-scoped one-shot
PostgreSQL client receives only the newly created `postgres/` staging directory, and every other
utility receives only the exact input or output it needs. This matters on Docker Desktop, where a
container mount must not rely on a Linux numeric UID to protect unrelated recovery points.

## Create a backup

Ubuntu:

```sh
sudo bash oscar.sh backup
```

Windows:

```powershell
.\oscar.bat backup
```

The command requires `OSCAR_BACKUP_MODE=single` and prints the final path and backup ID. A working
directory ending in `.partial` is not a complete backup. A finalized directory without `VERIFIED`,
or one not named by a valid `CURRENT`, is not the committed current snapshot. Do not rename a partial
or edit `CURRENT` by hand; preserve the error and run the locked command again after correcting the
cause.

Before publication, the launcher flushes every staged payload and directory, then invokes the
image's compiled `renameat2(RENAME_NOREPLACE)` publisher against two names in the same parent.
Publication therefore cannot replace a pre-existing backup ID, even across a race. The image also
contains a root-owned SHA-256 stamp of the packaged C source; release regression compares that
provenance and behavior-tests successful publication plus collision preservation.

Expected stages are:

1. validate `single` mode, storage identities, and any existing authenticated `CURRENT` before
   mutating services or backup data;
2. gateway/OSCAR quiesce if they were running;
3. active archive-object checksum verification and catalog/filesystem reconciliation while writers
   remain quiesced (the already-authenticated root-level `.oscar-storage-root` is host metadata and
   is excluded from the archive-object inventory);
4. streamed `pg_basebackup --wal-method=stream` plus application-state and cold-tier snapshots;
5. encrypted configuration/secrets and release metadata;
6. schema-v2 epoch/checksum generation, HMAC authentication, private-permission enforcement, and
   read-only verification inside `<backup-id>.partial`;
7. atomic no-replace publication as `<backup-id>` and best-effort backup-epoch catalog insertion;
8. atomic `VERIFIED` core verification, then offline confirmation of only the published journal
   lane/days and exact sealed segments captured by that core, followed by the authenticated
   `JOURNAL_CONFIRMED` receipt that completes schema-v2 acceptance; and
9. atomic authenticated `CURRENT` replacement, removal of only stale non-current schema-v2
   snapshots that independently pass full core and acceptance verification, then service resume and
   health wait.

There is one logical current snapshot. A second successful backup does not create a retention chain:
it commits the new snapshot through `CURRENT` and then cleans the prior fully authenticated and
accepted schema-v2 snapshot. Schema-v1, failed, `.partial`, unverified, unaccepted, unknown, or
unauthenticated directories are preserved with warnings rather than selected or deleted merely
because of age or name. Keep independent off-host copies under site policy; they are not managed by
the local `CURRENT` pointer.

"One current snapshot" describes steady state, not peak disk use. During replacement the backup
root must have room for both the old snapshot and the complete new candidate until `CURRENT`
commits. A crash can also leave a published non-current snapshot or private staging debris. If
`CURRENT` exists, the next locked storage command requires both its authenticated pointer and its
fully authenticated schema-v2 acceptance receipts before reconciling anything. Every non-current
final directory or deletion tombstone must independently pass the same core and acceptance checks
before removal; a name alone never authorizes recursive deletion. Schema-v1, failed, partial,
unauthenticated, and unaccepted candidates are preserved with warnings. If no `CURRENT` exists and
exactly one fully accepted schema-v2 candidate exists, the launcher reconstructs authenticated
`CURRENT` for it instead of erasing the only recovery point. Multiple accepted candidates are all
preserved and the command stops for operator review. Interrupted legacy schema-v1 deletion
tombstones are restored; old `.deleting-uncommitted-v2-*` and incomplete deletion tombstones are
preserved because their remaining contents cannot prove deletion authorization. A malformed,
non-regular, reparse-point, dangling, or acceptance-invalid `CURRENT` entry fails closed before any
candidate is changed.

The cleanup trap attempts to resume services if a stage fails. Always run `status` after a failed
backup and inspect both OSCAR and PostgreSQL logs. If structural verification succeeds but the
journal-confirmation bridge fails, the published candidate can retain a structurally valid,
authenticated `VERIFIED` core, but it is not an accepted or restorable schema-v2 recovery point.
The command still fails, services are resumed, the previous authenticated `CURRENT` remains
authoritative, and no unconfirmed lane/day becomes segment-deletion eligible. Correct the journal
inconsistency or let a later successful backup establish the missing protection rather than
fabricating a receipt.

The confirmation bridge does not relax the backup root's administrator-only protection. It first
revalidates the exact authenticated `oscar-state.tar.gz` member inventory in a networkless,
read-only, capability-free container. A separate one-shot extractor can read only that root-owned
archive and a new private snapshot directory; it cannot see the backup root. On Ubuntu, the
capability-free extractor is followed by an administrator-side ownership handoff. On Windows, the
extractor receives only the `CHOWN` capability needed for the same handoff. The Java confirmation
then runs as OSCAR UID/GID `10001:10001` with the snapshot mounted read-only. The snapshot is always
removed and previously running application services are resumed on success or failure. On Windows
Docker Desktop (WSL 2), extracting and cleaning up a multi-hundred-thousand-file `oscar-state.tar.gz`
snapshot across the Windows NTFS bind mount (`9P` bridge) is small-file metadata bound rather than
throughput bound—expect ~2–3 hours total backup wall time for ~300,000 retained-media/journal entries
(~18–20 GiB total snapshot size), whereas `restore` extracts `oscar-state.tar.gz` directly into the
Linux `oscar_oscar_state` named volume inside WSL 2 and completes much faster.

## Verify or re-verify a backup

`backup` performs this verification automatically. Use `backup-verify` to re-check a backup before
copy, restore, audit, or after moving it back into the configured backup directory. Supply the ID
printed by `backup`.

Ubuntu:

```sh
sudo bash oscar.sh backup-verify 20261017T153000Z-1a2b3c4d
```

Windows:

```powershell
.\oscar.bat backup-verify -BackupId 20261017T153000Z-1a2b3c4d
```

Verification:

- requires and authenticates `SHA256SUMS.hmac` before trusting checksum file names or digests;
  checksum-only legacy directories are rejected and never receive a `VERIFIED` marker or count
  toward retention;
- checks every `SHA256SUMS` entry;
- starts a one-shot, networkless, read-only PostgreSQL utility container and runs
  `pg_verifybackup` with every capability dropped except `DAC_READ_SEARCH`; that narrowly scoped
  read/traverse bridge supports both administrator-normalized Linux payloads and UID-999 Docker
  Desktop payloads without granting write access or weakening mode-0600/0700 host permissions,
  and no live database container is required;
- decrypts the secret/configuration archive into a disposable utility-container path;
- validates every tar payload without extracting it into the deployment: member names cannot be
  absolute, contain `..`, use backslash traversal, contain control characters, alias another path,
  repeat a name, or create file/directory prefix collisions, and only regular files/directories are
  allowed (links, devices, FIFOs, sockets, and unknown types are rejected);
- confines tar-listing scratch data to a private, root-only `/tmp` tmpfs capped at 256 MiB in the
  otherwise read-only, networkless, capability-free validator container. Scratch exhaustion fails
  verification before extraction or a `VERIFIED` marker and leaves no host-side temporary files;
- requires the exact top-level payload inventory and exactly one copy of every mandatory
  release-config file; schema v2 must omit `wal-archive.tar.gz`, while schema v1 must authenticate
  and include it;
- streams and validates the bounded canonical archive-generation UUID inventory and uses its
  authenticated count, byte length, and SHA-256 for collision-safe `CREATED`/`VERIFIED` catalog
  receipts; the exact list stays in the recovery point instead of being copied into PostgreSQL;
- validates the epoch UUID, exact schema version (`2` for newly created snapshots), immutable
  `CREATED` state, and exact backup-directory ID; and
- when PostgreSQL is offline, durably writes and fsyncs a UTC `VERIFIED` marker without a database;
  when it is running, first proves fixed-volume deployment ownership and then requires the exact
  idempotent live `VERIFIED` receipt or removes the marker.

Manual `backup-verify` and the verification performed before `restore` deliberately do **not** add
new live daily-journal backup confirmations or change `CURRENT`. Therefore manual verification
cannot turn a core-only schema-v2 candidate into an accepted recovery point; a valid authenticated
`JOURNAL_CONFIRMED` receipt must already exist, and restore additionally requires the matching
authenticated `CURRENT` pointer. This prevents inspection or restoration of an older copied recovery
point from mutating current journal eligibility or the committed local snapshot. `backup-prune` is
retired and performs no deletion.
Re-verification proves the authenticated snapshot has not changed; the quiesced archive/catalog
reconciliation is a mandatory invariant of creating that authenticated 3.11.0 snapshot, not a
comparison against the current live deployment.

For a newly created 3.11.0 backup, successful verification proves authenticated structural integrity
at that time and confirms the locally configured OSCAR/PostgreSQL utility images can read it; it
does not by itself complete schema-v2 acceptance. A
directory without `SHA256SUMS.hmac` is rejected rather than promoted into the verified retention
set. Verification does not prove that an operator can recover the separately escrowed key after an incident, that
every Compose service image remains available, or that application workflows pass after restore.
Only a restore drill proves those dependencies.

Validator scratch usage is determined by the number and path lengths of archive members, not by
their compressed payload bytes. The 256 MiB tmpfs is a deliberate fail-closed resource ceiling;
it is not an unlimited file-count guarantee. The one-million generation-ID ceiling is also a
hostile-input bound, not a supported-capacity claim. Inventory capture is SQL-limited to one entry
beyond that ceiling, and both validators reject an oversized file before scanning it; accepted
records are then parsed and hashed with bounded buffers. Trend file counts in OSCAR state, cold
archive, and backup payloads, and qualify `backup-verify` plus an isolated restore with a
representative high-watermark dataset before deploying a materially larger retention policy. A
scratch-exhaustion failure leaves the backup unverified and must be resolved by reducing file
cardinality through approved retention/tiering or by a reviewed release change—not by disabling
archive validation or making the validator scratch mount unbounded.

After verification, copy the complete backup directory to at least one encrypted medium or system
outside the OSCAR host and verify the checksums again at the destination. Restrict the copy because
it contains operational records and encrypted—not anonymized—credentials.

On Windows 11, format any external USB SSD or removable recovery carrier as `NTFS` (ideally
protected with BitLocker) rather than `FAT32` or `exFAT`, and run `.\oscar.bat prepare-host`
(`configure-windows-host.ps1 -Mode apply`) first so USB selective suspend and USB 3 Link Power
Management cannot drop the enclosure during multi-gigabyte snapshot copies. `FAT32` rejects archives
larger than 4 GiB, and `exFAT` cannot store the Windows DACLs (`SYSTEM`, `Administrators`, and
`docker-users`) required on active `-BackupDir` roots. Because `.oscar-storage-root` binds an active
`-BackupDir` to one `OSCAR_DEPLOYMENT_ID` and local machine SIDs, use the external USB drive as an
off-host carrier (`<backup-id>\` plus `CURRENT`, with `secrets\backup-key.txt` escrowed separately)
and copy the snapshot into the replacement host's initialized local NTFS `-BackupDir` before running
`.\oscar.bat backup-verify` and `.\oscar.bat restore`. On Windows PowerShell 5.1, `oscar-storage.ps1`
walks and removes temporary daily-file confirmation and restore staging trees through Win32
extended-length (`\\?\`) paths while rejecting nested reparse points, so base64-encoded retained-media
camera directories longer than 260 characters clean up reliably even on hosts where Win32
`LongPathsEnabled` has not yet been enabled.

## Restore a coordinated backup

Restore is destructive to the current PostgreSQL cluster, OSCAR state, cold archive, and active
deployment credentials. The configured backup root remains the read-only recovery source and is not
replaced. A v2 restore uses only WAL streamed into `postgres/pg_wal`; it neither reads nor writes an
external WAL archive. An authenticated v1 snapshot follows the explicit legacy compatibility path
and must contain the historical WAL payload required for v1 authentication, but restore ignores
that payload because streamed `postgres/pg_wal` is sufficient. Before
stopping or replacing anything,
the command requires the same valid backup ID twice, authenticates/verifies the backup, validates the
release-configuration archive, and proves that the current `.env`, backup epoch, and backed-up
`.env.example` all identify exactly OSCAR 3.11.0. It also requires every exact image resolved by the
current Compose configuration to exist locally; restore never substitutes or pulls a different tag.

A restore attempt does not change the recovery point's lifecycle state. An accepted recovery point
remains `VERIFIED` after either a successful or failed restore attempt; command output and site
recovery records document the attempt rather than inventing a second backup-state transition.

Before restoring:

1. Confirm the exact target host and backup ID.
2. Preserve any incident evidence or newer data needed for investigation.
3. Make the required `oscar:<version>` and PostGIS images available without changing their content.
4. Confirm the external backup key is present and readable only by the administrator.
5. Stop external RPM/camera/emulator producers or otherwise prevent duplicate replay during the
   recovery window.

Ubuntu:

```sh
sudo bash oscar.sh restore \
  --backup 20261017T153000Z-1a2b3c4d \
  --confirm 20261017T153000Z-1a2b3c4d
```

Windows:

```powershell
.\oscar.bat restore `
  -BackupId 20261017T153000Z-1a2b3c4d `
  -Confirm 20261017T153000Z-1a2b3c4d
```

The restore workflow:

1. verifies the backup again;
2. validates exact 3.11.0 release identity and local image availability again after verification;
3. decrypts the backed-up `.env`, `secrets/`, and `tls/` into a private staging directory, merges
   the target-local environment bindings, and validates the entire staged replacement set;
4. for schema v1 only, authenticates its required legacy WAL payload but does not stage, merge, or
   use it as a recovery or PITR source;
5. copies the current `.env`, `secrets/`, and `tls/` into
   `pre-restore-<backup-id>` under the release directory;
6. stops the gateway, waits for OSCAR's bounded writer/module drain to finish while PostgreSQL is
   still available, and only then stops PostgreSQL;
7. replaces the named PostgreSQL volume contents with the base backup;
8. replaces OSCAR application state and the configured archive tree while skipping each archive's
   `./` root member, preserving the existing Docker volume and bind-mount root metadata (archive
   member metadata is still applied below each root);
9. preserves and revalidates the target host's active archive and backup-root identities
   rather than extracting or trusting a marker from the source backup;
10. installs the already validated credential set from same-filesystem staging;
11. prepares PostgreSQL for recovery only through the base backup's consistency endpoint, promotes
    to a new timeline, reconstructs the exact authenticated `VERIFIED` epoch receipt, and proves a
    post-promotion write across checkpoint and clean restart while `archive_mode` remains off;
12. removes the persisted one-time recovery settings, restarts PostgreSQL while OSCAR remains
    stopped, and requires the recovery GUCs to return to defaults with no pending restart; and
13. starts OSCAR/gateway and waits for complete Compose health: top-level auto-start modules must be
    started and nested lane devices must have completed their startup attempts, rather than merely
    accepting HTTP availability. A device may settle offline without hiding its status UI.

Decryption, environment merge, credential-tree validation, and schema-v1 payload authentication
finish before the safety copy is created, services are stopped, or replaceable data is changed. A malformed encrypted set,
unsupported file type, link, or unsafe target environment therefore aborts without entering the
destructive phase.

### Same-host and cross-host environment policy

A restore recovers source data and credentials, but it does not turn the target host into the source
host. Before installing the decrypted files, the command takes the following bindings from the
target's current `.env` and writes them into the restored `.env`:

- `OSCAR_DEPLOYMENT_ID` and `OSCAR_BACKUP_MODE`;
- `OSCAR_POSTGIS_PLATFORM`, `OSCAR_HTTPS_PORT`, and `OSCAR_HOSTNAME`;
- the canonical credential bindings described below; and
- `OSCAR_ARCHIVE_DIR` and `OSCAR_BACKUP_DIR`.

The two active storage roots must already be absolute target paths. Every listed binding must occur
exactly once and be non-empty, and the target deployment ID must be valid. Restore fails before
changing the live credential set if those conditions are not met. Other backed-up settings, such as
JVM tuning, travel with the source environment. The release version is already required to match
exactly. Preserving the target backup mode prevents recovery media from silently changing the
site’s opt-in policy.

If the target already has one absolute `OSCAR_WAL_ARCHIVE_DIR` compatibility binding, restore
preserves it. Otherwise restore removes a source host's legacy-WAL binding instead of importing that
foreign path. Current restore never reads, mounts, or writes the directory.

This release intentionally supports only these credential locations:

```dotenv
OSCAR_SECRETS_DIR=./secrets
OSCAR_TLS_DIR=./tls
OSCAR_BACKUP_KEY_FILE=./secrets/backup-key.txt
```

Setup/upgrade, backup, and restore fail closed if the target `.env` uses any other values. The
encrypted backup, pre-restore safety copy, and installer all operate on these release-relative
directories; custom credential paths are not claimed to work. A backed-up source `.env` may contain
different values from an older deployment, but restore replaces them with the target's validated
canonical bindings before accepting the staged set.

This merge keeps named-volume ownership evidence (deployment labels or an exact legacy-adoption
receipt) aligned with `OSCAR_DEPLOYMENT_ID`, keeps Compose bound to the target archive, preserves an
optional target legacy-WAL location, and retains the target's external backup root. PostgreSQL
does not mount the legacy WAL directory.
Restore checks volume ownership again
after installing the merged environment and before starting services. On a same-host restore, the
source and target local bindings are normally identical, so behavior is unchanged. On a cross-host
restore, review container image provenance, endpoint identity, and TLS acceptance carefully:

- `image-inventory.txt` enforces exact OCI image `sha256` ID parity (`application_id`,
  `postgres_id`, and `gateway_id`) during `restore`. Load the exact `offline-images.tar` (or
  digest-pinned images) that produced the backup—or upgrade the source deployment to the target
  host's exact 3.11.0 release bundle before taking the migration backup—so image IDs match bit-for-bit.
- Source TLS material (`tls/server.crt` and `tls/server.key`) and application credentials are
  restored, while the target `OSCAR_HOSTNAME`, `OSCAR_HTTPS_PORT`, and `OSCAR_TLS_SANS` bindings in
  `.env` remain authoritative. If the replacement host uses a new IP address or DNS name that is not
  present in the restored self-signed certificate's Subject Alternative Names, regenerate or install
  a certificate covering the replacement host's SANs after verifying data recovery and recreate the
  `gateway` container (`docker compose --project-name oscar --env-file .env --file compose.yaml up --detach --no-deps --no-build --pull never --force-recreate gateway`) so its bind-mounted TLS secret files refresh.

The `pre-restore-*` directory is a safety copy of credentials, not a data rollback. It contains
sensitive plaintext files; protect it and remove it under the site's credential-retention policy
after the recovery is accepted. A retry refuses to overwrite an existing safety directory for the
same backup ID; preserve or move that directory deliberately before retrying.

On Ubuntu, backup directories are finalized as root-owned `0700` directories with `0600` payloads
under a `umask 077`. On Windows, inheritance is removed; the invoking administrator, SYSTEM, and
the local Administrators group retain control, while the local `docker-users` group receives
inherited read/execute access so confined one-shot Docker helpers can read backup payloads. Treat
`docker-users` as Docker-engine-equivalent privileged membership, not as an ordinary backup reader.
Preserve equivalent controls on copied backup media. When importing an off-host snapshot
(`<backup-id>\` plus `CURRENT`) and the separately escrowed `secrets\backup-key.txt` onto a
replacement Windows host, file-copy tools such as `Copy-Item`, `robocopy /COPY:DAT`, or `scp` leave
inherited DACLs (`AreAccessRulesProtected = $false`), which `oscar-storage.ps1` rejects fail-closed.
Re-apply explicit protected administrator + local `docker-users` read/execute ACLs from an elevated
PowerShell prompt before running `.\oscar.bat backup-verify` and `.\oscar.bat restore`:

```powershell
$BackupDir = 'D:\oscar-storage\backups'
$BackupId  = '20261017T153000Z-1a2b3c4d'
$KeyFile   = '.\secrets\backup-key.txt'
$AdminUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name

icacls "$BackupDir\$BackupId" /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "${AdminUser}:(OI)(CI)F" "docker-users:(OI)(CI)RX"
foreach ($ProtectedFile in @(
    "$BackupDir\CURRENT",
    "$BackupDir\$BackupId\VERIFIED",
    "$BackupDir\$BackupId\JOURNAL_CONFIRMED",
    $KeyFile
)) {
    icacls $ProtectedFile /inheritance:r /grant:r "*S-1-5-18:F" "*S-1-5-32-544:F" "${AdminUser}:F" "docker-users:RX"
}
```

## Post-restore acceptance

Do not reconnect producers until the restored system passes all relevant checks:

```sh
sudo bash oscar.sh status
sudo bash oscar.sh archive status
sudo bash oscar.sh archive verify
```

Also verify:

- login and role enforcement over HTTPS;
- the target hostname/port and the certificate presented for that endpoint;
- `OSCAR_DEPLOYMENT_ID` still matches both named-volume labels, or the exact adoption receipt still
  matches both deliberately retained pre-label volumes;
- archive, backup, secret, TLS, backup-key, backup-mode, and any optional legacy-WAL binding still name the
  intended target policy and paths;
- SensorHub module/driver status and the expected lane inventory;
- a recent event lookup by UUID and Event Details rendering;
- a legacy source video and an exact-five retained JPEG set, where present;
- daily-file journal startup with no CRC or immutable-publication mismatch;
- one representative query that spans hot and cold observations;
- reports and adjudication artifacts;
- backup epoch/manifest identity and the expected restore endpoint;
- PostgreSQL is out of recovery on a timeline newer than the base backup, the exact `VERIFIED`
  receipt exists, `archive_mode` is off, a post-promotion write survives checkpoint and clean
  restart, and no recovery setting/signal remains persisted; and
- database/application logs for checksum, WAL, archive, permission, or missing-object errors.

Run the full emulator-backed OSCAR regression suite before declaring a production recovery
successful. Record the backup ID, recovery start/end times, accepted data endpoint, checks performed,
and approver.

## Recovery boundary: no PITR

OSCAR 3.11.0 does not continuously archive PostgreSQL WAL and does not support point-in-time recovery.
The supported target is the consistency endpoint inside one verified coordinated snapshot. Do not
present a preserved legacy WAL root, a schema-v1 compatibility payload, or the Parquet cold tier as
a current PITR chain.

## One current snapshot and off-site copies

The local backup root has one authenticated logical current snapshot. `CURRENT`, not modification
time or directory sort order, selects it. A new backup is built and verified without disturbing the
old pointer; after the new snapshot is accepted and journal-confirmed, an atomic `CURRENT`
replacement commits it. Cleanup may then remove the prior non-current fully accepted schema-v2
snapshot. This order prevents a failed backup or crash from leaving zero authenticated recovery points.

`backup-prune` is retired. It remains accepted only to print retirement guidance and performs no
deletion. `OSCAR_BACKUP_RETENTION_COUNT` and `OSCAR_BACKUP_AUTO_PRUNE` are ignored legacy settings
and are not present in the 3.11.0 template. Never hand-edit `CURRENT` or delete a pointed-to snapshot.

Define a policy that retains enough **verified, off-host** snapshot copies to meet recovery
objectives. Off-host media are outside the local one-snapshot state machine; copy the complete
directory, re-run `backup-verify` after returning it to a controlled backup root, and retain its
separately escrowed key and exact images. This is endpoint recovery, not a WAL/PITR chain.

At minimum:

- explicitly opt in to `single` mode, then create (and therefore automatically verify) a coordinated
  snapshot on a documented schedule and before upgrades/policy changes;
- alert on backup, archive, OSCAR-state, and PostgreSQL-volume capacity separately;
- copy verified backups and the external key into independent failure domains;
- perform a full isolated restore at least quarterly and after a storage-format or PostgreSQL major
  change; and
- document who can authorize retention reduction and backup destruction.

Deleting the oldest cold archive from the live system does not delete it from existing backups or
portable exports. Include those copies in privacy requests and records-destruction audits.

## Disaster-recovery boundary

Within its configured paths, OSCAR is fully backupable: database, OSH/app state, daily journal and
files, media, reports, Parquet cold tier, configuration, credentials, and TLS material are
included. Recovery still depends on external infrastructure and operational evidence. Preserve the
release artifact/images, encryption key, host build documentation, DNS/certificate trust plan, and
restore-test records alongside—but not all in the same failure domain as—the coordinated backup.
