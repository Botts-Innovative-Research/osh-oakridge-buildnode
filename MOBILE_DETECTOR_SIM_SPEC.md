# Mobile Radiation Detector Simulators — Specification

**Target:** the OSCAR site-simulator container (`10.235.20.94`).
**Audience:** the agent/developer implementing simulators in that container. This document is self-contained — no access to the OSCAR build repo is required. Two complete, protocol-tested Python reference implementations are included as appendices; you may run them as-is, port them, or reimplement from the byte-level specs below.

## 1. Purpose

OSCAR currently displays four static RPM lanes (Rapiscan simulators on TCP `10100–10103`, RTSP cameras on `9001–9003`) at the simulated Arlington National Cemetery site. We are adding two **mobile** detectors — a person walking the site carrying:

1. a **Radiation Solutions RS-350** backpack detector, and
2. a **Kromek D5** RIID.

Each needs a simulator process in the site-sim container. OSCAR's existing drivers (`sensorhub-driver-rs350`, `sensorhub-driver-kromek-d5`) will connect to them; OSCAR then shows the walker moving live on the map, drops alarm markers where alarms occur, and lists the alarms in the event table for adjudication.

## 2. Network topology and operational requirements

Both simulators are **TCP servers**. The OSCAR node is always the client and dials out (same pattern as the existing RPM sims):

| Simulator | Listen port | Direction | Protocol style |
|---|---|---|---|
| RS-350 | **10110** | OSCAR connects → sim **pushes** continuously | Framed N42.42 XML, one-way |
| Kromek D5 | **10111** | OSCAR connects → **polls**; sim answers each request | SLIP-framed binary, request/response |

Operational requirements (both):

- Bind `0.0.0.0`; the host must be reachable **and answer ICMP ping** — the RS-350 driver probes reachability before connecting and will not connect otherwise.
- Accept reconnects indefinitely (OSCAR retries with backoff; the driver may reconnect at any time). Accepting multiple simultaneous connections is fine but not required; never refuse a new connection because an old one is half-dead.
- Plain TCP, no TLS, no auth.
- Run forever (systemd unit / nohup like the existing sims). Two independent processes.

## 3. Shared walker & radiation model

Both simulators simulate a pedestrian following a waypoint route at ~1.4 m/s with a 1 Hz tick, looping forever, with linear interpolation between waypoints. Default route: a loop connecting the four site gates (see config in Appendix A/B):

- Memorial Ave gate `38.88340, -77.06653`
- AFM gate `38.86782, -77.06666`
- Selfridge gate `38.87678, -77.07849`
- Marshall gate `38.88773, -77.06768`

**Radiation model:** expected gamma count rate = Poisson(background) + Σ hotspot `intensity_cps_at_1m / max(d², 1)` where `d` is distance in meters. Default hotspots (configurable): a Cs-137 source mid-route on the eastern road and a Co-60 source near the Selfridge gate. The walker **alarms while** expected rate > `background × alarm_factor` (default 1.6), which yields a deterministic alarm episode each time the route passes a hotspot; the episode ends when the walker moves away (this matters: OSCAR turns each alarm episode into one adjudicable "occupancy" event).

Config is a JSON file overriding defaults (port, serial, route waypoints, speed, hotspots, background rates, alarm factor). Run the two sims with different routes/directions (defaults already differ) so the two walkers are visually distinct; point both at the same route + start point if you want one person carrying both devices.

## 4. RS-350 simulator — wire protocol

### 4.1 Transport & framing

- TCP server on `10110`. On client connect, **push one message per second**. Never read from the socket (the driver never writes). No handshake, no ACK, no CRC, no keep-alive needed.
- Each message is: **`0x02` (STX) + one N42.42 XML document (UTF-8) + `0x03` (ETX)**. The driver scans byte-wise for STX, accumulates until ETX. Therefore the XML **must not contain byte `0x03`** anywhere. The `<?xml ...?>` declaration is optional (it is stripped if present).
- The XML root **must** be `<RadInstrumentData>` in namespace **`http://physics.nist.gov/N42/2011/N42`** (default xmlns). A wrong or missing namespace makes the driver's JAXB parser silently produce an empty object — nothing is published and no error is visible.

### 4.2 Document content

The driver dispatches internal outputs based on which blocks a document contains. **Include the instrument/item/calibration blocks in every document** and the driver's Status output works every tick; include Foreground every tick; include Background periodically (e.g. every 30 s); add the alarm blocks only while alarming.

| Block | Cadence | Driver requirement (parser hard-indexes — violating these throws) |
|---|---|---|
| `RadInstrumentInformation` | every doc | `RadInstrumentCharacteristics[0]` needs ≥2 `Characteristic`: `[0]` = device name (string), `[1]` = battery charge (**must parse as a number**) |
| `RadItemInformation` | every doc | `RadItemCharacteristics[0]` needs ≥4 `Characteristic` values: scanMode (string), scanNumber (number), scanTimeoutNumber (number), analysisEnabled (0/1) |
| `EnergyCalibration id="LinEnCal"` and `id="CmpEnCal"` | every doc | ids are matched **literally**; each `CoefficientValues` needs **≥3** space-separated numbers |
| `RadMeasurement` with `MeasurementClassCode` `Foreground` | every doc (1 Hz) | ≥2 `<Spectrum>` (`[0]`=linear, `[1]`=compressed; any channel count — 1024/256 typical), ≥2 `<GrossCounts>` (`[0]`=gamma, `[1]`=neutron, each with `CountData`), ≥1 `<DoseRate><DoseRateValue>` (µSv/h). **GPS goes here**: `RadInstrumentState/StateVector/GeographicPoint` with `LatitudeValue`/`LongitudeValue`/`ElevationValue` — this is how OSCAR tracks the walker; include it in every Foreground |
| `RadMeasurement` with `Background` | every ~30 s | same shape as Foreground minus DoseRate/GPS (2 spectra + 2 gross counts required) |
| `DerivedData` **and** `AnalysisResults/RadAlarm` | while alarming | **both must be present together** for the driver to emit an alarm. `DerivedData`: `StartDateTime`, `RealTimeDuration`, `Remark`. `RadAlarm`: `RadAlarmCategoryCode` ∈ {Alpha, Neutron, Beta, **Gamma**, Other, Isotope}, `RadAlarmDescription` = isotope text shown to operators (e.g. `Cs-137`) |

Timestamps: ISO-8601 UTC `StartDateTime` (e.g. `2026-07-12T14:00:00Z`); durations as XML duration (`PT1.0S`).

Note: OSCAR emits one adjudicable event per alarm *episode* (first alarming document opens it; it closes ~10 s after alarming documents stop). Continuous alarming documents while inside a hotspot radius are correct behavior. Also, the first alarm of an episode triggers OSCAR's WebID reachback analysis server-side; the simulator does not participate.

### 4.3 Example document

See `build_document()` in Appendix A for the canonical, driver-tested example (skeleton: RadInstrumentInformation + 2 RadDetectorInformation + RadItemInformation + 2 EnergyCalibration + [Background] + Foreground(+GPS) + [DerivedData + AnalysisResults]).

## 5. Kromek D5 simulator — wire protocol

### 5.1 Transport & message layout

- TCP server on `10111`. The driver polls: it sends one request frame and **blocks reading exactly one response frame** (no timeout!), one report at a time, every second. The simulator must therefore run a strict `read request → write response` loop and answer **every** request **promptly** — a dropped response hangs the driver's polling thread.
- **All integers and floats are little-endian** (floats = IEEE-754 LE).
- Logical message layout (both directions):

```
[ length : u16 LE ] [ mode : 0x00 ] [ componentId : u8 ] [ reportId : u8 ] [ payload : N bytes ] [ crc : u16 = 0x0000 ]
      length = 7 + N   (counts every logical byte shown above, including itself)
```

- Frames are SLIP-wrapped: `0xC0 + body + 0xC0`. Requests from the driver arrive with payload N=0, e.g. RadiometricsV1: `C0 07 00 00 07 C2 00 00 C0`.
- CRC is **never validated** — always send `00 00`.
- The response must **echo the request's componentId and reportId**. Never use reportId `0xFE` or `0xFF` (reserved ACK codes — the driver discards such responses).

### 5.2 ⚠ Byte-cleanliness constraint (the one real interop trap)

The driver reads `length` **raw** bytes off the wire, but `length` counts **logical** (pre-escape) bytes, and its SLIP decoder treats any interior `0xDB` as an escape byte. Consequently:

> **The response body (everything between the two `0xC0` frame bytes) must contain no `0xC0` and no `0xDB` bytes, and must NOT be SLIP-escaped.**

Practical technique (see `clean_*()` helpers in Appendix B): before emitting any u16/u32/i16/f32 field, check its LE encoding; if any byte is `0xC0`/`0xDB`, nudge the value minimally (counts −1; floats +1e-6 — that's ~0.1 m for a latitude) and re-check. For the 4096×u16 spectrum, clamping bin values to ≤191 makes every byte trivially clean.

### 5.3 Reports to answer

The driver polls per its config. **Only two reports are enabled by default in OSCAR — implement these two first:**

| Report | componentId / reportId | Default poll | Payload |
|---|---|---|---|
| **RadiometricsV1** | `0x07` / `0xC2` | 1 s | **8246 bytes**, table below |
| **RadiometricStatus** | `0x08` / `0x82` | 1 s | ≥17 bytes, table below — **alarm flags + GPS live here** |
| Status | `0x07` / `0xC5` | 10 s (if enabled) | ≥11 B: `[0]`appStatus u8, `[1]`powerSource u8 **enum 0–4**, `[2]`temperature i8 °C, `[3][4]`detectorStatus0/1 u8, `[5]`batteryLevel u8 %, `[6]`batteryChargeRate i8, `[7]`batteryTemperature i8, `[8]`usbStatus u8, `[9]`btStatus u8, `[10]`detectorStatus2 u8 |
| About | `0x07` / `0xC7` | once (if enabled) | ≥104 B: `[0..1]`firmware, `[2..3]`modelrev, `[4..53]`productName (50 B NUL-padded), `[54..103]`serialNumber (50 B NUL-padded) |
| DoseInfo | `0x07` / `0xD3` | 1 s (if enabled) | ≥21 B: 4×f32 (lifetimeDose, powerUpDose, userDose, doseRate µSv/h), u32 reserved, `[20]`selectedDoseDetector u8 **must be 0** |
| UnitID | `0x07` / `0xFC` | 1 s (if enabled) | 12 B |
| UTC | `0x07` / `0xE9` | 1 s (if enabled) | ≥9 B: u32 epoch-s, f32 tzOffset, u8 dst |
| Others (CompressionEnabled `0xCF`, EthernetConfig `0xCD`, OTG `0xC6`, UIRadiationThresholds `0xD1`, RemoteIsotope\* `0xEB/0xEC/0xEE/0xFB`) | `0x07` / … | disabled by default | answer with an empty payload if requested — the driver logs and skips; or implement per the enum-safe layouts in the OSH driver source |

**RadiometricsV1 payload (offsets into payload, LE):**

| off | type | field | | off | type | field |
|---|---|---|---|---|---|---|
| 0 | u32 | status (0 fine) | | 32 | i16 | neutronTemperature ×100 °C |
| 4 | u32 | realTimeMs since boot | | 34 | f32 | reserved |
| 8 | u32 | sequenceNumber (increment) | | 38 | u32 | gammaLiveTime ms |
| 12 | f32 | dose accumulated (µSv) | | 42 | u32 | gammaCounts (this interval) |
| 16 | f32 | doseRate (µSv/h) | | 46 | i16 | gammaTemperature ×100 °C |
| 20 | f32 | doseUserAccumulated (µSv) | | 48 | f32 | reserved |
| 24 | u32 | neutronLiveTime ms | | 52 | u8 | spectrumBitsSize = 12 |
| 28 | u32 | neutronCounts | | 53 | u8 | reserved |
| | | | | 54 | 4096 × u16 | spectrum bins (always all 4096) |

**RadiometricStatus payload:**

| off | type | field |
|---|---|---|
| 0 | u8 | doseAlarmActive (0/1) |
| 1 | u8 | gammaCpsAlarmActive (0/1) — **set 1 while in an alarm episode** |
| 2 | u8 | neutronCpsAlarmActive (0/1) |
| 3 | f32 | **latitude** (deg) — walker position |
| 7 | f32 | **longitude** (deg) |
| 11 | u32 | deviceTimestamp (epoch seconds) |
| 15 | u16 | numNuclideResults (0 is fine) |
| 17… | raw | nuclideData: per entry {u8 nuclideIdType, u8 category, f32 confidence} — optional |

**Enum safety:** any field documented as an enum is indexed into a Java enum array — an out-of-range ordinal makes the driver drop that whole report. Stay in range: powerSource 0–4, selectedDoseDetector 0 only, OTG mode 0–2, remote-control mode 0–3, remote state 0–5, nuclideIdType 0–26, thresholdType 0–3.

## 6. Acceptance tests

Protocol level (run inside the sim container):
1. RS-350: `python3 - <<'EOF'` connect to `:10110`, read to first `0x03`, strip to after `0x02`, `xml.etree` parse; assert root tag `{http://physics.nist.gov/N42/2011/N42}RadInstrumentData`, ≥2 instrument characteristics, ≥4 item characteristics, both `EnergyCalibration` ids, a Foreground with 2 spectra + 2 gross counts + DoseRate + GeographicPoint. Read a second frame ~1 s later; GPS must have moved. (The test harness used to validate Appendix A is available on request — it mimics the driver's byte-scan exactly.)
2. D5: send `C0 07 00 00 07 C2 00 00 C0`; read 1 byte (=C0), then 2 length bytes, then `length-2` raw bytes; assert length = 8253, **no `0xC0`/`0xDB` anywhere in the body**, body[3..4] echoes `07 C2`. Repeat with `08 82`; parse lat/lon f32 at payload offsets 3/7 and check they're on-site (38.86–38.89, −77.09…−77.06).

End-to-end (after OSCAR's walker lanes are configured — done on the OSCAR side):
3. OSCAR node connects within ~10 s of both sims being up (watch for inbound connections from the OSCAR container).
4. On the OSCAR node: `curl -u admin:oscar 'http://<oscar-host>:8282/sensorhub/api/systems?limit=100'` lists the walker lane systems; their `location` datastreams tick at 1 Hz and, when the walker crosses a hotspot, an occupancy observation appears and the OSCAR UI shows the alarm marker + event-table row.

## 7. Appendices — reference implementations

Both scripts below are stdlib-only Python 3, tested byte-for-byte against the actual OSH drivers' read logic (framing, required XML elements, payload sizes, byte-cleanliness, echo semantics). Copy them into the sim container and run:

```
python3 rs350_mock.py   # listens on 10110
python3 d5_mock.py      # listens on 10111
```

Treat them as the executable form of this spec: anything ambiguous above is resolved by what these scripts do.

### Appendix A — `rs350_mock.py`

```python
#!/usr/bin/env python3
"""
RS-350 backpack detector simulator (reference implementation).

Emulates the device side of the OSH sensorhub-driver-rs350 protocol:
a TCP *server* that, once the OSCAR node's driver connects, pushes one
ANSI N42.42 (2011) XML document per second, framed as STX(0x02) <xml> ETX(0x03).
The driver never writes; there is no handshake, ACK, or CRC.

A simulated walker follows a waypoint route (default: Arlington National
Cemetery gate loop). Radiation counts are Poisson background plus 1/r^2
contributions from configurable hotspots; while the expected count rate
exceeds background*alarm_factor the documents also carry the alarm blocks
(<DerivedData> + <AnalysisResults><RadAlarm>), which is what the driver
keys its Alarm output on.

Stdlib only. Usage:
    python3 rs350_mock.py [--config cfg.json] [--port 10110]
Config file (JSON) overrides any subset of DEFAULT_CONFIG.
"""
import argparse
import json
import math
import random
import socket
import threading
import time
from datetime import datetime, timezone

STX = b"\x02"
ETX = b"\x03"
N42_NS = "http://physics.nist.gov/N42/2011/N42"

DEFAULT_CONFIG = {
    "port": 10110,
    "serial": "WALKER1",
    "device_name": "RS350-WALKER1",
    "tick_s": 1.0,
    "speed_mps": 1.4,
    "background_gamma_cps": 1200.0,
    "background_neutron_cps": 0.4,
    "alarm_factor": 1.6,
    "background_block_every_s": 30,
    # Loop: Memorial Ave gate -> AFM gate -> Selfridge gate -> Marshall gate
    "route": [
        [38.88340, -77.06653],
        [38.87890, -77.06580],
        [38.87310, -77.06520],
        [38.86782, -77.06666],
        [38.86940, -77.07230],
        [38.87678, -77.07849],
        [38.88210, -77.07360],
        [38.88773, -77.06768],
        [38.88560, -77.06600],
    ],
    "hotspots": [
        {"lat": 38.87310, "lon": -77.06520, "intensity_cps_at_1m": 90000.0, "isotope": "Cs-137"},
        {"lat": 38.87678, "lon": -77.07849, "intensity_cps_at_1m": 60000.0, "isotope": "Co-60"},
    ],
}

M_PER_DEG_LAT = 111_320.0


def dist_m(lat1, lon1, lat2, lon2):
    dy = (lat2 - lat1) * M_PER_DEG_LAT
    dx = (lon2 - lon1) * M_PER_DEG_LAT * math.cos(math.radians(lat1))
    return math.hypot(dx, dy)


def poisson(lam):
    """Poisson sample; gaussian approximation for large lambda."""
    if lam > 50:
        return max(0, int(random.gauss(lam, math.sqrt(lam))))
    l, k, p = math.exp(-lam), 0, 1.0
    while True:
        p *= random.random()
        if p <= l:
            return k
        k += 1


class Walker:
    """Constant-speed waypoint follower, loops forever."""

    def __init__(self, route, speed_mps):
        self.route = route
        self.speed = speed_mps
        self.seg = 0
        self.seg_pos = 0.0  # meters into current segment

    def step(self, dt):
        remaining = self.speed * dt
        while remaining > 0:
            a = self.route[self.seg]
            b = self.route[(self.seg + 1) % len(self.route)]
            seg_len = dist_m(a[0], a[1], b[0], b[1])
            if self.seg_pos + remaining < seg_len:
                self.seg_pos += remaining
                remaining = 0
            else:
                remaining -= (seg_len - self.seg_pos)
                self.seg = (self.seg + 1) % len(self.route)
                self.seg_pos = 0.0

    def position(self):
        a = self.route[self.seg]
        b = self.route[(self.seg + 1) % len(self.route)]
        seg_len = max(dist_m(a[0], a[1], b[0], b[1]), 0.01)
        f = min(self.seg_pos / seg_len, 1.0)
        return a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f


class RadModel:
    def __init__(self, cfg):
        self.cfg = cfg

    def expected_gamma(self, lat, lon):
        cps = self.cfg["background_gamma_cps"]
        for h in self.cfg["hotspots"]:
            d = dist_m(lat, lon, h["lat"], h["lon"])
            cps += h["intensity_cps_at_1m"] / max(d * d, 1.0)
        return cps

    def nearest_hotspot(self, lat, lon):
        return min(self.cfg["hotspots"],
                   key=lambda h: dist_m(lat, lon, h["lat"], h["lon"]),
                   default=None) if self.cfg["hotspots"] else None

    def is_alarming(self, lat, lon):
        return self.expected_gamma(lat, lon) > \
            self.cfg["background_gamma_cps"] * self.cfg["alarm_factor"]


def spectrum(total_counts, n_channels, peak_channel=None):
    """Cheap exponential continuum with an optional photopeak."""
    decay = n_channels / 6.0
    weights = [math.exp(-i / decay) for i in range(n_channels)]
    if peak_channel is not None and 0 < peak_channel < n_channels:
        for i in range(max(0, peak_channel - 6), min(n_channels, peak_channel + 7)):
            weights[i] += 4.0 * math.exp(-((i - peak_channel) ** 2) / 8.0)
    wsum = sum(weights)
    return [int(total_counts * w / wsum) for w in weights]


ISOTOPE_PEAK_KEV = {"Cs-137": 662, "Co-60": 1332, "Am-241": 60, "Ba-133": 356}


def measurement_block(class_code, mid, start_iso, gamma_counts, neutron_counts,
                      dose_usvh=None, gps=None, isotope=None):
    # Linear calibration is 0 + 3.0*ch keV (below), so peak channel = keV/3.
    peak = None
    if isotope in ISOTOPE_PEAK_KEV:
        peak = ISOTOPE_PEAK_KEV[isotope] // 3
    lin = spectrum(gamma_counts, 1024, peak)
    cmp_ = spectrum(gamma_counts, 256, peak // 4 if peak else None)
    parts = [
        f'  <RadMeasurement id="{mid}">',
        f'    <MeasurementClassCode>{class_code}</MeasurementClassCode>',
        f'    <StartDateTime>{start_iso}</StartDateTime>',
        '    <RealTimeDuration>PT1.0S</RealTimeDuration>',
        f'    <Spectrum id="{mid}Lin" radDetectorInformationReference="DetGamma" '
        f'energyCalibrationReference="LinEnCal">',
        '      <LiveTimeDuration>PT1.0S</LiveTimeDuration>',
        f'      <ChannelData>{" ".join(map(str, lin))}</ChannelData>',
        '    </Spectrum>',
        f'    <Spectrum id="{mid}Cmp" radDetectorInformationReference="DetGamma" '
        f'energyCalibrationReference="CmpEnCal">',
        '      <LiveTimeDuration>PT1.0S</LiveTimeDuration>',
        f'      <ChannelData>{" ".join(map(str, cmp_))}</ChannelData>',
        '    </Spectrum>',
        f'    <GrossCounts id="{mid}Gamma" radDetectorInformationReference="DetGamma">',
        '      <LiveTimeDuration>PT1.0S</LiveTimeDuration>',
        f'      <CountData>{gamma_counts}</CountData>',
        '    </GrossCounts>',
        f'    <GrossCounts id="{mid}Neutron" radDetectorInformationReference="DetNeutron">',
        '      <LiveTimeDuration>PT1.0S</LiveTimeDuration>',
        f'      <CountData>{neutron_counts}</CountData>',
        '    </GrossCounts>',
    ]
    if dose_usvh is not None:
        parts += [
            f'    <DoseRate id="{mid}Dose" radDetectorInformationReference="DetGamma">',
            f'      <DoseRateValue>{dose_usvh:.4f}</DoseRateValue>',
            '    </DoseRate>',
        ]
    if gps is not None:
        lat, lon, alt = gps
        parts += [
            '    <RadInstrumentState radInstrumentInformationReference="InstInfo">',
            '      <StateVector>',
            '        <GeographicPoint>',
            f'          <LatitudeValue>{lat:.6f}</LatitudeValue>',
            f'          <LongitudeValue>{lon:.6f}</LongitudeValue>',
            f'          <ElevationValue>{alt:.1f}</ElevationValue>',
            '        </GeographicPoint>',
            '      </StateVector>',
            '    </RadInstrumentState>',
        ]
    parts.append('  </RadMeasurement>')
    return "\n".join(parts)


def characteristic(name, value, units="unit-less", data_class="string"):
    return (f'      <Characteristic><CharacteristicName>{name}</CharacteristicName>'
            f'<CharacteristicValue>{value}</CharacteristicValue>'
            f'<CharacteristicValueUnits>{units}</CharacteristicValueUnits>'
            f'<CharacteristicValueDataClassCode>{data_class}</CharacteristicValueDataClassCode>'
            f'</Characteristic>')


def build_document(cfg, walker, model, battery_pct, include_background, alarming):
    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    lat, lon = walker.position()
    exp_gamma = model.expected_gamma(lat, lon)
    gamma = poisson(exp_gamma)
    neutron = poisson(cfg["background_neutron_cps"])
    dose = exp_gamma / 12000.0  # crude uSv/h mapping
    hotspot = model.nearest_hotspot(lat, lon)
    isotope = hotspot["isotope"] if (alarming and hotspot) else None

    doc = [
        f'<RadInstrumentData xmlns="{N42_NS}">',
        '  <RadInstrumentInformation id="InstInfo">',
        '    <RadInstrumentManufacturerName>Radiation Solutions Inc</RadInstrumentManufacturerName>',
        f'    <RadInstrumentIdentifier>{cfg["serial"]}</RadInstrumentIdentifier>',
        '    <RadInstrumentModelName>RS-350</RadInstrumentModelName>',
        '    <RadInstrumentClassCode>Backpack</RadInstrumentClassCode>',
        '    <RadInstrumentVersion><RadInstrumentComponentName>Software'
        '</RadInstrumentComponentName><RadInstrumentComponentVersion>sim-1.0'
        '</RadInstrumentComponentVersion></RadInstrumentVersion>',
        '    <RadInstrumentCharacteristics>',
        characteristic("DeviceName", cfg["device_name"]),
        characteristic("BatteryCharge", f"{battery_pct:.0f}", "percent", "double"),
        '    </RadInstrumentCharacteristics>',
        '  </RadInstrumentInformation>',
        '  <RadDetectorInformation id="DetGamma">'
        '<RadDetectorCategoryCode>Gamma</RadDetectorCategoryCode>'
        '<RadDetectorKindCode>NaI</RadDetectorKindCode></RadDetectorInformation>',
        '  <RadDetectorInformation id="DetNeutron">'
        '<RadDetectorCategoryCode>Neutron</RadDetectorCategoryCode>'
        '<RadDetectorKindCode>He3</RadDetectorKindCode></RadDetectorInformation>',
        '  <RadItemInformation id="ItemInfo">',
        '    <RadItemCharacteristics>',
        characteristic("ScanMode", "Search"),
        characteristic("ScanNumber", "1", "unit-less", "double"),
        characteristic("ScanTimeoutNumber", "0", "unit-less", "double"),
        characteristic("AnalysisEnabled", "1", "unit-less", "integer"),
        '    </RadItemCharacteristics>',
        '  </RadItemInformation>',
        '  <EnergyCalibration id="LinEnCal">',
        '    <CoefficientValues>0 3.0 0</CoefficientValues>',
        '  </EnergyCalibration>',
        '  <EnergyCalibration id="CmpEnCal">',
        '    <CoefficientValues>0 12.0 0</CoefficientValues>',
        '  </EnergyCalibration>',
    ]
    if include_background:
        bg_gamma = poisson(cfg["background_gamma_cps"])
        bg_neutron = poisson(cfg["background_neutron_cps"])
        doc.append(measurement_block("Background", "Bkg", now_iso, bg_gamma, bg_neutron))
    doc.append(measurement_block("Foreground", "Fg", now_iso, gamma, neutron,
                                 dose_usvh=dose, gps=(lat, lon, 20.0), isotope=isotope))
    if alarming:
        category = "Gamma"
        description = isotope or "Unknown"
        doc += [
            '  <DerivedData id="Derived">',
            '    <MeasurementClassCode>NotSpecified</MeasurementClassCode>',
            f'    <StartDateTime>{now_iso}</StartDateTime>',
            '    <RealTimeDuration>PT1.0S</RealTimeDuration>',
            '    <Remark>Alarm</Remark>',
            '  </DerivedData>',
            '  <AnalysisResults id="Analysis">',
            '    <RadAlarm radDetectorInformationReferences="DetGamma">',
            f'      <RadAlarmCategoryCode>{category}</RadAlarmCategoryCode>',
            f'      <RadAlarmDescription>{description}</RadAlarmDescription>',
            '    </RadAlarm>',
            '  </AnalysisResults>',
        ]
    doc.append('</RadInstrumentData>')
    return "\n".join(doc)


def serve(cfg):
    walker = Walker(cfg["route"], cfg["speed_mps"])
    model = RadModel(cfg)
    state = {"battery": 100.0, "clients": [], "last_bkg": 0.0}
    lock = threading.Lock()

    def ticker():
        while True:
            t0 = time.time()
            walker.step(cfg["tick_s"])
            state["battery"] = max(5.0, state["battery"] - 0.002)
            include_bkg = (t0 - state["last_bkg"]) >= cfg["background_block_every_s"]
            if include_bkg:
                state["last_bkg"] = t0
            lat, lon = walker.position()
            alarming = model.is_alarming(lat, lon)
            xml = build_document(cfg, walker, model, state["battery"], include_bkg, alarming)
            frame = STX + xml.encode("utf-8") + ETX
            with lock:
                dead = []
                for c in state["clients"]:
                    try:
                        c.sendall(frame)
                    except OSError:
                        dead.append(c)
                for c in dead:
                    state["clients"].remove(c)
            if alarming:
                print(f"[rs350-sim] ALARM at {lat:.5f},{lon:.5f}", flush=True)
            time.sleep(max(0.0, cfg["tick_s"] - (time.time() - t0)))

    threading.Thread(target=ticker, daemon=True).start()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", cfg["port"]))
    srv.listen(4)
    print(f"[rs350-sim] listening on :{cfg['port']}", flush=True)
    while True:
        conn, addr = srv.accept()
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        print(f"[rs350-sim] client connected: {addr}", flush=True)
        with lock:
            state["clients"].append(conn)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", help="JSON file overriding DEFAULT_CONFIG keys")
    ap.add_argument("--port", type=int)
    args = ap.parse_args()
    cfg = dict(DEFAULT_CONFIG)
    if args.config:
        with open(args.config) as f:
            cfg.update(json.load(f))
    if args.port:
        cfg["port"] = args.port
    serve(cfg)


if __name__ == "__main__":
    main()
```

### Appendix B — `d5_mock.py`

```python
#!/usr/bin/env python3
"""
Kromek D5 RIID simulator (reference implementation).

Emulates the device side of the OSH sensorhub-driver-kromek-d5 protocol:
a TCP *server* speaking the Kromek serial protocol over SLIP framing.
The driver is a polling TCP client: every second it sends one or more
header-only request frames and BLOCKS reading one response frame each —
so this server is a simple "read one request -> write one response" loop.

Frame layout (logical bytes, before SLIP; ALL integers little-endian):
    [length u16 = 7 + N] [mode 0x00] [componentId] [reportId] [payload N bytes] [crc u16 = 0x0000]
wrapped in 0xC0 ... 0xC0. CRC is never checked; requests carry N=0.
The response must ECHO the request's componentId/reportId (never 0xFE/0xFF).

CRITICAL interop constraint: the driver reads `length` RAW bytes after the
frame byte but `length` counts LOGICAL (pre-SLIP-escape) bytes, and its SLIP
decoder treats interior 0xDB as an escape. Therefore the response body must
contain NO 0xC0 and NO 0xDB bytes, and must NOT be escaped. The clean_*()
helpers below nudge values minimally until their encoding is clean.

Reports implemented (the two default-enabled ones plus cheap extras):
    0x07/0xC2 RadiometricsV1     - dose/counts + 4096 x u16 spectrum (payload 8246 B)
    0x08/0x82 RadiometricStatus  - alarm flags + GPS lat/lon (this is the one
                                   OSCAR uses for alarms and location)
    0x07/0xC5 Status             - battery/temperature
    0x07/0xC7 About              - firmware/product/serial strings
Unknown reports are answered with an empty payload (driver logs and skips).

Stdlib only. Usage:
    python3 d5_mock.py [--config cfg.json] [--port 10111]
"""
import argparse
import json
import math
import random
import socket
import struct
import threading
import time

FRAME = 0xC0
ESC = 0xDB
BAD = (0xC0, 0xDB)

DEFAULT_CONFIG = {
    "port": 10111,
    "serial": "WALKER2",
    "tick_s": 1.0,
    "speed_mps": 1.4,
    "background_gamma_cps": 900.0,
    "background_neutron_cps": 0.3,
    "alarm_factor": 1.6,
    # Same site, opposite direction so the two walkers separate visually.
    "route": [
        [38.88773, -77.06768],
        [38.88210, -77.07360],
        [38.87678, -77.07849],
        [38.86940, -77.07230],
        [38.86782, -77.06666],
        [38.87310, -77.06520],
        [38.87890, -77.06580],
        [38.88340, -77.06653],
        [38.88560, -77.06600],
    ],
    "hotspots": [
        {"lat": 38.87310, "lon": -77.06520, "intensity_cps_at_1m": 90000.0, "isotope": "Cs-137"},
        {"lat": 38.87678, "lon": -77.07849, "intensity_cps_at_1m": 60000.0, "isotope": "Co-60"},
    ],
}

M_PER_DEG_LAT = 111_320.0


def dist_m(lat1, lon1, lat2, lon2):
    dy = (lat2 - lat1) * M_PER_DEG_LAT
    dx = (lon2 - lon1) * M_PER_DEG_LAT * math.cos(math.radians(lat1))
    return math.hypot(dx, dy)


def poisson(lam):
    if lam > 50:
        return max(0, int(random.gauss(lam, math.sqrt(lam))))
    l, k, p = math.exp(-lam), 0, 1.0
    while True:
        p *= random.random()
        if p <= l:
            return k
        k += 1


class Walker:
    def __init__(self, route, speed_mps):
        self.route, self.speed, self.seg, self.seg_pos = route, speed_mps, 0, 0.0

    def step(self, dt):
        remaining = self.speed * dt
        while remaining > 0:
            a = self.route[self.seg]
            b = self.route[(self.seg + 1) % len(self.route)]
            seg_len = dist_m(a[0], a[1], b[0], b[1])
            if self.seg_pos + remaining < seg_len:
                self.seg_pos += remaining
                remaining = 0
            else:
                remaining -= (seg_len - self.seg_pos)
                self.seg = (self.seg + 1) % len(self.route)
                self.seg_pos = 0.0

    def position(self):
        a = self.route[self.seg]
        b = self.route[(self.seg + 1) % len(self.route)]
        seg_len = max(dist_m(a[0], a[1], b[0], b[1]), 0.01)
        f = min(self.seg_pos / seg_len, 1.0)
        return a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f


# ---- byte-cleanliness helpers: keep 0xC0/0xDB out of the response body ----

def clean_u16(v):
    v = max(0, min(0xFFFF, int(v)))
    while any(b in BAD for b in struct.pack("<H", v)):
        v -= 1
    return struct.pack("<H", v)


def clean_u32(v):
    v = max(0, min(0xFFFFFFFF, int(v)))
    while any(b in BAD for b in struct.pack("<I", v)):
        v -= 1
    return struct.pack("<I", v)


def clean_i16(v):
    v = int(v)
    while any(b in BAD for b in struct.pack("<h", v)):
        v -= 1
    return struct.pack("<h", v)


def clean_f32(x, step=1e-6):
    x = float(x)
    for _ in range(1000):
        raw = struct.pack("<f", x)
        if not any(b in BAD for b in raw):
            return raw
        x += step
    return struct.pack("<f", 0.0)


def clean_u8(v):
    v = max(0, min(0xFF, int(v)))
    return bytes([v - 1 if v in BAD else v])


# ---- device state ----

class D5State:
    def __init__(self, cfg):
        self.cfg = cfg
        self.walker = Walker(cfg["route"], cfg["speed_mps"])
        self.t0 = time.time()
        self.seq = 0
        self.dose_total = 0.0
        self.battery = 100.0
        self.lock = threading.Lock()
        self.gamma_cps = cfg["background_gamma_cps"]
        self.neutron_counts_tick = 0
        threading.Thread(target=self._ticker, daemon=True).start()

    def _expected_gamma(self, lat, lon):
        cps = self.cfg["background_gamma_cps"]
        for h in self.cfg["hotspots"]:
            d = dist_m(lat, lon, h["lat"], h["lon"])
            cps += h["intensity_cps_at_1m"] / max(d * d, 1.0)
        return cps

    def _ticker(self):
        while True:
            with self.lock:
                self.walker.step(self.cfg["tick_s"])
                lat, lon = self.walker.position()
                exp = self._expected_gamma(lat, lon)
                self.gamma_cps = poisson(exp)
                self.neutron_counts_tick = poisson(self.cfg["background_neutron_cps"])
                self.dose_total += exp / 12000.0 / 3600.0  # uSv accrued this second
                self.battery = max(5.0, self.battery - 0.002)
                self.seq += 1
                self.alarming = exp > self.cfg["background_gamma_cps"] * self.cfg["alarm_factor"]
                if self.alarming:
                    print(f"[d5-sim] ALARM at {lat:.5f},{lon:.5f}", flush=True)
            time.sleep(self.cfg["tick_s"])

    # ---- report payload builders ----

    def radiometrics_v1(self):
        with self.lock:
            gamma_counts = int(self.gamma_cps)
            dose_rate = self._expected_gamma(*self.walker.position()) / 12000.0
            p = b"".join([
                clean_u32(0),                          # status
                clean_u32(int((time.time() - self.t0) * 1000)),  # realTimeMs
                clean_u32(self.seq),                   # sequenceNumber
                clean_f32(self.dose_total),            # dose (uSv)
                clean_f32(dose_rate),                  # doseRate (uSv/h)
                clean_f32(self.dose_total),            # doseUserAccumulated
                clean_u32(1000),                       # neutronLiveTime
                clean_u32(self.neutron_counts_tick),   # neutronCounts (per interval)
                clean_i16(2500),                       # neutronTemperature (x100 C)
                clean_f32(0.0),                        # neutronReserved
                clean_u32(1000),                       # gammaLiveTime
                clean_u32(gamma_counts),               # gammaCounts
                clean_i16(2500),                       # gammaTemperature (x100 C)
                clean_f32(0.0),                        # gammaReserved
                bytes([12, 0]),                        # spectrumBitsSize, reserved
            ])
            # 4096 x u16 spectrum; values clamped to <=191 so every byte is
            # trivially clean (low byte <0xC0, high byte 0x00).
            decay = 4096 / 6.0
            total = max(gamma_counts, 1)
            bins = bytearray()
            wsum = sum(math.exp(-i / decay) for i in range(0, 4096, 16)) * 16
            for i in range(4096):
                v = min(191, int(total * math.exp(-i / decay) / wsum * 16))
                bins += struct.pack("<H", v)
            payload = p + bytes(bins)
        assert len(payload) == 8246, len(payload)
        return payload

    def radiometric_status(self):
        with self.lock:
            lat, lon = self.walker.position()
            alarming = getattr(self, "alarming", False)
            return b"".join([
                clean_u8(0),                    # doseAlarmActive
                clean_u8(1 if alarming else 0), # gammaCpsAlarmActive
                clean_u8(0),                    # neutronCpsAlarmActive
                clean_f32(lat, step=1e-6),      # latitude (deg)
                clean_f32(lon, step=1e-6),      # longitude (deg)
                clean_u32(int(time.time())),    # deviceTimestamp (epoch s)
                clean_u16(0),                   # numNuclideResults
            ])

    def status(self):
        with self.lock:
            return b"".join([
                clean_u8(0),                    # appStatus
                clean_u8(1),                    # power source: BATTERY
                clean_u8(25),                   # temperature C
                clean_u8(0), clean_u8(0),       # detectorStatus0/1
                clean_u8(int(self.battery)),    # batteryLevel %
                clean_u8(0),                    # batteryChargeRate
                clean_u8(25),                   # batteryTemperature
                clean_u8(0), clean_u8(0),       # usbStatus, btStatus
                clean_u8(0),                    # detectorStatus2
            ])

    def about(self):
        name = b"Kromek D5 (sim)".ljust(50, b"\x00")[:50]
        serial = self.cfg["serial"].encode().ljust(50, b"\x00")[:50]
        return bytes([1, 0, 1, 0]) + name + serial


def build_frame(component_id, report_id, payload):
    body = struct.pack("<H", 7 + len(payload)) + bytes([0x00, component_id, report_id]) \
        + payload + b"\x00\x00"
    dirty = [b for b in body if b in BAD]
    if dirty:
        raise ValueError(f"response body contains framing bytes: {dirty[:5]}")
    return bytes([FRAME]) + body + bytes([FRAME])


def slip_decode(data):
    out = bytearray()
    i = 0
    while i < len(data):
        b = data[i]
        if b == ESC and i + 1 < len(data):
            out.append(FRAME if data[i + 1] == 0xDC else ESC)
            i += 2
        else:
            out.append(b)
            i += 1
    return bytes(out)


def handle_client(conn, addr, state):
    print(f"[d5-sim] client connected: {addr}", flush=True)
    buf = bytearray()
    try:
        while True:
            chunk = conn.recv(4096)
            if not chunk:
                break
            buf += chunk
            while True:
                # hunt for a complete 0xC0 ... 0xC0 frame with content
                try:
                    start = buf.index(FRAME)
                except ValueError:
                    buf.clear()
                    break
                end = start + 1
                while end < len(buf) and buf[end] == FRAME:
                    start = end          # collapse repeated frame bytes
                    end += 1
                try:
                    end = buf.index(FRAME, start + 1)
                except ValueError:
                    break                # incomplete frame, wait for more
                raw = slip_decode(bytes(buf[start + 1:end]))
                del buf[:end]            # keep trailing 0xC0 as next frame's opener
                if len(raw) < 7:
                    continue
                component_id, report_id = raw[3], raw[4]
                payload = dispatch(component_id, report_id, state)
                conn.sendall(build_frame(component_id, report_id, payload))
    except OSError:
        pass
    finally:
        conn.close()
        print(f"[d5-sim] client disconnected: {addr}", flush=True)


def dispatch(component_id, report_id, state):
    key = (component_id, report_id)
    if key == (0x07, 0xC2):
        return state.radiometrics_v1()
    if key == (0x08, 0x82):
        return state.radiometric_status()
    if key == (0x07, 0xC5):
        return state.status()
    if key == (0x07, 0xC7):
        return state.about()
    print(f"[d5-sim] unimplemented report {component_id:#04x}/{report_id:#04x}, "
          f"answering empty", flush=True)
    return b""


def serve(cfg):
    state = D5State(cfg)
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", cfg["port"]))
    srv.listen(4)
    print(f"[d5-sim] listening on :{cfg['port']}", flush=True)
    while True:
        conn, addr = srv.accept()
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        threading.Thread(target=handle_client, args=(conn, addr, state), daemon=True).start()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", help="JSON file overriding DEFAULT_CONFIG keys")
    ap.add_argument("--port", type=int)
    args = ap.parse_args()
    cfg = dict(DEFAULT_CONFIG)
    if args.config:
        with open(args.config) as f:
            cfg.update(json.load(f))
    if args.port:
        cfg["port"] = args.port
    serve(cfg)


if __name__ == "__main__":
    main()
```
