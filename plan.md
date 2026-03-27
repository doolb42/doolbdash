# tucCANeer — Project Design Document

**Version**: 0.1  
**Author**: [Your Name]  
**Licence (framework)**: MIT  
**Status**: Pre-development

---

## Table of Contents

1. [Summary](#1-summary)
2. [Problem Statement](#2-problem-statement)
3. [Project Scope and Separation of Concerns](#3-project-scope-and-separation-of-concerns)
4. [Vehicle Interface — The OBD-II Port and CAN Bus](#4-vehicle-interface--the-obd-ii-port-and-can-bus)
5. [tucCANeer — The Open Source Framework](#5-tuccaneer--the-open-source-framework)
6. [doolbdash — The Personal Build](#6-doolbdash--the-personal-build)
7. [Hardware Specification](#7-hardware-specification)
8. [Power Considerations](#8-power-considerations)
9. [Software Architecture](#9-software-architecture)
10. [Development Roadmap](#10-development-roadmap)
11. [Repository Structure](#11-repository-structure)
12. [Risks and Mitigations](#12-risks-and-mitigations)

---

## 1. Summary

Two projects, deliberately separated.

**tucCANeer** is a lightweight, open source Python framework for reading and writing CAN bus messages on Hyundai/Kia/Motor Company (HKMC) PHEV and EV platforms via a Raspberry Pi and SocketCAN-compatible hardware. It exposes vehicle state as a simple event bus and provides a clean API for sending control messages back to the vehicle. It has no opinion on display or input method and is designed to run on minimal hardware — a Raspberry Pi Zero 2W with a PiCAN HAT is the full requirement for the core use case.

**doolbdash** is a personal build on top of tucCANeer, adding physical toggle switches and a supplementary MFD showing vehicle state. The vehicle's existing infotainment system is untouched. doolbdash is not intended for public release in its current form; it is one example of what tucCANeer makes possible.

The immediate motivation: the 2024 Hyundai Tucson PHEV resets its regenerative braking level on every ignition cycle with no manufacturer-provided way to change the default. tucCANeer fixes this by sending the correct CAN message at startup.

---

## 2. Problem Statement

### 2.1 Regenerative Braking Default Behaviour

The 2024 Hyundai Tucson PHEV resets its regenerative braking level to the manufacturer default on every ignition cycle. The driver adjusts this via steering column paddle shifters, but the setting does not persist between starts. There is no manufacturer-provided mechanism to change this behaviour.

On a PHEV in normal urban driving, regenerative braking handles the majority of deceleration. The friction brakes — rotors and pads — receive insufficient regular contact as a result. Surface rust on rotors is a safety concern: it reduces initial braking bite for the first one or two applications after an extended period of regen-only deceleration. Running a lower regen level by default resolves this, but having to set it manually on every start is not a workable solution.

### 2.2 Touchscreen Controls

The Tucson's infotainment system uses capacitance and resistance-based touchscreen controls. These require visual attention to operate, provide no tactile feedback, and are unreliable with gloves or in cold conditions. Certain vehicle settings that could reasonably be mapped to a physical control are only accessible through this interface.

tucCANeer exposes vehicle state and control over a clean API. doolbdash uses that to wire up physical switches for the specific functions that matter — alongside the existing infotainment system, not in place of it.

---

## 3. Project Scope and Separation of Concerns

The two projects share a hardware platform but are separated at the API boundary.

```
┌─────────────────────────────────────────────────────────────┐
│                        doolbdash                            │
│        (personal build — physical switches, MFD)            │
│                                                             │
│   GPIO Handler  ──►  tucCANeer API  ──►  Display Widgets    │
└──────────────────────────┬──────────────────────────────────┘
                           │ consumes
┌──────────────────────────▼──────────────────────────────────┐
│                       tucCANeer                             │
│          (open source framework — MIT licence)              │
│                                                             │
│   CAN Reader  ──►  State Bus (Redis)  ◄──  CAN Writer       │
│                         │                                   │
│                   OBD-II / CAN HAT                          │
└─────────────────────────────────────────────────────────────┘
```

**tucCANeer** is responsible for:
- All direct interaction with the vehicle CAN bus
- Decoding raw CAN frames into named signals using DBC files
- Publishing decoded vehicle state to a Redis pub/sub channel
- Accepting control commands via API and transmitting the corresponding CAN messages
- Sending a configurable set of CAN messages on ignition-on detection — this is the startup default mechanism

**tucCANeer is not responsible for:**
- How vehicle state is displayed
- How control commands are generated
- Any hardware above the CAN interface layer

**doolbdash** is responsible for:
- Reading physical toggle switch state via GPIO and translating that to tucCANeer API calls
- Rendering a supplementary MFD showing vehicle state data pulled from the tucCANeer state bus
- All personal hardware configuration and wiring

The vehicle's existing infotainment system and controls are entirely unaffected. tucCANeer talks to the car's ECUs over the CAN bus the same way a diagnostic tool would — it does not sit between the driver and the factory controls, and it does not touch any manufacturer software.

---

## 4. Vehicle Interface — The OBD-II Port and CAN Bus

### 4.1 What the OBD-II Port Provides

The OBD-II (On-Board Diagnostics II) port is located under the dashboard on the driver's side of the 2024 Hyundai Tucson. Mandated on all EU vehicles sold after 2004, it provides standardised physical access to the vehicle's internal CAN bus networks. Pins 6 (CAN-High) and 14 (CAN-Low) connect to the primary CAN bus, which carries traffic between the Hybrid Control Module (HCM), Body Control Module (BCM), instrument cluster, and other ECUs — including the module responsible for processing paddle inputs and setting regenerative braking level.

### 4.2 CAN Bus Fundamentals

The Controller Area Network (CAN) protocol lets multiple ECUs communicate over a shared two-wire differential bus without a central host. Each message has an 11-bit or 29-bit identifier and up to 8 bytes of payload. All ECUs broadcast continuously; any node on the bus can read any message.

The two operations relevant to this project are:

- **Listening**: Capturing frames on the bus and decoding them against a DBC file to extract named signals — current regen level, drive mode, and so on.
- **Transmitting**: Constructing a valid CAN frame and injecting it to simulate a control input — the equivalent of pressing a paddle shifter.

### 4.3 DBC Files

A DBC (Database CAN) file describes which CAN message IDs carry which signals and how to decode raw bytes into meaningful values. The open source **opendbc** repository (comma.ai) already has DBC files for a wide range of HKMC vehicles with the relevant signals decoded — regen level, drive mode, battery SoC, EV/HEV operating mode.

The primary reference file is `hyundai_kia_generic_generated.dbc`. A regen level signal has been identified in related HKMC platforms at CAN ID `0x202` as a 4-bit field in the Vehicle Control Unit message. This must be verified against the Tucson PHEV specifically via live bus capture before any write operations are attempted.

### 4.4 Verification Process

Before writing any CAN messages to the vehicle, the following steps must be completed:

1. Connect a SocketCAN-compatible adapter to the OBD-II port
2. Use `candump` to capture a full bus recording while manually pressing the regen paddles
3. Identify the message ID and byte offset corresponding to regen level change by diffing recordings before and after paddle input
4. Cross-reference against the opendbc DBC file and the **sunnypilot/opendbc** fork, which contains explicit HKMC PHEV/HEV platform support
5. Use **Cabana** (comma.ai's CAN analysis tool) to visually verify signal behaviour over time
6. Confirm the identified message is accepted by the HCM when injected — beginning with a single carefully constructed test frame in a stationary vehicle

### 4.5 Gateway Considerations

Some vehicles implement a CAN gateway between the OBD-II port and internal bus networks, restricting which messages are visible or injectable from the diagnostic port. If this is the case on the Tucson PHEV, direct OBD-II injection may be insufficient and the CAN bus would need to be tapped closer to the source — for example, at the steering column wiring loom. The comma.ai and sunnypilot communities should be consulted on this point before hardware is ordered, as they will have definitive knowledge of the Tucson PHEV's bus topology.

---

## 5. tucCANeer — The Open Source Framework

### 5.1 Design Goals

- Runs on a Raspberry Pi Zero 2W with a PiCAN HAT — no more hardware required for the core use case
- No GPIO, display, or input handling in the framework itself
- All signal definitions live in DBC files derived from opendbc, not hardcoded in application logic
- Any consumer can read vehicle state and send commands in fewer than ten lines of Python
- A TOML configuration file defines which CAN messages to send on ignition-on detection and with what values — this is how the regen level default is set

### 5.2 Core Components

**`can_reader.py`**  
Subscribes to the SocketCAN interface, decodes incoming frames against the loaded DBC file using `python-can` and `cantools`, and publishes decoded signal values to Redis. Runs as a systemd service.

**`can_writer.py`**  
Subscribes to a Redis channel for outbound command requests, encodes commands into valid CAN frames using the DBC, and transmits them via SocketCAN. Validates commands against known signal ranges before transmission. Runs as a systemd service.

**`startup_sequence.py`**  
Monitors the CAN bus for ignition-on activity, detectable as the onset of regular bus traffic. On detection, reads the startup configuration file and dispatches configured commands to `can_writer.py` via Redis. This is what sets the regen level default on every start.

**`api.py`**  
A thin Python module providing `get_signal(name)` and `send_command(name, value)` against the Redis state bus. This is the public integration surface — doolbdash, a CLI script, or any other consumer talks to tucCANeer through this.

### 5.3 Supported Signals (Initial Target)

Minimum viable scope for tucCANeer v0.1, subject to Phase 1 verification:

- Regenerative braking level (read/write)
- Drive mode — Eco / Normal / Sport (read/write)
- EV/HEV operating mode (read)
- Battery state of charge (read)
- Vehicle speed (read)
- Ignition state (read, derived from bus activity)

### 5.4 Compatibility

tucCANeer targets the 2024 Hyundai Tucson PHEV as its primary development platform. Given the shared architecture across the HKMC PHEV/EV lineup, compatibility with the following platforms is expected but unverified until tested:

- Hyundai Ioniq PHEV / HEV
- Hyundai Kona EV / PHEV
- Kia Niro PHEV / HEV / EV
- Kia Sportage PHEV

---

## 6. doolbdash — The Personal Build

### 6.1 Overview

doolbdash adds a physical control layer and supplementary display on top of tucCANeer. The Pi lives permanently in the car — wired in, powered from the auxiliary outlet, and running from ignition-on without any intervention. The MFD and toggle switches are the primary interaction mechanism; a keyboard and mouse can be connected directly to the Pi when needed for maintenance or configuration, but normal daily use requires neither. The factory infotainment system is left completely alone — this is not a replacement for it, and the two systems share no dependencies.

### 6.2 Physical Controls

Toggle switches are mounted in a custom panel fabricated to suit the vehicle interior. Specific switch assignments are subject to revision during development.

| Control | Type | Function |
|---|---|---|
| Regen level | Rotary encoder | Set regen level 0–3 |
| Drive mode | 3-position toggle | Eco / Normal / Sport |
| EV force | Illuminated toggle | Force EV-only mode on/off |
| Display page | Momentary push | Cycle MFD workspace |

Illuminated toggles reflect current vehicle state read back from tucCANeer — not just switch position — so the indicator is accurate regardless of how the state was set.

### 6.3 Supplementary Display

A 7-inch 1024×600 HDMI display is mounted in the vehicle showing vehicle state data. It runs Arch Linux with Xorg and i3, launched via `xinit` with no display manager or desktop environment overhead.

Each i3 workspace is an MFD page, cycled by the dedicated momentary switch via `i3-msg`. Display widgets are lightweight Python scripts subscribing to Redis and updating in real time as vehicle state changes.

Planned pages for initial release:

- **Page 1 — Powertrain**: EV/HEV mode, battery SoC, regen level, drive mode
- **Page 2 — Journey**: Vehicle speed, estimated EV range, current power draw
- **Page 3 — System**: Pi CPU/memory, CAN bus health, tucCANeer service status

### 6.4 Relationship to Existing Vehicle Systems

doolbdash talks to the CAN bus directly, the same way a diagnostic tool does. The Tucson's navigation, media, climate controls, and everything else continue to operate exactly as from the factory. There is no dependency on or interaction with the manufacturer's infotainment software in either direction.

---

## 7. Hardware Specification

### 7.1 tucCANeer Minimum

| Component | Specification | Notes |
|---|---|---|
| Single-board computer | Raspberry Pi Zero 2W | Sufficient for CAN read/write and Redis at idle |
| CAN interface | PiCAN HAT (SK Pang) | Attaches directly to GPIO header; no USB required |
| OBD-II connector | OBD-II to DB9 cable | Standard; mates with PiCAN HAT |
| Power | Drawn from OBD-II port | Typically 500mA available; verify against Pi Zero draw |
| Storage | 16GB microSD | Class 10 minimum |

### 7.2 doolbdash Additional Components

| Component | Specification | Notes |
|---|---|---|
| Single-board computer | Raspberry Pi 4B (4GB) or Pi 5 | Required for display rendering |
| Display | 7" 1024×600 HDMI (Waveshare or equivalent) | Touch not required |
| Toggle switches | MTS series or equivalent | Sourced to suit panel aesthetic |
| Rotary encoder | EC11 or equivalent | For regen level selection |
| Custom panel | Fabricated to suit install location | Material and mounting TBD |
| Supplementary power | See Section 8 | OBD-II port insufficient for Pi 4B/5 and display |

---

## 8. Power Considerations

### 8.1 OBD-II Port Power Budget

The OBD-II port provides unswitched 12V on pin 16 with a typical current budget of 500mA–1A depending on the vehicle's fusing. A Raspberry Pi Zero 2W under moderate load draws approximately 300–400mA at 5V, making OBD-II power viable for the minimal tucCANeer deployment after regulation via a 12V-to-5V converter.

A Raspberry Pi 4B draws up to 1.2A under load; a 7-inch display adds a further 400–600mA. This combined draw exceeds what the OBD-II port can reliably supply and risks tripping the vehicle's diagnostic port fuse.

### 8.2 Auxiliary Power Outlet

The doolbdash full build must be powered from the vehicle's **12V auxiliary power outlet** (colloquially, the cigarette lighter socket) via a USB-C PD car charger rated at a minimum of 45W. A GaN-type charger is preferred for thermal efficiency in an enclosed under-dash environment.

The 100W GaN adaptor already installed in the vehicle's 12V auxiliary power outlet has sufficient headroom for this; a dual-output adaptor or second outlet is only needed if other devices are drawing from the same socket.

### 8.3 Power Sequencing

The Pi must be running before ignition-on CAN traffic appears, so the startup sequence fires reliably. The 12V auxiliary power outlet is live in accessory and run modes, so this is automatic. Boot time for a Pi Zero 2W on a minimal Arch install is approximately 15–20 seconds; for a Pi 4B approximately 10–15 seconds with an optimised initrd — both comfortably within the window between entering the vehicle and pulling away.

---

## 9. Software Architecture

### 9.1 Technology Stack

| Layer | Technology |
|---|---|
| OS | Arch Linux ARM |
| CAN interface | SocketCAN (kernel module) |
| CAN library | `python-can`, `cantools` |
| DBC source | opendbc / sunnypilot fork |
| State bus | Redis (pub/sub) |
| Startup management | systemd |
| Display (doolbdash) | Xorg + i3 |
| Widget runtime (doolbdash) | Python / GTK or plain X11 |
| GPIO (doolbdash) | `gpiozero` |

### 9.2 Service Dependency Graph

```
systemd
  └── socketcan.service               # brings up the CAN interface (slcan0 or can0)
        ├── tuccaneer-reader.service  # CAN → Redis
        ├── tuccaneer-writer.service  # Redis → CAN
        └── tuccaneer-startup.service # fires startup sequence on ignition-on
              └── (doolbdash only)
                    ├── doolbdash-gpio.service    # GPIO → tucCANeer API
                    └── doolbdash-display.service # i3 + widgets
```

### 9.3 Data Flow

**Read path (vehicle → display):**
```
Vehicle ECU
  → CAN frame on bus
  → SocketCAN kernel buffer
  → can_reader.py (decode via DBC)
  → Redis PUBLISH vehicle:signals
  → Widget scripts (SUBSCRIBE)
  → MFD display update
```

**Write path (switch → vehicle):**
```
Physical toggle switch
  → GPIO interrupt (gpiozero)
  → gpio_handler.py
  → tucCANeer api.py → send_command()
  → Redis PUBLISH vehicle:commands
  → can_writer.py (encode via DBC)
  → SocketCAN transmit
  → Vehicle ECU receives frame
```

---

## 10. Development Roadmap

### Phase 1 — CAN Verification (No writes)
- Set up Pi Zero 2W with PiCAN HAT and Arch Linux
- Connect to OBD-II port and bring up SocketCAN interface
- Run `candump` to capture live bus traffic
- Identify ignition-on signature
- Capture and verify regen paddle message IDs against opendbc DBC
- Cross-reference with sunnypilot fork and comma.ai community
- Confirm or rule out OBD-II gateway restriction
- Document all verified message IDs with byte maps

### Phase 2 — tucCANeer Core
- Implement `can_reader.py` with Redis pub/sub output
- Implement `can_writer.py` with DBC encoding and range validation
- Implement `startup_sequence.py` with TOML-based configuration
- Implement `api.py` integration surface
- Write systemd service files
- Test regen level default setting end-to-end
- Write README and hardware setup documentation
- Publish tucCANeer to GitHub under MIT licence

### Phase 3 — doolbdash Hardware
- Fabricate and wire toggle switch panel
- Mount display
- Wire GPIO to Pi 4B
- Validate `gpiozero` handler for all switch inputs

### Phase 4 — doolbdash Software
- Configure Arch Linux with i3 on Pi 4B
- Implement display widgets for all planned MFD pages
- Implement GPIO handler with tucCANeer API integration
- Configure illuminated switch state feedback loop
- Test full system end-to-end

### Phase 5 — Hardening
- Harden boot sequence and service recovery behaviour
- Stress-test over extended drives
- Finalise panel mounting and cable management

---

## 11. Repository Structure

### tucCANeer (public)

```
tuccaneer/
├── tuccaneer/
│   ├── __init__.py
│   ├── api.py
│   ├── can_reader.py
│   ├── can_writer.py
│   └── startup_sequence.py
├── dbc/
│   └── hyundai_tucson_phev_2024.dbc  # derived from opendbc, verified
├── config/
│   └── startup.toml.example          # example startup configuration
├── systemd/
│   ├── socketcan.service
│   ├── tuccaneer-reader.service
│   ├── tuccaneer-writer.service
│   └── tuccaneer-startup.service
├── docs/
│   ├── hardware-setup.md
│   ├── can-verification.md
│   └── api-reference.md
├── tests/
├── LICENSE
└── README.md
```

### doolbdash (personal)

```
doolbdash/
├── gpio/
│   └── handler.py
├── display/
│   ├── i3/
│   │   └── config
│   ├── widgets/
│   │   ├── powertrain.py
│   │   ├── journey.py
│   │   └── system.py
│   └── polybar/
│       └── config
├── systemd/
│   ├── doolbdash-gpio.service
│   └── doolbdash-display.service
├── hardware/
│   └── wiring.md
└── README.md
```

---

## 12. Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| OBD-II gateway blocks regen messages | Medium | High | Verify in Phase 1; fall back to wiring loom tap if required |
| Regen message ID differs from opendbc reference | Medium | Medium | Live capture verification before any writes |
| Injected CAN message triggers unintended ECU behaviour | Low | High | Validate against community data; test in stationary vehicle first |
| OBD-II port insufficient to power Pi Zero | Low | Low | Measure actual draw; fall back to auxiliary power outlet |
| Pi boot time exceeds ignition-to-drive window | Low | Medium | Optimise initrd; add watchdog to retry startup sequence |
| SocketCAN driver instability on Arch ARM | Low | Medium | Test against Pi OS baseline first if issues arise |

---

*Living document — will be updated as Phase 1 verification produces definitive results for the 2024 Hyundai Tucson PHEV CAN bus topology.*
