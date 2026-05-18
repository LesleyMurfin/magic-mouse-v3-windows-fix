# Diagram: DSM Trigger Flow (H-011 Bug)

**Purpose:** Sequence diagram showing the H-011 / PSN-0001 bug trigger path and how the patch intercepts it  
**Audience:** Developers investigating the root cause  
**Read Time:** 3 min

```mermaid
sequenceDiagram
    participant User
    participant BT as Bluetooth Radio
    participant DSM as DeviceSetupManager
    participant BTHPORT as BTHPORT.SYS
    participant REG as Registry<br/>(DynamicCachedServices)
    participant HID as HID Stack<br/>(COL01 / COL02)
    participant Filter as applewirelessmouse.sys<br/>[LOWER FILTER — patch]

    User->>BT: Magic Mouse idle 15-30 min
    BT->>BT: BT idle timeout — connection drops
    note over BT: Device remains paired.<br/>Connection drops to low-power.

    DSM->>DSM: Windows wakes DSM<br/>(Windows Update / scheduler)
    DSM->>BTHPORT: Enumerate paired BT devices
    BTHPORT-->>DSM: Magic Mouse container<br/>{fbdb1973-...}

    loop 35 property writes
        DSM->>BTHPORT: QueryDeviceProperty(Magic Mouse, prop_N)
        BTHPORT->>REG: Write DynamicCachedServices entry N
        REG-->>BTHPORT: ACK
        BTHPORT-->>DSM: Property value
    end

    note over BTHPORT,REG: After 35th write:<br/>BTHPORT flushes service cache.<br/>DynamicCachedServices rewritten.<br/>COL02 entry GONE -- merged into TLC.

    REG->>HID: PnP re-enumeration triggered
    HID->>HID: Re-reads DynamicCachedServices
    note over HID: COL02 not found.<br/>Falls back to unified TLC.<br/>mouhid.sys loses scroll binding.
    HID-->>User: SCROLL BROKEN (one-way)

    note over User,HID: --- Patched path (PATH-A) ---

    DSM->>Filter: Property write IRPs pass through filter
    Filter->>Filter: Detect DSM descriptor rewrite pattern
    Filter->>BTHPORT: Block / suppress collapse conditions
    BTHPORT->>REG: DynamicCachedServices rewritten but COL02 preserved
    note over REG,HID: COL01 + COL02 both present after rewrite.<br/>Mode A state maintained.
    HID-->>User: SCROLL WORKS
```

## Unpatched Timeline

```mermaid
gantt
    title H-011 Bug Timeline (Unpatched)
    dateFormat HH:mm
    axisFormat %H:%M

    section Mouse Activity
    Scroll working         :active, s1, 00:00, 15m
    BT idle (no input)     :crit, s2, 00:15, 15m

    section Background Services
    BT connection drop     :milestone, m1, 00:22, 0m
    DSM wakes              :active, d1, 00:22, 5m
    35 property writes     :crit, d2, 00:22, 3m
    DCS rewrite (collapse) :milestone, m2, 00:25, 0m

    section Result
    Scroll broken          :crit, r1, 00:25, 30d
```

## Patch Effectiveness (v1.0 Test Results)

| Condition | Time to scroll failure |
|-----------|----------------------|
| Unpatched | ~22 min after first idle disconnect |
| Patched (v1.0) | 69+ min in observed test window |
| Improvement | 3.1× |
| Long-term guarantee | Not yet characterized (v2 target) |

---

**Document Version:** 1.0.0  
**Last Updated:** 2026-05-18
