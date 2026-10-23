# OSCAR 3.9.2 data lifecycle and retention policy

This document defines when OSCAR data changes form, when it may be removed, and which safety gates
apply. It complements the [storage architecture](STORAGE_ARCHITECTURE.md) and the operational
procedures in [Storage operations](STORAGE_OPERATIONS.md).

This policy applies to the supported Ubuntu Server 24.04 x86-64 and Windows 11 x86-64 deployment
hosts. macOS deployment and storage operations fail closed; it is not a supported storage host.

## Policy summary

| Data class | Default transition | Removal gate | Removed automatically? |
| --- | --- | --- | --- |
| Selected high-volume detector observations | Copy to an `ACTIVE` Parquet generation when older than 48 hours | Valid Parquet/schema/manifest objects, active catalog generation, exact-row parity receipt, 24-hour overlap, no applicable hold | Yes for exact eligible rows in the shipping profile, normally about 72 hours after observation plus scheduling |
| Other PostgreSQL observations and transactional records | Remain hot | Existing application policy | Not by the cold-tier scheduler |
| Raw RPM daily-file source | Append immediately; publish prior day after rollover | Valid immutable CSV, v1 manifest, `PUBLISHED` ledger, 30 days after the later of day close or actual publication, and exact sealed-journal replay parity; sites may additionally require verified backup confirmation | Yes for eligible private sealed segments; published daily files are not pressure-cleanup candidates |
| Alarm source MP4 | Immediately eligible for an asynchronous attempt to publish exactly five JPEGs | Exactly five verified JPEGs and manifest, then 24-hour rollback grace and no hold | Yes, on a later successful retention pass |
| Retained five-JPEG media set | Remains available | Complete set, no hold, rollback grace elapsed, minimum pressure age met, filesystem at pressure threshold | Yes, only under configured storage pressure |
| Uncatalogued legacy video | Legacy behavior only | Not eligible for new pressure cleanup | No |
| Daily files, reports, adjudication, sitemap | Remain in application state | Site policy and explicit administration | No by storage-pressure cleanup |
| Cold archive generation | Primary cold tier; `ACTIVE` during verified overlap, then `SEALED` after exact hot-row deletion | Explicit dry-run plan selecting only `SEALED` generations, review, unexpired one-time token, no hold, object hash recheck | No; an administrator must run `archive purge` |
| Docker logs | JSON log rotation | Docker rotation settings | Yes, size-based rotation |
| Coordinated recovery snapshot | Disabled by default; manual `single` mode commits one schema-v2 snapshot through authenticated `CURRENT` | Full HMAC/checksum/tar/`pg_verifybackup` verification and journal confirmation before pointer replacement | A prior non-current snapshot is cleaned only after the new pointer commits and the candidate independently passes full schema-v2 acceptance; all other candidates are preserved; `backup-prune` is retired |

Defaults are starting points, not universal retention policy. The site owner must set periods that
meet regulatory, evidentiary, privacy, legal-hold, and capacity requirements.

## Observation lifecycle

### 1. Hot ingestion

An accepted observation receives a sequential OSH internal ID. Its mutable result block is
serialized immediately, then queued for a bounded prepared-statement batch. The standard profile
flushes every second or at 10,000 observations. Until a successful flush, the observation is
not durable in PostgreSQL; a failed batch remains queued for a later commit attempt.

The hot store remains authoritative for systems, datastream metadata, recent observations, event
records, occupancy/alarm workflows, adjudications, and reports. Parquet is the primary cold tier,
not a backup, and only output names listed in
`archive.outputNames` are eligible for cold tiering. The 3.9.2 default list is:

```text
gammaCounts
gammaThreshold
neutronCounts
setupGamma
setupNeutron
```

Occupancy/event records and the `dailyFile` compatibility stream are intentionally absent. OSCAR
does not cold-tier every table or every observation stream.

### 2. Non-disruptive archive export

The database's archive worker runs at `intervalMinutes` (60 by default). It computes a cutoff of
`now - hotRetentionDays`, truncated to a UTC hour, then finds the oldest eligible row whose
`archivegenerationid` is still null. This lookup includes late arrivals; it is not based only on the
last completed generation. A catch-up cycle starts at most `maximumGenerationsPerCycle` (24) and
stops starting new generations after `maximumCycleMinutes` (15); in-progress publication is
allowed to complete safely.

The worker is independent of the ingestion thread: it runs once immediately at module startup and
then at the configured interval. New observations remain cheap hot-journal writes and are not
individually converted to Parquet before they become age-eligible. The worker selects a half-open
UTC hour `[start, end)`. It uses a PostgreSQL read-only
`REPEATABLE READ` snapshot and a 5,000-row fetch size while flushing explicitly cleared 500-row
inserts into embedded DuckDB. Live inserts continue. Rows are ordered by `(phenomenontime, id)` and
the exporter publishes the largest deterministic prefix permitted by the configured row cap and
the effective byte cap. The effective byte cap is the lower of the operator setting and one eighth
of DuckDB session memory—32 MiB with the standard 256 MiB session—leaving room for table pages,
sort keys, compression, and Parquet buffers. Remaining unowned rows become normal same-hour job
revisions, so a restart resumes safely without tiny time slices or duplicate ownership. A single
row larger than the effective cap fails closed and remains hot for operator action.

On upgrade, the worker first reclaims the exact window of any latest-revision `FAILED` job or
two-hour-stale `EXPORTING` job that is wholly older than the cutoff. This includes sub-hour windows
created by the former time-bisection scheduler, preventing a successful replacement full-hour
archive from leaving an obsolete failed job in health reports.
If such a reclaimed window no longer has any eligible unowned rows, its attempt becomes
`SUPERSEDED` with an audit detail instead of remaining `FAILED`; later windows can continue.

The exporter and every other archive-side DuckDB operation use the configured memory, thread, and
temporary-space caps. Larger sorts or joins spill only into an operation-private directory, which
is removed after its connection closes. A fair process-wide gate admits no more than two sessions
by default; a waiter fails busy after 30 seconds before opening DuckDB or allocating scratch.
Exhausting admission, memory, or spill fails the operation without activating a generation or
deleting hot rows.

Publication order is:

1. Write and verify `generation-<uuid>.parquet`.
2. Write `generation-<uuid>.schemas.json.gz` from the same database snapshot.
3. Write `generation-<uuid>.manifest.json` last.
4. In one PostgreSQL transaction, mark the exact still-unowned rows with the generation UUID,
   require the marked row count to match the manifest, insert generation/object/schema catalog
   records, and move the job to `ACTIVE`.

The expensive snapshot read and Parquet/schema/manifest work occurs before the activation critical
section. Activation then takes an exclusive transaction-scoped advisory lock for that exact
store/scope and rechecks every exported row predicate while assigning ownership. Observation
inserts, updates, removals, overlays, tombstones, and lifecycle hot-row deletion take the shared
form of the store lock plus per-observation locks in ascending ID order. This fixed ordering prevents
an activation from racing a logical mutation without holding live ingestion behind file encoding.

If any step fails, partial objects are removed where possible, the job becomes `FAILED`, and the hot
rows remain. A failed or stale export job can be retried. A generation is not query-visible until
catalog activation succeeds.

### 3. Mixed-tier reads and mutations

While a generation is `ACTIVE`, the same logical observation can exist in PostgreSQL and Parquet.
Queries read both eligible tiers, de-duplicate by OSH ID, and prefer the PostgreSQL copy. Time,
datastream, feature-of-interest, internal-ID, ordering, latest-value, limit, CQL, and value filters
are applied without changing public IDs.

Parquet is immutable. An update to an already archived observation is written to
`oscar_obs_overlay`; a removal writes an `oscar_tombstone`. Reads apply the overlay or hide the
tombstoned row. This avoids rewriting a large generation for a one-row change. These mutation
tables must therefore be protected and backed up with PostgreSQL.

Logical removal participates in the retention protocol. After the shared store and ordered
observation mutation locks are held, the same PostgreSQL transaction takes a shared lock on the
hold table and resolves exact observation holds plus generation holds for only the requested IDs'
candidate archive ranges. A single held removal fails visibly. A filtered bulk removal skips held
rows, removes other matching rows, and reports only successful removals. A hold created in the
former select/delete race window therefore commits before the shared lock and is observed, or
waits until the removal commits; it cannot be silently bypassed by a hot delete or tombstone.

Observation ingestion uses the same logical identity as the OSH reference store: datastream,
feature of interest, phenomenon time, and result time. Replaying the same value is idempotent; a
different value at that identity is a last-write-wins correction that keeps the original public
observation ID. During archive grace the immutable hot parity row is left unchanged and the
correction is written transactionally to its generation-owned overlay. After hot deletion, a
bounded cold lookup resolves that same stable ID and still writes only the overlay, so a replay
cannot create a second hot observation beside the archived row.

The sequential allocator initializes from both the hot observation table and the maximum cataloged
archive ID for the exact store/scope. Catalog generations remain durable through sealing and purge,
so a restart cannot reuse a public OSH observation ID merely because its hot row was deleted.

### 4. Parity and optional hot deletion

The lifecycle worker checks unverified active generations. It re-hashes the Parquet object, reads
its rows in ID order, loads the exact hot IDs in bounded batches, and compares canonical row
digests. The receipt records expected/actual rows and success or failure. A failed receipt leaves
all hot data in place.

The shipped 3.9.2 profile sets `deleteHotAfterArchive=true`. A generation becomes hot-deletion
eligible only after:

- a successful `HOT_COLD_PARITY` receipt;
- `rollbackGraceDays` since activation (one day by default); and
- no active generation hold.

Together with the two-day archive threshold, this produces roughly 72 hours of hot residency plus
hourly scheduling and processing time. Deletion uses exact IDs from the verified Parquet object in transactions of `deleteBatchSize`
(5,000 by default) and additionally requires each PostgreSQL row's `archivegenerationid` to equal
that generation. Observation-specific holds are skipped. If held rows remain, the generation stays
`ACTIVE` and receives a deferred-hold receipt; a later cycle retries. It becomes `SEALED` only after
all exact generation rows are absent from the hot table. Each deletion batch participates in the
same shared-store/ordered-ID locking protocol, and sealing takes the exclusive store lock after the
batches finish, so a concurrent logical update or removal cannot fall between base-row deletion and
the generation state transition.

### 5. Cold-generation deletion

OSCAR does not age cold archive objects out automatically. An administrator uses the two-step
deletion flow documented under [Delete old cold generations](STORAGE_OPERATIONS.md#delete-old-cold-generations):

1. `archive dry-run` freezes the current set of eligible `SEALED` generations before a UTC cutoff,
   computes estimated rows/bytes/holds, and emits a random confirmation token once. The plan
   expires after 24 hours.
2. `archive purge` accepts only the matching plan and token, briefly stops only a previously running
   OSCAR service, and preflights every relative path and SHA-256 through a networkless, read-only
   one-shot helper that sees only the archive mount. It always attempts to resume OSCAR's prior
   state and does not report that resume complete until OSCAR's top-level auto-start services are
   started and each RPM/camera member nested under a lane has completed its startup attempt. An
   unavailable device may settle offline while OSCAR remains usable to report that state. This
   application-readiness barrier prevents a following administrative command from
   stopping a partially initialized node. Purge rechecks holds under the same database lock used
   by hold creation. One transaction
   moves every selected generation and object to durable `DELETING` state, making the entire
   generation non-queryable before filesystem removal begins. It then revalidates and deletes each
   object through the helper with archive write access and records `DELETED` or the crash-recovery
   result `ALREADY_ABSENT`. If interrupted, the same confirmed plan/token resumes generations and
   objects already in `DELETING` rather than creating an unreviewed selection.

Generation and object catalog rows remain with `PURGED`/`DELETED` state, along with a generation
tombstone and deletion ledger. This retained metadata is the audit trail that distinguishes a policy
removal from an unexplained missing object. Once that state is committed, sparse observation
overlays and observation tombstones explicitly owned by the purged generation are deleted in the
same final transaction; they are no longer queryable and otherwise would grow forever. A legacy
mutation without exact generation ownership is preserved for reviewed migration rather than being
guessed from a possibly gapped/overlapping ID range. The generation
tombstone, generation/object catalog, and deletion ledger are preserved. Purged generations are no
longer query candidates. Do not remove archive files directly with Explorer, Finder, `rm`, or a
storage-array lifecycle rule; that creates integrity failures instead of an auditable deletion.

`archive export` instead makes an independent portable copy of selected `ACTIVE` or `SEALED`
generations. Its catalog, explicit object list, checksums, and bundled DuckDB query make that package
queryable outside OSCAR, but the export is not live OSCAR storage and is not a coordinated backup.

## Daily-file lifecycle

### Capture

Each configured lane opens a writer in the Daily File Journal service. The journal client defaults
to `enabled=true`, `required=true`, and a 10-second service startup timeout. Records are appended in
lane order before parsing can discard malformed Rapiscan/RS350 input; Aspect records are appended
after the register snapshot is rendered.

An `.open` segment is forced after any of these defaults:

- 1,000 milliseconds;
- 128 records; or
- 1 MiB of framed data.

It rotates at 64 MiB or 15 minutes. The active segment and ledger are also forced at orderly close.
The durability interval is a maximum exposure window to sudden power loss, not permission to lose
or skip input after an I/O error.

### Recovery and day rollover

Startup validates the journal root and metadata without synchronously re-rendering the complete
historical backlog. Before a lane accepts its first new append, its current open segment is scanned
and any incomplete final frame is truncated to the last CRC-valid boundary. A complete frame with
an invalid length, timestamp, or CRC is reported as corruption and prevents silent continuation.
Older completed days and interrupted deletions are recovered in a bounded 16-lane/day-per-minute
background pass. This pass also handles older days for actively receiving lanes without holding the
live writer lock while a large CSV is rendered. Already complete ledger/manifest/CSV publications
take a metadata fast path and are not regenerated on each restart.

Dates are assigned using the configured IANA `zoneId` (UTC in the standard profile). Each daily
window is permanently recorded as `[startInclusive, endExclusive)`, so daylight-saving boundaries
are unambiguous. Completed days are sealed and rendered in journal order to the legacy headerless
CSV syntax. The data file is forced and atomically renamed, followed by its
`.manifest.v1.json`; the ledger is marked `PUBLISHED` last.

The manifest contains the lane UID, zone, immutable time window, record count, byte count,
filename, publication time, and SHA-256. Existing output is accepted only if it matches the
recovered journal; a conflicting immutable CSV or manifest is not overwritten.

### Compatibility observation cleanup

`dailyFileObservationMode` controls only the legacy OSH compatibility stream:

- `FULL` publishes every compatibility observation and uses manifest-gated completed-day cleanup.
- `LATEST` is the production compatibility label; it publishes the same live events and uses the
  same safe completed-day cleanup. It does not discard rows from the unsealed current day merely to
  retain one value.
- `NONE` disables compatibility observations but does not disable the durable journal.

The 3.9.2 standard profile uses `LATEST`. The lane system consumes each live `dailyFile` event to
derive occupancy transitions, so `NONE` would disable a required operational input. `LATEST` keeps
that live stream and registered datastream. The compatibility table contains the current unsealed
local day plus any manifest-blocked backlog; the journal and immutable daily CSV are the
authoritative history. This mode does not eliminate the initial PostgreSQL/WAL write because OSH
currently couples live event delivery with observation persistence.

OSCAR's completed-day cleanup validates the corresponding journal ledger,
manifest, CSV, window, and current checksum before it authorizes daily-file compatibility cleanup.
The exact-midnight pass is only an initial bounded attempt. If publication for a lane is still in
progress, no row or checkpoint is changed; the same oldest-first catch-up runs on every hourly
maintenance pass and retries it. `dailyFilePurgeWorkLimit` bounds each midnight or hourly invocation
to 50 lane/day attempts in the standard profile, so a multi-day backlog converges over successive
hours without an unbounded maintenance pass. Failures in other hourly purge phases are isolated and
cannot suppress this retry.
Setting `delegateObservationLifecycleToDatabase=true` delegates high-volume detector retention to
the tiered database; it does not disable daily-file or connection-status maintenance.

### Sealed-segment deletion gate

A published CSV is not by itself permission to remove the private sealed journal that produced it.
The standard `requireBackupBeforeSealedJournalDeletion=false` policy keeps managed backup optional
without allowing the private duplicate source to grow forever. After
`sealedJournalRetentionDays` (30 by default) from the later of day close or actual publication,
OSCAR validates the immutable CSV, manifest, and `PUBLISHED` ledger, freezes the candidate day, and
replays every sealed segment. The rendered byte count and SHA-256 must exactly match the published
CSV. A late, missing, corrupt, linked, open, or otherwise unsafe segment blocks deletion. Lifecycle
discovery and processing are durably queued and bounded, so neither startup nor a one-minute
maintenance cycle traverses the entire retained history.

A site may set `requireBackupBeforeSealedJournalDeletion=true`. In that stronger mode, creation of
an optional coordinated snapshot keeps the application stopped through authenticated checksum,
archive-member, and PostgreSQL verification. OSCAR records backup confirmation only when that
accepted snapshot contains the exact CSV, manifest, and sealed-segment inventory and the live
publication still matches. The receipt is bound to the backup ID and authenticated
`oscar-state.tar.gz` SHA-256. Manual `backup-verify` does not create receipts or change `CURRENT`.

## Media lifecycle

### Source recording

Camera recordings continue to be referenced by the occupancy observation's `videoPaths` value.
The v1 retained-media representation is additive, so old clients and old events remain readable.

For new recordings, a bounded FIFO serializes start, close, and cancel commands independently for
each camera. A successful start owns one generation-qualified source path,
`videos/clips/<camera-token>/<timestamp>-g<generation>.mp4`. The validated close return value is the only
authoritative path eligible for the occupancy; OSCAR does not associate a recording by directory
order, timestamp proximity, or a mutable camera filename. Publication requires an exact match for
the owning event, lane, camera, and generation, plus a nonblank, unique, finalized, nonzero MP4.

Non-alarm occupancies cancel and remove their unpublished recordings. If a close or cancel times
out, the affected camera queue is quarantined from later recording work while the underlying result
remains observed. A validated result that arrives after invalidation is removed, including its
partial output, so it cannot become an orphan or be attached to a subsequent event. Reconnects and
listener changes are generation-gated and use race-safe collections to keep callbacks with their
original occupancy.

### Five-frame publication

With the standard `timeToRetention=0`, each completed camera source is immediately eligible; the
sliding retention query processes it asynchronously on a retention cycle (every five minutes by default). It decodes the clip twice: first to construct the frame timeline, then to capture the five
selected distinct ordinals. A valid set contains:

1. first frame;
2. nearest distinct frame to 25 percent of the decoded timeline;
3. nearest distinct frame to 50 percent;
4. nearest distinct frame to 75 percent; and
5. last frame.

Every JPEG is written to a partial, forced, checked for complete JPEG markers and baseline SOF0,
decoded independently, and checked for opaque sRGB dimensions. The five frames are published before
the manifest. The manifest records source and asset hashes, byte counts, dimensions, codec, timing,
selected ordinals, lifecycle states, and rollback deadline. A durable per-identity job ledger makes
retries idempotent.

Before committing the manifest, OSCAR reserves independent direct-addressed catalog-reconciliation
and pressure-queue slots. The cyclic reconciliation worker freezes the queue tail and processes only
its configured share of `maintenanceWorkLimit`, so lifecycle/ledger repair remains restart-safe and
does not enumerate the retained-media tree. A pre-manifest crash leaves only a stale slot that the
worker discards; a post-manifest crash always leaves durable repair work.

New OSCAR-managed alarm clips receive a bounded post-roll until five video packets have been
muxed. The source is never deleted on the creation attempt. Any error, including a legacy or
externally supplied clip with fewer than five decoded frames, preserves the source and records a
failed job. After successful publication the source is
`PRESERVED_FOR_ROLLBACK` for `sourceRollbackGraceHours` (24 by default). A subsequent retention pass
re-verifies the set and, if no hold applies, advances through `ELIGIBLE_FOR_DELETION` to `DELETED`.

The standard worker runs every five minutes and advances the primary cursor by at most six hours of
event time per cycle. A separate delayed cursor revisits event time only after the 24-hour
late-arrival allowance, runs at most every six hours, and advances at most two hours per cycle. A
restart-resumable historical sweep handles older delayed records in 24-hour chunks and repeats
daily. Occupancy datastream IDs are cached for 15 minutes. These durable, bounded paths prevent a
late or previously uncatalogued clip from being skipped without restoring an all-history scan.

### Recording and retained-media regression gate

Release acceptance must create fresh alarm and non-alarm occupancies rather than validating only
pre-existing files. For every alarm, the suite resolves the exact event UUID and configured camera
UIDs, then requires one unique, nonblank generation-qualified source per camera, verifies that each
MP4 exists, is nonzero, and decodes with valid duration and dimensions, and rejects any new orphan
final or partial file. A non-alarm recording must leave no source behind. Back-to-back alarms and a
camera reconnect must preserve exact event/lane/camera ownership.

After the test-only retention interval elapses, acceptance requires one complete manifest per source
with exactly five independently decodable JPEGs, matching source identity and event/lane/camera
ledger fields, one successful attempt, and no failure record. The shipped production defaults are
one retention day and a five-minute query cadence; qualification may use an accelerated profile on
an isolated disposable site but must still prove the same five-frame and 24-hour source-grace
contracts.

The retained-media worker captures this profile when OSCAR starts. On a newly initialized
qualification site, save the accelerated profile and perform a supported OSCAR restart **before**
importing lanes or permitting emulator traffic. Verify the startup log and scan checkpoint use the
new eligible-through cutoff, then provision the lanes and perform the fixture's supported restart.
Saving the form alone does not reconfigure an already running worker. A checkpoint created under
an older profile deliberately resumes from its durable cursor instead of jumping over
unexamined history. Never delete or fast-forward a scan or reconciliation checkpoint to accelerate
a test. If a disposable site was initialized in the wrong order, recreate its disposable database
and state, or allow bounded oldest-first catch-up. Production requires catch-up or a reviewed
migration procedure.

### Viewer behavior

The Viewer requests the authenticated read-only event endpoint under
`/buckets/videos/media/{eventId}`. A returned media set is shown as five labeled still frames per
camera. Streaming validation caps the catalog body at 1 MiB, the response at eight cameras, each
frame at 12 MiB and 20 megapixels, either dimension at 6,000 pixels, and the event at 64 MiB and
120 megapixels. A frame body is stopped as soon as it exceeds its manifest byte count, even without
a valid `Content-Length`. Only the currently selected
frame for each camera is fetched, with at most three event-wide frame requests in flight. A `404`
means no retained-media v1 set exists, so the Viewer uses the unchanged legacy `videoPaths`
playback path. Invalid or missing retained assets are not served as successful images.

### Storage pressure

The pressure worker checks the filesystem every minute. At 85 percent used, it consumes eligible
complete media sets from a durable publication-order queue until usage reaches 80 percent. A set
must be at least 10 minutes old, outside rollback grace, and not held. Each cycle inspects at most
`maximumMediaSetsPerCycle` entries (200 by default), and the durable head resumes after restart.
No pressure cycle enumerates or sorts the retained-media tree. A selected set is marked `DELETING`,
assets and any remaining source are removed, and the manifest commit marker is removed last so an
interrupted pass can retry.

Pressure cleanup does **not** scan arbitrary files. It does not delete uncatalogued legacy videos,
daily CSVs/journals, adjudication data, reports, or Parquet generations. If no eligible retained
media can reach the target, OSCAR logs an error and preserves protected data.

## Holds, overlays, tombstones, and audit records

The archive catalog includes these control records:

| Record | Purpose |
| --- | --- |
| `oscar_retention_hold` | Prevent physical and logical generation/observation deletion while active; persist exact vs conservative resolution provenance |
| `oscar_obs_overlay` | Current value of a mutation to an immutable archived observation |
| `oscar_tombstone` | Suppress a policy/user-deleted observation without rewriting Parquet |
| `oscar_archive_verification` | Immutable history of parity, deletion, and deferred-hold receipts |
| `oscar_deletion_plan` / `_item` | Frozen, expiring set reviewed for cold deletion |
| `oscar_deletion_ledger` | Per-object deletion outcome retained after file removal |
| `oscar_backup_epoch` | PostgreSQL link to a coordinated backup manifest and the count/bytes/SHA-256 receipt for its authenticated archive-generation inventory; the exact UUID set remains in the backup |

The release CLI can list, create, and release generation or exact-observation holds. Creation
requires a generation UUID or numeric observation ID plus a reason; release records the actor and
time without deleting the hold row. Use the commands in
[Storage operations](STORAGE_OPERATIONS.md#manage-retention-holds) only as part of the site's
approved legal/records workflow. An exact extant hot row takes precedence over unrelated coarse
archive ID ranges; cold-only overlapping queryable and retired ranges remain fail-closed, and a
tombstone always prevents a new hold. Directly editing these tables can make retention results
incorrect.

New holds persist `GENERATION_EXACT`, `HOT_EXACT`, or `COLD_RANGE_CONSERVATIVE`. The conservative
mode means a cold-only ID was covered by a candidate generation's min/max block; because sparse
Parquet IDs may leave gaps, it protects the range but is not evidence that the exact observation
exists. A migrated pre-3.9.2 observation hold is labeled `LEGACY_UNKNOWN`: its historical exact-vs-
range provenance cannot be reconstructed, so it remains protective but must not be cited as proof
that an exact observation existed. Confirm the event or use an explicit generation hold when legal
certainty is required.

## Policy changes

Before shortening any period or enabling a deletion flag:

1. Record the business owner, reason, and effective date.
2. Check active legal/investigative holds.
3. Take and verify a coordinated backup.
4. Run mixed-tier queries and archive integrity verification.
5. Perform a deletion dry run and review counts, bytes, and held generations.
6. Change one policy at a time and monitor at least one complete lifecycle interval.
7. Record the resulting verification/deletion receipts with the change ticket.

Changing an archive period does not retroactively make manually copied exports disappear. Track and
dispose of every external copy under the same policy.
