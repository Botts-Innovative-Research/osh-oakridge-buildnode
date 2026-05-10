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

### 2. Extract the release archive to a fresh directory

Extract the downloaded ZIP to a fresh working directory.

Do not launch a new release on top of an older extracted directory. Reusing an old directory can leave behind monitor state, runtime data, logs, or generated config that makes troubleshooting harder.

### 3. Create the runtime environment file

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

### 4. Preferred production start: use `launch-all` sessionless

For routine production use, prefer the top-level **`launch-all`** scripts and run them **sessionless by default**. This avoids depending on an open SSH session, an RDP window, or a console that might be closed later.

`launch-all` is the preferred production path because it starts PostGIS and OSCAR with the selected `.env` profile without the extra monitor loop, recurring snapshots, JFR checks, thread dumps, database trend files, and monitor-directory logging. This keeps routine startup simpler and avoids collecting detailed profile data when operators do not need an in-depth system profile.

Prefer these **top-level launchers** over calling `osh-node-oscar/launch.(sh|bat)` directly unless you are debugging the node itself.

#### Windows production start

Interactive:

```bat
launch-all.bat
```

Sessionless from PowerShell:

```powershell
Start-Process cmd.exe `
  -ArgumentList '/c', 'launch-all.bat > launch.out 2>&1' `
  -WorkingDirectory $PWD `
  -WindowStyle Hidden
```

#### Linux production start

Interactive:

```bash
./launch-all.sh
```

Sessionless:

```bash
nohup ./launch-all.sh > launch.out 2>&1 &
```

#### Production auto-start after reboot

For production systems, configure the machine to start OSCAR automatically after restart.

##### Windows Task Scheduler

Create a scheduled task that:

- runs **whether the user is logged on or not**
- triggers **at startup**
- starts in the extracted OSCAR directory
- launches `launch-all.bat`
- uses a small startup delay if Docker Desktop needs time to initialize
- restarts the task on failure

A practical action is:

```text
Program/script: powershell.exe
Arguments: -NoProfile -ExecutionPolicy Bypass -Command "Set-Location 'C:\path\to\oscar-3.5.1'; cmd /c launch-all.bat >> launch.out 2>&1"
```

If using Docker Desktop on Windows, make sure Docker Desktop itself is configured to start with Windows before relying on the scheduled OSCAR start.

##### Linux systemd

Use a dedicated `systemd` unit so OSCAR starts after Docker is available and restarts automatically if the service fails.

Example `/etc/systemd/system/oscar.service`:

```ini
[Unit]
Description=OSCAR launch-all service
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=simple
User=oscar
WorkingDirectory=/home/oscar/oscar-3.5.1
ExecStart=/bin/bash -lc './launch-all.sh'
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

Then enable it:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now oscar.service
```

Also ensure Docker starts on boot:

```bash
sudo systemctl enable docker
```

### 5. Validation, troubleshooting, and profiling: use `monitor-oscar`

For testing, burn-in, side-by-side field evaluation, troubleshooting, and system profiling, start OSCAR with the monitoring wrapper instead of `launch-all`.

#### Windows monitor start

Preferred interactive start:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\monitor-oscar.ps1
```

Preferred sessionless start:

```powershell
Start-Process powershell.exe `
  -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"$PWD\monitor-oscar.ps1" `
  -WindowStyle Hidden `
  -RedirectStandardOutput "$PWD\monitor.out" `
  -RedirectStandardError "$PWD\monitor.err"
```

If `monitor-oscar.bat` is still present in a package, treat `monitor-oscar.ps1` as the preferred Windows monitor entrypoint.

#### Linux monitor start

```bash
chmod +x launch-all.sh osh-node-oscar/launch.sh monitor-oscar.sh check-oscar-status.sh
./monitor-oscar.sh
```

Linux sessionless launch:

```bash
nohup ./monitor-oscar.sh > monitor.out 2>&1 &
```

This is the preferred validation and troubleshooting path because it:

- starts PostGIS and OSCAR using the current launch scripts
- captures memory, thread, JFR, and database snapshots over time
- produces a monitor directory and status report inputs automatically
- gives operators the evidence needed to compare profiles, diagnose startup failures, and confirm that PostgreSQL sessions and JVM threads stabilize

Once the system is validated and no in-depth profile is needed, switch routine production starts back to `launch-all`.

### 6. Running-instance handling and duplicate monitor protection

The launch and monitor scripts detect already-running OSCAR JVMs.

Default behavior:

- `launch-all` refuses to start if OSCAR is already running
- `monitor-oscar` refuses to start if OSCAR is already running
- `monitor-oscar` also refuses to start if another `monitor-oscar` wrapper is already active

Optional behaviors:

- set `FORCE_RESTART=1` to stop the running OSCAR instance and start fresh
- set `ATTACH_TO_EXISTING=1` when using `monitor-oscar` to monitor the running instance instead of replacing it

When using `nohup`, Task Scheduler, `Start-Process`, or another sessionless strategy, check these files after launch:

- `monitor.last-status`
- `monitor.last-error`
- `monitor.out`
- `monitor.err` on Windows PowerShell launches that redirect stderr separately

If a second monitor start is refused, `monitor.last-status` records a clear failure such as `FAILED duplicate_monitor ...` so the operator can tell why the wrapper exited without staying attached to the terminal.

### 7. Reset and full cleanup guidance

If you were previously running OSCAR, stop the old deployment before extracting and launching a new copy.

#### Normal stop

Windows:

```bat
stop-all.bat
```

Linux:

```bash
./stop-all.sh
```

Also verify no old OSCAR JVM is still running.

Windows PowerShell:

```powershell
Get-CimInstance Win32_Process |
  Where-Object {
    $_.Name -match '^java(\.exe)?$' -and
    $_.CommandLine -like '*com.botts.impl.security.SensorHubWrapper*'
  } |
  Select-Object ProcessId, CommandLine
```

Linux:

```bash
pgrep -af 'com.botts.impl.security.SensorHubWrapper'
```

#### If `reset-all` was run but old lanes still appear

If a user runs the reset script while a monitor wrapper is still active, the monitor can restart OSCAR and old lanes can appear again. In that case, do a full cleanup:

1. run `stop-all` first so the monitor wrapper and OSCAR JVM are both stopped
2. confirm no `monitor-oscar` wrapper and no `SensorHubWrapper` JVM are still running
3. delete the extracted release directory
4. re-extract the ZIP
5. recreate `.env`
6. relaunch using the preferred sessionless method

Linux example:

```bash
./stop-all.sh
cd ..
sudo rm -r oscar-3.5.1
unzip oscar-3.5.1.zip
cd oscar-3.5.1
cp env.template .env
nohup ./launch-all.sh > launch.out 2>&1 &
```

On Linux, removing the extracted release directory may require `sudo` depending on how files were created during previous runs.

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
3. launch with `monitor-oscar` for first-run validation, troubleshooting, or profiling
4. use `check-oscar-status` after the monitored system reaches steady state
5. switch routine production starts to `launch-all` once validation is complete
6. use sessionless launch methods for unattended systems instead of relying on an open terminal

## MediaMTX for larger camera deployments

For larger camera counts, place **MediaMTX** in front of the RTSP sources and point OSCAR at the local MediaMTX proxy paths.

This reduces load on the Java backend because OSCAR no longer has to open, maintain, and recover every remote camera connection directly. MediaMTX absorbs much of the connection churn, buffering, and stream fan-out work, while OSCAR reads from fewer, more stable local proxy endpoints.

Use `monitor-oscar` while validating the camera profile, then return to `launch-all` for routine production operation. Keep the MediaMTX deployment simple and focused on camera proxying. See `dist/documentation/MediaMTX_OSCAR_camera_proxy_guide.md` for the full guide.

## PostgreSQL tuning

The packaged launch scripts size PostgreSQL by `SYSTEM_PROFILE`.

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
