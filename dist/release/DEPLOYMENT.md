# OSCAR Administrator Guide

OSCAR runs as three Docker Compose services: an HTTPS gateway, the non-root OSCAR application, and PostgreSQL/PostGIS. Only the selected HTTPS port is published to the host. PostgreSQL has no host port.

Start with [QUICKSTART.md](QUICKSTART.md) for installation. This guide documents deployment choices and routine administration.

## Supported initial hosts

- Windows 11 x86-64 with Docker Desktop and WSL 2
- Ubuntu Server 24.04 x86-64 with Docker Engine and the Compose plugin
- Apple Silicon macOS with Docker Desktop; optional native-backed features may be unavailable and PostGIS runs under AMD64 emulation

## Administrative CLI

Use `oscar.bat` on Windows and `oscar.sh` on Ubuntu or macOS.

| Action | Windows | Ubuntu/macOS |
| --- | --- | --- |
| Initialize | `oscar.bat init` | `sudo bash oscar.sh init` |
| Check prerequisites | `oscar.bat check` | `sudo bash oscar.sh check` |
| Start | `oscar.bat start` | `sudo bash oscar.sh start` |
| Stop | `oscar.bat stop` | `sudo bash oscar.sh stop` |
| Restart | `oscar.bat restart` | `sudo bash oscar.sh restart` |
| Status | `oscar.bat status` | `sudo bash oscar.sh status` |
| Logs | `oscar.bat logs` | `sudo bash oscar.sh logs` |
| Upgrade | `oscar.bat upgrade` | `sudo bash oscar.sh upgrade` |

Mutating commands require an elevated Administrator PowerShell window on Windows or root privileges on Ubuntu/macOS.

`start`, `stop`, and `restart` never build or download images. `init` and `upgrade` may prepare missing images for a connected release. If `offline-images.tar` is present, image preparation uses only that archive and fails if any required image remains unavailable.

## Initial setup options

The defaults are hostname `oscar.local`, HTTPS port `443`, and a self-signed certificate. Setup asks for an administrator password of at least 14 characters, generates unique database credentials, validates TLS, and starts the deployment.

Windows example with an imported certificate:

```powershell
.\oscar.bat init -Hostname oscar.example.org -Port 443 `
    -TlsMode import -CertificatePath C:\certs\server.crt `
    -PrivateKeyPath C:\certs\server.key
```

Ubuntu/macOS equivalent:

```sh
sudo bash oscar.sh init --hostname oscar.example.org --port 443 \
    --tls-mode import --certificate /secure/server.crt \
    --private-key /secure/server.key
```

By default, setup maps the hostname only on the OSCAR host. Use `-SkipHostsEntry` or `--skip-hosts-entry` to leave local host resolution unchanged. Site DNS or a hosts entry is still required on every workstation that connects to OSCAR.

`server.crt` must be a PEM certificate or chain. `server.key` must be its matching unencrypted PEM private key. The certificate subject alternative names must contain every DNS name or IP address used to reach OSCAR.

For an isolated deployment, administrators may use a deployment-specific certificate authority and install only its public certificate on workstations. Never place the certificate-authority private key in this release directory, a container, or a diagnostic bundle.

## Windows offline installation

Extract the offline ZIP into a local NTFS directory. From an Administrator PowerShell window:

```powershell
.\verify-bundle.ps1
.\oscar.bat init
```

The verifier checks every file against `SHA256SUMS`. If WSL or Docker Desktop is missing, OSCAR launches the bundled official installer and resumes after it exits. If Windows requires a restart, restart and run `oscar.bat init` again.

The offline CLI does not contact package repositories or container registries. Docker Desktop licensing must be reviewed independently by the deploying organization.

## Logs

The default displays the last 200 lines from all services and exits:

```powershell
.\oscar.bat logs
```

Select a service and optionally follow it:

```powershell
.\oscar.bat logs -Service oscar -Tail 500
.\oscar.bat logs -Service postgres -Follow
.\oscar.bat logs -Service gateway
```

Ubuntu/macOS uses `--service`, `--tail`, and `--follow`.

## Persistent state and secrets

Initialization creates:

```text
.env
secrets/oscar-admin-password.txt
secrets/oscar-db-password.txt
secrets/postgres-bootstrap-password.txt
tls/server.crt
tls/server.key
```

Docker Compose mounts secrets read-only. On Ubuntu, the setup CLI makes `secrets` and `tls` mode `0700`, with contained files readable by the deliberately non-root services. On Windows, it restricts the directories to the installing administrator and `SYSTEM` while preserving container-readable, read-only mounts.

The application configuration is copied into the `oscar_state` volume on first startup. Runtime configuration saves update only that persistent copy. Application libraries and viewer assets remain read-only in the image. PostgreSQL data is stored in the `postgres_data` volume.

`oscar stop` retains containers and both data volumes. Never run `docker compose down --volumes` unless permanent deletion of all OSCAR and PostgreSQL data is explicitly intended.

WebID is disabled by default. Failure to reach an optional configured WebID endpoint must not prevent OSCAR from starting.

## Security verification

After startup:

```sh
docker compose ps
docker compose exec postgres psql --username oscar_bootstrap --dbname gis --command "SELECT rolname, rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls FROM pg_roles WHERE rolname = 'oscar_app';"
```

Every reported privilege flag for `oscar_app` must be false. A host scan must show the configured HTTPS port and must not show ports `8282` or `5432`.

## Upgrade

Place the new release files in the deployment directory while preserving `.env`, `secrets/`, and `tls/`, then run:

```powershell
.\oscar.bat upgrade
```

```sh
sudo bash oscar.sh upgrade
```

The command validates Compose, prepares the versioned images, recreates changed services, waits for health checks, and retains the fixed `oscar_state` and `postgres_data` volumes. It never removes volumes.

Database backup/restore, certificate renewal, rollback automation, and version-specific configuration migration are planned administrator operations and must be completed before upgrades are declared production-ready.

## Compatibility scripts

`setup.*`, `launch-all.*`, and `stop-all.*` remain as compatibility wrappers. New documentation and automation should use only `oscar.bat` or `oscar.sh`.

Offline map layers are not currently required. The CLI retains an explicit MBTiles import TODO for a future milestone.
