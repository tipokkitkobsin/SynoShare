# Repair Selected Files — Plan

Date: 2026-11-13. Status: approved by the owner 2026-11-13.

## Decisions (grill-me, 2026-11-13)

| # | Topic | Decision |
|---|-------|----------|
| R1 | Checksum source | SHA-256 computed while downloading, stored per file. Optional manifest import (`sha256sum` / `md5sum` text format) gives a server-side reference. |
| R2 | Files downloaded before hashing existed | On-demand **Deep Verify**: hashes files from disk. No stored hash → record it as the baseline. Stored hash → compare. Resumable. |
| R3 | Repair vs main download | Repair is its own run over the selected files only. If the main download is running, pause it first; the user resumes it afterwards. |
| R4 | UI | Separate **Files** window: status filter, glob search, checkbox table, "Select All Broken", Deep Verify, Repair N. |

## Defaults (not asked; change if wrong)

- **Health per file**: `complete` · `missing` · `sizeMismatch` · `checksumMismatch` · `notDownloaded` · `unchecked` (complete by size, never hashed).
  "Broken" = missing, sizeMismatch or checksumMismatch.
- **Checksum compare order**: manifest hash (if imported) wins over the recorded download hash.
- **Manifest**: lines `<hex>  <path>`; 32 hex = MD5, 64 hex = SHA-256; paths relative to the share root; unknown paths reported, not fatal.
- **Glob filter**: `*` within a path segment, `**` across segments, matched against the relative path. A folder = `folder/**`.
- **Repair of one file**: download to `.synoshare.part` (Range resume if a part exists and the server answers 206; full re-download on 200), check size, hash; if a manifest hash exists it must match. Pass → atomic rename over the old file. Fail → old file untouched, file reported as still broken.
- **After repair**: re-verify every repaired file; summary lists repaired / still broken (with reason).
- **CLI parity**: `synoshare files`, `deep-verify`, `import-manifest`, `repair --match <glob> | --broken`.
- **Schema v2** (migration from v1, keeps data): `file.sha256`, `file.hashed_at`, `file.expected_hash`, `file.expected_algo`.
- No secrets in logs or tests; tests use FakeNAS with fake passwords only (as today).
- No large files are written by this work (tests use KB-sized fixtures); downloads still go to the user-chosen destination.

## Commits (TDD: test first, red, then green)

1. `feat: schema v2 and streaming SHA-256 recorded on download` (resume re-hashes the existing part prefix first)
2. `feat: file health classification and Deep Verify`
3. `feat: import checksum manifest (sha256sum/md5sum)`
4. `feat: select files by status or glob and repair only the selection`
5. `feat: CLI files, deep-verify, import-manifest, repair`
6. `feat: Files window for choosing and repairing files`

Integration tests (FakeNAS): repair with Range resume; server ignoring Range → full overwrite; repair failure leaves old file untouched;
unselected files untouched (bytes and mtime); manifest mismatch after repair → still broken; Deep Verify resume.

## ETA

| Part | Estimate |
|------|----------|
| Commits 1–4 (engine + tests) | ~2.5 h |
| Commit 5 (CLI) | ~0.5 h |
| Commit 6 (app window) | ~1.5 h |
| Review and fixes | ~0.5 h |
| **Total** | **~5 h** |
