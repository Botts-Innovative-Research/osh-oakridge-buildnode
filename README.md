# OSCAR

OSCAR combines OpenSensorHub modules, the OSCAR viewer, PostgreSQL/PostGIS, and a TLS gateway into a hardened Docker Compose deployment.

The configured HTTPS port and a port 80 HTTPS redirect are published. PostgreSQL and the OSCAR application port remain on private Compose networks. Java 21.0.10 is included in the OSCAR container image and is not required on deployment hosts.

## Installation

See the release [Quick Start](dist/release/QUICKSTART.md) for the shortest supported installation path. The [Administrator Guide](dist/release/DEPLOYMENT.md) covers certificates, offline Windows installation, lifecycle commands, security verification, and upgrades.

Supported initial deployment hosts:

- Windows 11 x86-64 with Docker Desktop and WSL 2
- Ubuntu Server 24.04 x86-64 with Docker Engine and the Compose plugin
- Apple Silicon macOS with Docker Desktop; PostGIS runs under AMD64 emulation

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

Both scripts use the locked Node.js dependency set, build the OSCAR viewer, compile the Java modules, and create:

```text
build/distributions/oscar-<version>.zip
```

Hardware-dependent tests remain outside these packaging scripts and must be run in an appropriately equipped test environment.

### Test a source-built release

The Viewer bundle and Java modules are copied into the versioned `oscar` container image. Building the ZIP does not update a running deployment, and `oscar restart` deliberately reuses the existing image.

For a full-system test, extract the newly built release into a clean directory and use `oscar init` for a disposable new deployment. To upgrade an existing test deployment, back it up and restore only its `.env`, `secrets/`, and `tls/` into the clean release directory before running `oscar upgrade`; do not overlay the ZIP on the old release-managed files. Compose uses the fixed `oscar` project name, so the upgrade retains the existing `oscar_state` and `postgres_data` volumes while preparing the image named by `OSCAR_VERSION` and recreating the changed services. OSCAR 4.0.0 therefore runs as `oscar:4.0.0`.

Do not reuse a published version number for different production images. During connected pre-release iteration under the same version, explicitly rebuild the intended tag before `upgrade`: on Ubuntu or macOS, use `OSCAR_VERSION=4.0.0 docker compose build oscar`; in PowerShell, set `$env:OSCAR_VERSION = '4.0.0'` before running `docker compose build oscar`. Building without the explicit override before `upgrade` can reuse the previous version from `.env` and produce the wrong tag. If an image must be removed instead, first run `docker compose down` without `--volumes`, then run `docker image rm oscar:4.0.0`; a running or stopped Compose container can otherwise keep the image referenced.

For isolated Viewer development, `cd web/oscar-viewer`, run `npm ci`, and then run `npm run dev`. This is useful for UI iteration against reachable OSCAR nodes, but it does not validate the packaged Viewer, FFmpeg camera telemetry, PostgreSQL filtering, container configuration, or the upgrade path. Use the release ZIP for final system testing.

## Developer documentation

The [translation system guide](docs/TRANSLATION_SYSTEM.md) documents language selection and persistence, admin and viewer resource lookup, sensor and Lane System form metadata, localized README help, and the complete procedure and validation checklist for adding or restoring a supported language.

The [operational views guide](docs/OPERATIONAL_VIEWS.md) explains how to assign lanes to workstation views, use view-specific URLs, and import or export assignments in lane spreadsheets.

The [Status of Health guide](docs/STATUS_OF_HEALTH.md) documents lane-level RPM and camera connectivity, detector and tamper faults, extended occupancy, operational-view scoping, and the acceptance checklist.

## Build Windows offline media

On a connected Windows x86-64 build workstation with Docker available:

```powershell
powershell -File tools/offline/build-offline-bundle.ps1 -CreateArchive
```

The offline builder invokes `build-all.bat`, downloads checksum-pinned official Windows prerequisites, exports the required images, creates `SHA256SUMS`, and produces:

```text
build/offline/oscar-<version>-windows-x86_64-offline.zip
```

The offline deployment CLI performs no downloads.

## Release checklist

Before tagging a release:

1. Run `node tools/update-version.js <version>` to update `build.gradle`, the deployment name in `dist/config/standard/config.json`, and `OSCAR_VERSION` in `dist/release/.env.example`.
2. Update the parent and Viewer changelog headings plus the localized operator-manual titles and wrapper.
3. Run `node tools/validate-release-metadata.js <version>` and confirm `dist/release/postgis/pgdata` does not exist.
4. Run the appropriate canonical build script.
5. Run hardware and platform validation in their designated environments.

Tags matching `v*` trigger the release workflow. The workflow validates the tag and version metadata, invokes `build-all.sh`, and publishes the connected release ZIP, localized operator-manual PDFs, and source archive. The connected ZIP also contains the current Markdown guides and localized manuals; obsolete pre-4.0 manuals are excluded.

Offline Windows media is built and validated separately because it contains platform-specific installers and container images.
