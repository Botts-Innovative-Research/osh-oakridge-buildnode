# OSCAR 3.11.0 cold archive format

OSCAR's cold observation tier is a portable set of ZSTD-compressed Parquet files, JSON manifests,
gzip-compressed datastream schema snapshots, and a PostgreSQL catalog. OSCAR uses the catalog for
safe online queries and lifecycle decisions; exported generations can be inspected independently
with DuckDB or another Parquet-capable tool. This is the primary cold tier for the configured five
high-volume output names, not a backup and not an export of every PostgreSQL table. A recoverable
system snapshot must also include the matching catalog, overlays/tombstones, application state, and
other coordinated payloads.

See [Storage architecture](STORAGE_ARCHITECTURE.md) for the system context and
[Storage operations](STORAGE_OPERATIONS.md) for the supported verification, export, and deletion
commands.

## On-disk layout

All paths stored in the catalog and manifests are relative to the configured archive root. The
standard container root is `/var/lib/oscar/archive`, backed by `${OSCAR_ARCHIVE_DIR}` on the host.

```text
archive-root/
  .oscar-storage-root
  datasets/
    observations/
      date=YYYY-MM-DD/
        profile=RAW_GATED/
          generation-<uuid>.parquet
          generation-<uuid>.schemas.json.gz
          generation-<uuid>.manifest.json
```

The `date=` and `profile=` directories are Hive-style partitions. The date is the UTC date of the
generation window start. The standard profile name is `RAW_GATED`.

`.oscar-storage-root` is host-local administrator metadata, not an archive object. It is validated
and authenticated before live archive commands, then recognized only at that exact root-level name
so catalog orphan reconciliation can exclude it. It is also excluded from coordinated backup tar
payloads and preserved across restore. It must never be copied from a source deployment to claim a
target root; nested or similarly named files receive no exemption from archive-layout validation.

Do not infer query authorization from directory names or a file's presence. OSCAR reads only
objects whose generation is `ACTIVE` or `SEALED` in PostgreSQL and whose resolved path stays under
the configured root.

## Parquet schema

Format version 1 uses these columns:

| Column | Type | Meaning |
| --- | --- | --- |
| `id_scope` | `INTEGER` | OSH scope for the observation ID |
| `id_value` | `BIGINT` | Stable sequential observation ID value |
| `datastream_scope` | `INTEGER` | OSH scope for the datastream ID |
| `datastream_id` | `BIGINT` | Stable datastream ID value |
| `foi_scope` | nullable `INTEGER` | OSH scope for the feature-of-interest ID |
| `foi_id` | nullable `BIGINT` | Feature-of-interest ID value |
| `phenomenon_time` | `TIMESTAMP` | Observation phenomenon time |
| `result_time` | `TIMESTAMP` | Observation result time |
| `result_json` | `VARCHAR` | OSH result block serialized against its datastream schema |
| `archive_version` | `INTEGER` | Row format version; currently `1` |
| `profile` | `VARCHAR` | Archive selection profile; normally `RAW_GATED` |

Rows are written in this order:

```text
datastream_id, phenomenon_time, result_time, id_value
```

DuckDB writes ZSTD-compressed Parquet with a row-group target of 122,880 rows. Sorting and the
Hive-style date partition allow Parquet min/max metadata and path selection to avoid scanning
unrelated time/datastream ranges.

A busy UTC-aligned staging window may be represented by several immutable generations with the same catalog window.
Each generation contains the next deterministic `(phenomenon_time, id_value)` prefix that fits the
bounded export budget; later prefixes use normal job revisions. Catalog ownership remains exact per
observation, so combined staging/cold reads and portable exports do not duplicate rows.

`result_json` is not a self-describing replacement for the OSH schema. Keep the matching schema
snapshot whenever a Parquet object is copied.

## Datastream schema snapshot

`generation-<uuid>.schemas.json.gz` is gzip-compressed UTF-8 JSON:

```json
{
  "format": "oscar-datastream-schema-snapshot",
  "version": 1,
  "schemas": [
    {
      "dataStreamId": 123,
      "json": "{...serialized OSH IDataStreamInfo...}"
    }
  ]
}
```

The schemas are loaded in the same PostgreSQL repeatable-read transaction as the observations. The
manifest lists their datastream IDs and the snapshot's path, SHA-256, byte count, and gzip
compression. OSCAR normally uses the live datastream schema; it falls back to this snapshot if the
live record is unavailable.

## Generation manifest

`generation-<uuid>.manifest.json` is UTF-8 JSON and is published after the Parquet and schema
objects. Its format is `oscar-observation-archive`, version `1`. A representative shape is:

```json
{
  "format": "oscar-observation-archive",
  "version": 1,
  "generationId": "00000000-0000-4000-8000-000000000000",
  "profile": "RAW_GATED",
  "windowStart": "2026-10-01T00:00:00Z",
  "windowEnd": "2026-10-01T01:00:00Z",
  "object": "datasets/observations/date=2026-10-01/profile=RAW_GATED/generation-....parquet",
  "sha256": "<lowercase SHA-256>",
  "bytes": 123456,
  "rowCount": 10000,
  "minimumId": 200000,
  "maximumId": 219999,
  "idScope": 4,
  "datastreamSchemaIds": [123, 124],
  "datastreamSchemas": {
    "object": "datasets/observations/date=2026-10-01/profile=RAW_GATED/generation-....schemas.json.gz",
    "sha256": "<lowercase SHA-256>",
    "bytes": 2345,
    "compression": "gzip"
  },
  "columns": ["id_scope:INTEGER", "..."],
  "sort": ["datastream_id", "phenomenon_time", "result_time", "id_value"],
  "compression": "zstd",
  "createdAt": "2026-10-17T12:34:56Z"
}
```

The actual UUID, IDs, counts, paths, timestamps, and digest replace the example values. Time windows
are half-open: `windowStart <= phenomenon_time < windowEnd`.

The manifest is a file-level commit marker, but online activation also requires the matching
PostgreSQL catalog transaction. A copied manifest must not be inserted into the catalog by hand.

## PostgreSQL catalog

The catalog migration is versioned in `oscar_storage_schema_version`. Its operational tables are:

The binary verifies the exact checksum of every recorded schema-version marker and refuses to open a
catalog with a higher recorded version. When a v4 marker is present, the v4-to-v5 upgrade verifies
that marker before applying any v5 DDL. This authenticates the declared migration lineage; it is not
a checksum of the live v4 table definitions. The transactional migration and its constraints validate
the live shape they consume, while a legacy catalog with no v4 marker follows the explicitly supported
marker-bootstrap path.
In-place storage-schema downgrade is unsupported: restore a coordinated backup into an isolated
deployment running the matching release rather than starting older code on a newer catalog.

| Table | Role |
| --- | --- |
| `oscar_archive_job` | Export attempts, revision, state, error, and two-hour stale-job recovery |
| `oscar_archive_generation` | Window, profile, object/manifest paths, Parquet hash, ID range, state, parity flag |
| `oscar_archive_object` | Every generation object, kind, relative path, SHA-256, bytes, and lifecycle state |
| `oscar_archive_id_block` | Generation ID range used to plan exact-ID lookups |
| `oscar_archive_schema` | PostgreSQL copy of each generation's datastream schemas |
| `oscar_obs_storage_route` | Stable mutable-versus-immutable classification for each observed datastream |
| `oscar_obs_stage_partition` | Attached/detached catalog for short-lived LOGGED Parquet-primary staging children |
| `oscar_obs_stage_owner` | Compact exact row-to-generation ownership while a staging child still overlaps Parquet; removed with the child |
| `oscar_event_locator` | Stable public-event to observation/generation locator reserved for direct lookup |
| `oscar_obs_overlay` | Mutable value for an updated immutable archived observation |
| `oscar_tombstone` | Logical removal of an immutable archived observation |
| `oscar_retention_hold` | Active/released generation or observation holds |
| `oscar_archive_verification` | Parity plus primary-stage retirement or compatibility hot-deletion receipts |
| `oscar_deletion_plan` / `oscar_deletion_plan_item` | Frozen, expiring cold-deletion selection |
| `oscar_deletion_ledger` | Per-object deletion audit trail |
| `oscar_media_manifest` / `oscar_media_asset` | Reserved structured media catalog records |
| `oscar_backup_epoch` | Link between a coordinated backup manifest and the bounded count, byte length, and SHA-256 receipt for its authenticated active/sealed-generation inventory; exact UUIDs stay in the backup file rather than a per-backup PostgreSQL array |

Archive-job state `SUPERSEDED` is an audited terminal no-op used when a reclaimed failed/stale
window contains no eligible unowned rows. It has no generation and is never query-visible.

Generation states used by the observation reader/lifecycle are:

```text
EXPORTING job --> ACTIVE generation --> SEALED generation --> DELETING generation --> PURGED generation
         `----> FAILED job
```

- `ACTIVE`: files are queryable and a verified PostgreSQL overlap can still exist.
- `SEALED`: parity passed and the corresponding Parquet-primary stage child has been
  dropped (or, in `HOT_RETENTION`, its exact hot rows were deleted); files remain queryable.
- `DELETING`: a confirmed purge transaction made the entire generation non-queryable and persisted
  deletion intent before the first file removal. Re-running the same plan/token resumes it.
- `PURGED`: an approved cold-deletion plan removed the objects; it is not queryable.

Object rows transition from `ACTIVE` to durable `DELETING` intent and then `DELETED`. The
intermediate state makes a confirmed purge restartable with the same plan/token after interruption.
Catalog, generation tombstone, and deletion-ledger rows remain after a purge so policy deletion is
auditable. Observation overlays and observation tombstones carrying that exact generation ID are
removed only in the final `PURGED` transaction because they no longer have a queryable target;
legacy unowned mutations are not guessed from ID ranges. The
generation tombstone and audit rows are not removed.

Hold creation/release and the purge visibility transition take the same PostgreSQL table lock. A
hold either commits first and excludes the generation, or the purge commits `DELETING` first and a
new hold is rejected; there is no interval in which a successful hold can race a file deletion.

## Integrity and atomicity

For each generation, OSCAR:

1. runs the source query in a read-only PostgreSQL `REPEATABLE READ` transaction;
2. verifies Parquet count, minimum ID, and maximum ID by reopening it in DuckDB;
3. forces each data object before publication;
4. publishes the manifest last;
5. records SHA-256 and bytes for Parquet, schema snapshot, and manifest in PostgreSQL;
6. marks exact source rows and activates the catalog in one PostgreSQL transaction; and
7. verifies the Parquet SHA-256 again before its first read in each OSCAR process.

The supported `archive verify` command additionally proves catalog completeness: every
query-visible (`ACTIVE` or `SEALED`) generation must have exactly one active Parquet object, one
active generation manifest, and one active datastream-schema snapshot, each with a confined path
and matching SHA-256. The required Parquet object's path and checksum must equal the generation's
authoritative `object_path` and `sha256`, and the manifest object's path must equal
`manifest_path`; verification hashes that exact file. It does not treat an absent object row—or a
stale generation pointer—as an empty successful verification. Verification reads one canonical
catalog snapshot before the file checks and requires the same snapshot afterward, so live archive
activation or purge makes the command fail/retry rather than report a mixed-time success.
The same snapshot verifies exactly one `oscar_archive_id_block` per query-visible generation, with
`min_id`/`max_id` equal to the generation bounds, and requires at least one matching
`oscar_archive_schema` row. This detects relational-catalog damage even when all three immutable
files and their checksums remain intact.

All embedded DuckDB work is resource bounded. Production defaults limit each connection to 256 MiB
of memory, two threads, and 4 GiB of spill in a private per-operation directory under
`/var/lib/oscar/duckdb-tmp`. A fair process-wide gate admits at most two sessions and fails a waiter
busy after 30 seconds, bounding the aggregate resource multiplier across exports, verification,
deletion, and cold queries. OSCAR rejects archive/scratch root overlap and, on POSIX, rejects an
existing scratch parent unless it is mode `0700`; the Linux deployment container provides the same
protection on Ubuntu and Windows hosts. A persistent `.oscar-duckdb.lock` lease (a real regular file,
mode `0600`) is held for the owning process/classloader lifetime. It prevents a concurrent owner
from cleaning live spill. On its first successful open, an owner holding the lease automatically
removes only recognized direct `<operation>-<lowercase UUID>` children abandoned by a prior owner;
unrelated entries and links are preserved. Normal operation children are closed and removed per
operation, while the lease remains until process shutdown. The entire scratch parent, including the
lease, is excluded from the portable archive and coordinated backup. Streaming reads cooperate with
shutdown between result rows in addition to cancelling the active JDBC statement.

Object publication and PostgreSQL activation cannot be one filesystem/database transaction. A file
that exists without an `ACTIVE`/`DELETING` catalog object is intentionally invisible and is reported
as an orphan by `archive status` and `archive verify`; a file whose catalog row is already `DELETED`
is also an error. A `.partial` is reported while it is younger than the two-hour stale-job window
and fails verification once stale. Reconciliation is report-only and never auto-deletes. A
cataloged object that is missing or has the wrong digest is an integrity incident; the reader fails
rather than silently returning an incomplete result.

The standard filesystem should support durable file force and rename semantics. Parquet publication
prefers an atomic move and falls back to a same-filesystem move when the Java platform reports that
atomic moves are unsupported. Keep a generation's objects on one reliable filesystem and never
write an archive directly onto a lossy synchronization directory.

## Querying a portable copy with DuckDB

First export a generation with the supported OSCAR command. Ubuntu:

```sh
sudo bash oscar.sh archive export \
  --store-key <store-key> \
  --id-scope <id-scope> \
  --generation 00000000-0000-4000-8000-000000000000 \
  --destination /secure/export/oscar-generation
```

Windows:

```powershell
.\oscar.bat archive export `
  -StoreKey <store-key> `
  -IdScope <id-scope> `
  -Generation 00000000-0000-4000-8000-000000000000 `
  -Destination D:\secure-export\oscar-generation
```

The destination must be a new directory. The command briefly stops only OSCAR when it was already
running and always attempts to resume it. A networkless, read-only-rootfs one-shot OSCAR-image
helper receives only the archive root read-only plus the fresh hidden export partial writable. It
revalidates every path component/no-link condition, verifies each source checksum, copies the object,
and verifies the copy. OSCAR preserves the catalog-relative `datasets/...` path and then renames the
complete package into place. It adds:

- `catalog-<generation-id>.json` with generation provenance;
- `objects-<generation-id>.json` with object paths, kinds, hashes, bytes, and states;
- `README.md` with portable-use instructions;
- `query.sql` ready for `duckdb < query.sql`; and
- `SHA256SUMS` covering every other package file.

Verify the online archive before export with `archive verify`, then verify `SHA256SUMS` after every
copy of the portable package.

From the export directory, DuckDB can query one file:

```sql
SELECT
    id_scope,
    id_value,
    datastream_id,
    phenomenon_time,
    result_json
FROM read_parquet(
    'datasets/observations/date=2026-10-01/profile=RAW_GATED/generation-<uuid>.parquet'
)
WHERE datastream_id = 123
  AND phenomenon_time >= TIMESTAMP '2026-10-01 00:15:00'
  AND phenomenon_time <  TIMESTAMP '2026-10-01 00:30:00'
ORDER BY phenomenon_time, id_value;
```

Or search a copied archive tree with partition discovery:

```sql
SELECT
    date,
    profile,
    datastream_id,
    min(phenomenon_time) AS first_sample,
    max(phenomenon_time) AS last_sample,
    count(*) AS samples
FROM read_parquet(
    'datasets/observations/date=*/profile=*/*.parquet',
    hive_partitioning = true,
    union_by_name = true
)
GROUP BY ALL
ORDER BY date, profile, datastream_id;
```

Treat `result_json` according to the corresponding serialized OSH datastream schema. For ad hoc
inspection, DuckDB JSON functions can extract known fields, but schema-aware tools should load the
`.schemas.json.gz` file rather than guess names or types.

## Copying and reviewing archives

Portable review does not require a running OSCAR installation. The supported export command copies
these as one unit:

- the Parquet object;
- its generation manifest;
- its gzip schema snapshot;
- the generation and object catalog JSON files;
- the generated README and DuckDB query; and
- the generated `SHA256SUMS` list.

Encrypt removable media and verify its checksums both after the copy and before review. Relative
paths make a complete archive tree relocatable, but an arbitrary copy is not automatically
registered as live OSCAR storage. Restoring OSCAR requires the coordinated PostgreSQL catalog and
archive copy described in [Backup and restore](BACKUP_RESTORE.md).

An external analyst can delete or reorganize an independent exported copy without changing the
running system. To delete the running system's oldest cold data without breaking queries, use the
tokenized `archive dry-run` and `archive purge` workflow; never manually delete the cataloged files.

## Compatibility rules for future writers

- Additive readers may accept future manifest or row versions only after explicit validation.
- A format-v1 writer must emit every documented column and exactly one matching schema snapshot.
- Public OSH scope/value ID pairs must never be renumbered during export.
- A writer must not modify an activated Parquet object in place. Corrections use overlays,
  tombstones, or a new generation/revision.
- The manifest remains the final file publication marker, and PostgreSQL activation remains the
  online query authorization marker.
- Object paths must stay relative, normalized, and under the configured archive root.
