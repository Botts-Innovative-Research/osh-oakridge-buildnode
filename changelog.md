# OSCAR Build Node Change Log
All notable changes to this project will be documented in this file. 
## 3.9.2 2026-10-18
### Storage-profile changes and rollout
- Introduce the `OscarTieredObsSystemDatabase` storage profile with sequential observation IDs, batched writes, archive ownership markers, and a versioned PostgreSQL archive catalog
- Initialize new PostgreSQL clusters with data checksums, WAL compression, I/O timing, and `pg_stat_statements`, while explicitly keeping `archive_mode=off` and omitting any external WAL bind; an existing cluster is not recreated by `upgrade`
- Preserve an upgraded deployment's saved `config.json` and database, so a pre-3.9.2 deployment is not silently converted to the complete 3.9.2 storage profile
- Require a fresh 3.9.2 database and standard configuration for the current test systems and new production deployments; preserve any required pre-3.9.2 production history through a separately validated migration
- Make the five allowlisted high-volume outputs Parquet-eligible after 48 hours and delete only exact generation-owned hot rows after parity plus a verified 24-hour overlap (about 72 hours plus scheduling); other observations and tables remain hot
- Replace aging-video keyframe reduction with an additive exact-five JPEG retained-media format; keep the legacy occupancy `videoPaths` field and Viewer playback fallback for old/unconverted events
- Make completed alarm video immediately eligible for asynchronous five-JPEG conversion on the next retention scan, preserve the source MP4 for 24 hours after verified publication, and keep every failed/fewer-than-five-frame source intact
- Make new self-signed deployments LAN/Tailscale-ready by adding active non-container LAN IPv4, stable Tailscale IPv4/IPv6, and discoverable MagicDNS identity to certificate SANs, accepting explicit additional DNS/IP SANs, validating every requested identity, and printing covered client URLs plus a verifiable public-certificate fingerprint

### Statistics reliability and resource control
- Serialize scheduled and operator-requested full National Statistics publications, use fixed-delay scheduling, and retain cancellable datastore shutdown so long archive-backed scans cannot overlap and multiply CPU, memory, or scratch-space pressure
- Return a terminal `COMPLETED` command only after a newly persisted statistics observation is available, preserve legacy statistics timestamp decoding without double-counting history, and use strictly increasing millisecond cutoffs with open-lower incremental ranges
- Keep the Viewer busy until the durable command status is terminal, fetch the exact returned observation instead of an older `latest` result, fail visibly on terminal command errors, and cancel stale UI work when the node or operational-view scope changes
- Execute operational-view range scans sequentially, disable duplicate refresh controls while initial or manual work is active, and regression-test the exact command, observation, rendered counts, and resource-safe lifecycle

### Storage and data lifecycle
- Add a crash-recoverable, per-lane direct daily-file journal that captures Rapiscan and RS350 input before parsing and Aspect register snapshots before observation publication
- Make the daily journal a required driver dependency by default so startup or append failures cannot silently bypass source-record capture
- Frame journal records with timestamp, length, and CRC32C; bound unforced data by time, record count, and byte count; recover only incomplete tails and fail visibly on complete-frame corruption
- Decouple journal readiness from historical backlog recovery: recover the current lane before its first append, process older lane/days in bounded background batches without holding live writer locks, and skip re-rendering complete durable publications so a restart cannot time out every RPM or repeat a large CPU/I/O spike
- Durably create every journal and retained-media directory component with parent-directory synchronization; surface permission and filesystem failures instead of treating them as platform fallbacks
- Make daily-journal shutdown bounded and fail-visible: service stop first closes admission, drains active sensor writer handles while allowing their final records and keeping periodic fsync active, then stops maintenance and forces/closes every lane; a timed close fails module shutdown instead of silently abandoning an unclosed writer
- Mark Rapiscan, RS350, and Aspect readers as stopping before transport teardown and join source workers before releasing their journal handles, so expected disconnects do not produce false errors and a final source record already in durable I/O cannot race sensor shutdown; RS350 releases its source writer independently of deferred WebID cleanup
- Serialize supported stop, restart, upgrade preparation, and restore shutdown as gateway, then OSCAR, then PostgreSQL on both Ubuntu and Windows; PostgreSQL remains available through OSCAR's bounded writer/module drain instead of receiving a concurrent Compose stop signal
- Publish immutable legacy daily CSVs with exact time-zone windows, SHA-256 manifests, atomic commit ordering, and a manifest-gated compatibility-observation cleanup path
- Retry the bounded daily-file cleanup on every hourly maintenance pass after the midnight attempt, isolate it from unrelated purge failures, and retain all unsealed current-day compatibility rows until manifest-validated publication
- Bound private daily-journal storage even when managed backup is disabled: after 30 days from the later of day close or publication, freeze and delete a sealed day only after immutable CSV/manifest/ledger validation and exact journal-to-CSV replay; retain an opt-in accepted-backup gate for sites that require it
- Replace startup and once-per-minute all-history journal enumeration with durable bounded lifecycle work queues, and recover interrupted staged deletion without discarding a late or unverified segment
- Batch observation inserts with immediate `DataBlock` snapshots, prepared statements, PostgreSQL batch rewriting, and one statement-level datastream-range update per batch
- Correct observation natural-key uniqueness for null fields, make exact replays idempotent and same-key corrections last-write-wins under the stable OSH ID, route archived corrections through generation-owned overlays even after hot-row deletion, fail index creation visibly when a legacy database contains ambiguous duplicates, and use the full expression index for natural-key conflict lookups even under PostgreSQL generic prepared plans
- Preserve the sequential observation-ID high-water from every cataloged archive state so a restart cannot reuse public IDs after a cold copy is cataloged and the corresponding hot rows are optionally deleted
- Export configured high-volume detector streams from a read-only repeatable-read snapshot into Hive-partitioned, sorted, ZSTD Parquet generations with gzip OSH datastream-schema snapshots
- Prevent dense-hour Parquet retries from exhausting DuckDB memory by clearing bounded 500-row insertion batches and publishing memory-derived deterministic same-hour prefixes; retries reuse the failed job (including exact legacy sub-hour windows), empty reclaimed attempts terminate as audited `SUPERSEDED` no-ops, later prefixes become ordinary revisions, and no unverified hot row is deleted
- Verify Parquet count/ID range before activation, publish manifests last, and atomically mark the exact exported hot rows so late arrivals remain eligible for later generations
- Serialize archive activation/sealing against ingestion, updates, removals, overlays, tombstones, and exact hot-row deletion with transaction-scoped store and ordered observation locks, while keeping file export outside the critical section
- Merge PostgreSQL and catalog-authorized Parquet reads behind the OSH observation-store contract, preferring hot overlap and applying archived overlays and tombstones without rewriting immutable files
- Push mutation-free explicit-stream `resultTime=latest` queries into indexed PostgreSQL lateral probes and DuckDB latest-per-stream reduction before merging the two tiers, so health refreshes read at most one hot and one cold candidate per stream instead of paging the complete hot history
- Implement PostgreSQL feature-parent lookup through the standard OSH datastore contract, so lane-scoped retention and purge code resolves the authoritative lane system instead of silently falling back to a child RPM identity
- Preserve open and closed temporal bounds through archive candidate pruning and DuckDB pushdown so cold selection, count, limit, and filtered removal match hot PostgreSQL semantics
- Add exact hot/cold row-digest parity receipts, a configurable rollback grace, bounded exact-ID hot deletion, generation/observation holds, and deferred sealing while held rows remain
- Add versioned archive jobs, generations, objects, ID blocks, schemas, locators, overlays, tombstones, holds, verifications, deletion plans/ledger, media records, and backup epochs
- Compact processed-observation and deletion metadata behind restart-safe cursors so long-running systems do not accumulate unbounded bookkeeping rows
- Add embedded DuckDB query pushdown over explicit catalog-authorized file lists and portable generation export for independent Parquet inspection
- Bound every embedded DuckDB export, parity, deletion, query, metadata, and count connection to production-configurable memory, thread, and per-operation spill limits; add fair process-wide session admission with a bounded fail-busy wait; confine sensitive scratch to private disjoint directories and remove it on normal close
- Keep general-purpose container temporary storage `noexec` while routing JVM native-library extraction to a bounded, owner-only executable tmpfs that is verified before startup
- Preserve 64-bit Admin configuration values with type-correct Long, Integer, Short, and range converters, including the 2 GiB archive-generation limit, instead of narrowing every whole number through a 32-bit converter
- Bound Viewer health snapshots to ten stream IDs per request with two global workers and a ten-second per-batch deadline, preventing large accumulated databases from leaving every RPM and camera indicator stuck at `Waiting`
- Persist the successfully uploaded lane-CSV bucket key in the OSCAR Service configuration, so Apply Changes plus the global Save action recreates live Lane, RPM, and camera modules after a supported restart instead of leaving only historical system records in PostgreSQL
- Serialize the legacy ERNIE VM250 XML-schema initialization across Rapiscan lanes, preventing 50-lane Windows restarts from racing the process-global registry and leaving apparently Started RPM modules with an unusable analyzer

### Media retention
- Serialize recording commands in a bounded per-camera FIFO and use generation-qualified filenames so reconnects and back-to-back occupancies cannot finalize or reuse another recording's clip
- Acknowledge occupancy MP4 OPEN only after the current recording generation has successfully muxed its first keyframe; bound readiness to five seconds, wake on stop/failure, reject stale generations, and remove the hidden partial instead of producing a zero-packet alarm clip
- Bind every published recording to its exact lane, camera, and alarm; reject blank, duplicate, cross-camera, stale-generation, or otherwise unowned paths instead of attaching them heuristically
- Cancel non-alarm recordings and fail closed on close timeouts, invalid output, or publication failure, while retaining authoritative late-close cleanup so delayed camera work cannot leave an orphaned clip
- Make camera, occupancy, and state-listener delivery race-safe so lifecycle transitions cannot lose, duplicate, or leak recording callbacks
- Retain exactly five distinct decoded positions (`FIRST`, `QUARTER`, `MIDDLE`, `THREE_QUARTERS`, and `LAST`) from each eligible alarm camera clip
- Give short saved alarm recordings a bounded post-roll until at least five video packets have been muxed, so one-second occupancies remain eligible for five-frame retention
- Encode each retained asset as an independently decodable opaque baseline sRGB JPEG with configurable quality (85 by default), SHA-256, dimensions, decoded ordinal, source PTS, and lifecycle metadata
- Publish frames before a versioned manifest commit marker, use a durable identity-keyed job ledger for idempotent retry, and preserve the source MP4 on every failure or fewer-than-five-frame result
- Fail closed unless retained media can resolve the authoritative `urn:osh:system:lane:*` parent, preventing a camera set from being committed under an RPM UID
- Bind each retention scan to a cancellable PostgreSQL operation and honor interruption between bounded maintenance items, allowing the supported OSCAR-before-PostgreSQL restart sequence to drain a historical backlog without leaving a database query running
- Preserve a successfully converted source for a configurable 24-hour rollback grace and delete it only on a later verified, unheld lifecycle pass
- Set the production profile to zero-day five-JPEG eligibility, scan asynchronous work in bounded five-minute windows, cache occupancy datastream IDs for 15 minutes, and persist bounded late-arrival plus repeating historical reconciliation cursors so restarts, delayed commits, and clock corrections do not skip eligible media
- Add an authenticated read-only event media API and Viewer five-frame gallery, with `404` fallback to unchanged legacy video playback
- Enforce streaming catalog/asset transfer limits plus bounded retained-media camera, frame-byte, dimension, decoded-pixel, and event-wide budgets in the Viewer; fetch only each camera's selected frame and limit event-wide frame-request concurrency
- Restrict storage-pressure cleanup to complete cataloged media sets, honor holds and source grace, publish `DELETING` before removal, and leave legacy video, daily files, adjudications, reports, and archives untouched

### Backup, deletion, and operations
- Default fresh deployments to `OSCAR_BACKUP_MODE=disabled`; require explicit `single` opt-in and an operator-selected safe absolute non-overlapping backup path before backup, verification, restore, or the retired prune command can run; recommend, but do not require, a separate physical drive for failure isolation
- Recover a unique fully accepted first-backup snapshot by reconstructing authenticated `CURRENT`; preserve ambiguous accepted sets plus schema-v1, failed, partial, unauthenticated, unaccepted, and incomplete deletion candidates for operator review, and fail closed on unsafe or acceptance-invalid `CURRENT`
- Add coordinated schema-v2 snapshot commands for a streamed PostgreSQL base backup, OSCAR state, primary Parquet cold tier, release metadata, and AES-256-CBC/PBKDF2-encrypted deployment credentials; omit cumulative `wal-archive.tar.gz`
- Automatically verify each new snapshot with SHA-256 and `pg_verifybackup`, retain versioned backup-epoch manifests and `VERIFIED` markers, and commit exactly one logical current snapshot through a four-line HMAC-authenticated `CURRENT` pointer
- Preserve explicit schema-v1 verification/restore compatibility, authenticating its required historical WAL payload but ignoring that external payload during restore because streamed `postgres/pg_wal` is sufficient, without treating legacy media as schema v2 or exposing a PITR workflow
- Authenticate each backup inventory with HMAC-SHA-256, stream the bounded canonical backup-time archive-generation UUID inventory, bind the catalog receipt to its count, byte length, and SHA-256 without duplicating a large UUID array in PostgreSQL, require the exact 3.9.2 epoch and image identities, and issue daily-journal confirmation receipts only after the recovery point has passed structural and cryptographic verification
- Authenticate the exact top-level backup payload inventory, require an explicit member allowlist for the release-configuration archive, reject duplicate names, path aliases, prefix collisions, links, reparse points, traversal, and out-of-root paths in every archive, and serialize every storage-administration mutation with a cross-command lock
- Publish backup and portable-export directories through a compiled Linux `renameat2(RENAME_NOREPLACE)` helper after durability barriers; stamp the helper's packaged-source SHA-256 into the image and regression-test collision preservation
- Keep coordinated snapshots outside every long-running service mount, give a network-scoped `pg_basebackup --wal-method=stream` client only its fresh staging directory, and exclude only verified image-owned state links from the mutable-state snapshot
- Preserve legacy WAL roots/data without mounting them into PostgreSQL or deleting them during setup/upgrade mode changes
- Resolve the Ubuntu release directory physically, reject symlinked launchers, and reject Windows launcher/release reparse points while canonicalizing storage-root ancestors, so an alias cannot bypass destructive-operation containment checks
- Restore PostgreSQL only through the selected online base backup's consistency endpoint, promote onto a fresh timeline, reconstruct the exact `VERIFIED` epoch receipt, and prove a post-promotion write across checkpoint and clean restart with `archive_mode=off`
- Preserve the existing Docker volume and bind-mount root metadata while restoring OSCAR state and cold archives by skipping each archive's root member, preventing otherwise valid restores from failing when the container runtime rejects timestamp or mode changes on a mounted root
- Reconcile the entire cold-archive root against the catalog and approved `datasets/` shape, including an otherwise empty/missing `datasets` tree, so unexpected top-level objects fail status, verification, and backup before publication
- Re-verify every payload against the bundle's exact SHA-256 inventory and always load the checksum-verified `offline-images.tar` during offline initialization or upgrade, even when same-version tags already exist locally, so stale development images cannot shadow the selected bundle; the co-packaged unsigned manifest provides integrity but not publisher/origin authentication
- Create persistent Docker volumes through setup, label new volumes with a deployment UUID, reject missing, foreign, or mixed ownership, and require an explicit audited adoption receipt before reusing unlabelled legacy volumes; declare the exact names external to Compose so upgrades never offer to recreate adopted data while reconciling immutable labels
- Force-recreate all service containers during a clean-directory upgrade so unchanged services cannot retain release-local secret/config mounts or Compose provenance from the previous directory, while preserving external storage roots and named data volumes
- Add explicit-confirmation restore and preservation of pre-restore deployment credentials
- Add an external primary-cold-tier archive bind, an optional administrator-owned single-snapshot root exposed only to scoped one-shot helpers, and size-rotated Docker logs
- Add archive status and full object-checksum verification commands that require exactly one active Parquet, manifest, and schema object for every query-visible generation, reject stale generation Parquet path/checksum or manifest-path pointers, and fail/retry if the canonical catalog snapshot changes during live verification
- Qualify archive-generation status fields across the object join so an object's identically named lifecycle columns cannot make the operator status query ambiguous
- Parse Docker image and volume inspection metadata as bounded, identity-validated JSON on Windows PowerShell 5.1, avoiding native-argument quote loss in setup, backup, and restore label checks
- Bind Windows durability-barrier flags with explicit unsigned Win32 types so PowerShell 5.1 can initialize protected storage roots without narrowing the high-bit `CreateFile` option
- Revalidate and extract the exact authenticated root-only OSCAR-state archive through a confined one-shot privilege bridge, then run daily-journal confirmation as the non-root OSCAR user before committing `CURRENT`
- Give every capability-free root helper an explicit neutral working directory on Linux and Windows, preventing the image's owner-only OSCAR state directory from breaking validators, extractors, HMAC helpers, TLS setup, or restore tools after capabilities are dropped
- Stream bounded UTF-8 bootstrap SQL over standard input on Windows PowerShell 5.1 instead of forwarding a quoted shell argument, preserving each statement exactly and retaining `ON_ERROR_STOP` failure behavior
- Stream the multiline PostgreSQL checksum-marker and saved OSCAR configuration acceptance checks over standard input on Windows PowerShell 5.1, so native quote rewriting cannot truncate a fresh initialization after healthy containers start
- Route every Windows setup/storage shell body and direct-`psql` statement through bounded UTF-8 standard input, require the direct `docker run` adapter to attach stdin itself, and relay setup-to-storage options through an allowlisted Base64/JSON environment envelope plus a fixed encoded child command so PowerShell 5.1 cannot rewrite operator values in native argv
- Run `pg_verifybackup` in a networkless, read-only helper with every capability dropped except `DAC_READ_SEARCH`, so both administrator-normalized Linux backups and UID-999 Docker Desktop backups remain verifiable without granting write access or weakening mode-0600/0700 host permissions
- Recheck the exact image inventory after connected OSCAR/PostGIS builds and pull the gateway only when it is still absent, avoiding an unnecessary registry/credential-helper dependency when the pinned gateway image is already cached
- Build connected Windows OSCAR/PostGIS images from explicit validated release contexts, avoiding the Docker Compose 5.6/Buildx 0.37 in-tree Dockerfile entitlement regression without disabling filesystem checks or granting wildcard host access
- Add supported generation/observation hold list/create/release commands with persistent actor, reason, and release audit fields
- Resolve observation-hold membership from an exact hot row before consulting coarse archive ID ranges, so sparse/interleaved retired generations cannot reject unrelated extant rows while tombstoned and cold-only ambiguous targets remain fail-closed
- Persist each new hold's `GENERATION_EXACT`, `HOT_EXACT`, or `COLD_RANGE_CONSERVATIVE` resolution mode, expose it in both administration CLIs, preserve unresolvable pre-3.9.2 observation-hold provenance as protective `LEGACY_UNKNOWN`, and document that neither a cold range nor unknown legacy provenance proves a sparse observation ID exists
- Enforce active observation and exact-generation holds transactionally across single and filtered hot/cold datastore removals and tombstones; single removal fails visibly, bulk removal skips protected rows, and set-based candidate lookup avoids per-row connection borrows or store-wide hold materialization
- Fail closed for generic tiered datastore/datastream clear, drop, table-clone backup, and table-replacing restore APIs; prevent datastream removal while any held observation remains, and reject opening a catalog created by a newer storage-schema version
- Add a two-step cold-deletion workflow that freezes eligible sealed generations in a 24-hour plan, emits a one-time token, rechecks holds and each object hash, validates relative paths, persists restartable `DELETING` intent, and retains generation tombstones plus catalog/deletion-ledger audit records
- Add atomic portable archive generation packages with catalog-relative data/schema/manifest objects, catalog JSON, README, ready-to-run DuckDB query, and package checksums
- Add complete architecture, lifecycle, archive-format, backup/restore, operations, monitoring, failure-recovery, privacy, and staged-rollout documentation
- Fail closed on macOS for 3.9.2 deployment/storage operations because Docker Desktop for Mac cannot meet the protected bind-root ownership and recovery-media isolation contract; production hosts are Ubuntu 24.04 or Windows 11/WSL 2

## 3.9.1
### Upgrade notes
- This release changes operator-facing navigation and adds operational-view URL scoping; train operators and validate workstation URLs before production rollout
- Build or import the versioned `oscar:3.9.1` image and run `oscar upgrade`; `oscar restart` alone continues to use the previously installed image
- The upgrade retains the existing `oscar_state` and `postgres_data` volumes and does not require a database reset
### Changes
- Add exact Event UUID lookup from the Events page and durable, node-qualified Event Details links that retain operational-view scope and fail closed for inaccessible lanes
- Show the canonical occupancy observation identifier in Event Details and browser-generated PDFs, and include/display it in compact QR and portable alarm transfers while retaining legacy version-1 import compatibility
- Add a localized Status of Health page showing every visible lane, RPM and camera connectivity, gamma high/low, neutron high, tamper, and configurable extended-occupancy faults
- Add compact dashboard lane indicators for independent RPM and camera connectivity plus gamma high/low, neutron high, tamper, and extended-occupancy state, reusing the bounded health snapshot without adding per-lane health feeds
- Publish a canonical lane occupancy-status stream so extended occupancy works consistently with Rapiscan, Aspect, and RS350 RPMs
- Publish FFmpeg camera connection-state telemetry on lifecycle transitions and every 30 seconds, keeping healthy camera state current through hourly database cleanup while allowing a stopped publisher's stale value to age out
- Produce valid FFmpeg MP4/HLS recordings from H.264 cameras by requiring discovered video dimensions and preserving packet PTS, DTS, duration, stream index, and time base during remuxing
- Make FFmpeg transcoder queues thread-safe and blocking, preserve native packet ownership and delayed-output flushing, surface worker failures, and prevent overlapping pipeline generations during stop, restart, or reinitialization
- Keep MP4 packet delivery ordered with recording close so healthy occupancy clips cannot finalize before queued video packets are written
- Reject and remove incomplete video recordings instead of retaining zero-byte or unfinalized clips, with live-camera recording/HLS coverage plus reconnect and failure-cleanup regression tests
- Start each per-camera recording-command watchdog only after FIFO and bounded alarm/save-decision waits finish and the camera operation is submitted, preventing healthy short occupancies and keyframe-gated startup from falsely quarantining a camera while retaining bounded hung-operation cleanup
- Start live HLS output on the first decodable H.264 keyframe and withhold unavailable playlists instead of serving an empty manifest or a segment that begins mid-GOP
- Treat rapid lane switches before the first HLS keyframe as successful cancellations while preventing queued packets from leaking into a restart and preserving real write or cleanup failures
- Show localized live-video preparation, terminal failure, and retry states in the Viewer, with bounded recovery for transient playlist, network, and media errors
- Document a one-to-two-second camera keyframe interval and provide a one-second closed-GOP preparation path for the 50-camera emulator while retaining low-CPU stream-copy publishing
- Make video-retention compaction fail-safe by validating a decoded frame and durably replacing the original only after the compacted clip is complete, while preserving the source clip on every failure path
- Refresh Status of Health in globally limited batches of at most 50 streams on entry and every 30 seconds, with 10-second request deadlines, replacing per-stream real-time MQTT feeds while avoiding oversized requests, recovering from stalled nodes, and bounding CPU and server load at large sites
- Resolve each eligible batched latest-health read with one indexed PostgreSQL lookup per stream so query cost does not grow with retained observation history
- Publish a Clear tamper baseline whenever the Rapiscan driver establishes or re-establishes an RPM connection, before processing later `TT` and `TC` transitions
- Replace orphan-prone Rapiscan reader threads with one close-aware pooled reader per connection, stop and join the old reader before reconnecting, exit cleanly at end-of-stream, and preserve concurrent input for all 50 lanes
- Accept an RPM occupancy summary immediately after a mid-occupancy connection by recording a zero neutron maximum when no neutron sample has arrived yet, instead of terminating the message reader
- Keep Dashboard-to-Lane Details gamma and neutron streams connected through route handoff, bind them by datastream ID, and release subscriptions cleanly so live plots do not open as threshold-only or empty
- Apply event filters across the full database result set and add PostgreSQL indexes for OSCAR event-filter queries
- Add URL-scoped operational views so one OSCAR deployment can present different lane groups to different workstations
- Scope viewer subscriptions, statistics, reports, navigation, health monitoring, and alarm notifications to the active operational view
- Add backward-compatible lane CSV import/export for operational-view assignments
- Export alarms from the dashboard or Event Details as compact QR codes, PNG images, or portable alarm files for air-gapped transfer
- Preserve chart endpoints, extrema, and gamma threshold crossings while adaptively downsampling gamma, neutron, and threshold data to fit reliable single-code QR capacity
- Scan alarms with a camera or saved image, import portable files, verify transfer integrity, redraw charts, and download or share the received package
- Add complete English, Spanish, French, and Greek interface and operator-manual coverage for alarm transfer
- Package the maintained release guides and all four localized operator manuals in the connected ZIP while excluding obsolete legacy manuals
- Validate changelog, deployment, and localized manual version labels against the release tag
- Migrate the Viewer to Next.js 16, React 19, Cypress 16, and Vite 8; remove obsolete vulnerable tooling, eliminate all known npm audit advisories and deprecated locked packages, and enforce both checks in release builds
- Update the Bnd and Java build configuration so Gradle 8.5 emits no Gradle feature deprecations and remains compatible with the Gradle 9 migration path
- Normalize the persisted SensorHub configuration to owner-only writable permissions (`0600`), repairing overly restrictive copies created by earlier releases
- Document that CSV imports remain in memory until the global Save action completes and require restart verification before acceptance
- Stamp and validate the OSCAR semantic version in the container image's OCI metadata instead of inheriting the base operating-system version label

## 3.9.0 2026-09-23
### Changes
- Add nested AND/OR alarm filtering on the dashboard and Events page
- Add inclusive numeric filters for occupancy ID, maximum gamma, and maximum neutron values
- Add individual, cross-page, and all-filtered alarm selection with bulk adjudication
- Remove Sentry.io
- Handle browser autoplay rejection without breaking live video or alarm audio
- Allow vehicle ID entry during dashboard alarm adjudication
- Add complete English, Spanish, French, and Greek administrator/operator manuals
- Publish validated, screenshot-complete PDF manuals with each GitHub release
## TODO
- Set default reconnect attempts to infinity

## 3.8.2 2026-09-21
## Changes
- Load lanes independently on viewer. Fixes issue that caused failure across all lanes when one lane was unreachable/unhealthy

## 3.8.1 2026-09-20
## Changes
- Fix OSM + site diagram layers
- Fix lane marker location discovery
- Fix camera stream resilience in backend & viewer
- Fix site diagram upload failures

## 3.8.0 2026-09-19
## Changes
- Full support for internationalization (i18n) in frontend viewer and administrative interface

## 3.7.5 2026-09-18
## Changes
- Add manual tamper clear action
- Fix charts that were only showing threshold and not counts
- Increase opacity of sitemap overlay and fit map to sitemap bounds

## 3.7.4 2026-09-16
## Changes
- Fix Leaflet blocking OSM tiles

## 3.7.3 2026-09-09
## Changes
- Allow installation when Docker has different permission set than administrator running setup command
- Fix minor bug in UI where lane UIDs could not have extensions (e.g. "...:lane:north:1")

## 3.7.2 2026-08-28
## Changes
- FFmpeg usage improvements

## 3.7.1 2026-08-27
## Changes
- Added configurable CORS whitelist to Jetty HTTP server

## 3.7.0 2026-08-22
## Changes
- Add cookie based session authentication as default so we dont store credentials in browser storage.
- Fix OSCAR viewer map to auto-fly to sitemap, even when offline.
- Add loading icon for unloaded client data.
- Fix dashboard lane tamper status to persist across refresh.
- MQTT fixes on client and server
- Make OSCAR CLI clickable
- Edit GH Actions workflow to generate offline builds
- Add "verify" to CLI and some flags to offline builder

## 3.6.2 2026-08-20
## Changes
- Fixed minor issue where GitHub actions workflow releases source containing node_modules, making source unnecessarily large

## 3.6.1 2026-08-20
## Changes
- Fixed bug where OSCAR CLI would show `oscar.local` as local hostname but not auto-map. 
  - Now this is automatically mapped on local machine to work.
- Fixed bug where gamma charts display "Gamma 0" at the start of an occupancy

## 3.6.0 2026-08-19
### Changes
- Decrease PostGIS connection pool size and idle time for connections
- Modify PostGIS datastore queries to prevent SQL injection
- Enforce file upload size limits and read-only permissions for files
- Add file upload policy to block common executable files
- Disable CSAPI HTML responses by default and add additional headers for security.
- Containerize all app components (OSH, postgres, reverse proxy)
- Remove default credentials from postgres and OSH
- Harden postgres permissions in deployment
- Added CLI for OSCAR initialization and app management

## 3.5.1 2026-08-01
### Changes
- Removed anonymous user/role.
- Enabled role-based access control for Connected Systems API by default.

## 3.5.0 2026-04-24
### Changes
- Updated LaneSystem README

This is the finalized release for OSCAR phase 3.5.

## 3.3.6 2026-04-23
### Changes
- Updated documentation with correct launch script names

## 3.3.5 2026-04-23
### Fixes
- Fixed bug in viewer with MQTT message parsing
- Updated documentation to reflect new changes

## 3.3.4 2026-04-22
### Fixes
- Fixed server side filtering with queries containing numeric comparisons

## 3.3.3 2026-04-22
### Fixes
- Fixed crashes caused by spreadsheet import
- Fixed locations not being deserialized/loaded from spreadsheet config

## 3.3.2 2026-04-17
### Fixes
- Fixed crash caused by video retention bug
- Fixed daily-file creation

## 3.3.1 2026-04-09
### Fixes
- Fixed OSCAR notifications
- Set video retention policy to enabled by default

## 3.3.0 2026-04-08
### Fixes
- Fixed client dashboard UI to allow double tapping occupancy instead of scrolling to click on "Details" button
- Fixed bug where video clips would not load on first /event-details page load
- Fixed Cambio usage to work offline
- Fixed bug where OSCAR Service Module would fail to restart

### Changes
- Modified occupancy data structure for RS350 occupancies, along with UI.
  - (This makes 3.3.0 incompatible with previous versions)

## 3.2.0 2026-04-04
### Changes
- Now fully supporting RS350 systems in backend and viewer
- Updated notification models and redirects.
- Updated Web ID / Adjudication UI
- Automated RS350 N42 Web ID analysis

## 3.1.0 2026-03-19
### Changes
- Attach node names to lane names on frontend dashboard to differentiate same-name lanes
- Add mobile UI and PWA support (with push notifications)
- Add support for adjudicating with Web ID supplemental analysis
### Fixed
- Fixed bug where chart points were out of order

## 3.0.0 2026-02-04
This is the official first release of 3.0.0
### Changes
- Data from database is purged regularly with "daily files" exported at midnight
- Added internationalization (i18n) to the frontend
- Sorted lanes by alphanumeric order in the frontend dashboard
- Use server-side filters in frontend tables
### Fixed
- Fixed issue where database is queried everytime Admin UI is loaded

## 3.0.0-rc.5 2025-12-11
### Changes
- Improved pagination speed on large datasets
- Make the time at which stats are published configurable
### Fixed
- Fixed bug with HLS thread-locking which causes live video to be unavailable after some time

## 3.0.0-rc.4 2025-12-05
### Changes
- Improved PostGIS query speed for observations
- Improved site stats page load time
### Fixed
- Fixed bug where adjudications would not submit, and duplicate isotopes would appear in adjudications
- Fixed an FFmpeg memory leak causing unbounded memory usage

## 3.0.0-rc.3 2025-11-26
### Fixed
- Fixed issue with FFmpeg transcoding causing node to crash
- Reduce launch script heap size to 6GB
- Reduce thread count for Rapiscan drivers

## 3.0.0-rc.2 2025-11-26
### Fixed
- Fixed issue with Windows `launch-all.bat` script not working
- Fixed embedded MQTT server issue on Windows

## 3.0.0-rc.1 - 2025-11-25
### Fixed
- Optimized requests on client via pagination and filtering
- Fixed adjudications not working properly on client
- Improved FFmpeg HLS latency and video consistency
- Fixed PostGIS queries taking too long
- Reverted launch script to use native JVM for OSH and Docker for PostGIS

## 3.0.0-alpha.4 - 2025-11-17
### Fixed
- Fixed MQTT not disconnecting on client
- Added fixes for FFmpeg issues
- Fixed occupancy videos not attached to every occupancy
- Fixed event preview charts
- Fixed video switching in live video / events
- Fixed issue where commands would never send due to duplicate control streams in CSAPI
- Added fix to decrease HLS latency

## 3.0.0-alpha.3 - 2025-11-12
### Added
- Added extra FFmpeg checks for invalid cameras.
### Changed
- Edited docker compose to restart OSH node on failure
- Edited docker compose to not use managed volume
- Edited ARM64 PostGIS Dockerfile to not use peer connection
- Changed web client to use single MQTT Web Socket connection for dashboard connections

## 3.0.0-alpha.2 - 2025-11-11
### Added
- Added MQTT Services to allow client to receive messages through a single persistent websocket instead of opening multiple websockets per lane.
- Added video retention
### Fixed
- Updated PostGIS to be able to handle commands and command statuses.

## 3.0.0-alpha.1 - 2025-11-07
### Added
- Added docker compose and Dockerfile for OSCAR OSH node, allowing PostGIS and OSH to be run with one script.
### Changed
- Swapped default H2 database with default PostGIS database.
- Update report paths to use valid Windows path

## 3.0.0-alpha - 2025-11-04
### Added
- [#19 Option to replace sitemap with site diagram](https://github.com/Botts-Innovative-Research/osh-oakridge-buildnode/issues/19)
- [#43 Implement Report Generation](https://github.com/Botts-Innovative-Research/osh-oakridge-buildnode/issues/43)
- [#48 Switched Database from H2 to PostgresSQL ](https://github.com/Botts-Innovative-Research/osh-oakridge-buildnode/issues/48)
- [#53 Streamlined Initial Configuration via Spreadsheet Import](https://github.com/Botts-Innovative-Research/osh-oakridge-buildnode/issues/53)
- Set up Sentry Testing
- Added Unit Tests for all drivers - (Rapiscan, Aspect, FFMpeg, Lane System)
- Set up Client testing using Cypress
- Added GitHub Actions for testing
### Changed
- [#106 Update client playback videostreams](https://github.com/Botts-Innovative-Research/osh-oakridge-buildnode/issues/106)
- Use local storage to save nodes configured on client server page.
-
### Removed
- [#89 Upgrade Log4j from EOL 1.x to a secure version](https://github.com/Botts-Innovative-Research/osh-oakridge-buildnode/issues/89)
### Fixed
- [#101 National View does not show the accurate data collected by each site](https://github.com/Botts-Innovative-Research/osh-oakridge-buildnode/issues/101)

## [2.3.1] - 2025-09-13
### Added
- Current PostGIS database module. (needs to be updated, but this provides a base for testing later versions of OSCAR)
- Dockerfiles and script to launch PostGIS instance.
### Changed
- Restructured repository, moving most directories that are unused in development under `dist`

## [2.3.0] 
Release 2.3.0 

### Added
- Added Deployment version to config.json

### Changed
- [#89](https://github.com/Botts-Innovative-Research/osh-oakridge-buildnode/issues/89)
Removed dependency to log4j

### Fixed
- [#90](https://github.com/Botts-Innovative-Research/osh-oakridge-buildnode/issues/90)
Aspect Charts:The prior issue mentioned the Aspect RPMs and the Admin Panel, but this encompasses Aspects issues on the client as well.
- [#]()
Update charts in client to display Rapiscan and Aspect charts 
- [#]()
  Node Form Fix: Updated NodeForm to check if node is reachable before adding it to the list of Nodes, so when configuring a node it will ensure that you can access that node before it continues processing and updating the UI.


## [2.2] - 2025-07-30
Release 2.2 request, no updates since 1.3.7.


## [1.3.7] 2025-07-18

### Added
- [#80](https://github.com/Botts-Innovative-Research/osh-oakridge-buildnode/issues/80)
  FEATURE REQUEST: Changelog
### Changed
- ToggleButtons are disabled when selected to prevent no component showing (e.g. On event-preview when 'cps' chart is selected you can only toggle to 'nsigma' chart)
- [#85](https://github.com/Botts-Innovative-Research/osh-oakridge-buildnode/issues/85)
  Neutron Chart Tick Marks
- [#86](https://github.com/Botts-Innovative-Research/osh-oakridge-buildnode/issues/86)
  Remove "Adjudicated" Filter from Alarming Occupancy Table
### Fixed
- Navigate from Map to Lane View by clicking on point marker
- [#90](https://github.com/Botts-Innovative-Research/osh-oakridge-buildnode/issues/90)
  Aspect RPMS are not working in version 1.3.5
- [#91](https://github.com/Botts-Innovative-Research/osh-oakridge-buildnode/issues/91)
  OSCAR Viewer Stability
- [#94](https://github.com/Botts-Innovative-Research/osh-oakridge-buildnode/issues/94)
  Incorrect Video Timeframe Display Leading to Playback Failure
- Aspect alarming events should now appear with charts/video in the event-preview and event-details
