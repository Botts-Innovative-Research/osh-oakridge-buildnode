# OSCAR 3.11.0 storage operations

This is the administrator runbook for OSCAR's PostgreSQL hot store, primary Parquet cold tier,
direct daily journal, retained media, and optional single coordinated snapshot. Commands assume the extracted 3.11.0
release directory is the current directory.

For design rationale see [Storage architecture](STORAGE_ARCHITECTURE.md). For exact state
transitions see [Data lifecycle](DATA_LIFECYCLE.md). For recovery see
[Backup and restore](BACKUP_RESTORE.md).

Run these procedures only on the supported Ubuntu Server 24.04 x86-64 or Windows 11 x86-64 Docker
Desktop/WSL 2 hosts. macOS deployment and storage commands fail closed and are not an operational
fallback.

## Safety rules

1. Never treat `docker compose down --volumes` as data destruction; Compose skips OSCAR's external
   named volumes. Never explicitly delete a named volume or remove a cataloged archive object unless
   permanent data loss is authorized and a verified backup is retained.
2. Never edit `.open`/`.seg` journal files, published daily CSVs/manifests, retained-media internals,
   Parquet files, or generation manifests in place.
3. Run `archive verify` before relying on stage retirement, exporting evidence, or creating a cold purge
   plan.
4. Use `archive dry-run` and its one-time token for cold deletion. Do not substitute `rm`, Explorer,
   storage-array expiration, or a generic object-store lifecycle.
5. Treat a missing or checksum-mismatched object as an integrity incident. Restore or investigate;
   do not delete its catalog record to make the error disappear.
6. Keep the backup encryption key outside the only backup and restrict all archive/export/backup
   copies as sensitive operational records.
7. Do not start two storage-administration commands concurrently. The launcher enforces one
   crash-released, nonblocking deployment lock and reports the competing command; investigate a
   persistent lock-file error rather than deleting or bypassing it. Locks are keyed by
   `OSCAR_DEPLOYMENT_ID` in `/run/lock/oscar-storage` (Ubuntu) or
   `%ProgramData%\OSCAR\StorageLocks` (Windows), so a
   clean-release upgrade cannot evade an older process's lock.

## Standard 3.11.0 configuration

New installations receive these defaults from `dist/config/standard/config.json`:

| Setting | Default | Operational effect |
| --- | --- | --- |
| `dailyFileJournal.enabled` / `required` on RPM drivers | `true` / `true` | Lane driver fails closed if durable source capture is unavailable |
| Journal force limits | 1 s / 128 records / 1 MiB | Maximum time/count/bytes before a segment force |
| Journal segment limits | 64 MiB / 15 min | Bounds recovery scan and segment size |
| Journal `zoneId` | `UTC` | Defines immutable daily windows and local timestamp field |
| Journal observation mode | `LATEST` | Keeps the live `dailyFile` events required for lane occupancy processing; only completed manifest-validated local days are removed, so the current unsealed day remains queryable |
| Daily-file cleanup work limit | 50 lane/day attempts per invocation | Bounds both the midnight attempt and each hourly manifest-gated retry while an outage backlog converges oldest-first |
| Sealed journal retention / backup gate | 30 days / `false` | Deletes private sealed source only after the later of day close or publication plus immutable-publication validation and exact frozen replay; sites may opt into an additional verified-backup requirement |
| Sealed journal lifecycle queue | bounded durable batches | Avoids startup and periodic all-history directory scans while recovery and deletion backlogs converge |
| Database `idProviderType` | `SEQUENTIAL` | Required for exact, race-free archive ownership |
| Database batch | 10,000 rows / 1 s | Bounded insert transaction and commit period |
| Primary stage window / delay / future skew | 30 min / 5 min / 5 min | The five allowlisted immutable outputs commit to UTC-aligned LOGGED PostgreSQL children first; a closed child becomes Parquet-eligible after the delay, and farther-future detector clocks are rejected |
| Parquet-primary worker interval | 1 min | Background export, parity, and retirement cadence; the at-most-one-hour normal staging budget is an SLO, not a hard deadline during failure or backlog |
| Archive work bounds | 2 generations / 2 verifications / 8 partition retirements / 15 min | Independently bounds each lifecycle phase and stops starting new generations at the duration bound; in-progress publication completes safely |
| Maximum generation | 2,000,000 rows / lower of 2 GiB operator cap or 1/8 DuckDB memory (32 MiB standard) | Deterministic `(phenomenontime,id)` prefixes become same-window revisions; 500-row cleared DuckDB inserts bound native staging memory, and a single oversized row fails closed in the LOGGED child |
| DuckDB memory / threads | 256 MiB / 2 per connection | Bounds native memory and CPU for every export, verification, parity, delete, cold query, metadata scan, and count |
| DuckDB session admission | 2 process-wide / 30 s wait | Fairly bounds the aggregate native-memory/CPU/spill multiplier; excess work fails busy and can be retried instead of opening an unbounded connection |
| DuckDB spill | 4 GiB per operation in `/var/lib/oscar/duckdb-tmp` | Each connection gets a mode-0700 private child that is removed on close; scratch must be disjoint from the immutable archive and is excluded from backup |
| Parquet compression | ZSTD level 6 | Cold-storage size/CPU tradeoff |
| Inactive `HOT_RETENTION` compatibility | 2 retention days / 60 min interval / 3 rollback days | Retained for configuration compatibility; these values do not impose a 72-hour raw PostgreSQL overlap in `PARQUET_PRIMARY` |
| `deleteHotAfterArchive` | `true` | After object re-hash and exact parity, transactionally detaches and drops a complete primary-stage child; it does not delete mutable event/workflow rows |
| Video retention age | 0 days | Makes a completed source video immediately eligible for asynchronous five-JPEG conversion on a retention scan |
| Retention scan / catch-up | 5 min / 6 h forward | Bounds normal discovery and catch-up work after downtime |
| Late-arrival scan | every 6 h / 2 h per pass / 24 h allowance | Rechecks delayed observations without an all-history rescan |
| Historical reconciliation | every 24 h / 24 h per pass | Durable repair path for older eligible observations |
| Retained evidence | exactly 5 JPEGs, quality 85 | First, quarter, middle, three-quarter, and last decoded frames |
| Source-video rollback grace | 24 h | MP4 preserved after a successful five-frame publication |
| Storage pressure | trigger 85%, target 80% | Removes only eligible cataloged media sets |
| Pressure minimum age | 10 min | Prevents immediate removal of newly published sets |
| Backup mode | `disabled` | Backup creation, verification, restore, and retired prune command require explicit `single` opt-in |
| Local recovery snapshots | 1 authenticated current snapshot | New schema-v2 snapshot commits through `CURRENT`; a prior snapshot is cleaned only after commit and independent full acceptance verification |

The one-snapshot value is steady state. Creating its replacement temporarily requires capacity for
the old snapshot and the complete new candidate until authenticated `CURRENT` commits. A crash may
leave non-current or private staging debris; the next locked storage command first requires an
authenticated, fully accepted schema-v2 `CURRENT`. It removes only non-current candidates whose
contents independently pass the same core and acceptance checks. Schema-v1, failed, partial,
unauthenticated, unaccepted, and incomplete deletion candidates are preserved with warnings. Before
the first `CURRENT` exists, exactly one fully accepted schema-v2 candidate is adopted by rebuilding
authenticated `CURRENT`; multiple accepted candidates are preserved and stop the command for
operator review. An unsafe, dangling, or acceptance-invalid `CURRENT` entry stops cleanup without
candidate mutation.

`delegateObservationLifecycleToDatabase=true` disables the old occupancy-gated high-volume purge so
the tiered database owns gamma/neutron lifecycle. It does not disable connection-status maintenance
or manifest-gated daily-file compatibility cleanup.

The `PARQUET_PRIMARY` setting applies only to fresh databases initialized from this standard
profile. PostgreSQL is still the short-lived commit-durable staging layer for the allowlisted immutable outputs,
and remains the system of record for mutable occupancy/alarm events, adjudications, reports,
metadata, overlays, tombstones, and non-allowlisted streams. Fresh primary staging children omit the
generic observation-payload GIN and mutable-event indexes; purpose-built event indexes remain on
the parent. Upgrade preserves an
existing schema and configuration rather than dropping that index or silently changing its mode.

Variable PostgreSQL keyset observation pages are deliberately kept unnamed at statement scope
(`prepareThreshold=0`). The same query shape is reused for different stream-ID sets and time
windows; allowing PostgreSQL to promote it to a generic server plan can make a 100-stream
connection-status cleanup scan the global observation-time index instead of the selective
stream/time indexes. Per-page planning has a small bounded cost and prevents that sustained CPU/I/O
regression, while ordinary ingest and stable queries retain server preparation and binary transfer.
Retention filters use native closed-open temporal ranges without a Java value predicate, so the
database can apply the requested batch limit; the H2 implementation independently preserves the
same open/closed endpoint semantics at its inclusive physical cursor.

An upgraded deployment keeps its persisted `/var/lib/oscar/config.json`; the release does not
silently replace site configuration. Always inspect the running module settings rather than assume
the file shipped in the ZIP became active.

## New installation and storage paths

For a new 3.11.0 production system, keep the live archive on durable monitored storage. Backup mode
is disabled until an administrator deliberately selects a safe absolute backup path that does not
overlap the release or archive roots. A separate physical drive is recommended for failure
isolation, but it is not required:

```dotenv
OSCAR_ARCHIVE_DIR=/absolute/path/to/oscar-storage/archive
OSCAR_BACKUP_MODE=disabled
OSCAR_BACKUP_DIR=/absolute/path/to/oscar-storage/backups
OSCAR_BACKUP_KEY_FILE=./secrets/backup-key.txt
```

The absolute storage roots are managed host paths, not backup payload placement instructions.
Archive is the live service bind. PostgreSQL runs with `archive_mode=off`, no archive command, and no
external WAL bind. An existing `OSCAR_WAL_ARCHIVE_DIR` binding is retained only as an inactive
compatibility location; fresh deployments do not add one. After `single` opt-in, the administrator-owned backup root is never mounted
into a long-running service and is exposed only to narrowly scoped one-shot helpers.
During either same-host or cross-host restore, OSCAR preserves those target roots along with the
target deployment ID, platform, and HTTPS endpoint while it restores source data, credentials, TLS
material, and portable configuration. A backup created under another host's storage paths therefore
cannot redirect the target after restore.

The credential settings shown above are different: `./secrets` and `./tls` are always canonical;
when `single` is selected, `./secrets/backup-key.txt` is canonical too. Backup, safety-copy, and
atomic install operations use those release-relative locations. Setup/upgrade, backup, and restore
reject custom active values before starting services or changing data. See [Backup and restore](BACKUP_RESTORE.md#same-host-and-cross-host-environment-policy).

Initialization converts the shipped sibling defaults into absolute paths under an `oscar-storage`
directory next to the versioned release directory and persists those absolute values in `.env`.
Fresh `disabled` mode creates only the service-owned archive root; it does not create the backup
root, backup key, or legacy-WAL compatibility root. Explicit `single` mode additionally creates the
administrator-owned backup root and generates the external backup key. Neither mode creates,
mounts, or writes the retired legacy-WAL compatibility root; an existing root is preserved
unchanged. Both modes initialize a new PostgreSQL cluster with data checksums and start
the services. A site may select different absolute paths through the supported setup options.
Custom relative paths are rejected because they would resolve against a different directory after
a clean-release upgrade.

When moving to a later release, copy the existing `.env`; do not replace its absolute storage roots
or backup-mode policy with the new `.env.example` values. The new release will reuse the archive,
preserve legacy WAL and backup data, and continue using the selected external backup root even when
it is extracted into a different sibling directory. Confirm that Compose mounts only the archive,
then confirm `OSCAR_BACKUP_MODE` and `OSCAR_BACKUP_DIR` directly from `.env` before upgrading.

Each active storage root must be a dedicated directory at least two path components below its
filesystem/volume root. The archive and backup roots must not equal, contain, or overlap one
another; neither may be inside or broad enough to contain the versioned release directory, and neither
may contain the administrator's home/profile directory. Existing path components must not be
symbolic links, junctions, or reparse points. Both
launchers enforce these rules before privileged storage work and again after initialization creates
the directories. This protects purge and restore operations from a typo such as `/`, `C:\`, a parent
mount, or a redirected path.

The Ubuntu launcher resolves its own release directory to a physical path and rejects a symlinked
launcher file before reading deployment configuration. The Windows launcher rejects every junction,
symbolic link, or other reparse point in its launcher/release path and resolves each storage root
through its nearest existing physical ancestor before containment comparisons. A release-directory
alias therefore cannot hide an active archive or backup root located inside the release (or a release
located inside one of those roots).

Each active root also has an administrator-owned `.oscar-storage-root` identity with format
`oscar-storage-root-identity`, version `1`, the deployment UUID, root kind (`archive` or `backup`),
claim time, and explicit-adoption audit fields. A missing marker on a nonempty active root,
a foreign deployment UUID, a swapped root kind, unsafe ownership/ACL, or a symlink/reparse-point
marker is a hard failure. The Ubuntu archive root is a root-owned service-group directory mode
`1770`; the sticky bit protects the root-owned marker. The
backup root is root-only mode `0700`. Windows uses a protected administrator ACL; `docker-users`
has the read/execute access required by the confined Docker helper and must be treated as a
Docker-engine-equivalent privileged group. Backup commands require `OSCAR_BACKUP_MODE=single` and
validate the applicable roots and Docker-volume identities. `backup-verify` may run with services
offline, but not while the deployment policy is disabled. It publishes/replaces `VERIFIED` and
normalizes permissions; any optional live-catalog write is separately volume-ownership-gated.

An upgrade may adopt a verified, nonempty legacy root exactly once with
`--adopt-legacy-storage-roots` on Ubuntu or `-AdoptLegacyStorageRoots` on Windows. Setup records
`adoption=explicit-existing`, UTC time, and actor in each marker. Do not use adoption for an empty
replacement path or a root from another deployment. Empty new roots are claimed automatically.

Ubuntu:

```sh
sudo bash oscar.sh init
```

Windows (Administrator Windows PowerShell 5.1 or the elevated launcher menu):

```powershell
.\oscar.bat init
```

Use local NTFS for a Windows release directory; do not put live database or journal state in a
cloud-synchronization folder. On Ubuntu, avoid network filesystems that cannot provide the required
rename, force, ownership, and PostgreSQL semantics.

### Existing pre-3.11.0 deployments

The complete 3.11.0 storage profile is not an automatic in-place conversion. `oscar upgrade` preserves
the existing application configuration and database volume, and PostgreSQL data checksums are an
initial-cluster property.

One narrow compatibility migration is automatic: supported `oscar upgrade` stops the application
tier and runs the restartable daily-file lifecycle-index migration before startup. The tool reads
the retained `/var/lib/oscar/config.json`, uses the configured Daily File Journal root/directory/zone,
and skips safely when that module is absent. It upgrades an earlier 3.11.0 preview journal without
scanning its historical tree on a live module thread. It does not convert a pre-3.11.0 database or
configuration into the complete tiered-storage profile. The same deployment-scoped lock excludes
backup, restore, and archive administration until the new services pass health checks. On failure,
final metadata stays uncommitted while restart-safe work markers may remain; the application stays
stopped, so fix the reported condition and rerun `upgrade`.

The 3.11.0 observation schema also installs a corrected natural-key unique index that treats null
feature, phenomenon-time, and result-time fields as equal. This is important because a null result
time is normal for OSCAR observations. If an older database already contains duplicates under that
corrected key, PostgreSQL deliberately refuses to create the index instead of choosing a row or
silently retaining ambiguity. Audit and resolve those duplicates under an approved migration before
attempting an in-place database upgrade. A fresh 3.11.0 database has no such cleanup requirement.

For the disposable test systems, initialize a clean 3.11.0 deployment and new database. For a
production pre-3.11.0 system whose history must remain available:

1. freeze retention/deletion changes;
2. take and verify the existing system's supported backup/export;
3. retain the old deployment read-only for policy lookup;
4. initialize 3.11.0 on clean state;
5. validate lane configuration and workflows;
6. migrate only records required by an approved, tested migration procedure; and
7. preserve the pre-3.11.0 system until retention and audit owners accept the transition.

Do not erase an old production volume simply to make the 3.11.0 module start.

## Production rollout

### Phase 1: validate the primary cold tier

The shipping profile commits only the five allowlisted immutable high-volume outputs to LOGGED,
UTC-aligned 30-minute PostgreSQL staging children, then makes each closed child Parquet-eligible
after five minutes and runs the worker every minute. After manifest-last activation, object re-hash,
and exact row/UUID parity, it transactionally detaches and drops the complete child. There is no
three-day duplicate-raw overlap in `PARQUET_PRIMARY`. The normal stage budget is at most one hour,
but failure, backlog, lock contention, or downtime can extend it. Mutable event/workflow records
remain in PostgreSQL.
Run long enough to create multiple generations across representative lane/output rates. Check:

```sh
sudo bash oscar.sh archive status
sudo bash oscar.sh archive verify
```

Windows:

```powershell
.\oscar.bat archive status
.\oscar.bat archive verify
```

Exercise queries that are hot-only, cold-only, and cross the retention boundary. Confirm event UUID
lookup, Event Details, charts, adjudication, report generation, and newest/latest observations.
Review parity receipts and failed archive jobs with the queries below.

### Phase 2: recovery acceptance

If the site requires OSCAR-managed recovery snapshots, opt in explicitly:

```sh
sudo bash oscar.sh upgrade --backup-mode single --backup-dir /srv/oscar-backups
```

```powershell
.\oscar.bat upgrade -BackupMode single -BackupDir D:\oscar-backups
```

Create and verify the single coordinated snapshot, copy it off-host, restore it on an isolated test
deployment, and run the full OSCAR regression suite. Confirm that the restored archive, journal,
daily files, media, and mixed-tier queries match the source system. See
[Backup and restore](BACKUP_RESTORE.md).

### Phase 3: validate whole-partition retirement

The primary lifecycle retires only a complete stage child whose rows all have exact, successfully
verified owners. Watch attached/detached stage counts and age, PostgreSQL/WAL volume, database size,
archive receipts, query latency, and logs. A healthy cycle should reclaim the relation as a unit,
without row-wise delete bloat or an autovacuum dependency. Do not run an unplanned `VACUUM FULL`,
which takes strong locks and can cause a major outage.

### Phase 4: cold retention

After the archive has accumulated beyond the site's cold-retention period, use the reviewed,
tokenized deletion workflow below. Keep at least one tested coordinated recovery snapshot or
off-site recovery point and apply the same policy to portable copies.

## Routine command reference

| Task | Ubuntu | Windows |
| --- | --- | --- |
| Service status | `sudo bash oscar.sh status` | `.\oscar.bat status` |
| OSCAR logs | `sudo bash oscar.sh logs --service oscar --tail 500` | `.\oscar.bat logs -Service oscar -Tail 500` |
| PostgreSQL logs | `sudo bash oscar.sh logs --service postgres --tail 500` | `.\oscar.bat logs -Service postgres -Tail 500` |
| Archive summary/holds | `sudo bash oscar.sh archive status` | `.\oscar.bat archive status` |
| Verify all active archive objects | `sudo bash oscar.sh archive verify` | `.\oscar.bat archive verify` |
| Coordinated backup | `sudo bash oscar.sh backup` | `.\oscar.bat backup` |
| Verify backup | `sudo bash oscar.sh backup-verify ID` | `.\oscar.bat backup-verify -BackupId ID` |
| List retention holds | `sudo bash oscar.sh archive hold list` | `.\oscar.bat archive hold list` |

The archive commands require a configured deployment. Backup, verification, and restore additionally
require `OSCAR_BACKUP_MODE=single`; disabled mode returns opt-in guidance before any mutation.
Mutating commands also require root/Administrator privileges. `backup-prune` is retired, hidden from
launcher menus, and retained only as a no-op compatibility command that explains the one-snapshot
`CURRENT` model.

The coordinated backup excludes the reserved `/var/lib/oscar/duckdb-tmp` path exactly. Keep that
default for scratch stored in OSCAR's persistent state. A custom DuckDB temporary parent is valid
only outside `/var/lib/oscar`, must remain disjoint from the archive, and needs its own capacity and
owner-only-permission monitoring. OSCAR holds `.oscar-duckdb.lock` in that parent for its process
lifetime (real regular file, mode `0600`) and refuses a concurrent owner. The first owner after a
crash removes only direct, canonical `<operation>-<lowercase UUID>` directories left by the prior
owner. Unrelated entries and symbolic links are not cleanup targets and should be investigated.

## Archive health inspection

`archive status` reports generation counts, rows, and Parquet bytes grouped by state/profile, then
the number of active holds. `archive verify` first expands every `ACTIVE` or `SEALED` generation
against the three required kinds and fails unless there is exactly one active
`OBSERVATIONS_PARQUET`, `GENERATION_MANIFEST`, and `DATASTREAM_SCHEMAS` row with a path and SHA-256;
the Parquet row must also repeat the generation's authoritative `object_path` and `sha256`, and the
manifest row must repeat its `manifest_path`. It then resolves and hashes those exact required files.
This prevents stale generation metadata or a missing catalog row from escaping verification
merely because there was no object row to iterate. Required and supplemental objects come from one
canonically ordered PostgreSQL snapshot. After hashing and filesystem reconciliation, the command
recaptures the same snapshot and requires byte-for-byte equality; a concurrent activation or purge
therefore fails with an explicit retry instead of certifying a mixed instant. Both commands also reconcile the complete physical
archive root without changing it. The administrator-owned `.oscar-storage-root` is the only
top-level exemption; all archive data must have the approved `datasets/...` shape. An unexpected
top-level object, empty/unapproved directory, absent `datasets` tree accompanied by other content,
unregistered final file, or still-present `DELETED` object fails the command before backup.
Symlinks/reparse points and non-regular entries also fail. A `.partial` younger than the archive
job's two-hour stale window is reported as possible in-progress work; at or beyond two hours it
fails as stale. Investigate ownership and job state—these commands never auto-delete an orphan.

For deeper inspection, use the bootstrap account inside the private PostgreSQL container. This does
not expose port 5432 on the host.

```sh
docker compose exec -T postgres sh -eu -c '
  PGPASSWORD=$(cat /run/secrets/postgres_bootstrap_password)
  PGOPTIONS=-csearch_path=oscar,public
  export PGPASSWORD PGOPTIONS
  exec psql --set=ON_ERROR_STOP=1 --username oscar_bootstrap --dbname gis "$@"
' psql-wrapper --command \
  "SELECT state, count(*) FROM oscar_archive_job GROUP BY state ORDER BY state;"
```

Recent failures:

```sh
docker compose exec -T postgres sh -eu -c '
  PGPASSWORD=$(cat /run/secrets/postgres_bootstrap_password)
  PGOPTIONS=-csearch_path=oscar,public
  export PGPASSWORD PGOPTIONS
  exec psql --set=ON_ERROR_STOP=1 --username oscar_bootstrap --dbname gis "$@"
' psql-wrapper --command \
  "SELECT id, profile, window_start, window_end, attempt, updated_at, left(error, 200) AS error
     FROM oscar_archive_job
    WHERE state = 'FAILED'
    ORDER BY updated_at DESC
    LIMIT 20;"
```

Parity and deletion receipts:

```sh
docker compose exec -T postgres sh -eu -c '
  PGPASSWORD=$(cat /run/secrets/postgres_bootstrap_password)
  PGOPTIONS=-csearch_path=oscar,public
  export PGPASSWORD PGOPTIONS
  exec psql --set=ON_ERROR_STOP=1 --username oscar_bootstrap --dbname gis "$@"
' psql-wrapper --command \
  "SELECT generation_id, verification_type, status, expected_rows, actual_rows, verified_at, detail
     FROM oscar_archive_verification
    ORDER BY verified_at DESC
    LIMIT 30;"
```

Active/unverified generations and their age:

```sh
docker compose exec -T postgres sh -eu -c '
  PGPASSWORD=$(cat /run/secrets/postgres_bootstrap_password)
  PGOPTIONS=-csearch_path=oscar,public
  export PGPASSWORD PGOPTIONS
  exec psql --set=ON_ERROR_STOP=1 --username oscar_bootstrap --dbname gis "$@"
' psql-wrapper --command \
  "SELECT id, state, parity_verified, window_start, window_end, row_count, activated_at
     FROM oscar_archive_generation
    WHERE state IN ('ACTIVE','SEALED')
    ORDER BY window_start
    LIMIT 50;"
```

Active holds (read-only SQL inspection):

```sh
docker compose exec -T postgres sh -eu -c '
  PGPASSWORD=$(cat /run/secrets/postgres_bootstrap_password)
  PGOPTIONS=-csearch_path=oscar,public
  export PGPASSWORD PGOPTIONS
  exec psql --set=ON_ERROR_STOP=1 --username oscar_bootstrap --dbname gis "$@"
' psql-wrapper --command \
  "SELECT id, subject_type, subject_id, resolution_mode, reason, created_by, created_at
     FROM oscar_retention_hold
    WHERE released_at IS NULL
    ORDER BY created_at;"
```

## Manage retention holds

Place a hold before a generation or exact observation could become eligible for hot or cold
deletion. Run `archive status` first and copy the exact `store_key` and `id_scope` shown for the
target generation. These two values are mandatory isolation boundaries: numeric observation IDs
may repeat in a different OSH store, and OSCAR refuses a hold, plan, purge, or export without the
explicit namespace. Listing includes active and released history:

```sh
sudo bash oscar.sh archive hold list
sudo bash oscar.sh archive hold create \
  --store-key <store-key> \
  --id-scope <id-scope> \
  --generation <generation-uuid> \
  --reason "investigation 2026-1042" \
  --created-by records-admin
```

For one observation, use its positive numeric internal ID:

```sh
sudo bash oscar.sh archive hold create \
  --store-key <store-key> \
  --id-scope <id-scope> \
  --observation 123456789 \
  --reason "case 2026-1042"
```

Windows equivalents:

```powershell
.\oscar.bat archive hold list
.\oscar.bat archive hold create `
  -StoreKey <store-key> `
  -IdScope <id-scope> `
  -Generation <generation-uuid> `
  -Reason "investigation 2026-1042" `
  -CreatedBy records-admin
.\oscar.bat archive hold create -StoreKey <store-key> -IdScope <id-scope> -Observation 123456789 -Reason "case 2026-1042"
```

The CLI verifies that a generation exists, validates identifiers/reason/actor fields, and returns a
hold UUID plus a durable `resolution_mode`. Record both with the controlling case. The list command
shows the mode for active and released history:

- `GENERATION_EXACT` means the supplied query-visible generation UUID was matched exactly.
- `HOT_EXACT` means the supplied observation ID matched an exact PostgreSQL row owned by this
  store/scope (either unowned hot data or a query-visible generation).
- `COLD_RANGE_CONSERVATIVE` means no exact PostgreSQL row remained and the ID fell only within a
  query-visible archive ID range. A Parquet generation can be sparse, so this protects every
  candidate generation range but **does not prove that the typed observation ID exists**. For legal
  certainty, verify the event/observation in OSCAR or place an explicit `GENERATION_EXACT` hold on
  the confirmed generation.
- `LEGACY_UNKNOWN` is migration-only. It marks a pre-3.11.0 observation hold whose original exact-
  row versus range-based resolution was not recorded. It remains protective but is not evidence
  that the exact observation existed. The CLI never creates a new hold with this mode.

Catalog migration labels older generation holds `GENERATION_EXACT` and older observation holds
`LEGACY_UNKNOWN`; it cannot reconstruct whether an old observation hold was created while its exact
hot row still existed or from a conservative cold range.

Release only after the legal/records owner authorizes it. Release records the actor/time and retains
the row:

```sh
sudo bash oscar.sh archive hold release --id <hold-uuid> --released-by records-admin
```

```powershell
.\oscar.bat archive hold release -HoldId <hold-uuid> -ReleasedBy records-admin
```

The release CLI is the supported hold interface. Do not update hold rows directly.
Hold creation is serialized with purge confirmation. Generation holds are accepted only while the
generation is `ACTIVE` or `SEALED`. For an observation, an exact PostgreSQL row is authoritative:
an unowned hot row or a row owned by an `ACTIVE`/`SEALED` generation remains holdable even when its
numeric ID falls inside an unrelated `DELETING`/`PURGED` generation's coarse minimum/maximum range.
An exact row owned by any other generation state is rejected. Only when no exact PostgreSQL row
exists does the CLI fall back to archive ID ranges; because those ranges can contain gaps when
eligible and ineligible streams interleave, a cold-only ID covered by both a queryable and a
`DELETING`/`PURGED` range is rejected as ambiguous. An observation tombstone always rejects hold
creation. These rules avoid both false rejection of extant data and false assurance after deletion
has started. Observation hold IDs are positive signed 64-bit values (maximum
`9223372036854775807`); the CLI rejects larger decimal values before SQL and uses `bigint`
predicates so PostgreSQL can retain index plans on observation and ID-block columns.

Active holds also protect logical datastore removal and cold
purge. Single-observation removal fails with an explicit active-hold error and leaves the row
visible. Bulk filtered removal skips held observation IDs and rows owned by a held generation,
continues removing eligible rows, and returns only the number actually removed; a later invocation
can remove the skipped rows after authorized release. Each single/batch removal first acquires the
normal store and ordered observation mutation locks, then takes a shared hold-table lock and reads
the relevant observation holds and only candidate generation holds on the same PostgreSQL
transaction. Hold creation/release takes the conflicting writer lock, so either the hold or the
removal wins completely without a per-row connection borrow.

For a tiered store, the generic datastore `clear`, `drop`, table-clone `backup`, and table-replacing
`restore` APIs are intentionally unsupported: each would bypass holds or omit the cold catalog and
objects. Use filtered hold-aware removal and the coordinated `oscar backup` / `oscar restore`
commands instead. Datastream removal holds a namespace-wide retention-hold read barrier and
preflights active observation and generation holds. If an exact, conservative, or unresolved hold
can protect the datastream, it aborts before changing any observation—including unheld siblings.
With a clean preflight, hold creation/release remains blocked through the bounded logical child
removals and metadata delete. The child removals are bounded, restartable transactions rather than
one unbounded all-or-nothing transaction: if a later child batch fails, datastream metadata remains,
already committed logical removals stay removed, and retry safely finishes the remaining children
before deleting metadata. Tiered datastream `clear`, `drop`, `backup`, and `restore` also fail closed
so decoding metadata cannot be orphaned. Integrators should treat these exceptions as a
storage-safety contract, not a transient database error.

## Delete old cold generations

Use a UTC cutoff that reflects approved policy. Only `SEALED` generations whose `window_end` is
before the cutoff can enter the plan.

### 1. Verify

```sh
sudo bash oscar.sh archive verify
```

### 2. Create and review a dry-run plan

```sh
sudo bash oscar.sh archive dry-run \
  --store-key <store-key> \
  --id-scope <id-scope> \
  --before 2026-01-01T00:00:00Z \
  --requested-by records-admin
```

Windows:

```powershell
.\oscar.bat archive dry-run `
  -StoreKey <store-key> `
  -IdScope <id-scope> `
  -Before 2026-01-01T00:00:00Z `
  -RequestedBy records-admin
```

The output includes the plan UUID, eligible rows/bytes, held-generation count, and a random
48-hex-character token. The token is shown once. The plan freezes the selected generation IDs and
expires after 24 hours; a later generation does not enter an already reviewed plan.

Review the plan against retention approval, active holds, current verified backups, and any open
incident. Do not proceed if counts are unexpected.

### 3. Purge the approved plan

```sh
sudo bash oscar.sh archive purge --store-key <store-key> --id-scope <id-scope> --plan <uuid> --token <token>
```

Windows:

```powershell
.\oscar.bat archive purge -StoreKey <store-key> -IdScope <id-scope> -Plan <uuid> -Token <token>
```

Purge briefly stops only OSCAR if it was running and always attempts to restore that prior state;
PostgreSQL and the gateway are not stopped. It preflights paths and hashes through a locked-down,
networkless, read-only-rootfs one-shot OSCAR-image helper that receives only the archive root
(read-only for verification, writable only for deletion). It then rechecks holds while holding the
same PostgreSQL lock used by hold creation. In one transaction it changes every selected generation
to `DELETING` (which
removes the whole generation from hot/cold query planning), persists generation/object deletion
intent, and only then starts filesystem removal. Catalog paths are resolved canonically beneath the
configured archive root; every helper path component is rechecked and symlink/reparse-point escapes
are rejected. If the process is interrupted, rerun the **same** plan and token; a confirmed plan
remains resumable, validates any still-present `DELETING` object, and records whether the helper
deleted it or found the transactionally authorized leaf already absent. Held items finish as
`COMPLETED_WITH_HOLDS`; create a new plan after the hold is formally released. Plan tokens are
hashed in PostgreSQL and cannot be used after completion; an unconfirmed plan expires after 24
hours. Finalization preserves the generation tombstone/catalog/deletion ledger but transactionally
removes observation overlays and observation tombstones that carry the exact now-`PURGED`
generation ID. Legacy unowned mutation rows require a separately reviewed migration.

When OSCAR was running before purge, the command returns only after the web service and all
top-level auto-start modules have reached `STARTED`, and after every nested lane RPM/camera has
completed its startup attempt. A disconnected device may settle offline without making OSCAR
unavailable; the Status of Health page reports that condition.

Docker may show the OSCAR container as `starting` while that bounded application initialization is
still in progress; this is expected and is stronger than an HTTP-only liveness probe. If it becomes
`unhealthy`, inspect the OSCAR logs for the specific module that did not start instead of immediately
issuing another restart.

Afterward, run `archive status`, `archive verify`, and a cold-range query. When `single` backup mode
is enabled, also create and verify the replacement snapshot. In disabled mode, confirm that the
backup command refuses without changing state and follow the site's approved recovery/export
policy. Retain the approval, dry-run output, deletion ledger, and verification result with
records-management evidence.

## Export a generation for independent review

Find the generation UUID with `archive status` plus the catalog query above, verify the archive, then
export it.

```sh
sudo bash oscar.sh archive export \
  --store-key <store-key> \
  --id-scope <id-scope> \
  --generation <uuid> \
  --destination /secure/review/oscar-archive
```

```powershell
.\oscar.bat archive export `
  -StoreKey <store-key> `
  -IdScope <id-scope> `
  -Generation <uuid> `
  -Destination D:\secure-review\oscar-archive
```

The destination must not already exist. The command briefly stops only OSCAR if it was running and
always attempts to resume it. Each object is checksum-verified and copied by the same locked-down
one-shot helper with only the archive mounted read-only and a newly created hidden export partial
mounted writable. The helper rechecks every component and rejects symlink/reparse-point objects.
The command preserves relative paths, adds generation and object
catalog JSON, `README.md`, a ready-to-run DuckDB `query.sql`, and `SHA256SUMS`, then renames the
complete package into place with the same compiled atomic no-replace publisher used by backups.
The staged tree and parent receive durability barriers first; a racing destination is never
overwritten and both trees remain available for diagnosis. The package is independently queryable
with DuckDB, but it is not added to OSCAR's live query plan and is not a replacement for a
coordinated OSCAR backup. See
[Archive format](ARCHIVE_FORMAT.md#querying-a-portable-copy-with-duckdb) for DuckDB examples.

## Daily-file checks

After UTC midnight (or local midnight if the configured journal `zoneId` was deliberately changed),
confirm for each active lane:

1. a prior-day `files/dailyfiles/<lane>_YYYY-MM-DD.csv` exists;
2. the matching `.csv.manifest.v1.json` exists;
3. CSV SHA-256 matches the manifest;
4. `recordCount` and `byteCount` are plausible;
5. the private ledger is `PUBLISHED` with the exact same half-open window; and
6. OSCAR logs have no journal force, CRC, atomic-rename, or immutable-publication error.

The midnight database-cleanup pass may reach a lane while its journal is still publishing. In that
case it logs a skip and leaves both the compatibility rows and durable checkpoint unchanged. Every
hourly maintenance pass retries the same bounded, oldest-first catch-up; after publication, confirm
that the prior-day rows are removed and the checkpoint advances. Current-day rows remain until the
day is sealed and published. Do not manually delete them to imitate a single-row `LATEST` view.

By default, private sealed segments become retention-eligible 30 days after the later of day close
or actual publication only when the immutable CSV, manifest, and ledger validate and a frozen replay
of every sealed segment exactly matches the published CSV. A late, missing, corrupt, linked, open,
or mismatched segment blocks deletion. Durable bounded lifecycle queues keep startup and each
maintenance cycle independent of total retained history. If the site enables
`requireBackupBeforeSealedJournalDeletion`, the exact lane/day inventory must additionally be bound
to an accepted coordinated snapshot; manual `backup-verify` does not create that receipt.

Journal internals live under `files/.dailyfile-journal`. They are private recovery state, not a
bucket for users to edit or download. Published CSVs are available in the authenticated
`dailyfiles` bucket according to configured permissions.

If the log reports a truncated final frame at startup, the journal has already truncated only the
incomplete tail and forced the repair. A CRC mismatch or a conflict with an existing immutable CSV
is different: stop the affected driver, preserve the lane/day segment directory, ledger, CSV, and
manifest, and investigate. Do not delete the conflicting artifact merely to start the driver.

## Retained-media checks

The retained-media worker loads its retention interval and query cadence at OSCAR startup. When an
administrator changes those values, use the supported `oscar restart` command and confirm the next
startup reports the expected eligible-through cutoff before relying on the new policy. Durable scan
checkpoints are intentionally monotonic and are not reset by a configuration edit. Do not delete or
edit or fast-forward them. For release qualification, save the accelerated profile on a newly
initialized disposable site and perform the supported restart before importing lanes or permitting
emulator traffic. Verify the current checkpoint first, then provision the lane fixture. If that
order was not followed, recreate the disposable database and application state or allow normal
oldest-first catch-up; checkpoint deletion is not an accepted shortcut.

For an event reached by the first eligible retained-media cycle:

- Event Details should show five labeled still frames per successfully retained camera;
- each frame endpoint should return `image/jpeg` only to an authenticated user with `videos` GET
  permission;
- the manifest should report five distinct `sourceFrameOrdinal` values and the positions `FIRST`,
  `QUARTER`, `MIDDLE`, `THREE_QUARTERS`, and `LAST`;
- every manifest `laneUid` should be the event's authoritative `urn:osh:system:lane:*` parent, never
  an RPM/sensor UID or `unknown-lane`;
- the source MP4 should remain during the 24-hour rollback grace; and
- after grace and a later successful retention pass, the manifest should report source state
  `DELETED` while the five frames remain viewable.

A `404` from the retained-media event endpoint is a compatibility signal: the Viewer must fall back
to the occupancy's legacy `videoPaths`. It is normal for legacy/pre-3.11.0 events. A manifest whose
referenced frame is missing or corrupt is not normal; the API withholds that asset, and the source
or backup should be used for recovery.

Release acceptance must include a one-second alarm whose saved OSCAR camera clip still publishes
exactly five distinct JPEG positions after bounded post-roll, plus an injected legacy clip with
fewer than five decoded frames. The legacy negative fixture must retain its MP4, record a failed
conversion, publish no partial media set, and continue through the Viewer's `404` legacy-video
fallback.

When storage reaches 85 percent, OSCAR logs a pressure-cleanup warning and removes only complete,
eligible media sets until 80 percent is reached. If it reports that storage remains above target,
add capacity or perform approved retention work. Do not expect pressure cleanup to remove daily
files, arbitrary legacy videos, reports, adjudications, or cold Parquet.

## Capacity and performance monitoring

There is no single safe capacity number for every site. Measure actual lanes, message frequency,
camera bitrate, alarm rate, retention, and query concurrency.

Container CPU and memory snapshot:

```sh
docker stats --no-stream
```

Confirm the effective archive bind source first. `init` persists absolute paths in `.env`; the
archive `source:` printed here is authoritative and must not point inside the versioned release
directory. There must be no PostgreSQL WAL bind. `OSCAR_BACKUP_DIR` also does not appear as a
long-lived Compose mount; confirm its single absolute `.env` value separately when mode is `single`.

```sh
docker compose config
```

Measure the actual mounted bind paths and named volumes through the running containers. These
POSIX-shell examples avoid accidentally inspecting obsolete
`data/` or `backups/` directories in the release tree:

```sh
docker compose exec -T oscar sh -c \
  'du -sh /var/lib/oscar/archive /var/lib/oscar/files /var/lib/oscar/db; \
   printf "oscar_state_files="; find /var/lib/oscar -xdev -type f | wc -l; \
   printf "cold_archive_files="; find /var/lib/oscar/archive -xdev -type f | wc -l; \
   df -h /var/lib/oscar/archive /var/lib/oscar'
docker compose exec -T postgres sh -c \
  'du -sh /var/lib/postgresql/data; df -h /var/lib/postgresql/data'
sudo du -sh -- \
  "$(awk -F= '$1=="OSCAR_ARCHIVE_DIR" {print substr($0,index($0,"=")+1)}' .env)"
```

When `OSCAR_BACKUP_MODE=single`, measure the separately configured backup root too:

```sh
sudo du -sh -- \
  "$(awk -F= '$1=="OSCAR_BACKUP_DIR" {print substr($0,index($0,"=")+1)}' .env)"
```

Trend the file counts as well as bytes and inodes. Coordinated-backup archive validation uses a
bounded 256 MiB private tmpfs; its scratch demand grows with tar member count and path length, not
with compressed media bytes. Treat an abrupt cardinality increase as an operational signal. When
`single` mode is enabled, run `backup-verify` and an isolated restore against a representative
high-watermark backup before adopting a materially larger retention window. In disabled mode,
confirm backup-command refusal/unchanged state and qualify the site's approved recovery/export
procedure instead. See
[Backup and restore](BACKUP_RESTORE.md#verify-a-backup) for the fail-closed limit and response.

PostgreSQL database and major relations:

```sh
docker compose exec -T postgres sh -eu -c '
  PGPASSWORD=$(cat /run/secrets/postgres_bootstrap_password)
  PGOPTIONS=-csearch_path=oscar,public
  export PGPASSWORD PGOPTIONS
  exec psql --set=ON_ERROR_STOP=1 --username oscar_bootstrap --dbname gis "$@"
' psql-wrapper --command \
  "SELECT pg_size_pretty(pg_database_size(current_database())) AS database_size;
   SELECT relname,
          pg_size_pretty(pg_total_relation_size(relid)) AS total,
          n_live_tup, n_dead_tup
     FROM pg_stat_user_tables
    ORDER BY pg_total_relation_size(relid) DESC
    LIMIT 20;"
```

WAL, checkpoints, temporary I/O, and query work should be trended rather than judged from one
sample. PostgreSQL 16 exposes useful fields in `pg_stat_wal`, `pg_stat_bgwriter`, and
`pg_stat_database`; `pg_stat_statements` is preloaded and created for new deployments.

```sh
docker compose exec -T postgres sh -eu -c '
  PGPASSWORD=$(cat /run/secrets/postgres_bootstrap_password)
  PGOPTIONS=-csearch_path=oscar,public
  export PGPASSWORD PGOPTIONS
  exec psql --set=ON_ERROR_STOP=1 --username oscar_bootstrap --dbname gis "$@"
' psql-wrapper --command \
  "SELECT wal_records, wal_fpi, pg_size_pretty(wal_bytes) AS wal_bytes
     FROM pg_stat_wal;
   SELECT datname, temp_files, pg_size_pretty(temp_bytes) AS temp_bytes,
          blk_read_time, blk_write_time
     FROM pg_stat_database
    WHERE datname = current_database();"
```

Expected behavior after rollout is lower PostgreSQL transaction/trigger/WAL overhead per telemetry
row and bounded long-term hot-table growth. Expect temporary CPU and sequential I/O during a
DuckDB export/parity pass, and CPU during FFmpeg JPEG extraction. DuckDB is capped per connection
at 256 MiB, two workers, and 4 GiB of spill by default, and a fair process-wide gate admits at most
two sessions. Work that cannot acquire capacity within 30 seconds fails busy without activating a
generation or dropping a stage child. Each generation is bounded; during backlog catch-up, one cycle may
start up to two generations over its 15-minute start window, verify at most two, and retire at most
eight complete stage children. Health/status UI polling remains independently bounded. Treat a
sustained regression—not a brief background spike—as the alert condition.

Track at least:

- hot database total/index/table size and dead tuples;
- archive bytes, generation backlog, export duration/failures, and parity latency;
- PostgreSQL `pg_wal` pressure, checkpoints, and `archive_mode=off` configuration drift;
- journal force/publication errors and time since last daily manifest per lane;
- media conversion success/failure, source-grace backlog, and pressure-deletion results;
- OSCAR/PostgreSQL CPU, resident memory, disk latency, and filesystem saturation;
- in `single` mode, backup age, verification age, off-site-copy age, and last successful restore
  drill; in disabled mode, the age and last successful drill of the site-approved recovery/export
  procedure; and
- query p50/p95/p99 for current events, UUID lookup, reports, and cross-tier history.

## Failure modes and recovery

| Symptom | Safety behavior | Operator action |
| --- | --- | --- |
| Required daily journal unavailable at driver startup | Driver fails closed | Restore service ordering, writable space/ownership, and atomic-rename-capable filesystem; restart journal then driver |
| Journal append/force fails | Required reader stops; record is not reported as accepted | Preserve logs/files, restore capacity/permissions, restart and verify lane publication |
| Truncated `.open` tail after crash | Only incomplete final frame is truncated | Confirm warning and next successful append/publication |
| Complete-frame CRC or immutable CSV mismatch | Initialization/publication fails visibly | Preserve all evidence; investigate storage/hardware; recover from verified copy |
| Observation batch commit fails | Snapshots stay queued for a later in-process retry | Fix PostgreSQL/network/disk immediately; restart only after assessing uncommitted-memory exposure |
| Archive export fails | LOGGED stage child remains; job records `FAILED` | Check database, archive space/permissions, DuckDB error, stale partials; allow controlled retry |
| DuckDB memory/spill cap is exhausted | Current export/query/parity operation fails; no generation is activated and no unverified stage child is dropped | Reduce query/export concurrency or window size, restore scratch capacity, or raise a cap only after site-specific load testing; a subsequent clean owner automatically reclaims recognized abandoned operation children |
| DuckDB session capacity stays busy for 30 seconds | Waiting operation fails before allocating a connection or scratch child; active work continues | Let the caller retry, inspect unusually long archive queries/exports, and raise concurrency only after measuring aggregate native memory, CPU, and spill |
| DuckDB scratch parent is broad, overlaps archive, has an unsafe lease, or is owned by another process | Archive operation fails before opening DuckDB or cleaning scratch | Keep `/var/lib/oscar/duckdb-tmp` disjoint from the archive and mode `0700`, keep `.oscar-duckdb.lock` a real regular file owned by OSCAR and mode `0600`, and stop the competing owner; on a non-POSIX embedding apply equivalent owner-only ACLs |
| Recognized DuckDB operation children remain after OSCAR starts | First-open recovery did not complete or archive work has not yet opened DuckDB | Preserve logs and unexpected entries, confirm no second OSCAR process owns the lease, then exercise `archive status`; only with OSCAR stopped should an operator remove confirmed abandoned canonical children by hand |
| Parity fails | Stage child remains; generation is not sealable | Compare receipt details and source/object hashes; do not bypass retirement |
| Stage age exceeds one hour | Safe publication/verification is delayed; LOGGED data remains queryable | Treat the one-hour target as an SLO alert: inspect backlog, failed jobs, parity, archive space, lock contention, and worker health; do not force-drop the child |
| Cataloged archive object missing/hash mismatch, ID block mismatch, or missing generation schema rows | Reader/verify/purge fails | Stop destructive work, preserve evidence, restore the coordinated database and exact archive objects from the same backup epoch, then verify again |
| Unregistered/`DELETED` archive file or stale `.partial` | Archive status/verify fails without changing the file | Correlate UUID/path with export jobs and logs; reconcile under an approved recovery procedure, never delete merely to clear the check |
| Source video has fewer than five decodable frames | No retained manifest; MP4 preserved | Correct camera/recording health; keep source under legacy playback and investigate |
| Retained-media lane parent cannot be resolved | No new manifest; source and retry state remain | Verify the RPM/camera systems are members of the intended OSH lane and that the deployed PostgreSQL datastore supports `getParent`; do not relabel an existing manifest by hand |
| Media publication fails | Partial set stays invisible; source preserved; retry ledger records failure | Check FFmpeg, source integrity, filesystem/rename/space; allow idempotent retry |
| Pressure cleanup cannot reach target | Protected data stays; error is logged | Add capacity or perform approved cold/media retention; never remove journal/adjudication files ad hoc |
| PostgreSQL reports archiver activity or an external WAL mount | Deployment drifted from the 3.11.0 profile | Stop rollout, preserve legacy data, restore `archive_mode=off`/no-WAL-bind configuration through the supported release, and requalify backup/restore |
| Backup fails | `.partial` or finalized-but-unverified directory remains; services are resumed where possible | Check `status`, preserve diagnostics, correct the cause, then re-verify or run a new backup |
| Restore fails | Deployment may remain stopped/partial | Keep producers disconnected; preserve `pre-restore-*`; repair cause and repeat from the same verified backup or escalate |
| PostgreSQL shutdown errors appear during OSCAR stop/restart | Qualification fails; OSCAR may not complete its database-backed module drain | Use the release `oscar` launcher, which stops gateway, OSCAR, and PostgreSQL sequentially; confirm the media-retention cancellation log completes, preserve logs, and do not substitute an unscoped multi-service Compose stop/restart |

## Monthly storage audit

At least monthly, and before changing retention:

1. Record filesystem and PostgreSQL sizes by data class.
2. Compare archive generation rows/bytes with attached stage count/age and whole-child retirement.
3. Review failed/stale jobs, parity failures, active holds, and deletion ledgers.
4. Verify all active archive objects.
5. Sample daily CSV manifest checks across lanes and daylight-saving boundaries where applicable.
6. Sample retained media across cameras, including source deletion after grace and legacy fallback.
7. Review orphaned partials/unregistered files without deleting them until ownership is established.
8. In `single` mode, verify the newest backup, off-site copy, and encryption-key escrow. In disabled
   mode, confirm backup-command refusal/unchanged state and verify the site-approved recovery/export
   procedure.
9. Review PostgreSQL WAL generation and archive growth. In `single` mode, also review backup growth
   and the tested endpoint-recovery snapshot; in disabled mode, review the site-approved
   recovery/export evidence.
10. Compare CPU, memory, disk latency, WAL, and query latency with the prior baseline.
11. Record findings, corrective actions, owner, and deadline in the site's operations system.

The regression suite validates functional storage workflows, but it does not replace production
capacity trending, records governance, security review, or real restore drills.

## Privacy and incident handling

Access to OSH APIs does not automatically authorize access to host archive/backup files. Limit host
administration and portable export rights separately. Log who created, copied, reviewed, and
destroyed an export. Use encrypted transport/media and never email raw alarm imagery or daily files
unless an approved secure channel and business purpose exist.

If integrity or unauthorized access is suspected, stop retention/deletion, preserve logs and
catalog state, take a forensic copy under incident procedure, and rotate affected credentials. Do
not run cleanup commands to conceal symptoms before evidence is captured.
