# Using MediaMTX to Reduce OSCAR Camera Stream Load

This guide explains how to use **MediaMTX** as a local RTSP proxy so OSCAR does not have to open large numbers of direct camera connections.

For **testing and side-by-side field deployment**, the recommended operational flow is:

1. prepare a fresh OSCAR 3.5.1 deployment
2. create `.env`
3. launch OSCAR with the monitoring script
4. proxy camera streams through MediaMTX
5. run the status-check script after warm-up
6. compare reconnect, thread, and database behavior with and without the proxy

---

## Why MediaMTX helps

Without a proxy, OSCAR may open many direct RTSP sessions to cameras. If you have many lanes, reconnect activity and repeated stream setup can create unnecessary load on the cameras and on the OSCAR host.

MediaMTX sits between OSCAR and the cameras:

- cameras stream to MediaMTX only when needed
- OSCAR connects to MediaMTX on the local machine instead of directly to every camera
- multiple lane definitions can reuse the same proxied path
- reconnects are handled against the local proxy instead of repeatedly hammering the physical cameras

This is especially useful when:

- many OSCAR lanes reuse a smaller number of real camera streams
- emulator lanes are used for testing or demonstrations
- direct camera sessions are expensive or unstable
- you want a simple local point to change, test, or swap stream sources

---

## Typical architecture

A common layout is:

1. physical cameras publish RTSP streams
2. MediaMTX runs on the same machine as OSCAR or on a nearby local host
3. MediaMTX exposes local RTSP paths such as `/lane03_cam`
4. the OSCAR lane CSV points camera hosts to the local MediaMTX service
5. the SRLS emulator or detector-side service is addressed separately from the same CSV

In this setup, OSCAR talks to:

- the SRLS emulator or RPM service for detector data
- MediaMTX for camera video

---

## Recommended OSCAR workflow when using MediaMTX

### 1. Verify dependencies

Make sure **Java 21+** and **Docker** are ready for OSCAR, and that MediaMTX is installed separately on the host where you plan to run the proxy.

### 2. Start OSCAR with monitoring

Linux:

```bash
./monitor-oscar.sh
```

Windows:

```bat
monitor-oscar.bat
```

### 3. Start MediaMTX

Linux:

```bash
./mediamtx mediamtx.yml
```

Windows PowerShell:

```powershell
.\mediamtx.exe mediamtx.yml
```

### 4. Let the system warm up

Allow enough time for lane startup, first client connections, and any reconnect behavior to appear.

### 5. Generate a status report

Linux:

```bash
./check-oscar-status.sh
```

Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\check-oscar-status.ps1
```

Review:

- thread count
- reconnect warnings
- camera-related log churn
- PostgreSQL session plateau behavior

---

## Why the provided MediaMTX settings are efficient

The configuration below keeps MediaMTX focused on lightweight RTSP proxying:

- `rtmp: no`
- `hls: no`
- `webrtc: no`
- `srt: no`

Disabling unused protocols avoids extra listeners and extra processing.

These options are also important:

- `sourceOnDemand: yes` means MediaMTX only pulls the upstream camera when a client requests the path
- `sourceProtocol: tcp` makes RTSP transport use TCP, which is often more reliable on LANs and across NAT or firewall boundaries
- `api: yes` with `apiAddress: :9997` gives you a simple status API for checking paths and clients

---

## Example MediaMTX configuration for Axis cameras

Use placeholders for credentials in documentation and shared files.

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

  lane05_cam:
    source: "rtsp://<user>:<password>@192.168.8.111/axis-media/media.amp?adjustablelivestream=1&resolution=640x480&videocodec=h264&videokeyframeinterval=15"
    sourceOnDemand: yes
    sourceProtocol: tcp

  lane06_cam:
    source: "rtsp://<user>:<password>@192.168.8.167/axis-media/media.amp?adjustablelivestream=1&resolution=640x480&videocodec=h264&videokeyframeinterval=15"
    sourceOnDemand: yes
    sourceProtocol: tcp
```

---

## How this supports many lanes with fewer real cameras

If your OSCAR deployment has 50 lanes with 2 cameras per lane, that is 100 camera references. Those 100 references do **not** need to be 100 unique physical camera connections.

With MediaMTX, many lane rows can point back to the same proxied path, such as:

- `rtsp://192.168.8.77:8554/lane04_cam`
- `rtsp://192.168.8.77:8554/lane06_cam`

That means the CSV can model many lane-camera assignments while MediaMTX proxies only a small set of real upstream streams.

---

## Example OSCAR service CSV entries

Upload the CSV through the **Services** tab in the OSCAR admin page.

```csv
Name,UniqueID,AutoStart,Latitude,Longitude,RPMConfigType,RPMHost,RPMPort,AspectAddressStart,AspectAddressEnd,EMLEnabled,EMLCollimated,LaneWidth,CameraType0,CameraHost0,CameraPath0,Codec0,Username0,Password0,CameraType1,CameraHost1,CameraPath1,Codec1,Username1,Password1
sim-0,simu-0,FALSE,35.89,-84.19,Rapiscan,192.168.8.77,1601,,,FALSE,FALSE,4.820000172,Custom,192.168.8.77:8554,/lane04_cam,,,,Custom,192.168.8.77:8554,/lane06_cam,,,
sim-2,simu-1,FALSE,35.883,-84.19,Rapiscan,192.168.8.77,1602,,,FALSE,FALSE,4.820000172,Custom,192.168.8.77:8554,/lane06_cam,,,,Custom,192.168.8.77:8554,/lane04_cam,,,
```

### Important CSV fields

- `RPMHost` and `RPMPort` point to the SRLS or Rapiscan emulator/service
- `CameraType0` and `CameraType1` are set to `Custom` so OSCAR uses the host/path directly
- `CameraHost0` and `CameraHost1` point to the machine running MediaMTX, usually `<host>:8554`
- `CameraPath0` and `CameraPath1` point to the MediaMTX path, such as `/lane04_cam`
- `Username` and `Password` fields are left blank because authentication is handled upstream by MediaMTX when it pulls from the real camera

---

## Sony camera settings to use

For Sony cameras, use the following secondary-stream settings:

- `H.264`
- `640x480`
- `15 fps`
- `1 s` keyframe interval when possible
- `high` H.264 profile
- `CBR`
- about `4000 kbps`

These settings are a good match for lightweight proxying and testing because they keep the stream modest while still providing stable H.264 output.

Example Sony-based MediaMTX path:

```yaml
api: yes
apiAddress: :9997
rtmp: no
hls: no
webrtc: no
srt: no
paths:
  lane03_cam:
    source: "rtsp://<user>:<password>@192.168.8.4:554/media/video2"
    sourceOnDemand: yes
    sourceProtocol: tcp
```

---

## Step-by-step setup

### 1. Install MediaMTX

Download MediaMTX for your platform and extract it onto the host that will run the proxy.

Typical contents include:

- `mediamtx` or `mediamtx.exe`
- `mediamtx.yml`

### 2. Create `mediamtx.yml`

Start with one of the examples above and add one path per real upstream camera stream.

### 3. Start MediaMTX

Linux:

```bash
./mediamtx mediamtx.yml
```

Windows PowerShell:

```powershell
.\mediamtx.exe mediamtx.yml
```

### 4. Verify MediaMTX is listening

Linux:

```bash
ss -ltnp | grep -E '8554|9997'
```

Windows PowerShell:

```powershell
Get-NetTCPConnection -LocalPort 8554,9997 -State Listen
```

### 5. Verify the API

Linux or macOS:

```bash
curl http://127.0.0.1:9997/v3/paths/list
```

Windows PowerShell:

```powershell
Invoke-RestMethod http://127.0.0.1:9997/v3/paths/list
```

### 6. Update the OSCAR CSV

Point lane camera hosts and paths to MediaMTX instead of the physical cameras.

### 7. Upload the CSV in OSCAR

In the OSCAR admin UI:

1. open the **Services** tab
2. upload the CSV
3. confirm the lanes import successfully
4. start the desired lanes or services

---

## Best practices

### Keep streams modest

Use modest stream settings for test environments:

- H.264
- 640x480
- 15 fps
- CBR
- 1-second keyframe interval when possible

### Use `sourceOnDemand`

This avoids pulling from upstream cameras when no OSCAR consumer is actually using the stream.

### Use local proxy paths in OSCAR

Do not point every lane directly at physical cameras if the same few streams can be reused.

### Keep protocols disabled unless needed

If you only need RTSP, keep HLS, WebRTC, RTMP, and SRT disabled.

### Use monitoring during evaluation

When comparing direct-camera versus proxied-camera behavior, always launch OSCAR with the monitoring script and collect a status report after warm-up.

---

## Troubleshooting

### OSCAR cannot open the stream

Check:

- MediaMTX is running
- the lane CSV points to the correct host and path
- port `8554` is open locally
- the MediaMTX path name matches exactly

Direct test example:

```bash
ffplay rtsp://127.0.0.1:8554/lane03_cam
```

### MediaMTX path exists but does not pull video

Check:

- upstream camera IP and credentials
- the source URL path
- whether the camera is configured for the requested stream format
- whether the camera accepts TCP RTSP transport

### Too many reconnects

MediaMTX can localize reconnect activity, but also check:

- camera network stability
- camera encoder settings
- duplicate or unstable stream consumers
- bad payloads or emulator-side issues
- OSCAR thread and reconnect logs from the monitor directory

### API works but paths do not appear active

With `sourceOnDemand: yes`, a path may stay idle until a client requests it. That is normal.

---

## Summary

MediaMTX reduces the burden of large camera configurations by turning many direct camera connections into a smaller number of local RTSP proxy paths.

In practice, that means:

- less direct pressure on physical cameras
- fewer repeated direct sessions from OSCAR
- easier CSV-based lane provisioning
- easier testing with emulator lanes
- simpler troubleshooting and stream replacement

For field evaluation, pair MediaMTX with the OSCAR monitoring and status-check scripts so you can compare reconnect behavior, thread growth, and system steadiness under realistic load.
