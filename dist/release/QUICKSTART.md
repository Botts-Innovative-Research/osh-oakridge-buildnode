# OSCAR Quick Start

## Windows 11

1. Install and start Docker Desktop, or use the Windows offline package that includes the approved installers.
2. Extract the OSCAR ZIP to a local NTFS directory.
3. Open PowerShell as Administrator in that directory.
4. Run:

```powershell
.\oscar.bat init
```

5. Enter the deployment hostname and an OSCAR administrator password of at least 14 characters.
6. Open the URL printed by setup, normally `https://localhost/sensorhub/admin`.

Setup creates deployment-specific database credentials, configures TLS, and starts OSCAR automatically. Do not run a separate launch script after initialization.

For offline media, verify it before initialization:

```powershell
.\verify-bundle.ps1
.\oscar.bat init
```

If a prerequisite installer requires a Windows restart, restart and run `oscar.bat init` again.

## Ubuntu Server 24.04

Install Docker Engine and the Docker Compose plugin, extract the connected release, and run:

```sh
sudo bash oscar.sh init
```

## Apple Silicon macOS

Install and start Docker Desktop, extract the connected release, and run:

```sh
sudo bash oscar.sh init
```

The pinned PostGIS image runs under AMD64 emulation.

## Routine administration

Windows:

```powershell
.\oscar.bat status
.\oscar.bat start
.\oscar.bat stop
.\oscar.bat restart
.\oscar.bat logs -Service oscar
```

Ubuntu/macOS:

```sh
sudo bash oscar.sh status
sudo bash oscar.sh start
sudo bash oscar.sh stop
sudo bash oscar.sh restart
sudo bash oscar.sh logs --service oscar
```

The default deployment uses HTTPS port `443`. `oscar.local` must resolve on every connecting workstation, and workstations must trust the selected certificate. See [DEPLOYMENT.md](DEPLOYMENT.md) for certificate import, DNS, log filtering, security verification, and upgrades.
