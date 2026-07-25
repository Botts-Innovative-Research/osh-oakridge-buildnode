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
