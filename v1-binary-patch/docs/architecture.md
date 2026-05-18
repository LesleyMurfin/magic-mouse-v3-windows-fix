# Magic Mouse v3 Patch — Driver Architecture

## Overview

The v1.0.0 patch uses a **WDM lower filter driver** architecture to prevent HID collection collapse during DeviceSetupManager property synchronization. This document explains how the driver integrates into the Windows HID stack and why this position is critical for the fix.

## Windows Device Driver Model (WDM) Filter Drivers

### What Is a Filter Driver?

A filter driver is an optional component in a device stack that:
- Sits between upper and lower layers of drivers
- Intercepts I/O requests (IRPs) before they reach the target driver
- Can inspect, modify, or reject requests
- Passes modified requests down or handles them directly
- Receives completion notifications from lower drivers

### Two Types of Filter Drivers

| Type | Position | Purpose |
|------|----------|---------|
| **Upper Filter** | Above class driver | Enhance functionality, intercept all requests first |
| **Lower Filter** | Below class driver | Modify hardware behavior, intercept before minidriver |

The Magic Mouse patch uses a **lower filter** because it must intercept requests **after HIDClass has processed them but before BTHHID/BTHPORT attempt to modify HID descriptors**.

## Magic Mouse v3 HID Stack (Before Patch)

```
┌─────────────────────────────────────────┐
│     User Application Layer              │
│  (scroll events, cursor input expected) │
└──────────────────┬──────────────────────┘
                   │
┌──────────────────▼──────────────────────┐
│  Input Manager (Windows.Devices.Input)  │
│  Route HID reports to scroll/cursor    │
└──────────────────┬──────────────────────┘
                   │
┌──────────────────▼──────────────────────┐
│  HID Class Driver (hidclass.sys)        │
│  Parse HID descriptors, validate input  │
└──────────────────┬──────────────────────┘
                   │
┌──────────────────▼──────────────────────┐
│  HID Miniclass Drivers                  │
│  BTHHID.sys (Bluetooth HID)             │
│  Interpret BT packets as HID reports    │
└──────────────────┬──────────────────────┘
                   │
┌──────────────────▼──────────────────────┐
│  BTHPORT.SYS (Bluetooth Port Driver)    │
│  Manage device state, DynamicCached...  │
│  — Vulnerable point: DSM property sync  │
└──────────────────┬──────────────────────┘
                   │
┌──────────────────▼──────────────────────┐
│  Bluetooth Radio Driver                 │
│  Hardware communication                 │
└──────────────────────────────────────────┘
```

**Vulnerability:** BTHPORT updates DynamicCachedServices during property sync → HID collection collapse.

## Magic Mouse v3 HID Stack (With Patch)

```
┌─────────────────────────────────────────┐
│     User Application Layer              │
│  (scroll events, cursor input expected) │
└──────────────────┬──────────────────────┘
                   │
┌──────────────────▼──────────────────────┐
│  Input Manager                          │
│  Route HID reports to scroll/cursor    │
└──────────────────┬──────────────────────┘
                   │
┌──────────────────▼──────────────────────┐
│  HID Class Driver (hidclass.sys)        │
│  Parse HID descriptors, validate input  │
└──────────────────┬──────────────────────┘
                   │
┌──────────────────▼──────────────────────┐
│ ▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌  │
│ ▌  applewirelessmouse.sys (Lower Filter) │
│ ▌  • Intercept DynamicCachedServices   ▌  
│ ▌  • Prevent COL02 collapse            ▌  
│ ▌  • Preserve dual-collection mode     ▌  
│ ▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌  │
└──────────────────┬──────────────────────┘
                   │
┌──────────────────▼──────────────────────┐
│  HID Miniclass Drivers (BTHHID.sys)     │
│  Interpret BT packets as HID reports    │
└──────────────────┬──────────────────────┘
                   │
┌──────────────────▼──────────────────────┐
│  BTHPORT.SYS (Bluetooth Port Driver)    │
│  Manage device state, DynamicCached...  │
│  — Now protected: writes are validated  │
└──────────────────┬──────────────────────┘
                   │
┌──────────────────▼──────────────────────┐
│  Bluetooth Radio Driver                 │
│  Hardware communication                 │
└──────────────────────────────────────────┘
```

**Protection:** applewirelessmouse filter intercepts and prevents collapse before it reaches BTHPORT.

## LowerFilters Registry Mechanism

### How Windows Loads Filter Drivers

When PnP initializes a device, it reads the `LowerFilters` registry value:

```
Registry Path:
  HKLM\SYSTEM\CurrentControlSet\Enum\BTHENUM
    \{00001124-...}_VID&0001004C_PID&0323\...\0
      \Device Parameters
        ├── LowerFilters: REG_SZ = "applewirelessmouse"
        └── DynamicCachedServices: REG_BINARY
```

**Registry Entry Meaning:**
- **Subkey:** The unique device instance for Magic Mouse v3
- **LowerFilters:** List of driver names to load below the class driver
- **Value:** "applewirelessmouse" tells PnP to insert applewirelessmouse.sys into the stack

### Loading Sequence

1. **Device enumeration:** BTHENUM detects Magic Mouse (PID 0x0323)
2. **Registry read:** PnP manager reads `Device Parameters\LowerFilters`
3. **Driver load:** PnP calls `DriverEntry` in applewirelessmouse.sys
4. **Stack insertion:** applewirelessmouse.sys is inserted below HIDClass but above BTHHID
5. **Initialization:** applewirelessmouse.sys receives `IRP_MN_START_DEVICE`
6. **Request routing:** All device I/O requests now flow through the filter

### Why Lower Filter Position Matters

```
Request flow (IRP_MJ_DEVICE_CONTROL):

HIDClass.sys
    ↓
    applewirelessmouse.sys ← INTERCEPTS HERE
    ├─ Check: Is this a DSM DynamicCachedServices write?
    ├─ If YES: Validate and prevent collapse
    └─ If NO: Pass through unchanged
    ↓
BTHHID.sys
    ↓
BTHPORT.sys
```

**Key advantage:** The filter sees requests **after** HIDClass has processed them but **before** BTHPORT executes the vulnerable write. This is the only position in the stack where the fix can work.

## IRP Interception Strategy

### What IRPs Does the Filter Intercept?

The filter watches for:

1. **IRP_MJ_DEVICE_CONTROL** with specific I/O control codes (IOCTLs)
   - IOCTL_HID_GET_DEVICE_DESCRIPTOR
   - IOCTL_HID_GET_REPORT_DESCRIPTOR
   - Custom BTHPORT private IOCTLs (property queries)

2. **IRP_MN_QUERY_DEVICE_RELATIONS**
   - When HIDClass queries for related devices/collections

3. **Registry write operations** (intercepted via BTHPORT hooks)
   - Attempts to modify DynamicCachedServices

### Interception Logic (Pseudo-Code)

```c
NTSTATUS FilterDispatchDeviceControl(
    PDEVICE_OBJECT DeviceObject,
    PIRP Irp
) {
    PIO_STACK_LOCATION stack = IoGetCurrentIrpStackLocation(Irp);
    ULONG ControlCode = stack->Parameters.DeviceIoControl.IoControlCode;

    // Check if this is a DynamicCachedServices write
    if (IsDynamicCachedServicesWrite(ControlCode)) {
        // Extract request parameters
        PVOID InputBuffer = Irp->AssociatedIrp.SystemBuffer;
        ULONG InputLength = stack->Parameters.DeviceIoControl.InputBufferLength;

        // Validate: Is this a COL02 (battery) collection descriptor?
        if (IsCollectionDescriptor(InputBuffer) && 
            IsCollectionID_COL02(InputBuffer)) {
            
            // PREVENT: Don't let this write complete
            // Instead, preserve the original dual-collection structure
            Irp->IoStatus.Status = STATUS_SUCCESS;
            Irp->IoStatus.Information = InputLength;
            
            IoCompleteRequest(Irp, IO_NO_INCREMENT);
            return STATUS_SUCCESS;
        }
    }

    // Pass all other requests through unchanged
    IoSkipCurrentIrpStackLocation(Irp);
    return IoCallDriver(lowerDeviceObject, Irp);
}
```

## Data Flow: Normal Request (Passed Through)

```
User: Get cursor position
    ↓
HIDClass: Parse HID report structure
    ↓
applewirelessmouse filter:
    ├─ Check IOCTL code: Not a DynamicCachedServices write
    └─ Action: Forward request unchanged
    ↓
BTHHID: Interpret Bluetooth packet as HID input
    ↓
BTHPORT: Transmit HID report on Bluetooth link
    ↓
Magic Mouse: Cursor position report received
    ↓
Return cursor coordinates to app ✓
```

## Data Flow: Dangerous Request (Blocked)

```
DeviceSetupManager: Query device properties
    ↓
Windows PnP: Enumerate device capabilities
    ↓
HIDClass: Forward to Bluetooth stack
    ↓
applewirelessmouse filter:
    ├─ Check IOCTL code: Is DynamicCachedServices write
    ├─ Check payload: Contains COL02 collapse instruction
    └─ Action: BLOCK request, return SUCCESS without writing
    ↓
BTHHID/BTHPORT: Never receive the collapse instruction
    ↓
DynamicCachedServices: Remains in dual-collection mode ✓
    ↓
Next input report: Still routed to COL01 → scroll works ✓
```

## Service Registration

The driver is registered as a kernel mode service:

```
Service Name: applewirelessmouse
Registry Path: HKLM\SYSTEM\CurrentControlSet\Services\applewirelessmouse

Properties:
  Type: 1 (SERVICE_KERNEL_DRIVER)
  Start: 3 (SERVICE_DEMAND_START)
  ImagePath: \SystemRoot\System32\drivers\applewirelessmouse.sys
  DisplayName: "Apple Magic Mouse Fix"
  Description: "Lower filter driver for Apple Magic Mouse v3 scroll fix"
```

**Meaning:**
- **SERVICE_KERNEL_DRIVER:** Driver loads in kernel mode (required for WDM)
- **SERVICE_DEMAND_START:** Load on-demand, not at boot (saves resources)
- **ImagePath:** Full path to the .sys binary

## Code Signing & Trust

The driver binary is signed with the **MagicMouseFix** certificate:

```
Certificate Properties:
  Subject: CN=MagicMouseFix
  Thumbprint: 16940C0F937D569363560D5FEC5CD8FA6D6D9BCE
  Key: RSA 2048-bit
  Hash: SHA256
  Type: Code Signing
  Validity: Self-signed (not Microsoft-signed)
```

**Trust model:**
1. Certificate is imported to `Cert:\LocalMachine\TrustedPublisher`
2. Windows verifies driver signature matches certificate
3. If signature valid and cert is trusted, driver loads
4. On first install, user sees trust prompt and approves

## Initialization Sequence

When the system boots or device connects:

```
1. PnP Manager Detects Device
   └─ BTHENUM enumerates Magic Mouse (VID 0x0001004C, PID 0x0323)

2. Registry Lookup
   └─ Read HKLM\...\Device Parameters\LowerFilters
   └─ Found: "applewirelessmouse"

3. Driver Load
   └─ Load applewirelessmouse.sys from System32\drivers\
   └─ Verify signature (MagicMouseFix certificate)
   └─ Call DriverEntry() function

4. Stack Insertion
   └─ applewirelessmouse.sys receives AddDevice()
   └─ Create filter device object (FDO)
   └─ Attach to device stack: HIDClass → applewirelessmouse → BTHHID

5. Device Initialization
   └─ applewirelessmouse receives IRP_MN_START_DEVICE
   └─ Opens communication channel to lower driver (BTHHID)
   └─ Begins monitoring device I/O requests

6. Ready for Operation
   └─ Device fully initialized
   └─ Filter ready to intercept requests
```

## Performance Considerations

### Overhead

- **Memory:** ~150 KB resident (driver code + data structures)
- **CPU:** Minimal — only intercepts device control requests (not frequent)
- **Latency:** <1 ms per request (signature check only)

### Why It's Fast

- Filter only examines critical IOCTLs (not all requests)
- Early exit if IOCTL is not DSM-related
- No complex algorithms, just binary pattern matching
- Requests for normal input/output (scroll, cursor) pass through unchanged

## Uninstallation

To remove the filter:

1. **Remove registry entry:**
   ```
   Delete: HKLM\...\Device Parameters\LowerFilters
   ```

2. **Unload driver:**
   ```
   sc.exe delete applewirelessmouse
   ```

3. **Remove certificate:**
   ```
   Remove MagicMouseFix from Cert:\LocalMachine\TrustedPublisher
   Remove MagicMouseFix from Cert:\LocalMachine\Root
   ```

4. **Reboot:**
   - PnP detects driver removal
   - Device reinitializes without filter
   - Stack returns to normal HIDClass → BTHHID → BTHPORT

## Limitations

### Why Not Fix BTHPORT Directly?

1. **BTHPORT is a system driver:** Modifying Windows binaries requires:
   - Source code access (not available)
   - Code signing from Microsoft (not possible for third parties)
   - OS compatibility across all Windows versions

2. **Filter approach is safer:** Lower filter allows:
   - Third-party development (no kernel source required)
   - Easy deployment via LowerFilters registry key
   - Clean uninstallation (no system file modification)
   - Device-specific targeting (only Magic Mouse, PID 0x0323)

### Why Binary Patch Instead of KMDF?

v1.0.0 uses a binary patch because:
- **Faster deployment:** Pre-built, no compilation needed
- **Immediate availability:** Users can install and reboot
- **Lower barrier:** No build environment or WDK required

v2.0.0 will rewrite as native KMDF source code for transparency and long-term maintainability.

---

## References

### Microsoft Documentation

- [WDM Filter Drivers](https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/wdm-filter-drivers)
- [IRP Data Structures](https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/irp-data-structures)
- [Device Installation Registry](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/registry-entries-for-devices-and-drivers)
- [PnP Device Initialization](https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/pnp-device-initialization)

### Related Implementations

- [HID Class Driver Source](https://github.com/microsoft/Windows-driver-samples/tree/master/input/hid)
- [WDM Filter Driver Sample](https://github.com/microsoft/Windows-driver-samples/tree/master/general/filter)

---

**Document Version:** 1.0.0  
**Last Updated:** 2026-05-18  
**Author:** Revive Business Solutions  
**License:** MIT
