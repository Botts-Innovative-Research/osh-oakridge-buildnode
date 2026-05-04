# OSCAR Launch, Monitoring, and Status Guide

This guide explains the purpose and use of the updated `.env`, `launch-all`, `launch`, `monitor-oscar`, and `check-oscar-status` scripts for both Linux and Windows. It covers profiles, dependencies, startup and shutdown flow, cleanup, and how to interpret the monitoring output.

## 1. What changed and why

The updated scripts were designed to make OSCAR easier to run, safer on smaller machines, and easier to diagnose when memory or stability problems appear.

The main improvements are:

- **Profile-based sizing** so Java and PostgreSQL use settings that fit the machine.
- **Safer defaults** for a 16 GB machine and other profiles.
- **Separation of responsibilities**:
  - `.env` holds deployment settings.
  - `launch-all` starts PostgreSQL and then launches OSCAR.
  - `launch` starts the Java node with the right memory and diagnostics.
  - `monitor-oscar` starts OSCAR and continuously collects diagnostic snapshots.
  - `check-oscar-status` summarizes all collected data into a single report file.
- **Built-in diagnostics** such as Native Memory Tracking and JFR support.
- **Cleaner testing workflow** so you can compare runs and determine whether memory is stable or leaking.

---

## 2. Which files are involved

### Shared configuration

- `.env`

### Linux

- `launch-all.sh`
- `osh-node-oscar/launch.sh`
- `monitor-oscar.sh`
- `check-oscar-status.sh`

### Windows

- `launch-all.bat`
- `osh-node-oscar\launch.bat`
- `monitor-oscar.bat`
- `check-oscar-status.ps1`

---

## 3. What each file does

## `.env`

This file is the shared configuration layer. It tells the scripts which profile to use, how to connect to PostgreSQL, and which passwords to pass into the Java process.

Typical variables:

```env
SYSTEM_PROFILE=16GB
DB_NAME=gis
DB_USER=postgres
DB_PASSWORD=postgres
DB_PORT=5432
DB_HOST=localhost
CONTAINER_NAME=oscar-postgis-container
KEYSTORE_PASSWORD=CHANGE_ME
TRUSTSTORE_PASSWORD=CHANGE_ME
JAVACPP_MAX_BYTES=
JAVACPP_MAX_PHYSICAL_BYTES=
JFR_FILENAME=
```

Why it is useful:

- keeps machine-specific configuration out of the launch scripts
- lets you switch between profiles without editing multiple files
- makes Linux and Windows setups consistent

How to modify it:

- change `SYSTEM_PROFILE` when moving to a different machine size
- change the DB settings if PostgreSQL is not local
- change the passwords to match your real keystore and truststore values
- optionally override JavaCPP or JFR paths only when needed

---

## `launch-all.sh` / `launch-all.bat`

This is the top-level launcher. It reads `.env`, starts the PostGIS container with profile-appropriate settings, waits for PostgreSQL to become ready, and then starts OSCAR by calling the node-specific `launch` script.

Why it is useful:

- one command starts the full stack
- PostgreSQL settings are tied to the profile
- ensures the DB is available before Java starts
- helps keep tests repeatable

What it usually does:

1. reads `.env`
2. maps `SYSTEM_PROFILE` to PostgreSQL settings
3. builds or starts the PostGIS container
4. waits for `pg_isready`
5. enters `osh-node-oscar`
6. runs `launch.sh` or `launch.bat`

How to modify it:

- change PostgreSQL memory settings if your workload changes
- change container name or port if you need multiple local deployments
- change image/tag names if your Docker workflow changes

Important note:

If you change PostgreSQL settings, you need the container to be recreated or restarted in a way that actually applies the new settings. The updated launchers were designed to make that more predictable.

---

## `osh-node-oscar/launch.sh` / `osh-node-oscar/launch.bat`

This script starts the Java node itself. It reads `.env`, maps the selected profile to Java memory settings, sets up certificates, enables diagnostics, and launches the OSCAR process.

Why it is useful:

- central place for Java sizing
- keeps profile logic out of the top-level launcher
- enables Native Memory Tracking so memory problems can be investigated later
- passes JavaCPP limits to help control native memory behavior

Typical responsibilities:

- choose `-Xms` and `-Xmx` from `SYSTEM_PROFILE`
- set `-XX:+UnlockDiagnosticVMOptions`
- set `-XX:NativeMemoryTracking=summary`
- set JavaCPP limits such as:
  - `-Dorg.bytedeco.javacpp.maxBytes=...`
  - `-Dorg.bytedeco.javacpp.maxPhysicalBytes=...`
- set keystore and truststore paths
- start `com.botts.impl.security.SensorHubWrapper`

How to modify it:

- adjust profile memory values if testing shows a machine can safely handle more or needs less
- change JavaCPP limits if native memory use is too tight or too loose
- update certificate paths if the install layout changes
- add temporary JVM flags for debugging

What not to remove:

- `-XX:+UnlockDiagnosticVMOptions`
- `-XX:NativeMemoryTracking=summary`

These are required for native memory inspection with `jcmd`.

---

## `monitor-oscar.sh` / `monitor-oscar.bat`

This is the diagnostic runner. It starts OSCAR, waits for the JVM to appear, starts JFR, and collects periodic snapshots into a timestamped `oscar-monitor-*` directory.

Why it is useful:

- gives you time-series data instead of one-off guesses
- captures memory, swap or pagefile, threads, and JVM info while OSCAR is running
- makes it easy to compare startup, steady state, and failure periods
- can be used as the primary launch method when you are testing stability

What it collects over time:

- JVM PID and command line
- process memory details
- thread counts
- heap information
- native memory summaries
- JFR recordings
- system memory and swap or pagefile state
- launch stdout and stderr logs

Linux snapshots commonly include:

- `/proc/<pid>/status`
- `/proc/<pid>/smaps_rollup`
- `pmap -x`
- `free -h`
- `vmstat`
- `jcmd VM.native_memory summary`
- `jcmd GC.heap_info`
- `jcmd JFR.check`

Windows snapshots commonly include the nearest equivalents through PowerShell, `tasklist`, `wmic` or CIM, performance counters, and `jcmd`.

How to modify it:

- change the snapshot interval if you want more or less detail
- change the match expression if the Java main class changes
- change the JFR size or age limits
- add extra OS-level commands if you want more counters

---

## `check-oscar-status.sh` / `check-oscar-status.ps1`

This is a reporting script. It reads the latest monitor directory and writes one report file that summarizes the current run.

Why it is useful:

- gives you one file to review or share
- compares first and latest snapshots
- shows recent trend lines
- shows whether memory is rising, flattening, or thrashing

What it includes:

- live process status
- live JVM state
- live JFR and NMT information
- system memory and swap or pagefile status
- first snapshot summary
- latest snapshot summary
- recent trend table
- log tails
- a quick interpretation section

How to modify it:

- change how many recent snapshots are included
- add custom grep or PowerShell parsing for errors you care about
- add application log searches for reconnect loops or parse failures

---

## 4. Choosing the right profile

`SYSTEM_PROFILE` is the most important setting in `.env`.

### Recommended meanings

- `RPI4`: very constrained system
- `8GB`: small development or reduced-workload machine
- `16GB`: reasonable full-node starting point
- `32GB`: larger system with more headroom

### How to make sure you use the right profile

Use the profile that matches the **actual machine memory**, not what you hope the workload can handle.

Linux:

```bash
free -h
```

Windows PowerShell:

```powershell
Get-CimInstance Win32_ComputerSystem | Select-Object TotalPhysicalMemory
```

General rule:

- use `16GB` only on a machine with about 16 GB RAM
- use `8GB` on smaller test systems
- use `32GB` only when the machine really has that headroom
- when in doubt, choose the **smaller** profile first

### Why this matters

The Java heap is not the only consumer of memory. OSCAR also uses:

- native libraries
- thread stacks
- PostgreSQL
- Docker
- OS page cache
- FFmpeg or JavaCPP native memory if video is enabled

A machine can fail even when Java heap is not full if native memory and database memory are too large.

---

## 5. Recommended profile behavior

The modified launchers use conservative sizing. A reasonable starting strategy is:

- smaller `Xms` than `Xmx`
- conservative PostgreSQL settings on shared hosts
- Native Memory Tracking enabled
- JFR started by the monitor rather than by the Java launcher

If a profile proves stable for your workload, you may increase it carefully. Do not scale memory up just because RAM exists.

---

## 6. Installing dependencies

## Linux dependencies

You normally need:

- Java **JDK**, not just a JRE
- Docker
- Bash
- `jcmd` (comes with the JDK)
- `pg_isready` inside the PostgreSQL container image
- optional helpers: `pmap`, `vmstat`, `free`

### Ubuntu or Debian example

```bash
sudo apt update
sudo apt install -y openjdk-21-jdk docker.io procps psmisc
```

Optional but useful:

```bash
sudo apt install -y net-tools sysstat
```

### Check whether dependencies are installed on Linux

```bash
java -version
action="jcmd"; command -v "$action"
docker --version
bash --version
free -h
vmstat 1 1
pmap $$ | head
```

---

## Windows dependencies

You normally need:

- Java **JDK**, not only a JRE
- Docker Desktop or a Docker Engine setup that provides `docker`
- PowerShell for the status script
- `jcmd.exe` from the JDK

### Check whether dependencies are installed on Windows PowerShell

```powershell
java -version
gcm jcmd
docker --version
$PSVersionTable.PSVersion
```

If `gcm jcmd` does not return anything, the JDK `bin` directory is probably not on `PATH`.

Typical `jcmd.exe` location:

```text
C:\Program Files\Java\jdk-<version>\bin\jcmd.exe
```

---

## 7. How to start the program

## Linux normal startup

If you want to start the stack normally:

```bash
./launch-all.sh
```

## Linux monitored startup

If you want diagnostics and a monitor directory:

```bash
./monitor-oscar.sh
```

To run it detached:

```bash
nohup ./monitor-oscar.sh > monitor.out 2>&1 &
echo $! > monitor.pid
```

---

## Windows normal startup

From the project root:

```bat
launch-all.bat
```

## Windows monitored startup

From the project root:

```bat
monitor-oscar.bat
```

Or from PowerShell:

```powershell
Start-Process -FilePath .\monitor-oscar.bat
```

---

## 8. How to stop the program

## Linux

If you started with `monitor-oscar.sh` and the script was written to stop the whole stack on signal:

```bash
kill "$(cat monitor.pid)"
```

If needed, stop parts manually:

```bash
pgrep -af 'com.botts.impl.security.SensorHubWrapper'
kill <java_pid>
docker stop oscar-postgis-container
```

## Windows

If the Windows monitor script supports a stop command:

```bat
monitor-oscar.bat stop
```

Otherwise stop the Java process and container manually:

PowerShell:

```powershell
Get-Process java | Stop-Process
 docker stop oscar-postgis-container
```

Be careful if multiple Java processes are running on the machine.

---

## 9. How to check that the monitor is working

## Linux

```bash
pgrep -af monitor-oscar.sh
pgrep -af 'com.botts.impl.security.SensorHubWrapper'
docker ps --filter name=oscar-postgis-container
ls -td oscar-monitor-* | head -n 1
tail -f monitor.out
```

## Windows PowerShell

```powershell
Get-Process java
Get-ChildItem . -Directory oscar-monitor-* | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Get-Content .\monitor.out -Tail 50 -Wait
```

---

## 10. How to generate a one-file status report

## Linux

```bash
./check-oscar-status.sh
```

This produces a file like:

```text
oscar-status-20260504-000101.txt
```

## Windows

```powershell
powershell -ExecutionPolicy Bypass -File .\check-oscar-status.ps1
```

This produces a similar one-file report.

---

## 11. How to analyze the data

The most important sections are:

- `LIVE JVM /proc STATUS` or the Windows live process section
- `LIVE JVM NATIVE MEMORY SUMMARY`
- `LIVE JVM GC HEAP INFO`
- `RECENT TREND`
- `vmstat` on Linux or pagefile/commit counters on Windows
- application log tails

### Healthy pattern

A healthy run usually looks like this:

- RSS rises during startup, then flattens
- heap usage rises and falls with normal GC activity
- NMT committed memory stays in a narrow band
- thread count stabilizes
- swap or pagefile use may rise some but stops growing
- system still has plenty of available memory
- there is little or no sustained swap-in and swap-out pressure

### Suspicious pattern

A suspicious run usually looks like this:

- RSS rises hour after hour without flattening
- VmSwap or pagefile keeps increasing steadily
- NMT committed memory keeps rising steadily
- thread count keeps climbing
- logs show reconnect loops and memory rises after each one
- system available memory keeps shrinking
- OS starts heavy paging or swapping activity

### Linux-specific interpretation tips

- `VmRSS`: resident memory in RAM
- `VmSwap`: memory for that process currently swapped out
- `vmstat si/so`: swap in and swap out activity
- `GC.heap_info`: whether Java heap is actually pressured
- `VM.native_memory summary`: whether JVM-managed native memory is rising

### Windows-specific interpretation tips

Watch these especially:

- process working set
- private bytes or commit size
- system commit charge versus commit limit
- pagefile usage
- `jcmd VM.native_memory summary`

### Important distinction

A process can fail from **native memory exhaustion** even when Java heap is not full. That was the original reason these scripts were added.

---

## 12. How to tell whether there is a leak

Do not judge from the first hour alone. Startup always causes growth.

Suggested checkpoints:

- **30 to 60 minutes**: look for obvious runaway behavior
- **2 to 4 hours**: see whether memory is leveling off
- **12 to 24 hours**: determine whether the process is stable or slowly drifting

What proves stability:

- recent trend lines become narrow and flat
- NMT committed memory stays near one range
- threads stay near one range
- swap or pagefile stops rising

What suggests a leak:

- all trend lines keep climbing across many hours
- the slope stays positive even after warmup
- memory jumps after every reconnect or retry cycle and never comes down

---

## 13. When to delete files

The monitor and status scripts generate files that can grow over time.

### Files you can delete safely after a run is complete

- old `oscar-status-*.txt` reports
- old `monitor.out`
- old monitor directories such as `oscar-monitor-20260503-174333`
- old JFR files that you no longer need

### Files you should keep while investigating a problem

- the monitor directory for the run you care about
- its `launch.stdout.log` and `launch.stderr.log`
- any `*.jfr` files
- any JVM crash logs such as `hs_err_pid*.log`

### Good cleanup practice

Delete old monitor directories only after:

- the run has been reviewed
- any useful JFR files have been copied somewhere safe
- you no longer need to compare against older runs

Linux cleanup example:

```bash
rm -rf oscar-monitor-20260503-174333
rm -f oscar-status-*.txt
```

Windows PowerShell cleanup example:

```powershell
Remove-Item .\oscar-monitor-20260503-174333 -Recurse -Force
Remove-Item .\oscar-status-*.txt
```

---

## 14. How to modify the scripts safely

When changing the scripts, change one category at a time:

1. profile memory sizes
2. PostgreSQL memory settings
3. monitoring interval
4. extra diagnostics
5. container or path settings

After each change, run a monitored test and compare the new `oscar-status-*.txt` report against an older stable run.

Do not change everything at once or you will not know what helped.

---

## 15. Recommended workflow

For a new machine:

1. put the correct `.env` in place
2. verify dependencies
3. verify the chosen `SYSTEM_PROFILE`
4. start with `monitor-oscar`
5. let it run at least 2 to 4 hours
6. generate a status report
7. check whether RSS, swap or pagefile, NMT committed, and threads plateau
8. only then decide whether to raise or lower memory settings

For production confidence:

1. run monitored overnight
2. generate a final status report
3. verify that recent trend lines are flat
4. archive one known-good monitor directory and status report for comparison

---

## 16. Common mistakes to avoid

- using a profile larger than the machine really supports
- assuming Java heap is the only memory that matters
- removing NMT flags from the Java launcher
- starting JFR twice from both the launcher and the monitor without intending to
- judging a leak from startup-only growth
- deleting monitor directories before reviewing them
- forgetting that repeated reconnects can be a logic problem even when memory looks stable

---

## 17. Bottom line

The updated scripts give you a repeatable way to:

- choose the right memory profile
- start OSCAR consistently
- capture memory diagnostics during the run
- summarize results into one report file
- distinguish between startup growth, stable operation, and a real leak

For day-to-day use, the most important steps are:

- set the correct `SYSTEM_PROFILE`
- start with `monitor-oscar` when testing
- use `check-oscar-status` to review the run
- keep the diagnostic files until you know the run is healthy
