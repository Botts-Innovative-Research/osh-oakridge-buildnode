# Status of Health

The OSCAR 4.0.0 Status of Health page gives operators one live row for every lane visible in the current Viewer scope. Open it with the heart-monitor icon in the left navigation.

## Lane scope

- `/health` lists every lane discovered from the configured nodes.
- `/health?view=<key>` lists every lane assigned to that operational view.
- Invalid operational-view keys and views with no assigned lanes fail closed and show no lane telemetry.

Operational views are a presentation boundary, not an authorization mechanism. See [OPERATIONAL_VIEWS.md](OPERATIONAL_VIEWS.md) for configuration and security guidance.

## What each row shows

| Group | Meaning |
| --- | --- |
| RPM connection | **Online** or **Offline** from the RPM connection-status stream. **Waiting** means that the Viewer has not received a usable current value. |
| Camera connections | One indicator per configured FFmpeg camera. OSCAR 4.0.0 publishes an explicit connection value after stream startup, reconnection failure, and shutdown. |
| Gamma high / gamma low / neutron high | **Fault**, **Clear**, or **Waiting** from the corresponding detector alarm-state telemetry. Missing or failed telemetry remains Waiting rather than appearing clear. |
| Tamper | **Fault**, **Clear**, or **Waiting** from the lane's tamper telemetry. |
| Extended occupancy | Active when the lane's canonical `occupancyStatus` remains occupied longer than the configured threshold. This status is model-independent across Rapiscan, Aspect, and RS350 RPMs. |
| Current occupancy | Elapsed time from the stable start timestamp in `occupancyStatus` for the occupancy currently in progress. |
| Last update | Local browser time at which the row last received connection or fault telemetry. |

Unknown or waiting connection or fault telemetry is intentionally not counted as healthy. A lane is healthy only when every expected RPM and camera has an explicit online value and each expected fault source has explicitly reported clear.

## Extended-occupancy threshold

The default threshold is one minute. Enter a value from 1 through 1440 minutes in **Extended occupancy threshold**. The Viewer saves the value in that browser, so different authorized workstations can use different operational thresholds without changing server configuration.

Changing the threshold re-evaluates occupancies already in progress. It does not modify detector observations, adjudications, reports, or server retention.

## Acceptance test

1. Open the unscoped `/health` page and confirm every expected lane is present.
2. Open each required operational-view URL and confirm that only its assigned lanes are present.
3. Confirm the RPM and every configured camera become **Online** after their modules start.
4. Stop and restart a test camera stream; verify **Offline** is reported during failure and **Online** returns after reconnection.
5. Exercise approved detector test inputs for gamma high, gamma low, neutron high, and tamper, then verify each indicator moves from Clear to Fault and back. Confirm unavailable telemetry shows Waiting, never Clear.
6. Set the extended-occupancy threshold to one minute, run a controlled occupancy beyond one minute on each installed RPM model, and verify the elapsed timer and fault indicator use the canonical lane occupancy status.
7. Reload the browser and verify the threshold persists and live updates resume.
8. Confirm that an unavailable node or missing telemetry is shown as waiting/offline rather than healthy.

Hardware fault tests must follow the site's approved procedures. Do not create an uncontrolled radiation, tamper, or traffic condition solely to exercise the interface.

## Troubleshooting

| Symptom | Checks |
| --- | --- |
| Lane is missing | Check node reachability, lane discovery, operational-view assignment, and the exact `?view=` key. |
| RPM remains Waiting | Verify the RPM driver exposes `connectionStatus`, the stream is reachable, and the Viewer can query its latest observation. |
| Camera remains Waiting | Confirm the lane generated the FFmpeg child, the child is running OSCAR 4.0.0 code, and its connection-status datastream was discovered. |
| Camera shows Offline | Verify RTSP host, port, credentials, codec/path, network reachability, and FFmpeg reconnect logs. |
| Fault remains Waiting | Confirm the expected detector or tamper datastream exists, its latest observation is readable, and its live subscription is connected. Waiting is deliberately not treated as Clear. |
| Fault never clears | Inspect the latest detector/tamper observations and confirm the source published the corresponding cleared state. |
| Occupancy duration is missing or unexpected | Verify system clocks, confirm the Lane System publishes `occupancyStatus`, and check that the RPM's daily-file/status input reports both occupancy entry and exit. |
| Page is empty in a scoped URL | Confirm at least one lane carries that operational-view key. Empty and invalid views intentionally fail closed. |
