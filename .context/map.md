# Map

| path | what |
|---|---|
| README.md | Three states, two drivers, install, Mode A/B collapse, roadmap |
| CHANGELOG.md | Unreleased Apple-route changes; KMDF 2.0.4.4–2.0.4.6; v1.0.0 |
| CONTRIBUTING.md | Redacted issue logs, hardware test procedures, PR title rules |
| SECURITY.md | Disclosure process, signing boundaries, legacy cert scope |
| DMCA-NOTICE.md | Verbatim Apple `.sys` redistribution and 48-hour takedown fallback |
| SEARCH.md | How the Pages site is set up to be found |
| LICENSE | MIT, Copyright 2026 Revive Business Solutions |
| docs/ | GitHub Pages site: index, install, scroll-fix, battery, faq, llms.txt |
| docs/CNAME | Published host drivers.magictray.app |
| scripts/ | Site link check, provenance gate, release package and verify |
| specs/gate_4.py | Host gate for the KMDF scroll spec |
| .github/workflows/ | Docs links, PowerShell lint, provenance, tag release |
| .github/FUNDING.yml | GitHub Sponsors handle plus the Stripe funding page |
| PSScriptAnalyzerSettings.psd1 | Lint settings the PowerShell workflow uses |
| v1-binary-patch/ | Driver 1: bundled Apple `.sys`, Install.cmd, installer, research docs |
| v1-binary-patch/apple-driver/ | Shipped unmodified `applewirelessmouse.sys` |
| v1-binary-patch/installer/ | Install and uninstall scripts, SHA256SUMS.txt |
| v1-binary-patch/docs/ | architecture, bug-analysis, hid-research, Mode A/B diagrams |
| v2-kmdf-driver/ | Driver 2 C source, INF, STATUS, SHIPPING, HID contract, signing docs |
| v2-kmdf-driver/Driver.c | Lower filter: ACL translate, control channel, battery `0x90` |
| v2-kmdf-driver/GestureEngine.c | Surface scroll, detent, two-finger rule |
| v2-kmdf-driver/scripts/ | Build, sign, freeze-hash, pnputil once, F1 watcher, scroll tune |
| v2-kmdf-driver/tests/ | Host gates: ACL, overlay, MT enable, scroll threshold, package |
| v2-kmdf-driver/STATUS.md | What 2.0.4.3 proved, what 2.0.4.4–2.0.4.6 changed in source only |
| v2-kmdf-driver/INCIDENT-2026-09-16.md | Battery 0% and dead scroll: measurements and the two defects |
| v2-kmdf-driver/BUILDING.md | EWDK discovery and the NuGet fallback that must not be signed |
| AGENTS.md | Read `.context/` first; optional graph, cost check, verified build/test/lint lines |
| .context/ | current, map, history, decisions |
| .aco/ | ACO maintainer kit: triage prompt, JEV docs, env sample; never commit `graph.db` |
| .ai/skills/aco-triage/ | Portable triage skill and its graceful-degrade verifier |
