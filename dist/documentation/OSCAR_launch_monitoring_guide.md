# OSCAR launch, monitoring, and database diagnostics guide

This guide explains the updated OSCAR launch and monitoring scripts for Linux and Windows. It covers:

- the purpose of `.env`, `launch-all`, `launch`, `monitor-oscar`, and `check-oscar-status`
- how to choose the right system profile
- how to start and stop OSCAR safely
- how to monitor memory and database usage
- how to diagnose PostgreSQL connection exhaustion
- how to clean up old artifacts

---

## 1. What changed

The launch scripts now do two different jobs:

- **launch scripts** size Java and PostgreSQL for the selected hardware profile and start the OSCAR stack
- **monitor scripts** capture time-series diagnostics while OSCAR runs
- **check scripts** summarize the latest run into one report file

The biggest recent addition is **database diagnostics**. The monitor now records PostgreSQL session counts, session states, and top session groups on each interval. The status-check script now includes database saturation analysis in the one-file report.

---

## 2. Files and what they do

### Shared configuration

#### `.env`
Holds deployment settings such as:

- `SYSTEM_PROFILE`
- `DB_NAME`
- `DB_USER`
- `DB_PASSWORD`
- `DB_PORT`
- `DB_HOST`
- `CONTAINER_NAME`
- keystore and truststore passwords
- optional JavaCPP and JFR overrides

This is the main place to choose the right profile.

### Linux launch files

#### `launch-all.sh`
Builds and starts the PostGIS container with profile-specific PostgreSQL settings, waits for the database to be ready, then starts OSCAR by calling `osh-node-oscar/launch.sh`.

#### `osh-node-oscar/launch.sh`
Loads `.env`, chooses the Java heap settings for the selected profile, sets up certificates, enables Native Memory Tracking, and starts OSCAR.

### Linux monitoring files

#### `monitor-oscar.sh`
Starts OSCAR, starts JFR, and captures repeated snapshots containing:

- JVM memory
- JFR status
- NMT summary
- thread dump
- Linux memory and swap state
- Docker status
- PostgreSQL session counts and session-state breakdown
- PostgreSQL tail logs

It also writes `db-connection-trend.csv`, which is the easiest file to inspect when diagnosing connection growth.

#### `check-oscar-status.sh`
Reads the latest monitor directory and writes a single text report that combines:

- current JVM state
- current memory and swap state
- current PostgreSQL session picture
- first snapshot vs latest snapshot
- last 20 snapshot trend lines
- recent OSCAR and Postgres logs

### Windows launch files

#### `launch-all.bat`
Windows equivalent of the Linux `launch-all.sh`. It starts the PostGIS container using the selected profile and then launches OSCAR.

#### `osh-node-oscar\launch.bat`
Windows equivalent of the Linux `launch.sh`. It starts OSCAR with the selected Java settings and Native Memory Tracking enabled.

### Windows monitoring files

#### `monitor-oscar.bat`
Starts OSCAR, attaches JFR with `jcmd`, and writes repeated snapshots for:

- JVM process state
- Windows commit and pagefile counters
- Docker status
- PostgreSQL session counts and top session groups

#### `check-oscar-status.ps1`
Windows equivalent of `check-oscar-status.sh`. It writes one status report file summarizing the latest monitor run.

---

## 3. Choosing the right profile

The most important setting in `.env` is:

```text
SYSTEM_PROFILE=16GB
```

Available profiles are usually:

- `RPI4`
- `8GB`
- `16GB`
- `32GB`

Choose the profile based on the machine that is actually running OSCAR.

### How to make sure you are using the right profile

1. Open `.env`
2. Confirm `SYSTEM_PROFILE` matches the host RAM class
3. Start OSCAR with the normal launch script
4. Check the launch output and verify the profile name printed by the script
5. Verify Postgres settings after startup:

Linux:

```bash
docker exec -it oscar-postgis-container psql -U postgres -d gis -c "show max_connections;"
```

Windows PowerShell:

```powershell
docker exec -it oscar-postgis-container psql -U postgres -d gis -c "show max_connections;"
```

For the current tuned setup, the intended PostgreSQL connection caps are:

- `RPI4`: 75
- `8GB`: 125
- `16GB`: 200
- `32GB`: 300

These are launch-script values, not `.env` values.

---

## 4. Why these scripts are useful

### Launch scripts

They keep OSCAR and Postgres sized consistently for the machine instead of using one oversized default everywhere.

### Monitor scripts

They answer questions like:

- is Java memory still growing?
- is swap/pagefile pressure building?
- is JVM native memory growing?
- is PostgreSQL session count rising toward the limit?
- are errors in the logs happening at the same time as DB pressure?

### Check scripts

They turn a whole monitor directory into one readable summary so you do not have to open dozens of snapshot files manually.

---

## 5. Dependencies

## Linux dependencies

Install or verify these:

- Docker
- Java JDK with `jcmd`
- Bash
- `psql` inside the Postgres container

Helpful but optional:

- `pmap`
- `vmstat`
- `free`

### How to install on Ubuntu

```bash
sudo apt update
sudo apt install openjdk-21-jdk docker.io procps psmisc
```

### How to check if they are installed

```bash
which java
which jcmd
which docker
which pmap
which vmstat
```

Check Docker:

```bash
docker --version
```

Check Java:

```bash
java -version
jcmd -h
```

## Windows dependencies

Install or verify these:

- Docker Desktop
- JDK with `jcmd.exe`
- PowerShell

### How to check on Windows

PowerShell:

```powershell
gcm java
gcm jcmd
gcm docker
```

If `jcmd` is not found, install a JDK and add its `bin` directory to `PATH`.

---

## 6. Starting OSCAR

## Linux normal start with monitoring

From the project root:

```bash
chmod +x launch-all.sh osh-node-oscar/launch.sh monitor-oscar.sh check-oscar-status.sh
nohup ./monitor-oscar.sh > monitor.out 2>&1 &
echo $! > monitor.pid
```

This starts:

- PostGIS
- OSCAR
- JFR
- memory and DB monitoring

## Linux start without monitoring

```bash
./launch-all.sh
```

## Windows normal start with monitoring

From the project root in `cmd`:

```bat
start /b monitor-oscar.bat
```

Or from PowerShell:

```powershell
Start-Process -FilePath .\monitor-oscar.bat
```

## Windows start without monitoring

```bat
launch-all.bat
```

---

## 7. Stopping OSCAR

## Linux

If you used the monitor script:

```bash
kill "$(cat monitor.pid)"
```

The monitor script is designed to stop:

- itself
- the OSCAR JVM
- the PostGIS container

## Windows

```bat
monitor-oscar.bat stop
```

This requests the same full-stack stop.

---

## 8. How to use the monitor output

Each monitor run creates a directory such as:

```text
oscar-monitor-20260503-174333
```

Inside it are:

- `launch.stdout.log`
- `launch.stderr.log`
- `jvm-pid.txt`
- `db-connection-trend.csv`
- one snapshot directory per interval

Each snapshot includes memory and DB files, for example:

- `nmt-summary.txt`
- `gc-heap-info.txt`
- `thread-print.txt`
- `db-total-sessions.txt`
- `db-by-state.txt`
- `db-by-app.txt`
- `db-activity-detail.txt`
- `db-error.txt`
- `docker-logs-tail.txt`

---

## 9. How to analyze the data

### Memory analysis

Look for whether these plateau:

- RSS / working set
- swap / pagefile usage
- thread count
- NMT committed memory

A healthy system usually rises at startup and then flattens.

### Database analysis

Look at:

- `db-total-sessions.txt`
- `db-by-state.txt`
- `db-by-app.txt`
- `db-connection-trend.csv`

A healthy DB profile usually looks like:

- total sessions rise at startup
- then total sessions plateau
- idle sessions stay reasonable
- total sessions remain comfortably below usable client slots

A suspicious DB profile looks like:

- total sessions keep climbing over time
- idle or idle-in-transaction sessions pile up
- `db-error.txt` contains `too many clients already`
- Postgres logs show repeated connection failures

### Important DB formula

Use:

```text
usable client slots = max_connections - superuser_reserved_connections
```

If total sessions are approaching that number, Postgres is near saturation.

---

## 10. How to create a one-file report

## Linux

```bash
./check-oscar-status.sh
```

This writes a file like:

```text
oscar-status-20260504-102524.txt
```

## Windows

```powershell
powershell -ExecutionPolicy Bypass -File .\check-oscar-status.ps1
```

That also writes a single status report file.

---

## 11. How to modify the scripts

### To change the profile mapping

Edit `launch-all.sh` or `launch-all.bat` for PostgreSQL sizing.

Edit `osh-node-oscar/launch.sh` or `osh-node-oscar\launch.bat` for Java sizing.

### To change monitoring frequency

Edit `INTERVAL` in `monitor-oscar.sh` or `monitor-oscar.bat`.

### To collect more DB detail

Add more `psql` queries in the monitor script and save them into the snapshot directory.

### To change JFR output size or retention

Edit:

- `JFR_MAX_AGE`
- `JFR_MAX_SIZE`
- `JFR_NAME`

---

## 12. When to delete files

You should delete monitor output when:

- you no longer need old runs
- the monitor directories are consuming too much disk space
- you have already captured the final report you need

## Linux cleanup

Delete old monitor output:

```bash
rm -rf oscar-monitor-2026*
```

Delete old one-file reports:

```bash
rm -f oscar-status-*.txt
```

## Windows cleanup

In PowerShell:

```powershell
Remove-Item .\oscar-monitor-* -Recurse -Force
Remove-Item .\oscar-status-*.txt -Force
```

Do **not** delete:

- `.env`
- `launch-all` scripts
- `launch` scripts
- keystore or truststore files
- `pgdata` unless you intend to wipe the database

---

## 13. Files you normally should not delete

Avoid deleting these unless you intentionally want to rebuild or reset the environment:

- `pgdata/`
- `osh-node-oscar/db/`
- `osh-node-oscar/osh-keystore.p12`
- `osh-node-oscar/truststore.jks`
- your main `.env`

---

## 14. How to verify dependencies after changes

## Linux quick check

```bash
which java
which jcmd
which docker
docker ps
```

## Windows quick check

```powershell
gcm java
gcm jcmd
gcm docker
docker ps
```

---

## 15. Recommended workflow for database issues

1. set the correct `SYSTEM_PROFILE`
2. start with `monitor-oscar`
3. let OSCAR run long enough to reach steady state
4. run `check-oscar-status`
5. inspect:
   - DB total sessions
   - DB by state
   - DB by app
   - Postgres logs
6. decide whether sessions plateau or keep climbing

If they keep climbing, you likely need one or more of:

- larger `max_connections`
- smaller Hikari pool limits
- reduced reconnect churn
- PgBouncer

---

## 16. Current practical interpretation

If memory plateaus but DB sessions keep climbing, the primary issue is no longer memory. It is database connection growth or connection retention.

That is why the updated monitor and check scripts now collect DB session data as first-class diagnostics.
