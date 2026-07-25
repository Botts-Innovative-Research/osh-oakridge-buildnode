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
