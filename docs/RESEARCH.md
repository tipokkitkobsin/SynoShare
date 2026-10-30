# Phase 1 — Research Findings (2026-10-30)

All items below were verified experimentally against the real share unless marked UNVERIFIED.

## Connection path

1. `https://gofile.me/<serverID>/<linkID>` returns HTTP 200 with a JS page (no HTTP redirect).
   The JS (`connect_lib.*.bundle.js`) resolves the NAS through QuickConnect.
2. `POST https://global.quickconnect.to/Serv.php` with
   `[{"version":1,"command":"get_server_info","id":"file_sharing_https","serverID":"<serverID>","is_gofile":true,"path":"<serverID>", ...}]`
   returns `server`, `service`, `env` (`control_host`, `relay_region`).
3. Direct paths (DDNS on 5000/5001/443, `ext_port` = 0) **time out** from a home network.
4. Relay host rule (from the bundle's `Gofile.getRelayHost`):
   `gofile-<hex(serverID)>.<relay_region>.quickconnect.to` → e.g. server ID `AbC12` in region `sg3` gives
   `gofile-4162433132.sg3.quickconnect.to`. Valid public TLS certificate. The browser lands on
   `https://<relay host>/sharing/<linkID>`.
   `request_tunnel` on the control host (`usc.quickconnect.to`) returns `errno 0`;
   UNVERIFIED whether it must be called first to keep the tunnel open.

## Sharing WebAPI (via relay, `/sharing/webapi/entry.cgi`)

`SYNO.API.Info` confirms: `SYNO.Core.Sharing.Login` v1, `SYNO.Core.Sharing.Initdata` v1,
`SYNO.FolderSharing.List` v1–2, `SYNO.FolderSharing.Download` v1–2. Unauthenticated List → error 101.

Flow (from the page's `sharing.js` and the reference project):
1. `SYNO.Core.Sharing.Login` `method=login`, params `sharing_id`, `password` → `sharing_sid` cookie.
   The web page wraps params with synowebapi client encryption; the reference project sends them
   plain over HTTPS. UNVERIFIED for this NAS.
2. `SYNO.Core.Sharing.Initdata` `get` with header `X-SYNO-SHARING: <linkID>` → `Private.filename` = root.
3. `SYNO.FolderSharing.List` v2 `list` (`folder_path`, `offset`, `limit`, `additional=["size","time","type"]`, `_sharing_id`).
4. `SYNO.FolderSharing.Download` v2 `download` (`path=["<remote>"]`, `mode="download"`, `_sharing_id`), GET.

## Range / speed

- Relay passes `Range` on static files: `206`, `content-range: bytes 100-199/834527`.
- Range on `FolderSharing.Download`: UNVERIFIED (needs login) — Phase 2 test.
- One 815 KB file via relay: ~0.56 MB/s (includes connection setup).

## Existing projects

- `shawnrancatore/synology-share-downloader` (Apache-2.0, Python/Tkinter, v1.3.0, 2026-10-11).
  Correct protocol, Range resume, `.part`, link-safety checks.
  **Does not use the QuickConnect relay** (README states it), so it cannot reach this NAS.
  No persistent state DB, size-only verification, overwrites on size mismatch.
- Decision: port its protocol knowledge to Swift (with attribution under Apache-2.0) and add relay support.
