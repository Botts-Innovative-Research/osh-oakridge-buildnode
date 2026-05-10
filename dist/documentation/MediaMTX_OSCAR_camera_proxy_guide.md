# Using MediaMTX to Reduce OSCAR Camera Stream Load

This guide shows the recommended **MediaMTX** pattern for camera-heavy OSCAR deployments.

The short version is simple: put MediaMTX between OSCAR and the physical cameras, point the OSCAR lane CSV at the MediaMTX RTSP paths, validate the camera profile with `monitor-oscar`, and then use `launch-all` for routine production starts.

## Why MediaMTX helps

Without a proxy, OSCAR opens direct RTSP sessions to each camera endpoint referenced by the lanes. At larger scale, that increases:

- Java-side camera session setup work
- reconnect churn when cameras or networks wobble
- socket and thread churn around repeated stream handling
- load on the physical cameras when many logical lanes reuse the same feeds

MediaMTX reduces that burden by presenting OSCAR with a smaller set of stable local RTSP paths. The proxy owns the upstream camera connections, while the Java backend talks to local endpoints instead of repeatedly reconnecting to every physical camera.

## Recommended operating model

- Use `monitor-oscar` during first-run validation, troubleshooting, burn-in, and camera-profile testing.
- Use `launch-all` for routine production after the camera profile is accepted.
- Keep MediaMTX on the OSCAR host or a nearby LAN host whenever possible.

## Minimal MediaMTX configuration

Use a lightweight RTSP-only profile unless you explicitly need other protocols.

```yaml
api: yes
apiAddress: :9997
rtmp: no
hls: no
webrtc: no
srt: no
paths:
  lane03_cam:
    source: "rtsp://<user>:<password>@192.168.8.73/axis-media/media.amp?adjustablelivestream=1&resolution=640x480&videocodec=h264&videokeyframeinterval=15"
    sourceOnDemand: yes
    sourceProtocol: tcp

  lane04_cam:
    source: "rtsp://<user>:<password>@192.168.8.229/axis-media/media.amp?adjustablelivestream=1&resolution=640x480&videocodec=h264&videokeyframeinterval=15"
    sourceOnDemand: yes
    sourceProtocol: tcp
```

### Why these settings are recommended

- `sourceOnDemand: yes` avoids pulling upstream video when OSCAR is not using the path.
- `sourceProtocol: tcp` is usually the most predictable RTSP transport on real LANs, VPNs, and NATed paths.
- Disabling `rtmp`, `hls`, `webrtc`, and `srt` keeps MediaMTX focused on simple RTSP proxying.
- The API on port `9997` gives you a quick way to verify that the paths are present.

## OSCAR CSV pattern

The OSCAR CSV should point camera fields at the MediaMTX host and path, not at the physical camera.

```csv
Name,UniqueID,AutoStart,Latitude,Longitude,RPMConfigType,RPMHost,RPMPort,AspectAddressStart,AspectAddressEnd,EMLEnabled,EMLCollimated,LaneWidth,CameraType0,CameraHost0,CameraPath0,Codec0,Username0,Password0,CameraType1,CameraHost1,CameraPath1,Codec1,Username1,Password1
sim-0,simu-0,FALSE,35.89,-84.19,Rapiscan,192.168.8.77,1601,,,FALSE,FALSE,4.820000172,Custom,192.168.8.77:8554,/lane03_cam,,,,Custom,192.168.8.77:8554,/lane04_cam,,,
```

### Important fields

- `RPMHost` and `RPMPort` still point to the SRLS, Rapiscan, or emulator service.
- `CameraType*` should be `Custom` when you want OSCAR to use the host and path directly.
- `CameraHost*` should point to the machine running MediaMTX, usually `<host>:8554`.
- `CameraPath*` should point to the MediaMTX path, such as `/lane03_cam`.
- `Username*` and `Password*` can usually remain blank because MediaMTX authenticates to the physical camera upstream.

## Quick setup

### 1. Start MediaMTX

Linux:

```bash
./mediamtx mediamtx.yml
```

Windows PowerShell:

```powershell
.\mediamtx.exe mediamtx.yml
```

### 2. Verify that MediaMTX is listening

Linux:

```bash
ss -ltnp | grep -E '8554|9997'
```

Windows PowerShell:

```powershell
Get-NetTCPConnection -LocalPort 8554,9997 -State Listen
```

### 3. Verify the API

Linux or macOS:

```bash
curl http://127.0.0.1:9997/v3/paths/list
```

Windows PowerShell:

```powershell
Invoke-RestMethod http://127.0.0.1:9997/v3/paths/list
```

### 4. Point OSCAR at the proxy

Update the lane CSV so each camera host and path points to MediaMTX instead of the physical device, then upload the CSV through the **Services** tab in the OSCAR admin page.

## Camera profile guidance

For larger systems, keep the streams modest unless you have already validated a heavier profile. A practical starting point is:

- H.264
- 640x480
- 15 fps
- CBR
- 1-second keyframe interval when possible

Those settings reduce total decode and transport cost while still giving OSCAR useful video.

## Fast troubleshooting

### OSCAR cannot open the stream

Check:

- MediaMTX is running
- the path name matches exactly
- the lane CSV points to the correct host and path
- port `8554` is reachable from the OSCAR host

Quick direct test:

```bash
ffplay rtsp://127.0.0.1:8554/lane03_cam
```

### The path exists but does not pull video

Check:

- upstream camera IP, credentials, and path
- whether the camera supports the requested stream format
- whether the camera accepts RTSP over TCP

### Reconnect churn is still high

MediaMTX reduces Java-side reconnect pressure, but it cannot fix every upstream problem. Also check:

- camera network stability
- encoder configuration
- duplicate consumers
- emulator-side or payload-side issues
- OSCAR thread and reconnect logs from the monitor directory

## Summary

MediaMTX reduces the burden on the OSCAR Java backend by replacing many direct camera sessions with a smaller set of local RTSP proxy paths. That usually means less reconnect churn, less socket and thread churn, easier lane reuse, and a simpler camera topology for large test or production systems.
