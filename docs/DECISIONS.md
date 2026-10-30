# SynoShare — Agreed Decisions

Date: 2026-10-30. Source: requirements interview (grill-me).

| # | Topic | Decision |
|---|-------|----------|
| 1 | Download destination | User-chosen folder, typically an external drive. Never iCloud Drive (sync would fight with `.part` files). |
| 2 | Destination filesystem | Often exFAT and shared with other data — do NOT reformat. Write `.part`, `fsync`, then atomic rename. Account for 128 KB cluster slack. |
| 3 | Share size | Unknown; user expects it fits. Listing phase must compute total + cluster slack and refuse to start if it exceeds free space. |
| 4 | UI | Native SwiftUI macOS app (Apple Silicon). Ad-hoc signed (no Developer ID available). UI designed with ui-ux-pro-max guidance. |
| 5 | Architecture | Swift Package `SynoShareKit` (library + `synoshare` CLI + tests) and `SynoShareApp` (SwiftUI) using it. Reusable for other Synology shares. No non-Synology backends (YAGNI). |
| 6 | Source location | Outside iCloud Drive (e.g. `~/Developer/SynoShare`); public GitHub repo. |
| 7 | Password / session | Password held in memory while app runs; optional "Remember in Keychain" (default off). Cookies persisted only in Keychain. Never in logs, SQLite state, or argv. |
| 8 | Existing files | Completed + size/mtime match: skip. Present but untracked, size match: skip, tag `adopted (size-only)`. Size mismatch: tag `conflict`, never overwrite; user picks Replace / Keep both. Changed on server after completion: tag `changed-on-server`, same handling. `.part` whose source changed: discard and restart. Case-insensitive name collisions: rename later one `name (2)`, record in report. |
| 9 | Sleep / drive loss | Hold `IOPMAssertion` (prevent idle sleep) while downloading; toggle, default on. Lid-close sleep cannot be prevented. On volume unmount: pause all (not failed); on remount re-verify `.part` sizes and resume from actual size. |
| 10 | Concurrency | Default 3 files, adaptive: drop to 1 on repeated 429/503/timeouts, ramp back. Optional speed cap, default off. No multi-connection per file. |
