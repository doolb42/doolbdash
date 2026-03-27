# Building a CAN Interface for the Raspberry Pi 4B with the MCP2515

This document covers everything needed to wire an MCP2515 CAN module to a Raspberry Pi 4B and bring it up as a working SocketCAN interface (`can0`) on Arch Linux ARM.

---

## What You Need

- Raspberry Pi 4B
- MCP2515 CAN module (pre-built breakout board with MCP2515 + TJA1050 on board)
- 7 lengths of solid core wire (or jumper leads for prototyping)
- Multimeter
- Soldering iron (if wiring directly into GPIO holes)

---

## How It Works

The MCP2515 is a CAN controller that speaks SPI. The TJA1050 is a CAN transceiver that converts the controller's logic-level TX/RX signals into the differential CANH/CANL signals the bus uses. On the cheap breakout modules, both chips are already on the board with the necessary passives. You are connecting two pre-built boards with six wires.

The Linux `mcp251x` kernel driver handles everything above the hardware layer. Once the wiring is correct and the device tree overlay is enabled, the Pi presents a standard SocketCAN interface identical to what any CAN HAT would give you.

---

## Wiring

### SPI Connection (Pi 4B GPIO → MCP2515 Module)

The Pi 4B has two hardware SPI buses. Use SPI0 (the default, and what the overlay expects).

| MCP2515 Pin | Pi 4B GPIO | Pi 4B Physical Pin |
|---|---|---|
| VCC | 5V | Pin 2 |
| GND | GND | Pin 6 |
| CS | GPIO 8 (SPI0 CE0) | Pin 24 |
| SCK | GPIO 11 (SPI0 SCLK) | Pin 23 |
| SI (MOSI) | GPIO 10 (SPI0 MOSI) | Pin 19 |
| SO (MISO) | GPIO 9 (SPI0 MISO) | Pin 21 |
| INT | GPIO 25 | Pin 22 |

The INT (interrupt) pin is technically optional but strongly recommended — without it the driver polls rather than using interrupts, which is inefficient and introduces latency.

### CAN Bus Connection (MCP2515 Module → OBD-II)

| MCP2515 Pin | OBD-II Pin |
|---|---|
| CANH | Pin 6 |
| CANL | Pin 14 |

If using a DB9 connector with a standard OBD-II to DB9 cable:

| MCP2515 Pin | DB9 Pin |
|---|---|
| CANH | Pin 7 |
| CANL | Pin 2 |

---

## MCP2515 Module Oscillator

**This is the most common gotcha.** The MCP2515 requires an external oscillator crystal, and most cheap modules come with either an **8MHz** or **16MHz** crystal. You must know which one yours has — the device tree overlay needs to match exactly or the CAN interface will come up but run at the wrong baud rate and fail to communicate.

Check the crystal on your module. It will have a number printed on it:
- `8.000` or `8M` = 8MHz
- `16.000` or `16M` = 16MHz

Note this down — you need it in the next section.

---

## Software Setup (Arch Linux ARM)

### 1. Enable SPI

Check SPI is enabled:

```bash
lsmod | grep spi
```

If `spi_bcm2835` is not listed, enable it by adding to `/boot/config.txt`:

```
dtparam=spi=on
```

### 2. Enable the MCP2515 Device Tree Overlay

Add the following to `/boot/config.txt`, substituting your oscillator frequency:

**For 8MHz crystal:**
```
dtoverlay=mcp2515-can0,oscillator=8000000,interrupt=25
```

**For 16MHz crystal:**
```
dtoverlay=mcp2515-can0,oscillator=16000000,interrupt=25
```

The `interrupt=25` corresponds to GPIO 25 wired to the INT pin above. If you chose not to wire INT, omit that parameter — but wire it.

### 3. Reboot

```bash
sudo reboot
```

### 4. Verify the Interface Exists

After reboot:

```bash
ip link show can0
```

You should see `can0` listed. If it is not there, check `dmesg` for errors:

```bash
dmesg | grep mcp
```

Common errors at this stage are oscillator mismatch or a wiring fault on the SPI lines.

### 5. Bring Up the Interface

Bring `can0` up at your target bitrate. Vehicle CAN buses typically run at 500kbps:

```bash
sudo ip link set can0 up type can bitrate 500000
```

Verify it is up:

```bash
ip link show can0
```

You should see `UP` in the flags.

### 6. Test — Listen for Traffic

With the OBD-II cable connected to the vehicle and ignition on:

```bash
candump can0
```

You should immediately see a stream of CAN frames. If you see nothing, double-check CANH/CANL polarity — swapping them is harmless but produces no traffic.

---

## Making It Persistent with systemd

You do not want to manually bring up `can0` on every boot. Create a systemd-networkd configuration instead.

Create `/etc/systemd/network/can0.network`:

```ini
[Match]
Name=can0

[CAN]
BitRate=500000
```

Enable and start systemd-networkd if not already running:

```bash
sudo systemctl enable systemd-networkd
sudo systemctl start systemd-networkd
```

`can0` will now come up automatically at boot at 500kbps.

---

## Verifying the Full Stack

With ignition on and `can0` up, install `can-utils` if not already present:

```bash
sudo pacman -S can-utils
```

Then:

```bash
# Dump all frames
candump can0

# Log to file for analysis
candump -l can0

# Send a test frame (use with caution on a live bus)
cansend can0 123#DEADBEEF
```

At this point you have a fully functional CAN interface, equivalent to any commercial CAN HAT, for the cost of a £2 module and some wire.

---

## Troubleshooting

| Symptom | Likely Cause |
|---|---|
| `can0` does not appear after reboot | dtoverlay not applied, or SPI not enabled |
| `can0` appears but `candump` shows nothing | CANH/CANL swapped, or wrong bitrate |
| `dmesg` shows `mcp251x spi0.0: MCP2515 didn't enter sleep mode` | Oscillator frequency mismatch in dtoverlay |
| Intermittent frames or corruption | Poor SPI wiring — keep SPI leads short and away from power lines |
| `candump` works but sent frames are ignored | Bus bitrate mismatch — verify vehicle bus runs at 500kbps |

---

## Next Step

Once `candump can0` is producing a live stream of vehicle CAN traffic, proceed to the tucCANeer CAN verification guide (`docs/can-verification.md`) to begin identifying the specific message IDs needed.
