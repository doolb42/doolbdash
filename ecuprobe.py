#!/usr/bin/env python3
"""
ECUProbe v3 - Best of Both Worlds
Target: HKMC Tucson PHEV 2024 (and compatible Hyundai/Kia PHEV platforms)
Platform: Raspberry Pi + CAN hat (e.g. PiCAN2 / MCP2515) via SocketCAN

Features:
  - Full argparse CLI (interface, duration, logdir, custom DID list)
  - Automatic ECU discovery across 0x700-0x7FF
  - Multi-service UDS probing: 0x22 (ReadDataByIdentifier),
    0x2E (WriteDataByIdentifier - discovery only, never writes),
    0x31 (RoutineControl - discovery only, never executes)
  - Correct UDS response address handling (req + 0x08)
  - ISO-TP flow control via python-can + can-isotp (not raw Scapy)
  - Single shared can.Bus instance for entire run (no per-request open/close)
  - OOP ECU class with address, name, and DID map
  - Known HKMC ECU name map (PCM, HCM, BCM, HybridControl, etc.)
  - Per-ECU CSV log + master JSON summary
  - Live CAN capture saved as .pcap (opens in Wireshark)
  - Full timestamped logging via stdlib logging module (file + console)
  - Robust error handling - no fatal stops on individual ECU/DID failures

Dependencies:
  pip install scapy python-can can-isotp

Raspberry Pi setup:
  sudo ip link set can0 up type can bitrate 500000
  (or let this script do it via --interface can0)
"""

import os
import sys
import csv
import json
import time
import logging
import argparse
import datetime
import subprocess
import threading
from pathlib import Path

# Scapy for live capture / pcap writing
from scapy.all import AsyncSniffer
from scapy.layers.can import CAN
from scapy.utils import PcapWriter
from scapy.utils import wrpcap

# python-can + can-isotp for proper ISO-TP with flow control
try:
    import can
    import isotp
except ImportError:
    print("ERROR: Missing dependencies. Run:  pip install python-can can-isotp")
    sys.exit(1)

# ──────────────────────────────────────────────
# CLI Arguments
# ──────────────────────────────────────────────
parser = argparse.ArgumentParser(
    description="ECUProbe v3 - HKMC Tucson PHEV UDS/ISO-TP ECU mapper",
    formatter_class=argparse.ArgumentDefaultsHelpFormatter,
)
parser.add_argument("--interface",  "-i", default="can0",
                    help="SocketCAN interface (e.g. can0, vcan0)")
parser.add_argument("--bitrate",    "-b", type=int, default=500000,
                    help="CAN bus bitrate in bps")
parser.add_argument("--duration",   "-d", type=int, default=60,
                    help="Live CAN capture duration in seconds")
parser.add_argument("--logdir",     "-l", default="~/ecudump",
                    help="Output directory for logs, CSVs, pcap, JSON")
parser.add_argument("--dids", nargs="+", type=lambda x: int(x, 16),
                    default=[0x202, 0x204, 0x018, 0x020, 0x030,
                             0x200, 0x201, 0x203, 0x205, 0x206, 0x207],
                    help="DID list to query per ECU (hex, space-separated)")
parser.add_argument("--timeout",    "-t", type=float, default=0.3,
                    help="ISO-TP response timeout per request (seconds)")
parser.add_argument("--services", nargs="+", type=lambda x: int(x, 16),
                    default=[0x22, 0x2E, 0x31],
                    help="UDS services to probe (hex). 0x2E/0x31 are read-only discovery only.")
parser.add_argument("--no-bring-up", action="store_true",
                    help="Skip bringing up the CAN interface (if already up)")
args = parser.parse_args()

INTERFACE    = args.interface
BITRATE      = args.bitrate
DURATION     = args.duration
LOGDIR       = Path(os.path.expanduser(args.logdir))
DID_LIST     = args.dids
TIMEOUT      = args.timeout
UDS_SERVICES = args.services
TIMESTAMP    = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")

LOGDIR.mkdir(parents=True, exist_ok=True)

# ──────────────────────────────────────────────
# Logging Setup  (file + console, stdlib)
# ──────────────────────────────────────────────
log_file = LOGDIR / f"ECUProbe_{TIMESTAMP}.log"

logging.basicConfig(
    filename=log_file,
    level=logging.DEBUG,
    format="[%(asctime)s] %(levelname)s: %(message)s",
    datefmt="%H:%M:%S",
)
console = logging.StreamHandler()
console.setLevel(logging.INFO)
console.setFormatter(logging.Formatter("[%(asctime)s] %(levelname)s: %(message)s", "%H:%M:%S"))
logging.getLogger("").addHandler(console)
log = logging.getLogger(__name__)

# ──────────────────────────────────────────────
# Known HKMC ECU Map
# ──────────────────────────────────────────────
KNOWN_ECUS: dict[int, str] = {
    0x7E0: "ECM",
    0x7E1: "TCM",
    0x7E2: "PCM",
    0x7E3: "HCM",           # Hybrid Control Module
    0x7E4: "FATC",          # Climate Control
    0x7E5: "BCM",           # Body Control Module
    0x7E6: "MDPS",          # Motor-Driven Power Steering
    0x7E7: "ESC",           # Electronic Stability Control
    0x7E8: "ICM",           # Instrument Cluster
    0x7ED: "HybridControl",
    0x7EF: "OBC",           # On-Board Charger
}

# UDS response address = request address + 0x08
def response_addr(req_addr: int) -> int:
    return req_addr + 0x08

# ──────────────────────────────────────────────
# CAN Interface Setup
# ──────────────────────────────────────────────
def bring_up_interface(iface: str, bitrate: int) -> None:
    """Bring up SocketCAN interface using subprocess (proper error handling)."""
    log.info(f"Bringing up {iface} at {bitrate} bps...")
    try:
        subprocess.run(["sudo", "ip", "link", "set", iface, "down"],
                       check=False, capture_output=True)
        subprocess.run(
            ["sudo", "ip", "link", "set", iface, "up", "type", "can", "bitrate", str(bitrate)],
            check=True, capture_output=True,
        )
        log.info(f"{iface} is up at {bitrate} bps")
    except subprocess.CalledProcessError as e:
        log.error(f"Failed to bring up {iface}: {e.stderr.decode().strip()}")
        sys.exit(1)

if not args.no_bring_up:
    bring_up_interface(INTERFACE, BITRATE)

# ──────────────────────────────────────────────
# Interface Sanity Check
# ──────────────────────────────────────────────
def check_interface(iface: str) -> None:
    """Confirm the CAN interface is UP before doing anything."""
    result = subprocess.run(["ip", "link", "show", iface],
                            capture_output=True, text=True)
    if "UP" not in result.stdout:
        log.error(
            f"Interface {iface} is not UP. "
            f"Run: sudo ip link set {iface} up type can bitrate 500000"
        )
        sys.exit(1)
    log.info(f"Interface {iface} confirmed UP.")

check_interface(INTERFACE)

# ──────────────────────────────────────────────
# DID Decoder  (extend with HKMC-specific logic)
# ──────────────────────────────────────────────
def decode_did(did: int, raw: bytes) -> dict:
    """
    Decode a DID response payload.
    Returns a dict with raw_hex and a decoded value.

    Extend the if/elif block below with HKMC-specific scaling formulas
    once you have the DID definitions from a service manual or reverse engineering.
    Example:
        0x202 -> battery SOC:  value = raw[0] * 0.5  (%)
        0x204 -> coolant temp: value = raw[0] - 40    (C)
    """
    if not raw:
        return {"raw_hex": "", "decoded": None}

    raw_hex = raw.hex()

    if did == 0x202:
        # Placeholder: Battery SOC  (1 byte, scale 0.5%)
        decoded = f"{raw[0] * 0.5:.1f} %" if len(raw) >= 1 else raw_hex
    elif did == 0x204:
        # Placeholder: Coolant temp (1 byte, offset -40 C)
        decoded = f"{raw[0] - 40} C" if len(raw) >= 1 else raw_hex
    else:
        # Generic: big-endian integer
        decoded = int.from_bytes(raw, "big")

    return {"raw_hex": raw_hex, "decoded": str(decoded)}

# ──────────────────────────────────────────────
# ISO-TP Request via python-can + can-isotp
# Accepts a shared bus — caller owns open/close.
# ──────────────────────────────────────────────
def isotp_request(bus: can.BusABC, req_addr: int, service: int,
                  did: int, timeout: float) -> bytes | None:
    """
    Send a single UDS request using ISO-TP with proper flow control.
    Accepts a shared can.Bus instance — do NOT open/close the bus here.
    Listens on the correct response address (req_addr + 0x08).

    NOTE: For 0x2E and 0x31 we only send a read/status-style subfunction
    to discover whether the ECU acknowledges the service — we never send
    write data or routine start commands.
    """
    resp_addr = response_addr(req_addr)

    # Build minimal payload per service
    if service == 0x22:
        # ReadDataByIdentifier — standard read
        payload = bytes([0x22, (did >> 8) & 0xFF, did & 0xFF])
    elif service == 0x2E:
        # WriteDataByIdentifier — send empty data, just probing for NRC/ACK
        # A real write would append data bytes; we intentionally omit them
        payload = bytes([0x2E, (did >> 8) & 0xFF, did & 0xFF])
    elif service == 0x31:
        # RoutineControl subFunction 0x03 = requestRoutineResults (read-only)
        payload = bytes([0x31, 0x03, (did >> 8) & 0xFF, did & 0xFF])
    else:
        payload = bytes([service, (did >> 8) & 0xFF, did & 0xFF])

    try:
        addr = isotp.Address(
            isotp.AddressingMode.Normal_11bits,
            txid=req_addr,
            rxid=resp_addr,
        )
        stack = isotp.CanStack(bus=bus, address=addr, params={'blocking_send': True})
        stack.start()
        try:
            MAX_RETRIES = 3
            BACKOFF = 0.05  # seconds

            send_ok = False

            for attempt in range(MAX_RETRIES):
                try:
                    stack.send(payload, send_timeout=timeout)
                    send_ok = True
                    break

                except can.CanOperationError as e:
                    # ENOBUFS (105) = kernel TX buffer full
                    if getattr(e, "errno", None) == 105:
                        log.debug(
                            f"TX buffer full (ECU 0x{req_addr:X}) "
                            f"attempt {attempt+1}/{MAX_RETRIES}"
                        )
                        time.sleep(BACKOFF * (attempt + 1))
                    else:
                        log.warning(f"CAN send error (ECU 0x{req_addr:X}): {e}")
                        return None

                except Exception as e:
                    log.warning(f"Unexpected send error (ECU 0x{req_addr:X}): {e}")
                    return None

            if not send_ok:
                log.debug(f"TX failed after retries (ECU 0x{req_addr:X})")
                return None

            # Only receive if send succeeded
            try:
                data = stack.recv(block=True, timeout=timeout)
                return data
            except Exception as e:
                log.debug(f"RX timeout/error (ECU 0x{req_addr:X}): {e}")
                return None
        finally:
            try:
                stack.stop()
            except Exception:
                pass

    except isotp.BlockingSendFailure:
        log.debug(f"ISO-TP send failed (ECU 0x{req_addr:X}, SVC 0x{service:X}, DID 0x{did:X})")
        return None
    except Exception as e:
        log.warning(f"ISO-TP error (ECU 0x{req_addr:X}, SVC 0x{service:X}, DID 0x{did:X}): {e}")
        return None

# ──────────────────────────────────────────────
# ECU Class
# ──────────────────────────────────────────────
class ECU:
    def __init__(self, address: int):
        self.address = address
        self.name    = KNOWN_ECUS.get(address, f"ECU_0x{address:X}")
        self.dids: dict[str, dict] = {}   # keyed by "0xSVC_0xDID" string

    def probe(self, bus: can.BusABC, services: list[int],
              did_list: list[int], timeout: float) -> None:
        """Probe all service/DID combinations for this ECU."""
        for svc in services:
            for did in did_list:
                raw = isotp_request(bus, self.address, svc, did, timeout)
                time.sleep(0.005)
                if raw:
                    decoded = decode_did(did, raw)
                    key = f"0x{svc:02X}_0x{did:04X}"
                    self.dids[key] = decoded
                    log.info(f"  {self.name} | SVC 0x{svc:02X} DID 0x{did:04X} -> "
                             f"{decoded['raw_hex']}  ({decoded['decoded']})")
                else:
                    log.debug(f"  {self.name} | SVC 0x{svc:02X} DID 0x{did:04X} -> no response")

    def to_csv(self, path: Path) -> None:
        with path.open("w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(["Service_DID", "Raw_Hex", "Decoded"])
            for key, val in self.dids.items():
                writer.writerow([key, val["raw_hex"], val["decoded"]])

    def to_dict(self) -> dict:
        return {"address": hex(self.address), "name": self.name, "dids": self.dids}

# ──────────────────────────────────────────────
# Live CAN Capture (Scapy AsyncSniffer -> .pcap)
# ──────────────────────────────────────────────
def live_capture(iface: str, duration: int, out_dir: Path, ts: str) -> None:
    log.info(f"Starting live CAN capture on {iface} for {duration}s...")

    pcap_file = out_dir / f"live_can_{ts}.pcap"
    writer = PcapWriter(str(pcap_file), append=False, sync=True)

    def handler(pkt):
        if pkt.haslayer(CAN):
            writer.write(pkt)

    sniffer = AsyncSniffer(
        iface=iface,
        store=False,
        prn=handler
    )

    sniffer.start()
    time.sleep(duration)
    sniffer.stop()

    writer.close()
    log.info(f"Live capture saved -> {pcap_file}")

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────
def main() -> None:
    log.info("=" * 60)
    log.info("ECUProbe v3 - HKMC Tucson PHEV 2024")
    log.info(f"Interface : {INTERFACE}  |  Bitrate: {BITRATE} bps")
    log.info(f"Services  : {[hex(s) for s in UDS_SERVICES]}")
    log.info(f"DIDs      : {[hex(d) for d in DID_LIST]}")
    log.info(f"Log dir   : {LOGDIR}")
    log.info("=" * 60)

    # ── Step 1: Live background capture runs in a thread
    capture_thread = threading.Thread(
        target=live_capture,
        args=(INTERFACE, DURATION, LOGDIR, TIMESTAMP),
        daemon=True,
    )
    capture_thread.start()

    # ── Step 2: Open one shared bus for the entire probe run
    found_ecus: list[ECU] = []

    try:
        bus = can.interface.Bus(channel=INTERFACE, interface="socketcan")
        log.info(f"Shared CAN bus opened on {INTERFACE}")
    except Exception as e:
        log.error(f"Failed to open CAN bus on {INTERFACE}: {e}")
        sys.exit(1)

    try:
        # ── Step 3: Discover and probe ECUs
        for addr in range(0x700, 0x7F8):  # cap at 0x7F7 — response addr is req+0x08, must stay < 0x7FF
            time.sleep(0.02)
            ecu_name = KNOWN_ECUS.get(addr, f"ECU_0x{addr:X}")
            log.debug(f"Pinging 0x{addr:X} ({ecu_name})...")

            # Discovery ping: single 0x22 request for first DID
            raw = isotp_request(bus, addr, 0x22, DID_LIST[0], TIMEOUT)
            if raw is None:
                continue

            log.info(f"Found ECU at 0x{addr:X} -> {ecu_name}")
            ecu = ECU(addr)

            try:
                ecu.probe(bus, UDS_SERVICES, DID_LIST, TIMEOUT)
            except Exception as e:
                log.warning(f"Probe error for {ecu_name}: {e}")

            found_ecus.append(ecu)

            # Write per-ECU CSV immediately after each ECU is probed
            csv_path = LOGDIR / f"{ecu.name}_{TIMESTAMP}.csv"
            ecu.to_csv(csv_path)
            log.info(f"CSV saved -> {csv_path}")

    finally:
        # Always close the bus cleanly, even if something goes wrong mid-scan
        bus.shutdown()
        log.info("CAN bus closed.")

    # ── Step 4: Master JSON summary
    summary = {"timestamp": TIMESTAMP, "interface": INTERFACE,
                "ecus": [e.to_dict() for e in found_ecus]}
    json_path = LOGDIR / f"ECUProbe_summary_{TIMESTAMP}.json"
    with json_path.open("w") as f:
        json.dump(summary, f, indent=2)
    log.info(f"JSON summary saved -> {json_path}")

    # ── Step 5: Wait for live capture to finish
    capture_thread.join()

    log.info("=" * 60)
    log.info(f"Done. {len(found_ecus)} ECU(s) found.")
    log.info(f"Logs in: {LOGDIR}")
    log.info("=" * 60)


if __name__ == "__main__":
    main()
