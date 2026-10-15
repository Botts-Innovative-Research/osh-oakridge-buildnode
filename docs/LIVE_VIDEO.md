# Live Video

OSCAR 4.0.0 starts Lane Details video only after the HLS stream has received a decodable H.264 keyframe. Until that point, the Viewer shows **Preparing live video** instead of presenting an empty player. If preparation or playback cannot recover within the bounded retry period, the Viewer shows a localized error and a **Retry** action.

## Camera requirements

- The configured camera endpoint must be reachable by the OSCAR container and provide an H.264 video stream.
- Camera clocks and packet timestamps must advance continuously.
- Configure a closed GOP with a keyframe interval of one to two seconds. At 15 frames per second, a one-second interval is `15` frames.
- Do not depend on a keyframe interval longer than the desired live-video startup time. OSCAR discards packets received before the first keyframe so that the first HLS segment can be decoded independently.

The OSCAR camera emulator prepares its source assets with a one-second closed GOP and then republishes them with stream copy. This keeps the Raspberry Pi workload low while giving every emulated camera a predictable startup bound. The implementation is maintained in [tyronechrisharris/Camera-emulator](https://github.com/tyronechrisharris/Camera-emulator) and introduced by [Camera-emulator PR #2](https://github.com/tyronechrisharris/Camera-emulator/pull/2).

### Prepare and apply emulator assets

Run these commands from the Camera-emulator repository root before its first start, or after replacing either tracked source recording:

```sh
./scripts/prepare-assets.sh
./scripts/validate-assets.sh
docker compose up -d --no-deps --force-recreate publisher-rpm-1 publisher-rpm-2
docker compose ps
```

`prepare-assets.sh` writes validated, ignored derivatives under `assets/prepared/` atomically; it does not replace the tracked `assets/RPM_1.mp4` and `assets/RPM_2.mp4` sources. `validate-assets.sh` verifies H.264, dimensions, frame rate, the leading random-access frame, every internal keyframe gap, and the loop seam. Recreate only `publisher-rpm-1` and `publisher-rpm-2` so their existing FFmpeg processes open the new derivatives. MediaMTX and OSCAR do not need to be recreated or reset.

Preserve the emulator's `.env`, configuration, tracked source media, and all OSCAR deployment state. Do not add `--volumes`, delete Docker volumes, re-import lanes, or rerun OSCAR initialization for this media update. To deliberately rebuild otherwise-current derivatives after changing the preparation recipe, use `FORCE_PREPARE_ASSETS=1 ./scripts/prepare-assets.sh`, validate again, and recreate only the two publisher services as shown above.

## Viewer behavior

The live-video panel has three explicit states:

| State | Meaning |
| --- | --- |
| Preparing live video | The start command succeeded and OSCAR is waiting for the first usable HLS playlist and keyframe. Initial playlist-not-found responses are expected in this state. |
| Playing | The browser loaded the playlist and is advancing decoded video. |
| Live video could not be played | Preparation or playback exhausted its bounded recovery attempts. Select **Retry** after checking the camera and network. |

The Viewer retries transient playlist and media failures without repeatedly issuing start commands. After a terminal failure, selecting **Retry** waits for the old start attempt to settle, sends one stop command, and then issues one fresh start command. Leaving Lane Details, changing lanes, or unmounting the player still sends the normal stop command and clears retry timers. Stopping while OSCAR is still waiting for the first keyframe is treated as a successful cancellation: native resources are finalized, incomplete HLS artifacts are removed, and queued packets cannot leak into a later restart. Actual packet-write or cleanup failures are still reported.

## Acceptance test

1. Open Lane Details for a lane with a connected camera.
2. Confirm the panel first shows **Preparing live video**, then begins playing within the configured camera keyframe interval plus normal network latency.
3. Confirm the playback time advances and the first HLS segment begins with a keyframe and decodes without missing-SPS/PPS errors.
4. Repeat on the first, middle, and last configured lanes, then switch rapidly between two lanes and confirm the old stream is stopped.
5. Stop an emulator publisher or disconnect a test camera. Confirm the Viewer eventually shows **Live video could not be played** and a **Retry** action instead of remaining at `0:00` indefinitely.
6. Restore the source, select **Retry**, and confirm playback resumes.
7. Run an occupancy recording and confirm its MP4 finalizes and decodes; the live-HLS startup gate must not change MP4 packet handling.

## Troubleshooting

| Symptom | Checks |
| --- | --- |
| Preparing lasts longer than expected | Check camera connectivity, confirm the stream is H.264, and measure the source keyframe interval. A long GOP directly increases worst-case startup time. |
| Live video could not be played | Restore camera/network reachability, inspect FFmpeg reconnect logs, and select **Retry**. |
| Player remains at `0:00` | Confirm the deployed OSCAR 4.0.0 image includes the keyframe-gated HLS and Viewer recovery fixes; inspect the first segment for a leading keyframe and valid H.264 parameter sets. |
| Emulator playback is slow to start | Run the emulator asset-preparation and validation scripts, then recreate the publisher containers. Runtime publishing should continue to use stream copy rather than live transcoding. |
| Recordings fail after a live-video change | Treat this as a regression. Live HLS and MP4 share camera input but have separate output rules; run the recording acceptance test before release. |
