# Diagram: Mode A vs Mode B HID Stack

**Purpose:** Side-by-side comparison of working (Mode A) vs broken (Mode B) HID collection structure  
**Audience:** Developers, advanced users diagnosing scroll failure  
**Read Time:** 2 min

```mermaid
flowchart TB
    subgraph A["Mode A — Working (Dual Collections)"]
        direction TB
        A1["HIDClass (hidclass.sys)"]
        A2["HidBth.sys (HID miniport)"]
        A3["applewirelessmouse.sys\n[LOWER FILTER]"]
        A4["BTHENUM PDO"]
        A5["COL01\nHID\\VID_004C&PID_0323&COL01\nmouhid → scroll + cursor"]
        A6["COL02\nHID\\VID_004C&PID_0323&COL02\nbattery / diagnostics"]
        A1 --> A2 --> A3 --> A4
        A4 --> A5
        A4 --> A6
    end

    subgraph B["Mode B — Broken (Collapsed TLC)"]
        direction TB
        B1["HIDClass (hidclass.sys)"]
        B2["HidBth.sys (HID miniport)"]
        B4["BTHENUM PDO"]
        B5["TLC (unified)\nHID\\VID_004C&PID_0323\nscroll DROPPED — ambiguous routing"]
        B1 --> B2 --> B4
        B4 --> B5
    end

    note1["DynamicCachedServices\nEntry 0: COL01  0x00110000\nEntry 1: COL02  0x00020000"]
    note2["DynamicCachedServices\nEntry 0: TLC    0x00110000\nEntry 1: empty  0x00000000\n(COL02 gone after DSM write)"]

    note1 -.->|"Mode A registry"| A4
    note2 -.->|"Mode B registry"| B4
```

## Key Differences

| Item | Mode A | Mode B |
|------|--------|--------|
| COL01 | Present, independent | Merged into TLC |
| COL02 | Present, independent | **Gone** |
| Lower filter | applewirelessmouse.sys loaded | Not present (or irrelevant — TLC already collapsed) |
| Scroll | Working | **Broken** |
| Trigger | Fresh pair or patch protecting | DSM 35-property write → BTHPORT DynamicCachedServices rewrite |
| Recovery | N/A | Full device unpair/repair, or patch install |

## State Transition

```mermaid
stateDiagram-v2
    [*] --> ModeA : Initial pair
    ModeA --> ModeB : BT idle (15-30 min)\n+ DSM 35-property write\n+ BTHPORT DynamicCachedServices rewrite
    ModeB --> ModeA : Unpair + repair\nOR patch install + reboot
    ModeA --> ModeA : Patch active --\nDSM write intercepted
    note right of ModeB : One-way without intervention.\nDevice reconnect / sleep/wake\ndo NOT auto-recover.
```

---

**Document Version:** 1.0.0  
**Last Updated:** 2026-05-18
