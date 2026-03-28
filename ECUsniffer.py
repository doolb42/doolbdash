#!/usr/bin/env python3
"""
CAN ECU Probe Script for Hyundai Tucson PHEV 2024
Probes ECUs via ISO-TP/UDS, captures CAN traffic, and logs results.
"""

import argparse
import logging
import os
import pathlib
import sys
from datetime import datetime
from colorama import Fore, Style, init as colorama_init
from scapy.all import AsyncSniffer, Packet
from scapy.contrib.isotp import ISOTP

# -----------------------------
# Constants
# -----------------------------
TARGET_RANGE = range(0x700, 0x7FF + 1)  # Address range to probe
KNOWN_DIDS = [0x202]  # Example DIDs of interest (regen level)
DEFAULT_INTERFACE = "can0"
DEFAULT_DURATION = 60  # seconds
ECU_LOG_DIR = pathlib.Path.home() / "ecudump"
ECU_LOG_DIR.mkdir(exist_ok=True)

colorama_init(autoreset=True)  # Initialize colorama for colored terminal output


# -----------------------------
# Logging Setup
# -----------------------------
TIMESTAMP = datetime.now().strftime("%Y%m%d_%H%M%S")
LOG_FILE = ECU_LOG_DIR / f"ecudump_{TIMESTAMP}.log"

logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(message)s",
)
log = logging.getLogger()


def cprint(msg: str, color: str = Fore.WHITE):
    """Print colored message to terminal while logging"""
    print(color + msg + Style.RESET_ALL)
    log.info(msg)


# -----------------------------
# CAN Setup
# -----------------------------
def bring_up_can(interface: str = DEFAULT_INTERFACE, bitrate: int = 500_000):
    """Bring up CAN interface with specified bitrate"""
    try:
        os.system(f"sudo ip link set {interface} down")
        os.system(f"sudo ip link set {interface} up type can bitrate {bitrate}")
        cprint(f"[PASS] {interface} brought up at {bitrate} bps", Fore.GREEN)
    except Exception as e:
        cprint(f"[FAIL] Failed to bring up {interface}: {e}", Fore.RED)
        sys.exit(1)


# -----------------------------
# ECU Probing
# -----------------------------
def probe_ecus(interface: str, duration: int = DEFAULT_DURATION):
    """Scan all ECUs in TARGET_RANGE using ISO-TP/UDS"""
    responding_ecus = []
    captured_packets = []

    cprint(f"Starting ECU probe on {interface} for {duration} seconds...", Fore.CYAN)
    sniffer = AsyncSniffer(
        iface=interface,
        store=False,
        prn=lambda pkt: handle_packet(pkt, captured_packets),
    )
    sniffer.start()

    # Send ISO-TP diagnostic requests to each target ECU
    for addr in TARGET_RANGE:
        try:
            # Example UDS ReadDataByIdentifier (0x22) request to known DID
            for did in KNOWN_DIDS:
                iso_pkt = ISOTP(txid=0x7DF, rxid=addr)  # Placeholder addresses
                # Placeholder payload: 0x22 + DID high byte + DID low byte
                payload = bytes([0x22, (did >> 8) & 0xFF, did & 0xFF])
                iso_pkt.send(payload, timeout=0.1)
                cprint(f"Probing ECU 0x{addr:X} DID 0x{did:X}", Fore.YELLOW)
        except Exception as e:
            cprint(f"[WARN] Failed to send to ECU 0x{addr:X}: {e}", Fore.YELLOW)
            continue

    sniffer.stop()
    cprint("ECU probe complete.", Fore.CYAN)
    return responding_ecus, captured_packets


def handle_packet(pkt: Packet, captured_list: list):
    """Callback for AsyncSniffer to process each packet live"""
    captured_list.append(pkt)
    summary = pkt.summary() if hasattr(pkt, "summary") else str(pkt)
    log.info(summary)


# -----------------------------
# Summary
# -----------------------------
def log_summary(responding_ecus: list, packets: list):
    """Print and log summary table"""
    cprint("\n=== ECU Probe Summary ===", Fore.MAGENTA)
    cprint(f"Total packets captured: {len(packets)}", Fore.CYAN)

    if responding_ecus:
        cprint(f"ECUs responded: {', '.join([hex(e) for e in responding_ecus])}", Fore.GREEN)
    else:
        cprint("No ECUs responded.", Fore.YELLOW)

    # Save packets to a capture file
    capture_file = ECU_LOG_DIR / f"capture_{TIMESTAMP}.pcap"
    if packets:
        from scapy.utils import wrpcap

        wrpcap(str(capture_file), packets)
        cprint(f"Packet capture saved: {capture_file}", Fore.CYAN)
    else:
        cprint("No packets captured.", Fore.YELLOW)


# -----------------------------
# Argument Parsing
# -----------------------------
def parse_args():
    parser = argparse.ArgumentParser(description="Probe Hyundai Tucson PHEV ECUs via ISO-TP/UDS")
    parser.add_argument("-i", "--interface", default=DEFAULT_INTERFACE, help="CAN interface")
    parser.add_argument("-d", "--duration", type=int, default=DEFAULT_DURATION, help="Sniff duration in seconds")
    parser.add_argument("-l", "--log", default=None, help="Optional log file override")
    return parser.parse_args()


# -----------------------------
# Main
# -----------------------------
def main():
    args = parse_args()
    interface = args.interface
    duration = args.duration

    cprint("=====================================", Fore.MAGENTA)
    cprint(f"CAN ECU Probe Script - {TIMESTAMP}", Fore.CYAN)
    cprint(f"Interface: {interface} | Duration: {duration}s", Fore.CYAN)
    cprint("=====================================", Fore.MAGENTA)
    log.info(f"Starting ECU probe on {interface} for {duration}s")

    bring_up_can(interface)
    responding_ecus, packets = probe_ecus(interface, duration)
    log_summary(responding_ecus, packets)
    cprint(f"Logs saved to: {LOG_FILE}", Fore.CYAN)
    cprint("=== Probe Complete ===", Fore.MAGENTA)


if __name__ == "__main__":
    main()
