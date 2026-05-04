# Using MediaMTX to Reduce OSCAR Camera Stream Load

This guide explains how to use **MediaMTX** as a local RTSP proxy so OSCAR does not have to open large numbers of direct camera connections. The goal is to reduce CPU, memory, reconnection churn, and camera-side load when many lanes reuse a smaller set of camera feeds.

## Why MediaMTX helps

Without a proxy, OSCAR may open many direct RTSP sessions to cameras. If you have many lanes, reconnect activity and repeated stream setup can create unnecessary load on the cameras and on the OSCAR host. MediaMTX sits between OSCAR and the cameras:

- Cameras stream to **MediaMTX** only when needed.
- OSCAR connects to **MediaMTX** on the local machine instead of directly to every camera.
- Multiple lane definitions can reuse the same proxied path.
- Reconnects are handled against the local proxy instead of hammering the physical cameras.

This is especially useful when:

- many OSCAR lanes reuse a smaller number of real camera streams
- emulator lanes are used for testing or demonstrations
- direct camera sessions are expensive or unstable
- you want a simple local point to change, test, or swap stream sources

## Typical architecture

A common layout is:

1. Physical cameras publish RTSP streams.
2. MediaMTX runs on the same machine as OSCAR.
3. MediaMTX exposes local RTSP paths such as `/lane03_cam`.
4. The OSCAR lane CSV points camera hosts to the local MediaMTX service.
5. The SRLS emulator is also addressed from the same CSV.

In this setup, OSCAR talks to:

- the **SRLS emulator** for RPM data
- **MediaMTX** for camera video

## Why the provided MediaMTX settings are efficient

The configuration below keeps MediaMTX focused on lightweight RTSP proxying:

- `rtmp: no`
- `hls: no`
- `webrtc: no`
- `srt: no`

Disabling unused protocols avoids extra listeners and extra processing.

These options are also important:

- `sourceOnDemand: yes` means MediaMTX only pulls the upstream camera when a client requests the path.
- `sourceProtocol: tcp` makes RTSP transport use TCP, which is often more reliable on LANs and across NAT or firewall boundaries.
- `api: yes` with `apiAddress: :9997` gives you a simple status API for checking paths and clients.

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

## How this supports many lanes with fewer real cameras

If your OSCAR deployment has 50 lanes with 2 cameras per lane, that is 100 camera references. Those 100 references do **not** need to be 100 unique physical camera connections.

With MediaMTX, many lane rows can point back to the same proxied path, such as:

- `rtsp://192.168.8.77:8554/lane04_cam`
- `rtsp://192.168.8.77:8554/lane06_cam`

That means the CSV can model many lane-camera assignments while MediaMTX proxies only a small set of real upstream streams.

## Example OSCAR service CSV entries

Upload the CSV through the **Services** tab in the OSCAR admin page.

Example rows:

```csv
Name,UniqueID,AutoStart,Latitude,Longitude,RPMConfigType,RPMHost,RPMPort,AspectAddressStart,AspectAddressEnd,EMLEnabled,EMLCollimated,LaneWidth,CameraType0,CameraHost0,CameraPath0,Codec0,Username0,Password0,CameraType1,CameraHost1,CameraPath1,Codec1,Username1,Password1
sim-0,simu-0,FALSE,35.89,-84.19,Rapiscan,192.168.8.77,1601,,,FALSE,FALSE,4.820000172,Custom,192.168.8.77:8554,/lane04_cam,,,,Custom,192.168.8.77:8554,/lane06_cam,,,
sim-2,simu-1,FALSE,35.883,-84.19,Rapiscan,192.168.8.77,1602,,,FALSE,FALSE,4.820000172,Custom,192.168.8.77:8554,/lane06_cam,,,,Custom,192.168.8.77:8554,/lane04_cam,,,
```

### What the important CSV fields mean

- `RPMHost` and `RPMPort` point to the SRLS or Rapiscan emulator/service.
- `CameraType0` and `CameraType1` are set to `Custom` so OSCAR uses the host/path directly.
- `CameraHost0` and `CameraHost1` point to the machine running MediaMTX, usually `<host>:8554`.
- `CameraPath0` and `CameraPath1` point to the MediaMTX path, such as `/lane04_cam`.
- `Username` and `Password` fields are left blank because authentication is handled upstream by MediaMTX when it pulls from the real camera.

## Sony camera settings to use

For Sony cameras, use the settings shown in the attached screenshot for the secondary stream:

- **Image codec 2:** `H.264`
- **Image size 2:** `640x480`
- **Frame rate 2:** `15 fps`
- **I-picture interval 2:** `Time`
- **Interval value:** `1 s`
- **H.264 Profile 2:** `high`
- **Bit rate compression mode 2:** `CBR`
- **Bit rate 2:** `4000 kbps`

These settings are a good match for lightweight proxying and testing because they keep the stream modest while still providing stable H.264 output.

## Example MediaMTX configuration for a Sony camera

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

Use placeholders when sharing docs or configs. Replace `<user>` and `<password>` on your system.

## Step-by-step setup

### 1. Install MediaMTX

Download MediaMTX for your platform from the project releases page and extract it onto the OSCAR host.

Typical contents include:

- `mediamtx` or `mediamtx.exe`
- `mediamtx.yml`

### 2. Create `mediamtx.yml`

Start with the Axis or Sony example above and add one path per real upstream camera stream.

### 3. Start MediaMTX

On Linux:

```bash
./mediamtx mediamtx.yml
```

On Windows:

```powershell
.\mediamtx.exe mediamtx.yml
```

### 4. Verify MediaMTX is listening

The default RTSP port is `8554`, and the API in this guide is on `9997`.

On Linux:

```bash
ss -ltnp | grep -E '8554|9997'
```

On Windows PowerShell:

```powershell
Get-NetTCPConnection -LocalPort 8554,9997 -State Listen
```

### 5. Verify the API

If the API is enabled, check it from the OSCAR host.

Linux or macOS:

```bash
curl http://127.0.0.1:9997/v3/paths/list
```

Windows PowerShell:

```powershell
Invoke-RestMethod http://127.0.0.1:9997/v3/paths/list
```

### 6. Update the OSCAR CSV

Point the lane camera hosts and paths to MediaMTX rather than the physical cameras.

### 7. Upload the CSV in OSCAR

In the OSCAR admin UI:

1. Open the **Services** tab.
2. Upload the CSV.
3. Confirm the lanes import successfully.
4. Start the desired lanes or services.

## How to think about path naming

Pick path names that are stable and meaningful. Good examples:

- `lane03_cam`
- `lane04_cam`
- `north_inbound_cam_a`
- `srls_demo_cam_1`

Try not to encode temporary information into the path name. If a physical camera changes, it is easier to update the MediaMTX `source` than to rewrite CSV files everywhere.

## Best practices

### Keep streams modest

Use modest stream settings for emulator or test environments:

- H.264
- 640x480
- 15 fps
- CBR
- 1-second keyframe interval when possible

These are close to the settings shown for the Sony camera and are also consistent with the Axis URLs you provided.

### Use `sourceOnDemand`

This avoids pulling from upstream cameras when no OSCAR consumer is actually using the stream.

### Use local proxy paths in OSCAR

Do not point 50 lanes directly at physical cameras if the same few streams can be reused. Point OSCAR at MediaMTX instead.

### Keep protocols disabled unless needed

If you only need RTSP, keep HLS, WebRTC, RTMP, and SRT disabled.

### Use placeholders in shared docs

Do not share real camera credentials in documentation, tickets, or screenshots.

## Troubleshooting

### OSCAR cannot open the stream

Check:

- MediaMTX is running
- the lane CSV points to the correct host and path
- port `8554` is open locally
- the MediaMTX path name matches exactly

Test directly:

```bash
ffplay rtsp://127.0.0.1:8554/lane03_cam
```

or with VLC using the same RTSP URL.

### MediaMTX path exists but does not pull video

Check:

- upstream camera IP and credentials
- the source URL path
- whether the camera is configured for the requested stream format
- whether the camera accepts TCP RTSP transport

### Too many reconnects

If OSCAR reconnects frequently, MediaMTX can still help by localizing the reconnect activity, but you should also check:

- camera network stability
- camera encoder settings
- duplicate or unstable stream consumers
- bad payloads or emulator-side errors

### API works but paths do not appear active

With `sourceOnDemand: yes`, a path may stay idle until a client requests it. That is normal.

## Why this is a good fit for emulator workflows

This approach is especially useful when:

- the SRLS emulator and OSCAR run on the same host
- test lanes are imported from CSV
- many lane definitions reuse a small group of video feeds

You can change upstream camera assignments in one place, `mediamtx.yml`, while keeping the OSCAR CSV stable.

## Summary

MediaMTX reduces the resource burden of multiple OSCAR camera streams by turning many direct camera connections into a smaller number of local RTSP proxy paths. In practice, that means:

- less direct pressure on physical cameras
- fewer repeated direct sessions from OSCAR
- easier CSV-based lane provisioning
- easier testing with emulator lanes
- simpler troubleshooting and stream replacement

For Axis cameras, keep the upstream URL parameters modest and stable. For Sony cameras, configure the second stream to H.264, 640x480, 15 fps, 1-second keyframe interval, high profile, CBR, and about 4000 kbps, then point MediaMTX at `/media/video2`.
