# Diagram: Filter Driver Stack Position

**Purpose:** Architecture diagram showing where applewirelessmouse.sys sits in the Windows HID stack  
**Audience:** Driver developers, security reviewers  
**Read Time:** 2 min

```mermaid
flowchart TB
    subgraph UserSpace["User Space"]
        direction TB
        U1["Applications\n(browsers, IDEs, terminals)"]
        U2["Windows Input Manager\n(user32.dll / WM_MOUSEWHEEL)"]
    end

    subgraph KernelSpace["Kernel Space — Driver Stack"]
        direction TB

        K1["hidclass.sys\nHID Class Driver\nInterprets HID report descriptors\nRoutes input to consumers"]

        K2["mouhid.sys\nMouse HID minidriver\nTranslates HID reports → WDM mouse events\nBinds to COL01"]

        K3["HidBth.sys\nBluetooth HID miniport\nParses SDP service attributes\nCreates HID collections from BT descriptors"]

        K4["applewirelessmouse.sys\nLOWER FILTER (PATH-A patch)\nIntercepts IRP_MJ_DEVICE_CONTROL\nSuppresses DSM-triggered descriptor rewrite\nPreserves COL01 / COL02 separation"]

        K5["BTHENUM PDO\nBluetooth Enumerator\nDevice instance node for Magic Mouse\nOwns DynamicCachedServices registry key"]

        K6["BTHPORT.SYS\nBluetooth Port Driver\nManages BT connections\nWrites DynamicCachedServices on property events"]

        K7["BT Radio Driver\n(vendor: Intel / Broadcom / etc.)"]

        K1 --> K2 --> K3 --> K4 --> K5 --> K6 --> K7
    end

    subgraph Hardware["Hardware"]
        H1["Bluetooth Radio (host)"]
        H2["Apple Magic Mouse v3\nPID 0x0323\nD0:C0:50:xx:xx:xx"]
    end

    UserSpace --> KernelSpace
    KernelSpace --> Hardware

    subgraph Registry["Registry — Filter Registration"]
        R1["HKLM\\SYSTEM\\CurrentControlSet\\Enum\\BTHENUM\\\n{00001124-...}_VID&0001004C_PID&0323\\7&...\\0\\\n  LowerFilters  REG_MULTI_SZ  applewirelessmouse"]
        R2["HKLM\\SYSTEM\\CurrentControlSet\\Services\\applewirelessmouse\\\n  Type=1 (kernel)\n  Start=1 (SYSTEM_START)\n  ImagePath=%SystemRoot%\\System32\\drivers\\applewirelessmouse.sys"]
    end

    R1 -.->|"PnP inserts filter here"| K4
    R2 -.->|"Service entry"| K4
```

## IRP Flow: Scroll Input (Mode A — Working)

```mermaid
sequenceDiagram
    participant App as Application
    participant IM as Input Manager
    participant HC as hidclass.sys
    participant MH as mouhid.sys
    participant HB as HidBth.sys
    participant AF as applewirelessmouse.sys
    participant BE as BTHENUM PDO

    App->>IM: WM_MOUSEWHEEL expected
    IM->>HC: ReadFile (HID report request)
    HC->>MH: IRP_MJ_READ (COL01)
    MH->>HB: IRP_MJ_INTERNAL_DEVICE_CONTROL
    HB->>AF: IRP_MJ_DEVICE_CONTROL (pass-through for normal reads)
    AF->>BE: Forward IRP (no interception on normal read)
    BE-->>AF: HID report: wheel delta = -3
    AF-->>HB: Forward report (unmodified)
    HB-->>MH: Parsed HID report
    MH-->>HC: Mouse input event
    HC-->>IM: WM_MOUSEWHEEL(-3)
    IM-->>App: Scroll event delivered
```

## IRP Flow: DSM Trigger Interception (Patched)

```mermaid
sequenceDiagram
    participant DSM as DeviceSetupManager
    participant BP as BTHPORT.SYS
    participant AF as applewirelessmouse.sys
    participant BE as BTHENUM PDO
    participant REG as DynamicCachedServices

    DSM->>BP: QueryDeviceProperty(BatteryLevel)
    BP->>AF: IRP_MJ_DEVICE_CONTROL (SDP attribute query)
    AF->>AF: Detect: DSM descriptor-rewrite pattern
    AF->>BE: Forward with modification (suppress collapse)
    BE->>REG: Write DynamicCachedServices (COL02 preserved)
    REG-->>BE: ACK
    BE-->>AF: Success
    AF-->>BP: Return result (filtered)
    BP-->>DSM: Property value returned
    note over REG: COL01 + COL02 both intact.<br/>Mode A preserved.
```

## File Locations After Install

```
C:\Windows\System32\drivers\
  applewirelessmouse.sys          ← 66,288 bytes, M14-signed
                                    SHA256: 370A5555...FA56A03

C:\ProgramData\MagicMousePatch\
  backup\
    applewirelessmouse.sys.bak    ← original (pre-patch) backup

Cert:\LocalMachine\TrustedPublisher\
  CN=MagicMouseFix               ← self-signed, thumbprint 16940C0F...

Cert:\LocalMachine\Root\
  CN=MagicMouseFix               ← same cert, imported to Root for driver load
```

---

**Document Version:** 1.0.0  
**Last Updated:** 2026-05-18
