# doolbdash

Personal vehicle cockpit build on top of [tucCANeer](https://github.com/doolb42/tuccaneer).

## What it is

A permanently installed Raspberry Pi 4B running Arch Linux in a 2024 Hyundai Tucson PHEV. It starts with the car, sets vehicle defaults via tucCANeer, and provides a physical control layer and supplementary MFD as an alternative to the factory touchscreen interface.

The factory infotainment system is untouched. This runs alongside it.

## What it's made of

- Physical toggle switches and a rotary encoder wired to GPIO — regen level, drive mode, EV force mode
- A 7" HDMI display running i3 showing vehicle state data pulled from the tucCANeer state bus
- Illuminated switches that reflect actual vehicle state, not just switch position

## What it is not

A replacement for the factory infotainment. Navigation, media, and climate controls remain exactly as stock.

## Dependencies

- [tucCANeer](https://github.com/doolb42/tuccaneer) — CAN bus framework
- Arch Linux ARM
- i3, Redis, gpiozero

## Status

Pre-development.
