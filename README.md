# OSCAR

OSCAR combines OpenSensorHub modules, the OSCAR viewer, PostgreSQL/PostGIS, and a TLS gateway into a hardened Docker Compose deployment.

The configured HTTPS port and a port 80 HTTPS redirect are published. PostgreSQL and the OSCAR application port remain on private Compose networks. Java 21.0.10 is included in the OSCAR container image and is not required on deployment hosts.

## Installation

See the release [Quick Start](dist/release/QUICKSTART.md) for the shortest supported installation path. The [Administrator Guide](dist/release/DEPLOYMENT.md) covers certificates, offline Windows installation, lifecycle commands, storage administration, security verification, and upgrades.

Supported deployment and operation hosts:

- Windows 11 x86-64 with Docker Desktop and WSL 2
- Ubuntu Server 24.04 x86-64 with Docker Engine and the Compose plugin

OSCAR 3.11.0 storage-profile deployment is intentionally blocked on macOS. Docker Desktop for Mac
cannot satisfy the tested bind-root ownership and recovery-media isolation contract used by this
release. Build/source inspection remains possible there, but initialize and operate 3.11.0 on a
supported Ubuntu or Windows host.

There is no default administrator password. The administrator supplies it during `oscar init`, and deployment-specific database credentials are generated automatically.

## Build from source

Clone all submodules:

```sh
git clone --recursive <repository-url>
cd osh-oakridge-buildnode
```

The canonical connected-release builds are:

```bat
build-all.bat
```

```sh
./build-all.sh
```

Both scripts use the locked Node.js dependency set, reject any npm advisory, test release-version updates, run the Viewer component suite and the Java software-only storage/media suites, compile the Java modules, and create:

```text
build/distributions/oscar-<version>.zip
```

Hardware-dependent tests remain outside these packaging scripts and must be run in an appropriately equipped test environment.
The Unix build also runs `tools/test-storage-scripts.sh`, which exercises the portable Bash and
PowerShell storage-administration safety guards. That harness does not replace the native Windows
PowerShell 5.1 gate: the release workflow runs `tools/test-storage-powershell.ps1` with
`powershell.exe` on Windows.

### Test a source-built release

The Viewer bundle and Java modules are copied into the versioned `oscar` container image. Building the ZIP does not update a running deployment, and `oscar restart` deliberately reuses the existing image.

For a full-system test, extract the newly built release into a clean directory and use `oscar init` for a disposable new deployment. OSCAR 3.11.0 therefore runs the new tiered database, direct daily-file journal, data-checksummed PostgreSQL cluster, primary Parquet cold tier, and optional external single-snapshot storage. Fresh deployments use `OSCAR_BACKUP_MODE=disabled`; `single` is a manual opt-in that requires an operator-selected safe absolute backup path that does not overlap the release or archive roots. A separate physical drive is recommended for failure isolation but is not required. PostgreSQL does not continuously archive WAL: it runs with `archive_mode=off` and no external WAL bind, and OSCAR does not provide PITR. Use a fresh 3.11.0 database and standard configuration when validating this storage profile; `upgrade` deliberately preserves an existing `config.json`, database volume, and legacy roots/data and does not silently migrate a pre-3.11.0 deployment.

For a 3.11.0-or-newer same-storage-profile upgrade, first create and verify a coordinated snapshot when the deployment has explicitly selected `single` mode, then copy only `.env`, `secrets/`, and `tls/` into a clean extracted release before running `oscar upgrade`; do not overlay the ZIP on old release-managed files. If the deployment previously adopted unlabelled legacy Docker volumes, also copy its `.oscar-volume-adoption` receipt. Initialization persists the archive path, and in `single` mode the backup path, as absolute paths outside the versioned release; the legacy-WAL binding is retained only to preserve any existing compatibility tree. Copying `.env` preserves those paths and the backup-mode policy. Confirm the archive bind and absence of a PostgreSQL WAL bind with `docker compose config`; the backup root is not mounted into a long-running service. Compose uses the fixed `oscar` project and exact external volumes `oscar_oscar_state` and `oscar_postgres_data`. During upgrade, the storage administrator lock covers the ordered application stop, configuration-aware offline daily-file lifecycle-index migration, and force-recreated service restart. The migration reads the persisted `/var/lib/oscar/config.json`, safely skips when no Daily File Journal module is configured, and creates no new work markers when the journal is already indexed. A failed or interrupted scan can leave idempotent work markers and an explicit restart marker, but it does not publish completion metadata; OSCAR remains stopped and the same upgrade is safe to retry. All named volumes and external roots remain attached. Retire the prior release directory only after health and mount/provenance verification. Never remove a parent or sibling path containing a preserved external archive, legacy-WAL, or backup root.

A pre-3.11.0 system does not have the coordinated-snapshot/root-identity contract and is not an ordinary in-place upgrade. Preserve it read-only after its supported backup/export, then use the separately qualified migration/bootstrap procedure. Only after confirming that both legacy named volumes and all nonempty active archive/backup roots belong to that deployment may an administrator use the explicit one-time adoption switches. Any legacy-WAL tree remains untouched compatibility data. The adoption switches create deployment-bound audit receipts/markers for active roots; they must never combine unrelated storage or bypass a foreign/swapped identity.

Do not reuse a published version number for different production images. During connected pre-release iteration, `init` and `upgrade` rebuild both local release contexts (`oscar:<version>` and `oscar-postgis:<version>`) even when matching tags are cached, then recreate the services without deleting named volumes. The bounded explicit Windows builds avoid Docker Compose 5.6's in-tree Dockerfile entitlement regression without granting wildcard filesystem access. The regression platform gate compares packaged and deployed helper hashes so a stale same-tag restore image cannot be certified. Never replace a published version tag with different image contents.

Viewer builds require Node.js 22.12 or newer on a supported even-numbered release line (22, 24, or 26). For isolated Viewer development, `cd web/oscar-viewer`, run `npm ci`, `npm run audit:dependencies`, and then `npm run dev`. This is useful for UI iteration against reachable OSCAR nodes, but it does not validate the packaged Viewer, FFmpeg camera telemetry, PostgreSQL filtering, container configuration, or the upgrade path. Use the release ZIP for final system testing.

## Developer documentation

The [translation system guide](docs/TRANSLATION_SYSTEM.md) documents language selection and persistence, admin and viewer resource lookup, sensor and Lane System form metadata, localized README help, and the complete procedure and validation checklist for adding or restoring a supported language.

The [operational views guide](docs/OPERATIONAL_VIEWS.md) explains how to assign lanes to workstation views, use view-specific URLs, and import or export assignments in lane spreadsheets.

The [Status of Health guide](docs/STATUS_OF_HEALTH.md) documents lane-level RPM and camera connectivity, detector and tamper faults, extended occupancy, operational-view scoping, and the acceptance checklist.

The [live-video guide](docs/LIVE_VIDEO.md) documents keyframe requirements, the Viewer's preparing and recovery states, emulator expectations, troubleshooting, and end-to-end playback acceptance tests.

The [storage architecture](docs/STORAGE_ARCHITECTURE.md) explains the 3.11.0 PostgreSQL hot store, Parquet cold tier, durable daily journal, and exact-five JPEG retained-media design for each successfully converted camera clip. The companion [data-lifecycle policy](docs/DATA_LIFECYCLE.md), [archive-format contract](docs/ARCHIVE_FORMAT.md), [backup/restore runbook](docs/BACKUP_RESTORE.md), and [storage-operations runbook](docs/STORAGE_OPERATIONS.md) cover retention, portability, deletion, recovery, monitoring, and rollout.

## Build Windows offline media

On a connected Windows x86-64 build workstation with Docker available, run the builder with Windows
PowerShell 5.1 (`powershell.exe`):

```powershell
powershell -File tools/offline/build-offline-bundle.ps1 -CreateArchive
```

The default `Both` profile invokes `build-all.bat`, downloads checksum-pinned official Windows prerequisites, exports the required images, creates `SHA256SUMS`, and produces two artifacts:

```text
build/offline/oscar-<version>-windows-x86_64-offline-full.zip
build/offline/oscar-<version>-windows-x86_64-offline-images.zip
```

The `full` artifact includes the pinned Docker Desktop and WSL prerequisites. The smaller `images` artifact requires Docker Desktop and WSL 2 to be installed and running already. Neither offline deployment path performs downloads.
Every offline `init` or `upgrade` re-verifies that the exact payload set and bytes match the
co-packaged `SHA256SUMS`, then reloads the checksum-verified image archive even when matching tags
already exist. This detects corruption and changes relative to that manifest, but the manifest is
bundled and unsigned: it does not authenticate the publisher or release origin. If origin
authentication is required, verify the outer ZIP against an independently trusted detached
signature or provenance attestation before transferring it into the offline environment.

## Release checklist

Before tagging a release:

1. Run `node tools/update-version.js <version>` to update `build.gradle`, the release-workflow pin, the deployment name, and `OSCAR_VERSION`.
2. Write the parent and Viewer changelog entries. Review every current-release label enforced by `tools/validate-release-metadata.js` in the root/release/feature guides, Modules documentation wrappers, and all four localized manuals. Update current-release labels and translated content together, but preserve historical introduction versions and migration boundaries such as `pre-3.11.0` unless the compatibility policy itself changed.
3. Run `node tools/validate-release-metadata.js <version>` and confirm `dist/release/postgis/pgdata` does not exist.
4. Run the appropriate canonical build script.
5. Run `tools/test-storage-powershell.ps1` under Windows PowerShell 5.1, then complete and record the
   manual release-acceptance matrix: fresh initialization, same-profile upgrade, backup/verification,
   isolated restore, archive status/verification/export, copy-only mixed-tier queries, tokenized
   purge of disposable data, zero-day (next-scan) exact-five JPEG eligibility and fewer-than-five-frame fallback, and both
   offline profiles on Windows 11 x86-64 with Docker Desktop/WSL 2 and local NTFS. Repeat deployment
   and storage acceptance on Ubuntu Server 24.04 x86-64, and confirm macOS deployment operations fail
   closed. Record the release version, image IDs, test results, and approver. Docker Desktop license
   acceptance and any required restart remain administrator actions; OSCAR does not accept the
   agreement on their behalf.

Configure the GitHub `oscar-release-acceptance` environment with required reviewers. The tag
workflow reaches that protected environment only after the tiered-storage PostgreSQL suite, the
destructive disposable PostgreSQL self-contained restore/timeline drill, and the native Windows
PowerShell 5.1 gates pass; approval attests that the recorded manual matrix above passed before the
workflow packages or publishes artifacts.

Tags matching `v*` trigger the release workflow. Before packaging, the workflow runs the explicitly listed direct tiered-storage integration methods against a disposable PostgreSQL/PostGIS service pinned to the same base-image digest used by the release. Those methods cover the database hot/cold lifecycle, late arrivals, failed activation cleanup, observation conflict handling, archive-activation races with updates/removals, one-connection cold-removal revalidation, restart ID high-water, open time bounds, online index migration, final-flush failure, byte limits and splitting, sparse windows, stale-job retry, symlink rejection, and independent-store namespace isolation without pulling in the legacy inherited PostGIS suite. A separate destructive PostgreSQL 16 job proves self-contained base-backup recovery with no WAL volume, promotion onto a new timeline, a durable post-promotion write, `archive_mode=off`, and cleanup of recovery-only settings. A disposable Compose gate also proves that both adopted external volumes retain their identities and canaries without a volume-recreation prompt. A native Windows job parses and exercises the release PowerShell scripts under Windows PowerShell 5.1. These automated gates do not replace the manual Docker Desktop/WSL 2, Ubuntu deployment, backup/restore, purge/export, or FFmpeg acceptance matrix above. Ordinary `build-all.sh` runs remain software-only and do not require PostgreSQL or Docker on localhost. After the gates pass, the workflow invokes `build-all.sh` and publishes the connected release ZIP, localized operator-manual PDFs, source archive, and structurally validated Windows offline media. The connected ZIP also contains the current Markdown guides and localized manuals; obsolete legacy manuals are excluded.

The release workflow builds and structurally validates the Windows offline media, but publication
still requires the recorded Windows 11 Docker Desktop/WSL 2 runtime acceptance above.
