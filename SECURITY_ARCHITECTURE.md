# OSCAR Security Hardening Architecture

**Critical Domain Context:**
This project is an Open Source Central Alarm Station (OSCAR) monitoring radiation portal monitors. The application runs cross-platform on Windows, macOS, and Linux. The primary critical threat is the unauthorized suppression, modification, or spoofing of alarms. Note this specific nomenclature:
* **G Alarm:** Gamma Alarm.
* **N Alarm:** Neutron Alarm.
* **G-N:** Gamma Neutron Alarm.

**OpenSensorHub (OSH) Ecosystem Constraint:**
OSCAR is built on the OpenSensorHub framework. **Under no circumstances may any code modifications break compatibility with the larger OSH ecosystem.** * Standard OGC SWE, SOS, and SPS API endpoints must remain fully compliant.
* Sensor drivers (e.g., video processing, hardware interfaces mapped in `config.csv`) must not be prevented from initializing or communicating.
* Machine-to-machine API routes cannot rely on human-interactive authentication (like 302 redirects to a TOTP login).

**Global Build Constraint:**
Whenever generating or modifying Dockerfiles for this project, you MUST ensure the font package is explicitly set to `fonts-freefont-ttf`. This is strictly required to prevent downstream rendering failures in the application's graphical reporting components.

## Database Security Implementation

### SCRAM-SHA-256 Authentication
PostgreSQL is configured to enforce `scram-sha-256` authentication for all database users. This is initialized during the PostGIS container setup via `POSTGRES_INITDB_ARGS`.

### Docker Secrets for Database Credentials
The system uses Docker Secrets (via bind mounts) to manage database passwords.
- **Injected Secret Path**: `/run/secrets/db_password` within the container.
- **Environment Variable**: `POSTGRES_PASSWORD_FILE` points to this secret path.
- **Backend Priority**: The OSH Java backend is architected to prioritize the `POSTGRES_PASSWORD_FILE` environment variable during initialization, overriding any plaintext credentials in `config.json`.

### Configurable Networking and TLS
- **DB Host**: The database host is configurable via the `DB_HOST` environment variable (default: `localhost`), enabling secure deployment on separate LAN machines.
- **TLS Enforcement**: All connections from the OSH backend to PostGIS are secured over TLS. This is enforced by using `sslmode=require` in the JDBC connection string in the `ConnectionManager`.

## Application-Level Security Hardening

### Ephemeral CA and TLS Certificates
On first boot, the system generates an ephemeral Root CA and a Leaf TLS certificate.
- **Root CA Private Key**: Held strictly in memory during the generation of the leaf certificate and never persisted to disk.
- **Leaf Certificate**: Stored in a PKCS12 keystore (`osh-keystore.p12`).
- **Key Storage Security**: The keystore password is automatically generated and stored in a hidden `.app_secrets` file. Access to this file and the keystore is restricted to the executing user using POSIX permissions (Linux/macOS) or ACLs (Windows).
- **Public CA Download**: The public Root CA certificate is available for download at `/sensorhub/admin/ca-cert` to allow clients to establish trust.

### Setup Wizard and Credential Management
The system does not ship with default administrative credentials.
- **Uninitialized State**: If the system detects that it has not been configured (no admin password set), it enters an uninitialized state.
- **Mandatory Redirection**: In the uninitialized state, all requests to the root URL or Admin UI are redirected to a Setup Wizard.
- **Initialization**: The Setup Wizard forces the creation of a strong admin password (hashed using PBKDF2) and initializes the TOTP 2FA seed.
- **Bridged Session Authentication**: To prevent repeated authentication prompts between isolated Jetty contexts (e.g., the root Viewer and the `/sensorhub` Admin UI), the system implements a session bridging mechanism. Validated 2FA sessions are registered in a global registry and propagated across contexts using a `BridgedAuthenticator` and manual cookie header parsing.
