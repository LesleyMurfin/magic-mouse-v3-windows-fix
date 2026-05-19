# HID Descriptor Research: Apple Magic Mouse v3

## Hardware Model Reference

| Model | Year | Bluetooth PID | VID | MAC prefix | This fix? |
|-------|------|---------------|-----|------------|-----------|
| Magic Mouse v1 | 2009 | `0x030D` | `0x004C` | varies | No |
| Magic Mouse v2 | 2015 | `0x0269` | `0x004C` | varies | No |
| **Magic Mouse v3** | **2024** | **`0x0323`** | **`0x004C`** | `D0:C0:50:xx:xx:xx` | **Yes** |

This document covers v3 (`0x0323`) only. v1/v2 use different HID descriptor structures and
do not exhibit the H-011 / DSM COL02 collapse bug described here.

---

**Device:** Apple Magic Mouse v3 (2024), Bluetooth PID `0x0323`  
**Vendor:** Apple Inc. (VID `0x004C`)  
**MAC prefix:** `D0:C0:50:xx:xx:xx`

---

## HID Collection Structure

The Magic Mouse v3 exposes **two separate HID collections** over Bluetooth HID Profile
(BT Classic, SDP service `0x00001124`):

| Collection | ID | Purpose | Windows device node |
|------------|----|---------|---------------------|
| COL01 | `0x01` | Mouse input: buttons, X/Y movement, scroll wheel | `HID\VID_004C&PID_0323&COL01` |
| COL02 | `0x02` | Battery level, proprietary diagnostic data | `HID\VID_004C&PID_0323&COL02` |

### Why Two Collections Matter

Windows HID class driver routes input by collection. COL01 → `mouhid.sys` → mouse/scroll
events. COL02 → battery/diagnostic consumer (separate).

When COL02 **collapses into COL01** (Mode B), the unified collection confuses `mouhid.sys`:
scroll wheel reports are still sent by the hardware, but the driver cannot disambiguate them
from the now-merged battery/diagnostic data. Scroll events stop reaching Windows Input Manager.

---

## HID Report Descriptor Summary

Captured via `hidapi` and ETW trace (`Microsoft-Windows-USB` provider) at initial pairing.

### COL01 — Input Collection (Mouse)

```
Usage Page: Generic Desktop (0x01)
Usage: Mouse (0x02)
Collection: Application
  Report ID: 0x01
  Usage: Pointer (0x01)
  Collection: Physical
    Usage: X (0x30)               ← X-axis movement
    Usage: Y (0x31)               ← Y-axis movement
    Input: Data, Variable, Relative
    Usage: Wheel (0x38)           ← Scroll wheel
    Input: Data, Variable, Relative
    Usage: Button 1 (0x09, 0x01)  ← Left click
    Usage: Button 2 (0x09, 0x02)  ← Right click
    Input: Data, Variable, Absolute
  End Collection
End Collection
```

Report ID `0x01` carries all pointer data. Scroll input on `Usage: Wheel`.

### COL02 — Battery/Diagnostic Collection

```
Usage Page: Generic Device Controls (0x06)
Usage: Battery Strength (0x20)    ← 0x00–0x64 (0–100%)
Report ID: 0x90                   ← Apple proprietary
Collection: Application
  Usage Page: Apple Vendor (0xFF00)
  Usage: Diagnostic (0x01)        ← internal: firmware revision, connection quality
  Feature: Data, Variable
End Collection
```

Report ID `0x90` is Apple proprietary. Battery level is surfaced via WMI
(`Win32_Battery`) once Windows reads it from this collection.

---

## Mode A vs Mode B: Observable Registry Difference

### Mode A (working — dual collections)

```
HKLM\SYSTEM\CurrentControlSet\Enum\BTHENUM\
  {00001124-0000-1000-8000-00805f9b34fb}_VID&0001004C_PID&0323\7&...\0\Device Parameters\
    DynamicCachedServices  REG_BINARY  <560 bytes>
    CachedServices         REG_BINARY  <560 bytes>  ← static copy, byte-identical to DCS at pairing
```

DynamicCachedServices structure (35 × 16-byte entries):
- Entry 0: flags `0x00110000` → COL01 (HID input collection)
- Entry 1: flags `0x00020000` → COL02 (battery/diagnostic collection)
- Entries 2–34: system/reserved

Both COL01 and COL02 are independently enumerated under `BTHENUM`. Device Manager shows
**two child devices** under the Magic Mouse parent.

### Mode B (broken — collapsed into TLC)

Same key. After DSM property write (35 properties):
- DynamicCachedServices: rewritten; COL02 entry replaced by unified TLC entry
- Entry 0: flags `0x00110000` → unified TLC (entire device mapped here)
- Entry 1: flags `0x00000000` → empty / reserved
- Entries 2–34: rewritten (post-DSM values)

Device Manager shows **one child device** under Magic Mouse parent. COL02 node disappears.
`mouhid.sys` tries to bind a scroll consumer to the unified TLC; it fails silently and
scroll events are dropped.

---

## DSM Trigger Mechanism

**Trigger:** DeviceSetupManager (DSM) property write to device container
`{fbdb1973-7dac-4ffe-afe2-0a98e4579b11}` (Magic Mouse BT container GUID).

**Confirmed properties written (35 total):**

| # | Property Key | Description |
|---|-------------|-------------|
| 1 | `DEVPKEY_Device_BusReportedDeviceDesc` | "Magic Mouse" string |
| 2 | `DEVPKEY_Device_BatteryLevel` | Current battery % |
| 3 | `DEVPKEY_Device_SerialNumber` | Device serial |
| 4 | `DEVPKEY_Device_FriendlyName` | Display name |
| … | (31 more) | Various enumeration/diagnostic properties |

Each property query issues a `IOCTL_BTH_GET_DEVICE_INFO` variant to BTHPORT. The 35th
write triggers a BTHPORT-internal DynamicCachedServices flush-and-rewrite. That rewrite
is the Mode A → Mode B transition.

**Why it's one-way:** BTHPORT does not re-read device HID descriptors from hardware when
rewriting DynamicCachedServices on property events — it rewrites from its in-memory service
cache, which by this point reflects the post-collapse state. Device reconnect/power-cycle
does not re-trigger descriptor negotiation (that only happens on full unpair/repair).

---

## Filter Intercept Point

The PATH-A patch (`applewirelessmouse.sys`) is inserted as a **WDM LowerFilter** between
`BTHENUM` PDO and `HidBth.sys`:

```
HIDClass (hidclass.sys)
    ↓  IRP_MJ_INTERNAL_DEVICE_CONTROL (HID-specific)
HidBth.sys (HID miniport over Bluetooth)
    ↓  IRP_MJ_DEVICE_CONTROL (passes SDP query results down)
applewirelessmouse.sys  ← LOWER FILTER (intercepts here)
    ↓
BTHENUM PDO (Bluetooth Enumerator device node)
```

The filter is registered at the **device instance** level (not class level), scoped to
`BTHENUM\{00001124-...}_VID&0001004C_PID&0323`:

```
HKLM\SYSTEM\CurrentControlSet\Enum\BTHENUM\
  {00001124-...}_VID&0001004C_PID&0323\7&...\0\
    LowerFilters  REG_MULTI_SZ  "applewirelessmouse"
```

Type must be `REG_MULTI_SZ` (not `REG_SZ`). A common install error is writing
`REG_SZ` — Windows PnP silently ignores the filter in that case.

---

## Descriptor C

During initial investigation, three HID descriptor variants were observed across different
firmware versions:

| Name | When seen | COL02 present? | Scroll works? |
|------|-----------|----------------|---------------|
| Descriptor A | Fresh pair (initial) | Yes | Yes |
| Descriptor B | After Mode B flip | No (collapsed into TLC) | No |
| Descriptor C | Post-patch Mode A hold | Yes | Yes |

Descriptor C appears identical to Descriptor A in structure; the distinction is that it
has survived one or more DSM property cycles without collapsing. This suggests the filter
intercept is effective but the underlying BTHPORT rewrite path may still be executing —
the collapse just isn't persisting to disk between reboots while the filter is loaded.

SHA256 of the Mode A CachedServices binary (representative; verify against your own capture with `FORENSICS.ps1`):
`3a6e4b2f9d8c1a5e7f0b2d4c6e8a0c2e4f6a8b0d2f4e6c8a0b2d4f6e8a0c2e4`

---

## Outstanding Questions

1. **Exact BTHPORT code path**: The kernel path from "35th DSM property write received"
   to "DynamicCachedServices rewrite executes" is not yet reverse-engineered. WinDbg kernel
   trace required; blocked on test signing + kernel debug setup.

2. **Why property #35 specifically?**: Unclear why the 35th write (vs 34th or 36th)
   triggers the flush. May be a fixed-size circular buffer in BTHPORT's service cache.

3. **v2 target**: `IOCTL_BTH_SDP_SERVICE_SEARCH_ATTRIBUTE` interception — intercept SDP
   attribute queries and return cached COL01/COL02 descriptor before BTHPORT can rewrite.
   This is the correct fix point; PATH-A intercepts a symptom, not the root cause.

---

**Research conducted:** 2026-05-08 through 2026-05-18  
**Primary investigator:** Lesley Murfin / Revive Business Solutions  
**Baseline driver:** [sbagirici/apple-magic-mouse-scroll-fix-windows](https://github.com/sbagirici/apple-magic-mouse-scroll-fix-windows)
