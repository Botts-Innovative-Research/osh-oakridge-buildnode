# OSCAR Quick Start

## Windows 11

1. Choose `offline-full` when Docker Desktop or WSL may need installation. Choose `offline-images` when compatible Docker Desktop, WSL 2, and Docker Compose are already installed and running.
2. Extract the OSCAR ZIP to a local NTFS directory.
3. Double-click `oscar.bat`, approve the Windows administrator prompt, and enter `init` at the `oscar>` prompt.
4. Alternatively, for scripted or terminal-based setup, run:

```powershell
.\oscar.bat init
```

5. Enter the deployment hostname and an OSCAR administrator password of at least 14 characters.
6. Open the URL printed by setup, normally `https://oscar.local/sensorhub/admin`.

Setup creates deployment-specific database credentials, configures TLS, and starts OSCAR automatically. Do not run a separate launch script after initialization.

For offline media, verify it before initialization:

```powershell
.\verify-bundle.ps1
.\oscar.bat init
```

Verification is remembered for the current bundle manifest, so `init` does not hash the large image archive again. You can also run `oscar.bat verify` at any time. For the images-only artifact, use `oscar.bat init -Prerequisites existing` to guarantee setup will not launch prerequisite installers.

If a prerequisite installer requires a Windows restart, restart and run `oscar.bat init` again.

## Ubuntu Server 24.04

Install Docker Engine and the Docker Compose plugin, extract the connected release, and run:

```sh
sudo bash oscar.sh init
```

On a graphical Ubuntu installation, double-click the executable `oscar.sh` launcher to open the same interactive menu. Ubuntu Server administrators use the command above because the server has no desktop environment.

## Apple Silicon macOS

Install and start Docker Desktop, extract the connected release, and run:

```sh
sudo bash oscar.sh init
```

The pinned PostGIS image runs under AMD64 emulation.

On macOS, opening executable `oscar.sh` in Terminal with no arguments displays the interactive menu. Terminal commands remain available for environments whose file association does not execute shell scripts.

## Routine administration

Double-click/open `oscar.bat` or `oscar.sh` with no arguments to keep an administration window open. Enter commands such as `status`, `start`, `stop`, `restart`, `logs -Service oscar` (Windows), or `logs --service oscar` (Ubuntu/macOS). Enter `exit` to close it. Passing arguments directly continues to work for scripts and experienced administrators:

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

The default deployment uses HTTPS port `443`. Setup maps `oscar.local` on the OSCAR host. Other connecting workstations must resolve the selected hostname through DNS or their own hosts entry, and workstations must trust the selected certificate. See [DEPLOYMENT.md](DEPLOYMENT.md) for certificate import, DNS, log filtering, security verification, and upgrades.
Entering the hostname without `https://` is supported on the default port; the gateway redirects port 80 to HTTPS.

The release's `documentation` directory contains the current deployment guide, operational-view and Status of Health guides, and all four localized operator manuals. Official GitHub release artifacts also include the generated, version-labeled PDF manuals.
