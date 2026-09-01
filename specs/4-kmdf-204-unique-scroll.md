# Spec 4 — KMDF unique 2.0.4.1 scroll package (PID 0323)

## Current State

Live Windows KMDF is `C:\Windows\System32\drivers\MagicMouseDriver.sys` SHA256 `AD5D244B176D650961594EDED153C46F9A52004C424DABFD86E50844E447546B` (oem16 `f7bf31c7`). Pointer works. Wheel absent: COL01 Input `0x12` is X/Y only.

Worktree `/data/projects/.worktrees/magic-mouse-v3-windows-fix-scroll` is detached `a5214c9` (`origin/ai/kmdf-204-unique-pkg-7748`). Source unique package exists: INF `MagicMouseDriver-kmdf-204-scroll.inf` DriverVer `09/01/2026,2.0.4.1`, dest `MagicMouseDriver-kmdf-204-scroll.sys`, HID stays on RID `0x12` and adds Wheel `0x0038` + AC Pan; battery is Input `0x90`. No signed `.sys` in tree. Linux cannot WDK-build.

2026-09-01 Linux gate: `bash v2-kmdf-driver/tests/validate-package.sh` exited 0 (all unique-identity / HID-contract checks OK).

Yesterday: PATH-A `applewirelessmouse.sys` BSOD `0xD1`. Failed 2.0.4 SHA `845435CE…` reused `MagicMouseDriver.inf` / `.cat` / `.sys` and hardlinked oem26 → Kernel-Power Event 41.

This section is authoritative. Production load of any new `.sys` on the Apr 30 PC is out of scope until owner_approval after hardware proof.

## Summary

Done for this ADW feature slice means BUILD ships pointer-safe unique 2.0.4.1 source only: INF `MagicMouseDriver-kmdf-204-scroll.inf`, dest `MagicMouseDriver-kmdf-204-scroll.sys`, DriverVer `09/01/2026,2.0.4.1`, SCM/AddService/LowerFilters `MagicMouseDriver204Scroll`. Live oem16 service `MagicMouseDriver` stays bound to SHA `AD5D244B`; hijacking that SCM is Kernel-Power Event 41 / BSOD. PATH-A `applewirelessmouse.sys` is a `0xD1` ship-blocker. ACL 6→8 grow only after `SdpPatchSuccess` and proven buffer capacity; else pointer-safe no-op. `BRB_L2CA_ACL_TRANSFER` uses WDK `bthddi.h` fields, never 14393 offsets. SDP capacity is allocation, used length is `IoStatus.Information`; fail closed `STATUS_BUFFER_TOO_SMALL`. Linux gate stays `bash v2-kmdf-driver/tests/validate-package.sh`. This session does not load a kernel driver, does not pnputil, and does not `adw:merge`. `owner_approval` waits on hardware pointer-and-wheel proof.

## Files to Touch

Kernel (AdwBuildKernel owns `.c`/`.h`):

1. `v2-kmdf-driver/Driver.c` — BRB via `bthddi.h`; ACL grow gated on `SdpPatchSuccess` + proven capacity; DISPATCH-safe completions stash PBRB; Diag under `MagicMouseDriver204Scroll`
2. `v2-kmdf-driver/Driver.h` — unique service/diag names; `MM_MOUSE_REPORT_LEN` 8
3. `v2-kmdf-driver/AclTranslate.c` / `AclTranslate.h` — 6→8 only if capacity >= need; `BufferSize` is used length, not allocation
4. `v2-kmdf-driver/InputHandler.c` / `InputHandler.h` — SDP rewrite fail closed `STATUS_BUFFER_TOO_SMALL`
5. `v2-kmdf-driver/GestureEngine.c` / `GestureEngine.h` — keep RID `0x12` X/Y + Wheel extra

Gate (AdwBuildGate owns `.ps1`/`.inf`/`.sh`; INF only if AddService/LowerFilters still equal `MagicMouseDriver`):

6. `v2-kmdf-driver/MagicMouseDriver-kmdf-204-scroll.inf` — AddService and LowerFilters MUST be `MagicMouseDriver204Scroll`
7. `v2-kmdf-driver/tests/validate-package.sh` — Linux identity + HID + unique-SCM gate; do not weaken
8. `v2-kmdf-driver/Install-KMDF.ps1` and `scripts/*.ps1` — signed unique pnputil only; refuse PATH-A, live dest, SHA `845435CE`, `Copy-Item` onto System32/DriverStore, `/delete-driver` oem16

Do not touch live `MagicMouseDriver.sys`, `MagicMouseDriver.inf`, PATH-A `applewirelessmouse.sys`, or `HidDescriptor.c` (HID already: RID `0x12` X/Y `0x0030`/`0x0031` + Wheel `0x0038` + AC Pan, battery Input `0x90`, never Feature `0x47`, never RID `0x02`).

## Step-by-Step

1. Keep live Apr 30 `MagicMouseDriver.sys` SHA `AD5D244B176D650961594EDED153C46F9A52004C424DABFD86E50844E447546B` installed. Fail closed if any script would `Copy-Item` onto System32 or DriverStore, or `/delete-driver` oem16. Do not load a kernel driver this session.
2. Unique identity: INF `MagicMouseDriver-kmdf-204-scroll.inf`, dest/ServiceBinary `MagicMouseDriver-kmdf-204-scroll.sys`, DriverVer `09/01/2026,2.0.4.1`. Fail if DriverVer is `08/30/2026,2.0.4.0` or `08/31/2026,2.0.4.0` (oem26 / PR #3 collision).
3. Unique SCM: AddService and LowerFilters MUST be `MagicMouseDriver204Scroll`. MUST NOT be `MagicMouseDriver` — that is live oem16. Hijack rewrites ImagePath without replacing `AD5D244B` on disk; a bugcheck is Event 41 / BSOD, and `/delete-driver` of the unique package can strand oem16. SHOWSTOPPER if INF still names `MagicMouseDriver`.
4. Refuse PATH-A `applewirelessmouse.sys` (known BSOD `0xD1`). Refuse SHA `845435CEF0DABAF2FD0638717E44F6A774556CECE47F00C8B12328B5B2B3FDE3`. Refuse dest `MagicMouseDriver.sys` / `MagicMouseDriver.inf`. Refuse unsigned activate (`pr3-activate`).
5. `BRB_L2CA_ACL_TRANSFER`: use WDK `bthddi.h` struct fields only (`Buffer`, `BufferSize`, `BufferMDL`, `Type`). Delete 14393 byte-offset literals. Completions are DISPATCH-safe: stash PBRB in request context; do not re-read the IRP stack.
6. SDP rewrite: capacity is the allocation (`bufAllocLen`); used length is `IoStatus.Information`. If the injected descriptor cannot fit, return `STATUS_BUFFER_TOO_SMALL`. Never write past the buffer.
7. ACL 6→8 grow only if `SdpPatchSuccess` AND proven capacity >= need (8, or 9 with `0xA1`). Else no-op: native 6-byte `0x12` X/Y stays (pointer lives, wheel omitted). Do not treat `BufferSize` as allocation. Growing an 8-byte payload into a 6-byte hidparse report is Event 41.
8. Diag registry under `Services\MagicMouseDriver204Scroll`, never `Services\MagicMouseDriver`.
9. HID contract (do not weaken): COL01 RID `0x12` keeps X/Y `0x0030`/`0x0031`; add Wheel `0x0038` + AC Pan extras; battery Input `0x90`; never RID `0x02`; never Feature `0x47`.
10. Linux gate: `bash v2-kmdf-driver/tests/validate-package.sh`. Non-zero is a BUILD fail. Do not skip. Red-first if AddService/LowerFilters equal `MagicMouseDriver`, dest is `MagicMouseDriver.sys`, or Wheel `0x38` is lost.
11. Windows-only later (not this session): WDK unique TargetName, freeze-hash, human `signtool` thumb `16940C0F`, then `pnputil /add-driver MagicMouseDriver-kmdf-204-scroll.inf /install` beside oem16. Missing `.cat` or wrong thumb: do not load.
12. Hardware must keep pointer and show Wheel `0x0038` on report `0x12`. Then `owner_approval`. No `adw:merge`. Draft PR #4 stays draft. Event 41 or timeout → restore oem16, do not retry unsigned.

## Verification

Linux gate (this environment; must exit 0):

```bash
bash v2-kmdf-driver/tests/validate-package.sh
```

Red-first: the script must exit 1 if `MagicMouseDriver.inf` is restored, `ServiceBinary` is `%12%\MagicMouseDriver.sys`, AddService or LowerFilters equals `MagicMouseDriver`, or HidDescriptor loses `0x09, 0x38`.

Live restore hash must remain (do not hash-copy or overwrite this session):

```bash
sha256sum /mnt/c/Windows/System32/drivers/MagicMouseDriver.sys
```

Expected: `ad5d244b176d650961594eded153c46f9a52004c424dabfd86e50844e447546b`. Any other hash after this session is an error.

Kernel fail-closed (source review; no live load): ACL 6→8 is a no-op unless `SdpPatchSuccess` and proven alloc capacity >= need; SDP writes never exceed allocation; BRB fields come from `bthddi.h`; completions do not re-read IRP stack; Diag key is `Services\MagicMouseDriver204Scroll`.

Hardware (Windows, after signed unique pnputil only; not this session): pointer still moves; finger scroll produces Generic Desktop Wheel `0x0038` on report `0x12`. Feature `0x47` must keep failing. Timeout or Event 41 → restore oem16, do not retry unsigned. `owner_approval` only after that proof.

## Notes for Next Agent

- ADW lane: feature. Gates: specs_present, acceptance_gate_red_first, spec_substantive, test_plan_present, owner_approval.
- Blast: kernel filter. Never auto-merge. No `adw:merge`. No pnputil / Copy-Item onto System32/DriverStore / bcdedit/testsigning this session.
- Unique SCM `MagicMouseDriver204Scroll` for AddService and LowerFilters. Live name `MagicMouseDriver` is oem16 — hijack is Event 41 / BSOD.
- PATH-A `applewirelessmouse.sys` is BSOD `0xD1` ship-blocker. Refuse SHA `845435CE…` and dest `MagicMouseDriver.sys` / `MagicMouseDriver.inf`.
- HID: keep X/Y `0x0030`/`0x0031` on `0x12`; add Wheel `0x0038` + AC Pan; battery Input `0x90`; never RID `0x02` / Feature `0x47`.
- Kernel: BRB via `bthddi.h`; ACL 6→8 only after `SdpPatchSuccess` + proven capacity; SDP fail closed; Diag under `Services\MagicMouseDriver204Scroll`.
- Giveaway artifact name: `MagicMouseDriver-kmdf-2.0.4-scroll-<sha8>.sys` after freeze-hash. Not `MagicMouseDriver.sys`.
- Design already in `v2-kmdf-driver/HID-CONTRACT.md` and `SIGN-AND-INSTALL.md`.
- GitHub PR #4 is the unique-package PR (draft, do not merge).
- DOCS-TRAY residual: `MAGIC-TRAY.md` still tells operators to Keep LowerFilters=`MagicMouseDriver`. Tray docs must not set LowerFilters=`MagicMouseDriver` (oem16 hijack / Event 41). Do not edit `MAGIC-TRAY.md` from this spec slice.
