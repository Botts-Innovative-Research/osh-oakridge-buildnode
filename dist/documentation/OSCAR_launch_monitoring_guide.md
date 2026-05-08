# OSCAR launch, monitoring, and database diagnostics guide

This guide covers the current **OSCAR 3.5.1 packaged deployment workflow** for Linux and Windows.

It explains:

- how to prepare a fresh prebuilt release
- how to create `.env`
- how the updated `launch-all`, `launch`, `monitor-oscar`, `stop-all`, `reset-all`, and `check-oscar-status` scripts behave
- how already-running OSCAR instances are handled
- how to validate Java, Docker, memory, and database health
- how to use MediaMTX and status reports during testing and side-by-side field deployment

---

## 1. Recommended operating model

For **testing, burn-in, and side-by-side field deployment**, the preferred workflow is:

1. unzip the prebuilt release into a fresh folder
2. create `.env`
3. verify **Java 21+** and **Docker**
4. start with the **monitoring script**
5. let the system warm up
6. run the **status-check script**
7. review JVM, thread, and PostgreSQL behavior before wider deployment

Use the top-level **sessionless launchers** when possible:

- `launch-all.sh` / `launch-all.bat`
- `monitor-oscar.sh` / `monitor-oscar.bat`

Avoid launching `osh-node-oscar/launch.(sh|bat)` directly unless you are debugging the node itself.

---

## 2. Fresh install and upgrade cleanup

If the machine has previously run OSCAR, clean up the old deployment before extracting **OSCAR 3.5.1**.

### Linux

```bash
pgrep -af 'com.botts.impl.security.SensorHubWrapper'
kill <old_pid>

docker rm -f oscar-postgis-container
docker network rm oscar-postgis-network || true
rm -rf /path/to/old/oscar-3.5.0
```

### Windows PowerShell

```powershell
Get-CimInstance Win32_Process |
  Where-Object {
    $_.Name -match '^java(\.exe)?$' -and
    $_.CommandLine -like '*com.botts.impl.security.SensorHubWrapper*'
  } |
  Select-Object ProcessId, CommandLine

Stop-Process -Id <old_pid> -Force

docker rm -f oscar-postgis-container
docker network rm oscar-postgis-network
Remove-Item -Recurse -Force .\oscar-3.5.0
```

If the Docker network does not exist, that is fine. The goal is to avoid carrying old container state or an old extracted release folder into the new test run.

For a full local reset between side-by-side test installs, use `reset-all.sh` or `reset-all.bat`.

---

## 3. Required dependencies

### Linux

Required:

- Bash
- Java 21 or newer
- `keytool`
- Docker

Recommended for monitoring:

- `jcmd`
- `pmap`
- `free`
- `vmstat`

Ubuntu example:

```bash
sudo apt update
sudo apt install openjdk-21-jdk docker.io procps psmisc
```

Verify:

```bash
java -version
which keytool
which docker
which jcmd
```

### Windows

Required:

- PowerShell
- Java 21 or newer
- Docker Desktop or Docker Engine

Recommended:

- `jcmd.exe`

Verify:

```powershell
java -version
docker version
Get-Command java
Get-Command docker
Get-Command jcmd
```

The Windows launchers now use **PowerShell/CIM**-based process discovery. They do not depend on `wmic`.

### Important dependency policy

The updated scripts distinguish between **required** dependencies and **optional** runtime extras.

Hard failures are for things such as:

- Java
- Docker
- `keytool` where the script needs it
- required packaged files and directories such as `osh-node-oscar/lib`

Warning-only cases include:

- missing `.env` when defaults are available
- missing `trusted_certificates`
- missing `nativelibs`
- missing optional monitoring helpers such as `pmap` or `vmstat`

A missing `nativelibs` directory no longer stops startup by itself.

---

## 4. Environment file setup

Create `.env` before launch.

- if the packaged release ships **env.txt**, rename it to **.env**
- if the source tree ships **env.template**, copy it to **.env**

Linux:

```bash
cp env.template .env
```

Windows PowerShell:

```powershell
Copy-Item .\env.template .\.env
```

### Core settings

```dotenv
SYSTEM_PROFILE=16GB
DB_NAME=gis
DB_USER=postgres
DB_PASSWORD=postgres
DB_PORT=5432
DB_HOST=localhost
CONTAINER_NAME=oscar-postgis-container
```

### Process and monitor behavior settings

```dotenv
FORCE_RESTART=0
ATTACH_TO_EXISTING=0
MAX_WAIT_SECONDS=300
RETRY_MAX=120
RETRY_INTERVAL=2
POSTGIS_READY_DELAY=5
```

### What these mean

- `FORCE_RESTART=0` -> refuse to start if OSCAR is already running
- `FORCE_RESTART=1` -> stop the running OSCAR instance and start fresh
- `ATTACH_TO_EXISTING=0` -> monitor script refuses to attach to a running OSCAR process
- `ATTACH_TO_EXISTING=1` -> monitor script attaches to the running OSCAR process instead of replacing it
- `MAX_WAIT_SECONDS` -> how long monitor scripts wait for the Java process to appear
- `RETRY_MAX`, `RETRY_INTERVAL`, `POSTGIS_READY_DELAY` -> PostGIS readiness timing

---

## 5. Profile-based sizing

The launchers size Java and PostgreSQL by `SYSTEM_PROFILE`.

Supported profiles:

- `RPI4`
- `8GB`
- `16GB`
- `32GB`

Representative PostgreSQL `max_connections` values:

- `RPI4` -> 75
- `8GB` -> 125
- `16GB` -> 200
- `32GB` -> 300

The launchers also set:

- `superuser_reserved_connections=10`
- `idle_session_timeout=600000`
- connection and disconnection logging

---

## 6. Launch scripts and what they do

### `launch-all.sh` / `launch-all.bat`

These are the supported top-level launchers.

They:

- load `.env` when present
- validate Java and Docker
- detect an already-running OSCAR instance
- size PostgreSQL for the selected profile
- rebuild or reuse the PostGIS image
- remove the existing named PostGIS container if necessary
- start a new PostGIS container with the current settings
- wait for PostgreSQL readiness
- call `osh-node-oscar/launch.(sh|bat)`

### `osh-node-oscar/launch.sh` / `osh-node-oscar/launch.bat`

These launch only the OSCAR Java node.

They:

- load `.env` when present
- validate Java and `keytool`
- detect an already-running OSCAR instance
- choose heap and JavaCPP settings for the selected profile
- build or refresh the Java trust store
- initialize the packaged admin password flow
- start the Java process with Native Memory Tracking enabled

Optional runtime extras are handled gracefully:

- if `nativelibs` exists, the launcher adds `java.library.path`
- if `nativelibs` does not exist, the launcher warns and continues
- if `trusted_certificates` does not exist, the trust-store helper uses the copied default Java `cacerts` store and continues

Use these direct node launchers mainly for debugging.

---

## 7. How already-running OSCAR instances are handled

### Launch behavior

By default, if an OSCAR JVM is already running, `launch-all` and `launch` stop and print an error instead of silently starting another instance.

Typical message:

```text
OSCAR is already running with PID(s): ...
Stop the running instance first, or set FORCE_RESTART=1 to replace it.
```

### Force replacement

Set:

```dotenv
FORCE_RESTART=1
```

Then the scripts attempt to stop the running OSCAR process before starting a new one.

### Monitor attach behavior

For monitor wrappers, you have two supported choices:

- `FORCE_RESTART=1` -> replace the running OSCAR instance and monitor the new one
- `ATTACH_TO_EXISTING=1` -> keep the running OSCAR instance and attach monitoring to it

---

## 8. Starting OSCAR

### Recommended first-run start with monitoring

#### Linux

```bash
./monitor-oscar.sh
```

Preferred Linux sessionless launch:

```bash
nohup ./monitor-oscar.sh > monitor.out 2>&1 &
```

The packaged Linux build now marks all shipped `*.sh` files executable. If your unzip tool strips execute bits, restore them with:

```bash
chmod +x *.sh osh-node-oscar/*.sh
```

#### Windows

```bat
monitor-oscar.bat
```

Preferred Windows sessionless launch from PowerShell:

```powershell
Start-Process -WindowStyle Hidden -FilePath cmd.exe -ArgumentList '/c monitor-oscar.bat ^> monitor.out 2^>^&1' -WorkingDirectory (Get-Location)
```

This creates an output directory such as:

```text
oscar-monitor-20260505-032622
```

and captures:

- launch stdout and stderr
- JVM PID information
- JFR status
- GC heap information
- native memory summaries
- thread dumps
- Docker status
- PostgreSQL session and activity data
- trend CSV files for database sessions

### Routine start without monitoring

#### Linux

```bash
./launch-all.sh
```

#### Windows

```bat
launch-all.bat
```

---

## 9. Stopping and resetting OSCAR

### `stop-all`

The `stop-all` scripts now begin by asking the monitor to stop first.

### Monitor singleton protection

`monitor-oscar.sh` and `monitor-oscar.bat` now refuse duplicate monitor starts.

Typical behavior:

- a second monitor launch prints a clear error and exits
- the message tells the operator to run `stop-all` or the monitor stop command first
- stale monitor lock state from an unclean exit is cleaned up automatically when no live monitor process is found
- `monitor.last-status` is updated on every start, stop, refusal, and JVM exit
- `monitor.last-error` records the latest actionable failure text

This closes the gap where OSCAR already protected the backend process, but the monitor wrapper could still be started twice.

For sessionless launches such as `nohup`, a hidden `cmd.exe`, Task Scheduler, or a service wrapper, operators should check:

- `monitor.last-status`
- `monitor.last-error`
- `monitor.out` if stdout and stderr were redirected there

Behavior:

- attempt to stop the monitor
- do not wait indefinitely for monitor exit
- continue with direct fallback shutdown of OSCAR and PostGIS if needed

This avoids `stop-all` getting stuck on a monitor-closing attempt.

### `reset-all`

Use `reset-all` when you want a clean local test surface before trying a different packaged installation on the same machine.

It:

- asks the monitor to stop first
- stops OSCAR Java processes
- removes the PostGIS container and volumes
- clears local runtime state used by the packaged installation

Linux:

```bash
./reset-all.sh
```

Windows:

```bat
reset-all.bat
```

---

## 10. Status reports

### Linux

```bash
./check-oscar-status.sh
```

### Windows

```powershell
powershell -ExecutionPolicy Bypass -File .\check-oscar-status.ps1
```

These scripts summarize the latest monitor run into a single text report that includes:

- process status
- live JVM information
- heap and native memory summaries
- current container status
- PostgreSQL activity snapshots
- first-versus-latest trend comparison
- recent log tails

---

## 11. What healthy startup looks like

A healthy first-run profile typically looks like this:

- Java RSS rises during startup and then levels out
- thread count rises during startup and then stabilizes
- PostgreSQL sessions rise during startup and then plateau well below usable client slots
- swap or pagefile usage stays low
- `db-error` remains empty

### Important PostgreSQL rule

```text
usable client slots = max_connections - superuser_reserved_connections
```

If total sessions keep climbing toward that number, PostgreSQL is nearing saturation.

---

## 12. Interpreting the monitor output

Key files in a monitor directory:

- `launch.stdout.log`
- `launch.stderr.log`
- `jvm-pid.txt`
- `db-connection-trend.csv`
- one timestamped snapshot directory per interval

Key per-snapshot files:

- `nmt-summary.txt`
- `gc-heap-info.txt`
- `thread-print.txt`
- `db-max-connections.txt`
- `db-total-sessions.txt`
- `db-by-state.txt`
- `db-by-app.txt`
- `db-activity-detail.txt`
- `docker-logs-tail.txt`

Use `db-connection-trend.csv` as the fastest way to spot connection growth, plateauing, or saturation.

---

## 13. MediaMTX during field testing

For larger camera configurations or side-by-side test deployments:

1. start OSCAR with `monitor-oscar`
2. route camera streams through MediaMTX
3. let the system run long enough to capture reconnect and thread behavior
4. run `check-oscar-status`
5. compare JVM threads, reconnect logs, and PostgreSQL sessions before and after enabling MediaMTX

MediaMTX is especially helpful when many logical lane-camera assignments reuse a smaller number of real camera streams.

---

## 14. Troubleshooting checklist

### Launch fails before Java starts

Check:

- `.env` exists if you intend to override defaults
- Java 21+ is installed
- Docker is running
- required directories such as `osh-node-oscar/lib` exist
- the trust store and keystore files exist where the launch script expects them

Remember:

- missing `nativelibs` is warning-only
- missing `trusted_certificates` is warning-only if the default Java trust store can be copied successfully

### Monitor reports that another monitor is already running

This is expected if a previous `monitor-oscar` session is still active.

Use:

- `./stop-all.sh` or `monitor-oscar.bat stop` / `./monitor-oscar.sh stop` to stop the existing monitor cleanly
- the same monitor start command again after the first monitor exits

If the earlier monitor was terminated abruptly, the next start should clean up stale monitor lock state automatically.

### Monitor hangs waiting for Java

Check `launch.stdout.log` and `launch.stderr.log` inside the newest monitor directory.

Common causes:

- PostGIS container startup failed
- the OSCAR Java process exited immediately after launch
- a required runtime path is missing
- a certificate, trust store, or password-initialization step failed

### PostgreSQL sessions keep climbing

Inspect:

- `db-total-sessions.txt`
- `db-by-state.txt`
- `db-by-app.txt`
- `db-activity-detail.txt`
- `db-connection-trend.csv`

### Thread count keeps climbing

Inspect:

- `thread-print.txt`
- reconnect-related warnings in `launch.stdout.log`
- MediaMTX versus direct-camera behavior under the same test workload

---

## 15. Files you normally should not delete

Do not delete these unless you intentionally want to reset state:

- `.env`
- `osh-node-oscar/db/`
- `pgdata/`
- `osh-node-oscar/osh-keystore.p12`
- `osh-node-oscar/truststore.jks`

It is safe to delete old monitor directories and generated status reports once you have kept the reports you need.
