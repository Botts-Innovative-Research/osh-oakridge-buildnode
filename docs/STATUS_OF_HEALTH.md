# Status of Health

The OSCAR 3.9.1 Status of Health page gives operators one current-status row for every lane visible in the current Viewer scope. Open it with the heart-monitor icon in the left navigation.

## Lane scope

- `/health/` lists every lane discovered from the configured nodes.
- `/health/?view=<key>` lists every lane assigned to that operational view.
- Invalid operational-view keys and views with no assigned lanes fail closed and show no lane telemetry.

Operational views are a presentation boundary, not an authorization mechanism. See [OPERATIONAL_VIEWS.md](OPERATIONAL_VIEWS.md) for configuration and security guidance.

## What each row shows

| Group | Meaning |
| --- | --- |
| RPM connection | **Online** or **Offline** from the RPM connection-status stream. **Waiting** means that the Viewer has not received a usable current value. |
| Camera connections | One indicator per configured FFmpeg camera. OSCAR 3.9.1 publishes an explicit connection value after stream startup, reconnection failure, and shutdown, then republishes the current value every 30 seconds while the driver is running. |
| Gamma high / gamma low / neutron high | **Fault**, **Clear**, or **Unknown** from the corresponding detector alarm-state telemetry. Missing or failed telemetry remains Unknown rather than appearing clear. |
| Tamper | **Fault**, **Clear**, or **Unknown** from the lane's tamper telemetry. |
| Extended occupancy | Active when the lane's canonical `occupancyStatus` remains occupied longer than the configured threshold. This status is model-independent across Rapiscan, Aspect, and RS350 RPMs. |
| Current occupancy | Elapsed time from the stable start timestamp in `occupancyStatus` for the occupancy currently in progress. |
| Last update | Local browser time at which the row last received connection or fault telemetry. |

Unknown or waiting connection or fault telemetry is intentionally not counted as healthy. A lane is healthy only when every expected RPM and camera has an explicit online value and each expected fault source has explicitly reported clear.

## Dashboard indicators

The dashboard shows a compact version of the same health snapshot beside every lane name:

| Indicator | Meaning |
| --- | --- |
| Antenna | RPM connection. Green is Online, red with a slash is Offline, and gray is Unknown. |
| Video camera | One icon for each configured camera, in camera-name order. Green is Online, red with a slash is Offline, and gray is Unknown. |
| `γ↑` / `γ↓` / `n↑` | Gamma-high, gamma-low, and neutron-high state. Red means active and gray means the current state is Unknown. Clear radiation faults are hidden to keep the lane card compact. |
| Warning triangle | Tamper state. Red means active and gray means Unknown. An active tamper also shows the existing clear-tamper action. |
| Timer | Extended occupancy. Red means the configured threshold has been exceeded and gray means occupancy telemetry is Unknown. |

Hover over a lane name or indicator for its label; assistive technology receives the same labels directly. The icons use both shapes and colors so color alone is not required. Selecting the card still opens Lane Details; keyboard users can select it with Enter or Space.

### Rapiscan tamper startup state

Rapiscan tamper messages are transition events, not a periodically repeated snapshot. A unit sends `TT` when a monitored door or power condition enters tamper and `TC` when that condition clears. The [DOE/PNNL Rapiscan maintenance guide](https://d5.pnnl.gov/sites/default/files/2023-02/RPM_Maint_Guide_Drawings.pdf) specifies that each is sent only once for the corresponding power or cabinet-door transition; it does not require `TC` merely because OSCAR connected while the cabinet was already closed. Therefore a new OSCAR database can correctly show **Tamper: Unknown** until the RPM reports either transition. OSCAR does not infer **Clear** from an active TCP connection, because doing so would display an unobserved safety state as healthy.

A test RPM emulator may establish a deterministic initial state by sending the protocol-valid line `TC,111111,111111,111111,111111` after accepting a client connection when its own modeled door and power state is known to be clear. That behavior belongs in the emulator; the production Rapiscan driver and Viewer must continue to leave a missing tamper observation as Unknown. On real hardware, use only the site's approved tamper test or operator procedure to establish and verify the first explicit state.

## Current values and refresh interval

After lane discovery completes, the Status of Health page or dashboard fetches the latest observations in batches of at most 50 health streams and repeats the refresh every 30 seconds instead of opening a real-time MQTT feed for every health stream. The two routes share one implementation and only the visible route mounts it, so opening the dashboard does not duplicate the Status of Health polling loop. No more than two health requests run at once across all configured nodes, and batches are scheduled round-robin so a large node does not delay another node's first snapshot. The PostgreSQL store resolves an eligible batch with one indexed latest-row probe per requested stream, so the work is bounded by the batch size rather than by the number of historical observations. Each batch has a 10-second deadline; the production browser request is cancelled at that deadline so a stalled node cannot freeze later refreshes. A failed batch or a successful response missing an expected current observation changes that status to **Waiting** and does not prevent successful batches from updating. Observations older than the last accepted timestamp cannot restore a stale state after it becomes Waiting. This avoids oversized URLs and bounds concurrent database work at large sites.

The dashboard retains only the existing gamma and neutron real-time listeners needed to sound new-alarm audio; those listeners are removed when the dashboard unmounts. Connection, camera, tamper, and occupancy icons do not create additional MQTT subscriptions. The icon rendering itself is lightweight SVG. Extended occupancy schedules only the next exact lane threshold crossing and then schedules the following one, rather than rerendering every lane once per second. Clearing tamper queues one immediate post-command health refresh, even when a periodic refresh is already running. At a typical 50-lane site with two cameras per lane, the health snapshot is approximately seven small latest-state requests every 30 seconds per node (the exact number depends on installed streams), with at most two requests in flight.

The FFmpeg driver also republishes each camera's unchanged connection state every 30 seconds. Connection-status observations older than one hour are removed by the normal database-retention job, so the heartbeat keeps a healthy running camera current without weakening stale-data detection. If the driver stops publishing, its last value ages out and the Viewer returns to **Waiting** rather than displaying an indefinitely stale **Online** state.

Connection, fault, and occupancy changes can therefore take up to one 30-second refresh interval to appear. Once an active occupancy has been observed, its elapsed-time display continues to advance between refreshes.

## Extended-occupancy threshold

The default threshold is one minute. Enter a value from 1 through 1440 minutes in **Extended occupancy threshold**. The Viewer saves the value in that browser, so different authorized workstations can use different operational thresholds without changing server configuration.

Changing the threshold re-evaluates occupancies already in progress. It does not modify detector observations, adjudications, reports, or server retention.

## Acceptance test

1. Open the unscoped `/health/` page and confirm every expected lane is present.
2. Open each required operational-view URL and confirm that only its assigned lanes are present.
3. Confirm the RPM and every configured camera become **Online** within one refresh interval after their modules start.
4. Stop and restart a test camera stream; verify **Offline** is reported during failure and **Online** returns within one refresh interval after reconnection.
5. Exercise approved detector test inputs for gamma high, gamma low, neutron high, and tamper, then verify each indicator moves from Clear to Fault and back within one refresh interval. Confirm unavailable fault telemetry shows Unknown, never Clear.
6. Set the extended-occupancy threshold to one minute, run a controlled occupancy beyond one minute on each installed RPM model, and verify the elapsed timer and fault indicator use the canonical lane occupancy status.
7. Reload the browser and verify the threshold persists and periodic status updates resume.
8. Confirm that an unavailable node or missing telemetry is shown as waiting/offline rather than healthy.
9. Repeat steps 3 through 8 using the compact indicators beside each lane on the dashboard. Confirm every expected camera has its own icon, clear fault icons remain hidden, active and Unknown states are distinguishable, and the lane card still opens Lane Details.
10. Leave the dashboard and then the Status of Health page open for at least two minutes each while watching server logs and container CPU. Expect requests containing no more than 50 health stream IDs, with no more than two health requests in flight, on entry and approximately every 30 seconds; confirm there are no per-stream latest-observation bursts or health-page MQTT feeds, no health listeners accumulate after navigating between pages, CPU returns to the site's normal steady state, and a controlled status change appears within one refresh interval.
11. For release validation, confirm a healthy camera's latest connection-status timestamp advances at least once within 60 seconds and remains queryable after the hourly retention job. Confirm a stopped driver does not publish a heartbeat and its stale value can still age out.

Hardware fault tests must follow the site's approved procedures. Do not create an uncontrolled radiation, tamper, or traffic condition solely to exercise the interface.

## Troubleshooting

| Symptom | Checks |
| --- | --- |
| Lane is missing | Check node reachability, lane discovery, operational-view assignment, and the exact `?view=` key. |
| RPM remains Waiting | Verify the RPM driver exposes `connectionStatus`, the stream is reachable, and the Viewer can query its latest observation. |
| Camera remains Waiting | Confirm the lane generated the FFmpeg child, the child is running OSCAR 3.9.1 code with the 30-second connection heartbeat, and its connection-status datastream was discovered. Query the latest observation twice at least 30 seconds apart; its timestamp should advance while the driver is running. If it does not, inspect the FFmpeg reconnect/heartbeat logs and deployed image. |
| Camera shows Offline | Verify RTSP host, port, credentials, codec/path, network reachability, and FFmpeg reconnect logs. |
| Fault remains Unknown | Confirm the expected detector or tamper datastream exists, its latest observation is readable, and the next per-node refresh completes. Unknown is deliberately not treated as Clear. |
| Rapiscan tamper remains Unknown while other values update | This can be correct after a fresh database or driver connection: Rapiscan sends `TT` and `TC` on transitions rather than periodically. Confirm the RPM has emitted an explicit tamper or tamper-clear event. A test emulator with a known-clear modeled state should emit `TC` when the client connects. Do not treat connection success as tamper clear. |
| Fault never clears | Inspect the latest detector/tamper observations and confirm the source published the corresponding cleared state. |
| A recent change is not shown immediately | Wait for the next 30-second refresh. Health status can lag the source by up to one refresh interval. |
| Occupancy duration is missing or unexpected | Verify system clocks, confirm the Lane System publishes `occupancyStatus`, and check that the RPM's daily-file/status input reports both occupancy entry and exit. |
| Page is empty in a scoped URL | Confirm at least one lane carries that operational-view key. Empty and invalid views intentionally fail closed. |
| CPU remains high while the page is open | Check server logs for latest-observation batches of at most 50 stream IDs, no more than two concurrent health requests, a 10-second deadline for a stalled batch, and a refresh approximately every 30 seconds. Confirm the deployed PostgreSQL observation store uses indexed latest-per-stream probes for these batches; a `DISTINCT ON` plan that scans and sorts each stream's history indicates an older build. If the Viewer sends oversized or per-stream latest-observation requests or opens per-stream health MQTT feeds, confirm the deployed image contains the OSCAR 3.9.1 Status of Health performance correction. |
