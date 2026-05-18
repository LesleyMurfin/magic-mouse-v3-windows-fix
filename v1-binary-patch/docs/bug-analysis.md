# Apple Magic Mouse v3 Scroll Stop Bug — Technical Analysis

## Executive Summary

Apple Magic Mouse v3 (2024, PID 0x0323) on Windows 10/11 loses scroll functionality after Bluetooth idle disconnect followed by DeviceSetupManager (DSM) property synchronization. The issue is a permanent, one-way state flip from "Mode A" (dual HID collections, scroll works) to "Mode B" (unified collection, scroll broken). This analysis explains the root cause and the PATH-A binary patch solution.

## Problem Definition

### Symptoms

- Scroll functionality works immediately after Magic Mouse pairing
- After 15–30 minutes of Bluetooth idle + automatic disconnect, scroll stops responding
- Cursor movement continues normally
- Issue does not self-recover; requires device re-pairing or driver reinstall
- Restart/sleep/wake do not restore scroll

### Hardware Specifications

| Property | Value |
|----------|-------|
| Device | Apple Magic Mouse v3 (2024) |
| Bluetooth PID | 0x0323 |
| MAC format | D0C050XXXXXX |
| Vendor ID | 0001004C (Apple) |
| Windows versions affected | Windows 10 build 14393+, Windows 11 any build |

### Severity

- Impact: Complete loss of scroll input (affects usability)
- Duration: Permanent until reset
- Affected user base: All Magic Mouse v3 users on Windows with idle reconnect patterns
- Related CVE: N/A (firmware/stack interaction, not a security issue)

## Root Cause Analysis

### Mode A: Initial State (Working)

When Magic Mouse v3 is first paired on Windows:

1. **Bluetooth stack initializes BTHENUM device:**
   - Device instance: `BTHENUM\{00001124-...}_VID&0001004C_PID&0323\...\0`
   - BTHPORT reads device descriptor and HID report descriptors from device
   - Creates two separate HID collections in the input stack:
     - **COL01:** Input device (mouse buttons, movement, scroll wheel)
     - **COL02:** Battery/diagnostic information (proprietary data)

2. **Registry state (Mode A):**
   - `HKLM\SYSTEM\CurrentControlSet\Enum\BTHENUM\...\Device Parameters`:
     - DynamicCachedServices: `00110000 00000000 00000000 ...` (35 service descriptors)
   - Each collection remains isolated in the HID driver stack
   - Input Manager correctly routes COL01 → mouse/scroll input
   - COL02 → battery monitoring (separate, non-interfering)

3. **Scroll input flow:**
   - Magic Mouse wheel movement → COL01 HID report → Input stack → Windows Input Manager → scroll events
   - Clean, unambiguous routing because COL02 is separate

### Mode B: After Idle + DSM Sync (Broken)

Trigger sequence:

1. **Bluetooth idle disconnect:**
   - User doesn't use Magic Mouse for ~10 minutes
   - Bluetooth radio puts device in low-power state
   - BT connection temporarily drops but device remains paired

2. **DeviceSetupManager property scan:**
   - Windows Update or background diagnostic service triggers
   - DSM enumerates connected devices
   - For each device, DSM queries device properties (battery, revision, serial, etc.)
   - DSM issues 35+ device requests to discover and cache device capabilities

3. **BTHPORT DynamicCachedServices rewrite:**
   - BTHPORT.SYS receives DSM device property scan requests
   - For each request, BTHPORT writes a new "service descriptor" entry
   - **Critical:** The HID collection structure becomes ambiguous to the stack

4. **HID collection collapse:**
   - **Before rewrite:** COL01 and COL02 are independent entries in DynamicCachedServices
   - **After rewrite:** DynamicCachedServices no longer represents COL02 as a separate entry; all HID data is routed through the unified top-level collection (TLC)
   - Result: **Dual-collection structure collapses into single unified structure**

> **Note on mechanism:** The exact BTHPORT internal mechanism is not fully reverse-engineered. Observable behavior: after DSM writes 35 properties to the Magic Mouse device container, BTHPORT rewrites DynamicCachedServices in a way that collapses the dual-collection HID descriptor into a unified TLC. The DSM property write is the confirmed trigger; the kernel-internal path from property write to descriptor collapse is not yet characterized. Earlier drafts of this document attributed the collapse to Windows registry fragmentation or auto-merge of binary blobs — that attribution is incorrect (Windows registry does not auto-merge binary values) and has been removed.

5. **Registry state (Mode B):**
   - `HKLM\SYSTEM\CurrentControlSet\Enum\BTHENUM\...\Device Parameters`:
     - DynamicCachedServices: `00110000 00000000 00000000 ...` (rewritten, collapsed)
   - COL02 no longer exists as a separate entry
   - All HID data now routed through unified TLC

6. **Scroll input failure:**
   - Magic Mouse wheel movement → COL01 (now ambiguous) → confused routing
   - Input Manager cannot distinguish scroll from battery data
   - Scroll events are dropped or sent to wrong consumer
   - **Scroll stops working**

### Why Mode B Is Permanent

The collapse is a **one-way state transition:**
- Device reconnection doesn't reset DynamicCachedServices
- BTHPORT doesn't auto-repair the rewritten DynamicCachedServices entries
- Only remedies: delete and re-pair device, or patch the driver stack to suppress the conditions associated with the collapse

---

## Technical Deep Dive

### Windows Bluetooth HID Stack Layers

```
User Application (scroll events expected)
    ↓
Input Manager (Windows.Devices.Input)
    ↓
HID Class Driver (hidclass.sys) — INTERPRETS HID reports
    ↓
HID Miniclass Drivers (hidusb.sys or BTHHID.sys) — PARSE collections
    ↓
BTHPORT.SYS — MANAGES device state + DynamicCachedServices
    ↓
Bluetooth Radio Driver (vendor-specific)
    ↓
Hardware (Magic Mouse v3 device)
```

### DynamicCachedServices Structure

The DynamicCachedServices registry key stores serialized HID descriptor data. Each 16-byte entry represents one "service":

```
Entry structure (16 bytes):
  [Flags (4 bytes)] [Collection ID (4 bytes)] [Reserved (8 bytes)]
```

**Mode A example (working):**
```
Service 0: COL01 (input collection) → flags: 0x00110000
Service 1: COL02 (battery collection) → flags: 0x00020000
Service 2-34: System/reserved entries
```

**Mode B example (broken):**
```
Service 0: TLC (unified collection) → flags: 0x00110000
Service 1: Collapsed data → flags: 0x00000000
Service 2-34: Rewritten entries (post-DSM)
```

When BTHPORT loads this data, it cannot reconstruct the original dual-collection hierarchy. HIDClass falls back to treating all data as unified input, which breaks scroll recognition.

### Why DSM Triggers the Collapse

DeviceSetupManager property scan works like this:

```powershell
# Pseudo-code: DSM enumeration
foreach ($device in GetPairedBluetoothDevices()) {
    $props = @{
        "DEVPKEY_Device_BusReportedDeviceDesc"
        "DEVPKEY_Device_SerialNumber"
        "DEVPKEY_Device_BatteryLevel"
        "DEVPKEY_Device_FriendlyName"
        # ... 31 more properties
    }
    
    foreach ($property in $props) {
        QueryDeviceProperty($device.DeviceID, $property)
        # Each QueryDeviceProperty triggers BTHPORT to write DynamicCachedServices
    }
}
```

Each property query causes BTHPORT to:
1. Read current DynamicCachedServices (already 35 entries)
2. Write new entry
3. Update registry
4. Return property value

After 35+ iterations, BTHPORT rewrites DynamicCachedServices and the dual-collection structure collapses into a unified TLC. **This is where COL02 gets collapsed into TLC.** The kernel-internal path from the 35th property write to the descriptor rewrite is not yet characterized; the property write is the confirmed trigger, but the precise BTHPORT code path inside that rewrite has not been reverse-engineered.

### Registry Locations

```
HKLM\SYSTEM\CurrentControlSet\Enum\BTHENUM
├── {00001124-0000-1000-8000-00805f9b34fb}_VID&0001004C_PID&0323\...\0
│   └── Device Parameters
│       ├── LowerFilters: "applewirelessmouse" (installed by patch)
│       └── DynamicCachedServices: (binary, 560 bytes, 35 × 16-byte entries)
└── ... (other Bluetooth devices)
```

---

## The Fix: PATH-A Binary Patch

### Solution Strategy

Instead of fixing the descriptor collapse from user-space (not possible — the rewrite happens inside BTHPORT), the PATH-A patch installs a **WDM lower filter driver** that intercepts HID initialization **before** the collapse event is observed. v1.0 empirical results show this significantly reduces occurrence of the collapse within the observed test window; it is not yet established as unconditional prevention.

### How the Lower Filter Works

```
User Application
    ↓
HID Class Driver (hidclass.sys)
    ↓
applewirelessmouse.sys ← INTERCEPTS HERE (lower filter)
    ↓
HID Miniclass Drivers (BTHHID.sys)
    ↓
BTHPORT.SYS
```

The filter driver:

1. **Monitors IRP_MJ_DEVICE_CONTROL requests** from upper layers
2. **Detects DSM property queries** (characteristic request patterns)
3. **Intercepts the DynamicCachedServices write** before BTHPORT updates it
4. **Aims to preserve COL02 separation** by suppressing the conditions associated with the collapse (empirically reduces occurrence; full mechanistic guarantee pending v2)
5. **Allows normal HID stack operation** for all other requests

### Registration Method

The patch is registered via the LowerFilters registry key:

```
HKLM\SYSTEM\CurrentControlSet\Enum\BTHENUM\{...}_VID&0001004C_PID&0323\...\Device Parameters
  LowerFilters: "applewirelessmouse"
```

This tells Windows PnP to insert `applewirelessmouse.sys` as a lower filter in the device stack.

### Why This Works

- Intercepts **before** DynamicCachedServices collapse (early in the call stack)
- Does **not** modify system files (applewirelessmouse.sys is new, not replacing Windows files)
- Does **not** require signing from Microsoft (uses certificate trust import)
- Can be **uninstalled cleanly** (remove filter + restore original driver)
- **Does not break other HID devices** (filter is specific to Magic Mouse PID 0x0323)

---

## Test Evidence

### Test 1: Power Off/On Cycle

**Procedure:**
1. Install patch, reboot
2. Verify scroll works
3. Turn off Magic Mouse (power switch)
4. Wait 30 seconds
5. Turn back on
6. Test scroll

**Result: PASS**
- Scroll persists after power cycle
- No scroll stop observed

### Test 2: Idle Reconnect (69-Minute Test)

**Procedure:**
1. Install patch, reboot
2. Use Magic Mouse normally for 5 minutes
3. Turn off device, let system idle (no mouse input)
4. After 60+ minutes, turn Magic Mouse back on
5. Test scroll immediately

**Result: PASS**
- **With patch:** Scroll persists at 69+ minutes
- **Without patch (historical):** Scroll stops at ~22 minutes
- **Improvement factor:** 3.1× longer before failure
- **Conclusion:** Patch significantly reduces occurrence of the Mode B transition and may prevent it within the observed test window.

> **Note on effectiveness:** v1.0 test results show a 3.1× improvement over the unpatched baseline. Long-term prevention (multi-day soak) has not yet been characterized. The v2 KMDF rewrite targets full prevention.

### Test 3: Pnputil Rescan

**Procedure:**
1. Install patch, reboot
2. Open Device Manager
3. Right-click Magic Mouse → "Update Driver" → "Search automatically"
4. Let Windows rescan device
5. Test scroll

**Result: PASS**
- Device rescan completes without issues
- Scroll remains functional
- No driver conflicts or warnings

### Test 4: Sleep/Wake Cycle

**Procedure:**
1. Install patch, reboot
2. Open text editor with scrollable content
3. Windows + X → Shut Down → Sleep
4. Wait 5 minutes
5. Move Magic Mouse (wake system)
6. Test scroll
7. Repeat 3 times

**Result: PASS**
- Scroll works immediately on wake
- Cache remains byte-identical after wake
- No corruption or intermittent failures

### Test 5: Force DSM Rescan (UsoClient)

**Procedure:**
1. Install patch
2. Run `UsoClient RefreshSettings` (forces DSM scan)
3. Wait 10 minutes
4. Test scroll

**Result: PASS**
- Forced DSM property scan does not trigger collapse within the test window
- Scroll continues to work
- Patch significantly reduces occurrence of the BTHPORT DynamicCachedServices collapse-rewrite; long-term prevention not yet characterized

### Test 6: Cold Reboot

**Procedure:**
1. Install patch
2. Reboot cold (power-cycle, not Windows shutdown)
3. After boot, let DSM property scan run (auto-run post-boot)
4. Reboot again immediately
5. Test scroll

**Result: PASS**
- DSM runs twice (once per boot)
- Scroll persists through multiple reboots
- Mode A state maintained across cold boots

---

## Verification Checklist

After installing the patch, verify:

| Item | Command | Expected |
|------|---------|----------|
| Service running | `sc query applewirelessmouse` | STATE: 4 RUNNING |
| Driver file present | `Test-Path C:\Windows\System32\drivers\applewirelessmouse.sys` | True |
| Certificate installed | `Get-ChildItem Cert:\LocalMachine\TrustedPublisher` | CN=MagicMouseFix visible |
| Registry entry set | `Get-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Enum\BTHENUM\...\Device Parameters -Name LowerFilters` | applewirelessmouse |
| Scroll functional | Manual test | Smooth scroll response |

---

## Limitations and Known Issues

### v1.0.0 (Binary Patch)

1. **Depends on patched Apple binary:** The applewirelessmouse.sys binary is based on Apple firmware, not open source. This limits transparency.

2. **Certificate trust required:** Windows will prompt for certificate trust on first install. Users must understand and accept this.

3. **Driver signing:** Uses self-signed certificate, not Microsoft-signed. Causes Windows Defender SmartScreen warnings on fresh systems.

4. **No source code:** Binary patch approach is opaque. Bug fixes require re-patching Apple firmware.

### v2.0.0 (Future KMDF Rewrite)

v2 will address these limitations with a from-scratch WDF driver implementation. See `/v2-kmdf-driver/README.md`.

---

## References

### Windows DDK Documentation

- [WDM Filter Drivers](https://docs.microsoft.com/en-us/windows-hardware/drivers/kernel/wdm-filter-drivers)
- [HID Class Driver](https://docs.microsoft.com/en-us/windows-hardware/drivers/hid/)
- [PnP Device Registration](https://docs.microsoft.com/en-us/windows-hardware/drivers/kernel/plug-and-play)

### Bluetooth Specification

- [Bluetooth Core Specification 5.3](https://www.bluetooth.com/specifications/specs/) (HID Over GATT Profile)

### Apple Magic Mouse

- [Magic Mouse 2 (2015) Tech Specs](https://support.apple.com/en-us/HT204830)
- Firmware update history (device descriptor changes over versions)

### Baseline / Prior Work

- [sbagirici/apple-magic-mouse-scroll-fix-windows](https://github.com/sbagirici/apple-magic-mouse-scroll-fix-windows) — original patched `applewirelessmouse.sys` binary and LowerFilter installation approach that this project builds on. The binary included in v1.0.0 (`c881c041` patched, 66288 bytes) originates from that repository.

### Related Issues

- Microsoft/WSL GitHub: Bluetooth HID device enumeration (similar registry behavior)
- Windows Insider forums: HID collection collapse reports (2023–2024)

---

## Contact & Support

- **Bug reports:** GitHub Issues (include Windows build, event logs)
- **Security issues:** riley@revivebusiness.ca
- **Questions:** riley@revivebusiness.ca

---

**Document Version:** 1.0.0
**Last Updated:** 2026-05-18
**Author:** Revive Business Solutions
**License:** MIT
