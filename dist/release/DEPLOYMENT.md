# Secure OSCAR Compose Deployment

This release runs the TLS gateway, OSCAR, and PostgreSQL as Docker Compose services. Only the configured HTTPS port is published to the host. PostgreSQL has no host port.

## Supported initial hosts

- Windows 11 x86-64 with Docker Desktop and WSL 2
- Ubuntu Server 24.04 x86-64 with Docker Engine and the Compose plugin
- Apple Silicon macOS with Docker Desktop; optional native-backed OSCAR features may be unavailable and the pinned PostGIS image runs under AMD64 emulation

## Required first-run files

Create these files before starting OSCAR:

```text
secrets/oscar-admin-password.txt
secrets/oscar-db-password.txt
secrets/postgres-bootstrap-password.txt
tls/server.crt
tls/server.key
```

Each password file must contain exactly one strong, unique password on its first line. Do not reuse the OSCAR administrator password for either database role.

Docker Compose implements these local secrets as read-only file mounts. On Ubuntu, make the `secrets` and `tls` directories mode `0700`, owned by the installing administrator, and the files inside them mode `0644` so the deliberately non-root service processes can read the mounted files. Other host users cannot traverse the protected parent directories. On Windows and macOS, restrict both directories to the installing administrator and the Docker service using host ACLs; do not place them in a shared folder. The setup CLI will apply these permissions automatically.

`server.crt` must be a PEM certificate or PEM certificate chain. `server.key` must be its unencrypted PEM private key. The certificate subject alternative names must include every DNS name or IP address operators use to reach OSCAR.

For an isolated site, a site administrator may create a deployment-specific certificate authority, use it to sign the server certificate, and install only the public CA certificate on client devices. Never copy the CA private key into `tls`, a container, or a diagnostic bundle.

The setup CLI will automate secret generation, certificate import/generation, access controls, and client trust export. Until that CLI is delivered, these files must be provisioned by the administrator.

## Configuration

Copy `.env.example` to `.env` to override defaults. The important settings are:

```dotenv
OSCAR_HTTPS_PORT=443
OSCAR_VERSION=3.5.2
```

WebID is disabled by default. An administrator may configure an approved local endpoint later through OSCAR. Failure to reach that optional endpoint must not prevent OSCAR from starting.

On first startup, the image copies the release configuration into the persistent `oscar_state` volume, hashes the supplied OSCAR administrator password, and configures the database connection to read its password from `/run/secrets/oscar_db_password`. Later OSH configuration saves overwrite only the persistent copy; application libraries and viewer assets remain read-only in the image.

## Start and stop

Windows:

```bat
launch-all.bat
stop-all.bat
```

Ubuntu or macOS:

```sh
./launch-all.sh
./stop-all.sh
```

Open `https://<certificate-name>/sensorhub/admin`. There is no default password.

Stopping the deployment does not remove the `oscar_state` or `postgres_data` volumes. Do not run `docker compose down --volumes` unless permanent deletion of all OSCAR and PostgreSQL data is intended.

## Security verification

After startup, verify:

```sh
docker compose ps
docker compose exec postgres psql --username oscar_bootstrap --dbname gis --command "SELECT rolname, rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls FROM pg_roles WHERE rolname = 'oscar_app';"
```

All reported privilege flags for `oscar_app` must be false. A scan of the host must show the selected HTTPS port and must not show ports 8282 or 5432.

Database backup, restore, schema migration, certificate renewal, offline map import, and versioned configuration migration will be administrator-only setup CLI operations. They are not delegated to the running OSCAR service.
