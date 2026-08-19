# OSCAR

OSCAR combines OpenSensorHub modules, the OSCAR viewer, PostgreSQL/PostGIS, and a TLS gateway into a hardened Docker Compose deployment.

Only the configured HTTPS port is published. PostgreSQL and the OSCAR application port remain on private Compose networks. Java 21.0.10 is included in the OSCAR container image and is not required on deployment hosts.

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

1. Update the version in `build.gradle`.
2. Set `deploymentName` in `dist/config/standard/config.json` to `OSCAR <version>`.
3. Set `OSCAR_VERSION` in `dist/release/.env.example` to the same version.
4. Confirm `dist/release/postgis/pgdata` does not exist.
5. Run the appropriate canonical build script.
6. Run hardware and platform validation in their designated environments.

Tags matching `v*` trigger the release workflow. The workflow validates the tag and version metadata, invokes `build-all.sh`, and publishes the connected release ZIP and source archive.

Offline Windows media is built and validated separately because it contains platform-specific installers and container images.
