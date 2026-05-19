# DMCA / Legal Notice

## Purpose

This project distributes a patched Windows kernel driver (`applewirelessmouse.sys`) that restores scroll functionality on Apple Magic Mouse v3 hardware on Windows 10/11.

## Good Faith Statement

The project exists to enable interoperability between hardware the user has lawfully purchased (Apple Magic Mouse v3) and a platform Apple does not officially support for this device (Windows 10/11). The patched binary restores functionality (Bluetooth HID scroll input) that Apple's stock driver fails to maintain on Windows after Bluetooth idle reconnect and DeviceSetupManager property synchronization.

## Copyright Acknowledgement

The v1.0.0 binary in `/v1-binary-patch/` is derived from Apple Inc.'s `applewirelessmouse.sys`. Apple Inc. retains all copyright in the original work. Modifications are limited, targeted changes intended solely to restore scroll behavior on Windows; no Apple branding, identification, or signing material is reused.

## DMCA §1201(f) — Interoperability Exemption

This work is published in reliance on the interoperability exemption at 17 U.S.C. §1201(f), which permits reverse engineering of a program for the sole purpose of achieving interoperability of an independently created program with other programs. The patch enables interoperability between Magic Mouse v3 hardware and the Windows HID stack.

## Removal Policy

If Apple Inc. submits a DMCA takedown notice requesting removal of the patched binary, the binary file(s) will be removed from this repository within 48 hours of receipt. The patch methodology, documentation, root-cause analysis, and installer scripts will remain published — they are independent works that do not embed Apple's copyrighted code.

## v2 Independence

The v2 KMDF driver in development (`/v2-kmdf-driver/`) is an independent implementation written from scratch in C against the public Windows Driver Kit. It is not derived from Apple's binary and is intended to fully replace the v1 binary patch.

## DMCA Contact

Send DMCA notices and legal correspondence to: **riley@revivebusiness.ca**
