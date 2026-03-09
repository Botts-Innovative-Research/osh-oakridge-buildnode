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
