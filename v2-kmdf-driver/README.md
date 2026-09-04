# v2 — KMDF Filter Driver

**STATUS: In production.** This is the recommended driver for the Apple Magic Mouse 2024 (Bluetooth PID `0x0323`) on Windows. It has been in daily use for months and restores scroll, gestures, **and** battery percentage at the same time.

> Packaging note: the signed binary (`MagicMouseDriver.sys` + `MagicMouseDriver.cat`) ships as an asset on the tagged GitHub release. Full source is published alongside it. This README describes the real, shipping driver — not a roadmap.

## What it does

A Kernel Mode Driver Framework (KMDF) **lower filter** on the Bluetooth HID stack
(`HidClass → HidBth → [this filter] → BTHENUM`). Instead of patching any Apple
binary, it intercepts the device's SDP service-attribute query and substitutes a
corrected HID report descriptor, so Windows sees a device that scrolls *and*
reports battery.

- **Scroll + gestures:** the injected descriptor exposes a Generic Desktop Mouse
  TLC (Report ID `0x02`) with X/Y, vertical Wheel, and AC Pan (Consumer `0x0238`)
  horizontal scroll.
- **Battery:** exposed as a **Feature report, Report ID `0x47`** (Generic Device
  Controls page `0x06`, Usage `0x20`), value `0–100` = battery percent. Read from
  user space with `HidD_GetFeature`. No filter flipping, no workaround — it is
  live at the same time as scroll.

This is the key difference from the v1 binary patch, where scroll and battery were
mutually exclusive and required a manual registry flip. See the repo-root README's
"Choose Your Driver" section.

## Mechanism

- Installs as the sole `LowerFilters` entry (`MagicMouseDriver`) on the v3
  `BTHENUM` stack, class `HIDClass`.
- Intercepts `IOCTL_BTH_SDP_SERVICE_SEARCH_ATTRIBUTE` (`0x410210`) and injects the
  corrected HID report descriptor into SDP attribute `0x0206`.
- Device-scoped to Magic Mouse 2024 only
  (`BTHENUM\…_VID&0001004C_PID&0323`); other HID devices are untouched.

## Source layout

```
v2-kmdf-source/                 (in the private backup; published with the release)
├── Driver.c / Driver.h         # DriverEntry, device add, IOCTL filtering
├── HidDescriptor.c / .h        # The injected report descriptor (scroll + battery)
├── InputHandler.c / .h         # Input report handling
├── GestureEngine.c / .h        # Gesture mapping
├── MagicMouseDriver.inf        # Lower-filter install, HIDClass
├── MagicMouseDriver.vcxproj    # Visual Studio / WDK project
└── (signed MagicMouseDriver.sys + .cat ship as release assets)
```

## Install (signed binary)

```powershell
pnputil /add-driver MagicMouseDriver.inf /install
```

The shipped binary is self-signed; trusting the signing certificate and enabling
test-signing is covered in the repo-root install docs. Battery reads work as soon
as the device re-enumerates under the filter — no extra step.

## Signing

The shipping `.sys`/`.cat` are self-signed. The exact signed binary is shipped
as-is and is **not** rebuilt from source for release: the private key that signed
it is not reproducible from the build host, so a rebuild would not reproduce the
same signature. Build-from-source is supported for developers who want to audit or
modify and re-sign with their own certificate.

## License

MIT.
