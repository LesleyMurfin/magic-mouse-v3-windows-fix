# v2.0.0 — KMDF Driver (Work in Progress)

**STATUS: WORK IN PROGRESS — NOT PRODUCTION READY**

This directory contains the roadmap and architecture for v2.0.0, a from-scratch KMDF (Kernel Mode Driver Framework) filter driver implementation. v2 replaces the v1 binary patch with native source code, eliminating dependency on Apple firmware patching.

## Why v2?

### v1 Limitations

| Issue | v1 Binary Patch | v2 KMDF Source |
|-------|---|---|
| Transparency | Binary only (opaque) | Full source code |
| Apple dependency | Patches Apple firmware | Independent implementation |
| Signing | Self-signed cert | Windows-signed (future) |
| Maintainability | Requires re-patching firmware | Direct source modifications |
| SmartScreen | Warnings on new systems | Better reputation over time |
| Compliance | Custom certificate trust | Standard driver signing |

### v2 Advantages

1. **Open source:** Full implementation visible for audit and modification
2. **No Apple dependency:** Standalone KMDF driver, no firmware patching
3. **Better signing:** Compatible with Microsoft code signing and certification
4. **Cleaner deployment:** No custom certificate imports, standard Windows driver model
5. **Long-term support:** Source code can be maintained across Windows versions
6. **Transparency:** Security research and third-party review possible

## Architecture

### KMDF vs WDM

| Aspect | v1 (WDM Lower Filter) | v2 (KMDF Filter) |
|--------|---|---|
| Framework | Windows Driver Model (WDM) | Kernel Mode Driver Framework (KMDF) |
| Code size | ~66 KB binary | ~150 KB source (compiled similar size) |
| Complexity | Direct IRP handling | Object-oriented framework |
| Debuggability | Standard kernel debugging | KMDF-aware tools |
| Best practice | Older, but functional | Modern Windows driver development |

### File Structure

```
v2-kmdf-driver/
├── README.md (this file)
├── src/
│   ├── main.c            # DriverEntry, device creation
│   ├── filter.c          # Filter dispatch routines
│   ├── magic_mouse.c     # Magic Mouse-specific logic
│   ├── ioctl_handlers.c  # Device I/O control handling
│   └── common.h          # Shared definitions
├── inc/
│   ├── filter.h
│   ├── magic_mouse.h
│   └── version.h
├── magic_mouse_v3.vcxproj    # Visual Studio project
├── magic_mouse_v3.sln        # Visual Studio solution
├── build.cmd                 # Build script
├── BUILDING.md               # Build instructions
└── docs/
    ├── KMDF_MIGRATION.md     # Migration notes from WDM
    └── TEST_PLAN.md          # Comprehensive test plan
```

## Development Status

### Completed

- [ ] Architecture design (pending)
- [ ] KMDF framework skeleton (pending)
- [ ] Magic Mouse PID detection (pending)
- [ ] IRP filtering logic (pending)
- [ ] DynamicCachedServices interception (pending)
- [ ] Error handling (pending)
- [ ] Unit tests (pending)
- [ ] Integration tests (pending)
- [ ] Code review (pending)

### In Progress

- KMDF initialization
- Device enumeration and filtering

### Planned

- IRP interception and validation
- Registry manipulation safeguards
- Comprehensive testing (all 6 test scenarios)
- Public source code release
- Microsoft signing certification

## Building v2 (When Available)

### Prerequisites

- Windows Driver Kit (WDK) 10.0 or later
- Visual Studio 2019 or later
- .NET Framework 4.7+ (for build tools)

### Build Steps

```powershell
# Open Visual Studio as Administrator
# File → Open Solution → magic_mouse_v3.sln
# Build → Build Solution (F7)
# Output: magic_mouse_v3.sys in output directory

# Or command-line:
msbuild magic_mouse_v3.sln /p:Configuration=Release /p:Platform=x64
```

### Signing (Pre-Release)

```powershell
# Test-sign for development
signtool sign /f MagicMouseFix.pfx /p password /t http://timestamp.server.com ^
  magic_mouse_v3.sys

# Production (pending Microsoft certification)
# Will be signed by Revive Business Solutions' code signing certificate
```

## Testing (When Available)

v2 will be tested with the same 6-scenario test suite as v1:

1. **Power off/on:** Scroll persists
2. **69-minute idle:** Scroll stable after extended idle
3. **pnputil rescan:** Device rescan compatible
4. **Sleep/wake:** Cache integrity maintained
5. **UsoClient force-DSM:** DSM property scan blocked
6. **Cold reboot:** Multiple DSM runs don't trigger collapse

See `docs/TEST_PLAN.md` for detailed procedures.

## Deployment Roadmap

### Phase 1: Internal Testing (Target: Q3 2026)

- Complete source implementation
- Run all 6 test scenarios
- Code review and security audit
- Document building and testing process

### Phase 2: Beta Release (Target: Q4 2026)

- Source code published to GitHub (this repo)
- Beta version for experienced users
- Feedback collection
- Bug fixes based on testing

### Phase 3: Production Release (Target: Q1 2027)

- Microsoft code signing certification
- v2.0.0 final release
- v1.0.0 marked as deprecated (still supported)
- Migration guide for v1 → v2

## Design Principles

### v2 KMDF Implementation Will Follow:

1. **Minimal interception:** Only intercept critical DSM property queries, pass all others through
2. **Fast path:** No complex algorithms, early exit for non-Magic Mouse devices
3. **Error safety:** If uncertainty exists, allow request (fail-open for stability)
4. **Logging:** Debug tracing for issue diagnosis without performance penalty
5. **Isolation:** Device-specific filtering (PID 0x0323 only), no impact on other HID devices
6. **Compliance:** Follow Windows Driver Frameworks best practices

## Comparison: v1 vs v2

### v1 (Binary Patch) — Current Production

**Use v1 if:**
- You need a fix now (before v2 is available)
- You're comfortable with binary patches
- You're not concerned about certificate trust prompts

**Install:** See `/v1-binary-patch/README.md`

### v2 (KMDF Source) — Future

**Use v2 when:**
- You want to audit the source code
- You prefer open-source drivers
- Microsoft-signed binaries become available
- You're building a derivative project

**Timeline:** v2 becomes available Q3 2026 (beta), Q1 2027 (production)

## Migration Path: v1 → v2

When v2.0.0 is released:

1. **v1 continues to work:** v1.0.0 will remain available and supported
2. **Side-by-side installation:** v1 and v2 can coexist (though only one should be active)
3. **Migration script:** Uninstall v1, install v2 (simple PowerShell script)
4. **No breaking changes:** v2 maintains same functionality and registry interface

## Contributing

v2 development will welcome contributions for:
- Code implementation (KMDF driver skeleton, dispatch routines, etc.)
- Testing on additional hardware configurations
- Documentation improvements
- Code review and security audit

**Process:**
1. Fork this repository
2. Create feature branch: `git checkout -b ai/v2-feature-name`
3. Implement feature + tests
4. Open pull request with test evidence
5. Code review before merge

See `CONTRIBUTING.md` for details.

## FAQ

### Q: Why not release v2 now?

A: KMDF driver development requires:
- WDK environment setup
- Driver architecture design
- IRP routing and interception logic
- Comprehensive testing on multiple Windows versions
- Security audit before public release

Releasing an untested driver would be irresponsible.

### Q: When will v2 be ready?

A: Target timeline:
- **Architecture & design:** May–June 2026
- **Implementation:** July–August 2026
- **Testing:** September 2026
- **Beta release:** October 2026
- **Production release:** January 2027

### Q: Can I help build v2?

A: Yes! Contributors welcome once the source skeleton is available. See `CONTRIBUTING.md`.

### Q: Will v1 stop working when v2 is released?

A: No. v1 will continue to work and be supported. v2 is an alternative, not a replacement. You choose which to install.

### Q: What about Windows 12 / ARM64?

A: v2 architecture will support:
- Windows 11 22H2+
- Windows 10 build 14393+ (best-effort)
- x64 architecture (primary target)
- ARM64 (secondary, pending testing)

v1 works on these now; v2 will maintain same compatibility.

## Current Users (v1.0.0)

If you've installed v1.0.0 and it's working, **no action is required**. v1 remains production-ready and fully supported.

When v2 becomes available, you can optionally upgrade by:
1. Uninstalling v1 (`Uninstall-MagicMousePatch.ps1`)
2. Installing v2 (PowerShell or WiX installer)
3. Rebooting

---

## Resources

### Windows Driver Development

- [Microsoft Windows Driver Kit](https://docs.microsoft.com/en-us/windows-hardware/drivers/)
- [KMDF Documentation](https://docs.microsoft.com/en-us/windows-hardware/drivers/wdf/kmdf-version-history)
- [Windows Driver Samples](https://github.com/microsoft/Windows-driver-samples)

### Related Projects

- [WDF Filter Driver Sample](https://github.com/microsoft/Windows-driver-samples/tree/master/general/filter)
- [HID Class Driver](https://github.com/microsoft/Windows-driver-samples/tree/master/input/hid)

---

**Document Version:** 1.0.0 (WIP)  
**Last Updated:** 2026-05-18  
**Status:** Not production ready — do not install on production systems  
**Author:** Revive Business Solutions  
**License:** MIT (when source is released)
