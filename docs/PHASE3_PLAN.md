# Phase 3 — Implementation Plan

Read first: `docs/DECISIONS.md` (binding decisions), `docs/RESEARCH.md` (verified protocol).
Existing code: `Sources/SynoShareKit/{Models,QuickConnect,ShareClient}.swift`, probe CLI in `Sources/synoshare/`.

## Verified protocol facts (do not change without re-verifying)

- Resolve: `QuickConnect.resolve` → relay `https://gofile-<hex(serverID)>.<region>.quickconnect.to`. Direct NAS paths time out.
- Login: POST `/sharing/webapi/entry.cgi`, `api=SYNO.Core.Sharing.Login&version=1&method=login`,
  `sharing_id` and `password` as **JSON literals**, **without** `X-SYNO-SHARING` header (else error 101).
  Wrong password → error 1001. Cookie `sharing_sid` set in the session.
- List: `SYNO.FolderSharing.List` v2 works after login (probe listed 336 folders / 59,092 files).
- Download: `SYNO.FolderSharing.Download` v2 GET honours `Range` → `206` + `Content-Range` (verified, SHA-256 identical).
- Test share (private): ~506 GiB, ~59k files, largest file 81 GiB, max depth 7. Many small files (e.g. 64 KB `.db`).
- Per-request latency is high (~0.4 s); 64 KB file → 0.15 MB/s. Bulk speed unknown.

## Engine (`SynoShareKit`)

1. `StateStore` — SQLite (system `libsqlite3`, no deps) at `<dest>/.synoshare/state.sqlite`, WAL mode.
   Tables: `job(share_server_id, share_link_id, dest, root, created_at)`, `folder(path, listed)`,
   `file(path PK, rel_path, size, mtime, status, bytes_done, local_name, attempts, last_error, verified_at)`.
   Status: `pending | downloading | done | failed | conflict | changed_on_server | adopted | skipped_unsafe`.
   Never store password or cookies. Logs never show the full link id. Listing is resumable (folder.listed).
2. `PathMapper` — remote path → local path under dest. Reject `..`, absolute, control chars, `/` in names.
   Case-insensitive collision (exFAT) → `name (2).ext`, recorded in `local_name`.
3. `Downloader` — streaming via `URLSessionDataDelegate`, writes chunks to `<file>.part` with `FileHandle`,
   resumes with `Range: bytes=<partSize>-`. Expect 206 when resuming; if 200 → truncate and restart.
   If server size/mtime changed since listing → discard `.part`. On completion: size must equal listed
   size, `F_FULLFSYNC`, atomic `rename`, set mtime. Never overwrite an existing completed file (DECISIONS #8).
4. `Scheduler` — default 3 concurrent, adaptive down to 1 on repeated 429/503/timeouts, ramp back after
   successes. Retry with exponential backoff + jitter (1 s → 60 s cap), max 8 attempts per file then `failed`.
   Session expiry (API error 105/106/119, or a JSON body on download) → re-login once using an in-memory
   password provider, then retry. Wrong password → stop everything, surface error.
5. `Preflight` — free space vs remaining bytes rounded to 128 KiB clusters; refuse to start if insufficient.
6. `PowerAssertion` — `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep)` while active.
7. `VolumeWatcher` — `NSWorkspace.didUnmountNotification` for the dest volume → pause all (not failed);
   on remount, re-read `.part` sizes and continue.
8. `Verifier` — recheck all `done` files: exists, size matches; report mismatches. No re-download.
9. `Report` — files/folders discovered, expected size, done, failed, skipped, conflicts, downloaded bytes,
   size mismatches. States clearly: size match ≠ integrity guarantee (no server checksum).
10. Progress as `AsyncStream<EngineEvent>` (per-file progress, overall bytes, speed EWMA, current files,
    errors). Log to `<dest>/.synoshare/log.txt`, redacted.

## CLI (`synoshare`)

`list | download | retry-failed | verify | status | speedtest`, each `<share-url> --dest <dir>`
(`status`/`verify` need only `--dest`). Password via `readpassphrase` only. Ctrl-C → graceful stop
(finish chunk, flush state). `speedtest`: Range-fetch 32 MiB from the largest file, report MB/s.

## App (`SynoShareApp`, SwiftUI, macOS 14+, Apple Silicon, ad-hoc signed)

Single window: Share URL field, SecureField password, "Remember in Keychain" (default off), destination
picker (`NSOpenPanel`), Connect/List, Download All, Pause/Resume, overall progress + speed + ETA,
current files, Failed list + Retry Failed, Summary sheet, Verify button, "Prevent sleep" toggle.
Follow macOS HIG; semantic colors; light/dark; accessibility labels. Ad-hoc `codesign -s -`.

## Tests

Unit: PathMapper, StateStore transitions, Scheduler backoff/adaptive concurrency, Report math,
Preflight math. Integration: `URLProtocol` stub simulating 206/200/416/timeout/session expiry/JSON
error bodies; resume after kill; duplicate files; conflict handling. Target ≥ 80% coverage of SynoShareKit.
