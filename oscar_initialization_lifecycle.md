# OSCAR System: Initialization and Restart Lifecycle

This document provides a comprehensive step-by-step detail of the initialization and restart lifecycle of the current working OSCAR hybrid system. It breaks down the exact logic, execution order, and specific mechanisms that orchestrate the PostGIS database, OSH Java backend, and certificate generation, which are critical when migrating to a fully containerized Docker Compose stack.

## 1. Startup Timing and Service Delays

### Boot Process and Execution Order
The current startup logic is driven by shell/batch scripts (e.g., `dist/release/launch-all.sh`, `launch-all.bat`), which manage the sequential initialization of components. The execution order is strictly enforced:
1. **Pre-flight Checks & Credentials:** Generates the `.db_password` file if it doesn't exist.
2. **PostGIS Initialization:** Builds the `oscar-postgis` Docker image and launches the database container.
3. **Wait-State Logic:** Repeatedly checks if the database is fully ready before proceeding to backend launch.
4. **Backend Launch:** Executes the backend startup script (`osh-node-oscar/launch.sh` or `launch.bat`).

### Wait-State Logic for PostGIS
The launch script uses an explicit loop to delay the backend startup until PostGIS has fully loaded its spatial extensions (`gis` and `template_postgis` databases).
1. **`pg_isready` Polling Loop:** The script polls the PostGIS container every 5 seconds (defined by `RETRY_INTERVAL`) using the `pg_isready` command targeting the `gis` database.
   ```bash
   RETRY_COUNT=0
   until docker exec -u "$DB_USER" "$CONTAINER_NAME" pg_isready -d "$DB_NAME" > /dev/null 2>&1; do
     echo "PostGIS not ready yet, retrying..."
     sleep "${RETRY_INTERVAL}"
   done
   ```
2. **Additional Buffer (Sleep 30):** Once `pg_isready` succeeds, an explicit 30-second sleep (`sleep 30`) is executed to ensure PostGIS has sufficient time to complete loading all internal initializations and spatial extensions before backend connections are attempted.
3. **Final Verification Loop:** A final safety loop ensures PostGIS hasn't entered a restart loop after the 30-second wait before allowing the backend to launch:
   ```bash
   until docker exec -u "$DB_USER" "$CONTAINER_NAME" pg_isready -d "$DB_NAME" > /dev/null 2>&1; do
     echo "PostGIS still restarting, waiting..."
     sleep 5
   done
   ```

## 2. Certificate Authority & TLS Generation

TLS generation is handled by the Java backend using `LocalCAUtility.java` (`security-utils/src/main/java/com/botts/impl/security/LocalCAUtility.java`).

### Timing of Certificate Generation
The certificate generation happens **on backend startup**, initiated when the `LocalCAUtility.checkAndRenewCertificates()` method is invoked. It checks if `osh-keystore.p12` exists. If not, it assumes a first-boot scenario and generates the CA and leaf certificates.

### Generation Mechanism
1. **Keystore Password Generation:** Generates a random 32-byte Base64 password and saves it to `.app_secrets`.
2. **Root CA Generation:** Generates a persistent self-signed RSA-2048 Root CA certificate (`CN=OSCAR Root CA`) valid for 20 years (7300 days).
3. **Leaf Certificate Generation:** Generates an RSA-2048 leaf certificate (`CN=localhost`) signed by the Root CA, valid for 1 year (365 days).
4. **Keystore Storage:** Stores both the root and leaf certificates in `osh-keystore.p12` (using PKCS12 format) under the aliases `root-ca` and `jetty`, respectively.
5. **Public Export:** Exports the Root CA public certificate to `root-ca.crt` for clients to trust.

### File Extraction and Proxy Access
*   **Format:** The certificates are stored primarily within the `osh-keystore.p12` Java Keystore format. The Root CA is also exported as a PEM-formatted `root-ca.crt`.
*   **Exposure to Reverse Proxy:** In a Docker Compose stack, if Caddy requires PEM-encoded `.crt` and `.key` files rather than `.p12` format, you may need an init-container or an update to `LocalCAUtility` to explicitly export `osh-leaf.crt` and `osh-leaf.key` to the filesystem alongside `root-ca.crt`.

## 3. Database Provisioning & Authentication

### Generating and Passing `.db_password`
1. The `.db_password` is generated on the host machine by the launch script (`launch-all.sh`) using OpenSSL during the pre-flight phase:
   ```bash
   if [ ! -f "$POSTGRES_PASSWORD_FILE" ]; then
       echo "Generating new database password..."
       openssl rand -base64 32 > "$POSTGRES_PASSWORD_FILE"
   fi
   ```
2. It is passed into the PostGIS Docker container via a combination of bind mounts and environment variables:
   *   `-v "$POSTGRES_PASSWORD_FILE:/run/secrets/db_password"`
   *   `-e POSTGRES_PASSWORD_FILE="/run/secrets/db_password"`

### Enforcing `scram-sha-256`
The enforcement of `scram-sha-256` authentication is handled explicitly in the PostGIS Dockerfile (`dist/release/postgis/Dockerfile`). The `POSTGRES_INITDB_ARGS` environment variable is set to configure the database initialization command:

```dockerfile
ENV POSTGRES_INITDB_ARGS="--auth-local=trust --auth-host=scram-sha-256 -c max_parallel_workers_per_gather=0 -c max_parallel_workers=0 -c ssl=on -c ssl_cert_file=/var/lib/postgresql/server.crt -c ssl_key_file=/var/lib/postgresql/server.key"
```
The `--auth-host=scram-sha-256` flag ensures all TCP connections (which the Java backend will use) require SCRAM-SHA-256 password hashing.

## 4. Setup Wizard & State Persistence (TOTP/Auth)

### Uninitialized vs. Initialized State
The system determines its initialization state dynamically on boot via `SecurityManagerImpl.isUninitialized()` (`include/osh-core/sensorhub-core/src/main/java/org/sensorhub/impl/security/SecurityManagerImpl.java`).

The system is considered **Uninitialized** (and thus redirects to the Setup Wizard) if any of the following conditions are met:
1.  The `IUserRegistry` is missing.
2.  The `admin` user does not exist in the registry.
3.  The `admin` user's password is a default value (e.g., null, empty, `"admin"`, `"oscar"`, `"test"`, `"__INITIAL_ADMIN_PASSWORD__"`, or matches a specific default hash signature `8x2vK/T2P9I2f2vK/T2P9A==`).
4.  The `admin` user has not configured TOTP (Two-Factor Authentication) secrets (`twoFactorSecret` is null).

If all conditions are cleared (admin exists, custom password set, TOTP enabled), the system boots in an **Initialized** state.

### State Persistence of Admin Credentials and TOTP
The security state, including users, roles, password hashes, and TOTP secrets, is managed by the `BasicSecurityRealm` module (`include/osh-core/sensorhub-core/src/main/java/org/sensorhub/impl/security/BasicSecurityRealm.java`) and `BasicSecurityRealmConfig.java`.

When the Setup Wizard is completed, the changes to the `admin` user (password hash, `twoFactorSecret`) are committed to the configuration. The persistence mechanism works as follows:
1.  **Serialization:** The `BasicSecurityRealmConfig` uses Gson to serialize user configurations (including `password` and `twoFactorSecret` fields from `BasicSecurityRealmConfig.UserConfig`) into JSON. Note that `BasicSecurityRealm.java` specifically handles *permissions* in `user_permissions.json` and `role_permissions.json`, while the overarching configuration state (the `users` array containing passwords/secrets) is inherently tied to the module's core JSON configuration (e.g., `config/modules/security.json`).
2.  **Filesystem Storage:** The state is saved to the backend's filesystem.
3.  **Survival Across Restarts:** Because these configuration files are written to the host filesystem (which should be mounted as a persistent volume in Docker), the updated `UserConfig` (with the hashed password and TOTP secret) is reloaded into memory during the `doInit()` phase of `BasicSecurityRealm` on the next boot, ensuring the system remains in an "Initialized" state.
