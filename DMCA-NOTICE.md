# DMCA / Legal Notice

## Purpose

This project enables scroll (and, with Magic Tray, battery reporting) on Apple Magic Mouse hardware
on Windows 10/11, for mice the user has lawfully purchased, on a platform Apple does not support
for these devices.

## What Apple material this repository contains

**`v1-binary-patch/apple-driver/applewirelessmouse.sys` — Apple's driver, redistributed verbatim.**

- Apple Inc. retains all copyright. The file is **unmodified**: SHA256
  `08F33D7E3ECE2C73950A9706F1C4C9057894EAEAF1C4FB355F261F3C2333378F`, 78,424 bytes, version
  6.1.7700.0, and its Apple signature plus Microsoft WHQL countersignature verify intact
  (`CN=Microsoft Windows Hardware Compatibility Publisher`).
- It is **not** patched, reverse engineered, or re-signed. It is included so users do not have to
  extract it from Apple's Boot Camp Support Software by hand.
- It is redistributed under Apple's own software licence terms, which the user accepts by using it.
  This repository claims no licence over it; the MIT licence covers only this project's own
  installer scripts, documentation and driver source.
- **Apple's driver alone does not fix anything.** The independently written work here is the
  *registration*: creating the kernel service and binding the driver as a lower filter on the
  device, which Windows does not do on a non-Mac PC. That logic is this project's, not Apple's.

A previous release also distributed a **byte-patched** derivative of the same driver (SHA256
`370A5555…`, re-signed with this project's certificate). That variant is **no longer shipped**. It
is documented in `v1-binary-patch/README.md` only so that an existing installation can be
identified, and the installer labels it as legacy.

## Good Faith Statement

The project exists to enable interoperability between hardware the user lawfully owns and a
platform Apple does not officially support for that hardware. Apple ships no Windows driver for the
Magic Mouse v3 Bluetooth PID (`0x0323`), and its Boot Camp installer refuses to run on non-Apple
hardware, leaving owners of every Magic Mouse model without working scroll on Windows.

## DMCA §1201(f) — Interoperability Exemption

To the extent that analysis of Apple's driver and of the Windows HID stack was required to
establish how to bind the filter and how the multitouch reports are framed, that work is published
in reliance on the interoperability exemption at 17 U.S.C. §1201(f), which permits reverse
engineering for the sole purpose of achieving interoperability of an independently created program
with other programs.

## Removal Policy

If Apple Inc. submits a DMCA takedown notice requesting removal of `applewirelessmouse.sys`, the
binary will be removed from this repository **within 48 hours** of receipt, and the installer will
fall back to acquiring the driver from the user's own machine (`-FromDriverStore`) or a path the
user supplies (`-DriverPath`). The installer scripts, documentation, root-cause analysis and the
KMDF driver source will remain published — they are independent works that embed no Apple code.

## KMDF driver independence

The KMDF driver is an independent implementation written from scratch in C against the public
Windows Driver Kit. It is **not** derived from Apple's binary, contains no Apple code, and does not
depend on Apple's driver being installed. It is a separate driver, not a replacement for the
Apple-driver route; both are maintained. Its source and documentation are published in
`v2-kmdf-driver/`, under this project's MIT licence: the C sources (`Driver.c`, `GestureEngine.c`,
`AclTranslate.c`, `HidDescriptor.c`, `InputHandler.c` and their headers), the INF, the host-side
test gates, and the build and signing scripts. No compiled or signed binary is distributed.

## DMCA Contact

Send DMCA notices and legal correspondence to: **riley@revivebusiness.ca**
