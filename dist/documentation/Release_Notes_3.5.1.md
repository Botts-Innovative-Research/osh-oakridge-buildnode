# Release Notes

## Overview

OSCAR **3.5.1** improves deployment stability, observability, and scalability for larger multi-lane systems. This release focuses on:

* reducing memory pressure
* preventing PostgreSQL connection exhaustion
* improving runtime diagnostics
* simplifying deployment on Linux and Windows
* improving support for MediaMTX-based camera proxy deployments
* making launch and monitoring behavior safer when OSCAR is already running
* improving first-run dependency and startup validation

These changes were validated against a high-load configuration monitoring **50 radiation portal monitors and 100 camera streams**.

This is a **prebuilt release**. Users should **unzip OSCAR 3.5.1 into a fresh directory** and start it with the included **monitoring script**, preferably using the **sessionless launch** when possible.

---

## Before you start

### Required dependencies

Install these before running OSCAR 3.5.1:

* **OpenJDK 21**
* **Docker**

The packaged release archive is expected to be named **`oscar-3.5.1.zip`**.

### Recommended deployment model

For testing, side-by-side field deployment, and first-run validation:

* unzip the release into a **new clean folder**
* rename `env.txt` to `.env` if needed
* select the correct system profile in `.env`
* use **MediaMTX** for camera-heavy deployments
* start OSCAR with the **sessionless monitoring launch** when possible
* use the new reset scripts when you need to clear a previous local test install before switching releases
* use the **check/status script** to review performance

---

## What is new

### Profile-based system sizing

Deployment now supports profile-based resource tuning instead of using one fixed memory configuration for every machine.

Supported profiles:

* `RPI4`
* `8GB`
* `16GB`
* `32GB`

These profiles allow the JVM and PostgreSQL configuration to be matched to the host hardware through the `.env` file and updated launch scripts.

### Updated launch flow

Launch scripts were updated for both Linux and Windows so they can:

* load the selected system profile
* size Java heap appropriately for the machine
* size PostgreSQL more appropriately for the machine
* start the PostGIS container with tuned settings
* provide a more consistent startup path across environments
* check for required dependencies before launch
* stop or refuse duplicate OSCAR launches based on script settings
* avoid hard failure on optional runtime paths such as `nativelibs` or extra trusted-certificate drop-ins when they are not present

### Safer process handling

The launch and monitoring scripts now better handle cases where OSCAR is already running.

Improvements include:

* detection of already running OSCAR processes
* clearer behavior when a prior instance is found
* support for stopping and relaunching cleanly when configured to do so
* monitor behavior aligned with launch behavior end to end
* reduced risk of duplicate Java processes and conflicting monitor sessions
* explicit single-instance protection for the Linux and Windows monitor wrappers

This makes startup behavior safer during testing, upgrades, and repeated field launches.

### Dependency and environment validation

Deployment scripts now better validate startup prerequisites and packaged paths before launch.

Improvements include:

* dependency checks for **Java 21** and **Docker**
* clearer startup errors when required tools are missing
* improved trust store handling on Windows
* better validation of expected runtime directories and packaged files
* updated environment template support for launch and monitor behavior

These changes make prebuilt deployment more reliable, especially on fresh Windows systems.

The current launcher checks now distinguish between required dependencies and optional runtime extras. Missing required tools such as Java or Docker still stop startup. Missing optional paths such as `nativelibs` or `trusted_certificates` no longer stop startup by themselves.

### PostgreSQL tuning improvements

PostgreSQL startup settings were updated to better support larger deployments.

Improvements include:

* increased connection limits by profile
* reduced per-connection memory pressure
* reserved superuser or admin connection slots
* idle session timeout support
* connection and disconnection logging for diagnostics

For the 16 GB profile, PostgreSQL was raised from the earlier 100-connection ceiling to a higher-capacity configuration, resolving the immediate `too many clients already` failure mode during large-scale operation.

### Hikari connection pool fix

The main cause of database session over-allocation was identified and corrected in the PostGIS datastore connection manager.

#### Root cause

* each Hikari pool was configured with `maximumPoolSize(20)`
* `minimumIdle` was not set
* Hikari therefore defaulted `minimumIdle` to the same value as `maximumPoolSize`
* with multiple pools active, the system held a very large number of idle PostgreSQL sessions open at all times

#### Fix

* reduced per-pool size
* explicitly set `minimumIdle(0)`
* shortened idle timeout behavior
* preserved sufficient active connection capacity while eliminating unnecessary idle connection hoarding

#### Result observed in testing

* PostgreSQL steady-state sessions dropped from about **186** to about **21**
* idle JDBC sessions dropped from about **180** to about **15**
* database headroom increased substantially
* the immediate Postgres connection saturation problem was eliminated

This is the most important backend stability improvement in this release.

### Monitoring and status scripts

New monitoring and status-check scripts were added for both Linux and Windows.

The monitor wrappers now also include a singleton guard so a second `monitor-oscar` launch is refused while another monitor is already active. This prevents duplicate snapshot loops, duplicate JFR starts, and confusing status output during sessionless operation. The wrappers now also update `monitor.last-status` and `monitor.last-error`, which makes it much easier to understand why a sessionless launch exited without staying attached to a terminal window.

These scripts can now:

* launch OSCAR under monitoring
* support sessionless launch for normal deployment use
* capture JVM memory status
* capture native memory tracking summaries
* capture JFR status
* capture OS memory and swap usage
* capture PostgreSQL session counts and saturation state
* capture database activity detail
* produce a single-file health and status report for rapid review

### Reset and shutdown scripts

The deployment scripts now also support cleaner teardown between test installs.

These updates include:

* `stop-all` scripts that try to stop the monitor first, then continue with direct fallback shutdown
* `reset-all` scripts that stop OSCAR processes, remove the PostGIS container and volumes, and clear local runtime state for clean retesting
* better support for side-by-side installation testing on the same host

### Improved database diagnostics

Monitoring now includes PostgreSQL visibility such as:

* `max_connections`
* `superuser_reserved_connections`
* total active sessions
* session state counts
* connection trend logging over time
* recent PostgreSQL log activity

This makes it much easier to distinguish between:

* memory pressure
* connection pool over-allocation
* true connection leaks
* normal steady-state pool behavior

### MediaMTX deployment guidance

Documentation was added for using **MediaMTX** as a local RTSP proxy layer to reduce the resource burden of handling many camera streams directly in OSCAR.

This supports a deployment model where:

* a smaller number of upstream camera streams are proxied locally
* multiple lanes can reuse proxied feeds
* OSCAR connects to stable local endpoints instead of managing a large number of direct camera connections

This architecture is recommended for larger systems and appears to reduce camera-related reconnect burden.

### Documentation updates

Documentation was added or expanded for:

* `.env` usage
* launch scripts
* monitoring scripts
* check or status scripts
* profile selection
* dependency installation and verification
* startup and shutdown procedures
* data interpretation and troubleshooting
* MediaMTX camera proxy setup
* already-running instance handling
* environment template settings for restart and attach behavior

---

## Problems addressed

### Memory pressure from fixed JVM sizing

Previous deployments used a one-size-fits-all Java memory model. On smaller or moderately sized machines, this could reserve too much memory for the JVM and reduce operating system and PostgreSQL headroom, increasing swap or pagefile pressure.

### PostgreSQL connection exhaustion

Large deployments were exhausting PostgreSQL connection capacity because multiple Hikari pools were keeping too many idle connections open. This caused:

* `too many clients already`
* Hikari connection timeouts
* database degradation under load

### Duplicate launch and monitoring confusion

Repeated test starts could leave users uncertain whether OSCAR was already running, whether a second Java process had been created, or whether the monitor had attached to the correct instance. A related gap was that the backend launchers had duplicate-start protection, but the monitor wrapper itself could still be started twice.

The updated scripts address this by making existing-instance behavior more explicit and consistent, and by refusing a second live monitor session.

### Limited visibility into failure mode

Earlier logs were often noisy or incomplete during failures. The new monitoring and status scripts make it easier to determine whether the bottleneck is:

* Java heap
* native memory
* swap usage
* PostgreSQL session pressure
* query activity
* startup or reconnect churn

---

## Behavior observed after the fixes

After applying the connection pool fix and updated deployment tuning:

* PostgreSQL sessions dropped from about **186** to about **21** in testing
* idle JDBC sessions dropped from about **180** to about **15**
* JVM swap usage dropped to **0** in the improved test run
* the system remained stable during startup and warm-up
* database headroom improved dramatically

---

## If you previously ran OSCAR

If this machine was already running an older OSCAR release, do **not** install OSCAR 3.5.1 over the top of the old directory.

Before starting OSCAR 3.5.1, stop and remove the older deployment components:

* stop the old PostGIS container
* remove the old PostGIS container
* remove the old Docker network used by the previous OSCAR deployment, **if one exists**
* stop any old OSCAR Java process that is still running
* delete the old `oscar-3.5.0` directory
* unzip OSCAR **3.5.1** into a fresh folder

### Linux cleanup example

Stop and remove the old PostGIS container:

```bash
docker stop oscar-postgis-container 2>/dev/null || true
docker rm oscar-postgis-container 2>/dev/null || true
```

If the previous deployment created a dedicated Docker network, remove it after the container is gone:

```bash
docker network ls
docker network rm <old-network-name>
```

Stop any running OSCAR Java process if needed:

```bash
pkill -f 'com.botts.impl.security.SensorHubWrapper' || true
```

Remove the previous OSCAR folder:

```bash
rm -rf ~/oscar-3.5.0
```

### Windows cleanup example

Stop and remove the old PostGIS container:

```powershell
docker stop oscar-postgis-container
docker rm oscar-postgis-container
```

If the previous deployment created a dedicated Docker network, remove it after the container is gone:

```powershell
docker network ls
docker network rm <old-network-name>
```

Stop any running OSCAR Java process if needed:

```powershell
Get-CimInstance Win32_Process |
  Where-Object {
    $_.Name -match '^java(\.exe)?$' -and
    $_.CommandLine -like '*com.botts.impl.security.SensorHubWrapper*'
  } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
```

Delete the previous OSCAR folder:

```powershell
Remove-Item -Recurse -Force .\oscar-3.5.0
```

If you are unsure whether a dedicated OSCAR Docker network exists, list networks first and remove only the one associated with the old OSCAR deployment.

---

## Fresh install workflow for OSCAR 3.5.1

### Step 1: unzip the release

Extract OSCAR **3.5.1** into a new folder.

The packaged release archive is expected to be named `oscar-3.5.1.zip`.

Example:

```text
oscar-3.5.1/
```

### Step 2: confirm dependencies

Make sure the machine has:

* **OpenJDK 21**
* **Docker**

The packaged release archive is expected to be named **`oscar-3.5.1.zip`**.

### Step 3: configure the environment file

The release may include the environment file as:

```text
env.txt
```

Rename it to:

```text
.env
```

For Linux packaged builds, the `*.sh` files in the archive are now packaged executable. If your unzip tool strips permissions, restore them with `chmod +x *.sh osh-node-oscar/*.sh` before launching.

Then edit the file and select the correct hardware profile:

* `RPI4`
* `8GB`
* `16GB`
* `32GB`

The environment template also supports launch and monitoring behavior such as restart and attach settings.

### Step 4: start with the monitoring script

For OSCAR 3.5.1, users should launch with the monitoring script so diagnostics begin immediately.

Use the **sessionless launch** when possible so OSCAR keeps running without requiring an attached terminal session.

#### Linux

Preferred:

```bash
./monitor-oscar.sh --daemon
```

If your script version starts sessionless by default, use:

```bash
./monitor-oscar.sh
```

Use an attached launch only for interactive troubleshooting.

#### Windows

Preferred:

```bat
monitor-oscar.bat
```

Use the sessionless option if your Windows wrapper provides both attached and detached modes.

Use an attached launch only for interactive troubleshooting.

### Step 5: check performance with the included status script

After startup, and again after the system has been running for a while, generate a status report.

#### Linux

```bash
./check-oscar-status.sh
```

#### Windows

```powershell
powershell -ExecutionPolicy Bypass -File .\check-oscar-status.ps1
```

This report helps verify that memory, swap, and PostgreSQL usage remain healthy.

---

## Recommended field test workflow

For testing and side-by-side field deployment, users should:

1. stop and remove any old OSCAR PostGIS container
2. remove the old OSCAR Docker network **if one exists**
3. stop any old OSCAR Java process if one is still running
4. delete the old `oscar-3.5.0` folder
5. unzip OSCAR **3.5.1** into a fresh folder
6. install or verify **OpenJDK 21** and **Docker**
7. rename `env.txt` to `.env` if needed
8. select the correct profile in `.env`
9. configure and use **MediaMTX** for camera-heavy systems
10. start OSCAR with the **sessionless monitoring launch** when possible
11. use the check or status script to compare system behavior and performance
12. use the reset script when you need to remove the local OSCAR runtime state before testing another package on the same machine

This is the preferred workflow for:

* first-time deployment on a machine
* side-by-side comparison with another build
* validating memory behavior
* validating PostgreSQL behavior
* validating MediaMTX camera proxy performance

---

## Included updates

### Linux

* `.env`-based configuration
* `launch-all.sh`
* `launch.sh`
* `monitor-oscar.sh`
* `check-oscar-status.sh`

### Windows

* `.env`-based configuration
* `launch-all.bat`
* `launch.bat`
* `monitor-oscar.bat`
* `check-oscar-status.ps1`

---

## Recommended operating model

### Deployment

* select the correct hardware profile in `.env`
* use the updated launch scripts
* use the **sessionless monitoring launch** for initial validation and normal field deployment when possible
* use the attached launch only for interactive troubleshooting
* let the scripts manage already-running instances instead of manually launching duplicates
* use MediaMTX where many camera streams are involved
* review generated status reports during early burn-in testing

### Validation after upgrade

After upgrading, confirm that:

* PostgreSQL sessions plateau well below the configured connection limit
* swap usage remains low or zero
* JVM RSS stabilizes after startup
* thread count does not continuously climb over long runs
* database status reports do not show saturation errors

---

## Known issues still under observation

These changes significantly improve stability, but a few items are still worth monitoring:

* `RapiscanSensor` parse errors such as `For input string: "000NaN"`
* repeated MQTT `Broken pipe` errors
* high thread counts in some runs
* reconnect churn on certain devices or services

These do not appear to be the primary cause of the major stability issue addressed in this release, but they remain candidates for future cleanup.

---

## Upgrade notes

1. Stop and remove any previous OSCAR PostGIS container.
2. Remove the previous OSCAR Docker network **if one exists**.
3. Stop any previous OSCAR Java process that is still running.
4. Delete the old `oscar-3.5.0` directory.
5. Unzip OSCAR **3.5.1** into a fresh directory.
6. Install **OpenJDK 21** and **Docker**.
7. Rename `env.txt` to `.env` if needed.
8. Edit `.env` and select the correct hardware profile.
9. For camera-heavy deployments, configure MediaMTX.
10. Start the system with the **sessionless monitoring launch** when possible.
11. Use the check or status script after startup and again after runtime burn-in.

---

## Summary

This release materially improves OSCAR behavior on larger systems by:

* matching resource use to host hardware
* reducing unnecessary database connection retention
* improving monitoring and diagnostics
* increasing deployment consistency across Linux and Windows
* supporting MediaMTX-based camera proxy architectures
* validating dependencies and packaged startup requirements earlier
* handling already-running OSCAR instances more safely

The biggest backend improvement is the correction of oversized Hikari idle pooling, which reduced PostgreSQL session usage from approximately **186** to approximately **21** in testing.
