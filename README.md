# OSH OAKRIDGE BUILDNODE

This repository packages the OSH server and OSCAR client deployment used for ORNL field and test systems.

## Requirements

- Java 21 or newer
- Docker Engine or Docker Desktop, running before launch
- A packaged OSCAR release archive, or a local source checkout for build workflows
- Node v22 only when building from source

## OSCAR 3.5.1 packaged release quick start

This section is for operators using the **prebuilt OSCAR 3.5.1 release ZIP**.

### 1. Verify required dependencies

Windows PowerShell:

```powershell
java -version
docker version
```

Linux:

```bash
java -version
docker version
```

Use **Java 21 or newer**. The launch scripts validate dependencies and will stop early if Java or Docker is missing or too old.

### 2. If you were previously running OSCAR, start fresh

Before extracting **OSCAR 3.5.1**, stop the old deployment and remove old local runtime artifacts.

Windows PowerShell:

```powershell
Get-CimInstance Win32_Process |
  Where-Object {
    $_.Name -match '^java(\.exe)?$' -and
    $_.CommandLine -like '*com.botts.impl.security.SensorHubWrapper*'
  } |
  Select-Object ProcessId, CommandLine

# Stop the old OSCAR JVM if one is still running
Stop-Process -Id <old_pid> -Force

# Stop and remove the old PostGIS container
docker rm -f oscar-postgis-container

# Remove the old Docker network if it exists
docker network rm oscar-postgis-network
```

Linux:

```bash
pgrep -af 'com.botts.impl.security.SensorHubWrapper'
kill <old_pid>

docker rm -f oscar-postgis-container
docker network rm oscar-postgis-network || true
```

Then delete the old extracted release folder, such as **oscar-3.5.0**, before extracting **oscar-3.5.1**.

### 3. Extract the release archive

Extract the downloaded ZIP to a fresh working directory.

### 4. Create the runtime environment file

For packaged releases, use the environment file that ships with the archive:

- if the package includes **env.txt**, rename it to **.env**
- if the package includes **env.template**, copy it to **.env**

Windows PowerShell:

```powershell
Copy-Item .\env.template .\.env
```

Linux:

```bash
cp env.template .env
```

Edit `.env` before first launch and at minimum confirm:

- `SYSTEM_PROFILE`
- `DB_NAME`
- `DB_USER`
- `DB_PASSWORD`
- `DB_PORT`
- `CONTAINER_NAME`

Useful optional settings include:

- `FORCE_RESTART=1` to replace an already-running OSCAR instance
- `ATTACH_TO_EXISTING=1` to monitor an already-running OSCAR instance
- `MAX_WAIT_SECONDS=300`
- `RETRY_MAX=120`
- `RETRY_INTERVAL=2`
- `POSTGIS_READY_DELAY=5`

### 5. Preferred first start: use the monitoring script

For testing, burn-in, and side-by-side field deployment, start OSCAR with the monitoring wrapper instead of launching the node directly.

Windows:

```bat
monitor-oscar.bat
```

Linux:

```bash
chmod +x launch-all.sh osh-node-oscar/launch.sh monitor-oscar.sh check-oscar-status.sh
./monitor-oscar.sh
```

This is the recommended first-run path because it:

- starts PostGIS and OSCAR using the current launch scripts
- captures memory, thread, JFR, and database snapshots over time
- produces a monitor directory and status report inputs automatically

### 6. Routine start without monitoring

When monitoring is not needed, use the top-level launch script:

Windows:

```bat
launch-all.bat
```

Linux:

```bash
./launch-all.sh
```

Prefer these **sessionless top-level launchers** over calling `osh-node-oscar/launch.(sh|bat)` directly unless you are debugging the node itself.

### 7. Running-instance handling

The launch and monitor scripts now detect already-running OSCAR JVMs.

Default behavior:

- `launch-all` refuses to start if OSCAR is already running
- `monitor-oscar` refuses to start if OSCAR is already running

Optional behaviors:

- set `FORCE_RESTART=1` to stop the running OSCAR instance and start fresh
- set `ATTACH_TO_EXISTING=1` when using `monitor-oscar` to monitor the running instance instead of replacing it

### 8. Generate a status report after startup

After the system has been up long enough to settle, generate a one-file report.

Windows PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\check-oscar-status.ps1
```

Linux:

```bash
./check-oscar-status.sh
```

### 9. Admin access

The admin username is typically **admin**. Do **not** assume the packaged password is always `admin`.

For packaged releases, the initial password should be managed through the packaged secret file or environment-driven password initialization flow. Verify the package contents, then change the password before production use.

## Building from source

Clone the repository and update all submodules recursively:

```bash
git clone git@github.com:Botts-Innovative-Research/osh-oakridge-buildnode.git --recursive
```

If you already cloned without `--recursive`, run:

```bash
cd path/to/osh-oakridge-buildnode
git submodule update --init --recursive
```

## Build

Navigate to the project directory:

```bash
cd path/to/osh-oakridge-buildnode
```

Run the build script.

Linux/macOS:

```bash
./build-all.sh
```

Windows:

```bat
build-all.bat
```

After the build completes, the output is written under `build/distributions/`.

## Source-tree deployment

If you are testing from a source checkout instead of a packaged release:

1. create `.env` from `env.template`
2. verify Java 21 and Docker
3. launch with `monitor-oscar` for first-run validation
4. use `check-oscar-status` after the system reaches steady state

## MediaMTX for larger camera deployments

For test systems and larger multi-lane deployments, consider placing **MediaMTX** in front of camera streams so OSCAR connects to stable local RTSP proxy paths instead of directly to every camera. See the updated MediaMTX guide in `dist/documentation/MediaMTX_OSCAR_camera_proxy_guide.md`.

## PostgreSQL tuning

The packaged launch scripts now size PostgreSQL by `SYSTEM_PROFILE`.

Representative values:

- `RPI4` -> max_connections 75
- `8GB` -> max_connections 125
- `16GB` -> max_connections 200
- `32GB` -> max_connections 300

The launchers also set:

- `superuser_reserved_connections=10`
- `idle_session_timeout=600000`
- connection and disconnection logging

## Secure node over TLS

To secure the OSH node over TLS, generate a Java keystore with an SSL certificate.

```text
keytool -genkeypair -alias <alias_name> -keyalg RSA -keysize 2048 -validity <days> -keystore <keystore_filename>.jks -storepass <keystore_password> -keypass <key_password> -dname "CN=<Common Name>, OU=<Organizational Unit>, O=<Organization>, L=<Locality>, ST=<State>, C=<Country>" -ext "SAN=<Subject Alternative Name>"
```

Then configure the keystore path, password, alias, and HTTPS port in `config.json` or in the Admin Panel under **Network -> HTTP Server**.

## Releasing a new version

### Release checklist

Before releasing from `dev`:

1. update `version` in `build.gradle`
2. update `deploymentName` in `dist/config/standard/config.json`
3. ensure `dist/release/postgis/pgdata` is not packaged
4. verify the release ZIP name matches the intended version, such as `oscar-3.5.1.zip`
5. verify the release root directory name also matches the intended version
6. verify `env.template`, release notes, README, and launch documentation all reflect the same version

### Release steps

1. merge `dev` into `main`
2. tag the release on `main`
3. push the release tag and allow the workflow to build and publish the release artifacts
