# SynoShare

Resumable downloader for password-protected Synology File Station share links
(`https://gofile.me/<server>/<link>`), including NAS boxes that are reachable only
through the QuickConnect relay. Native SwiftUI app plus a command-line tool, for
Apple Silicon Macs running macOS 14 or later.

Not affiliated with or endorsed by Synology Inc. "Synology" and "QuickConnect" are
trademarks of their owners.

## Features

- Downloads a whole shared folder and keeps the directory tree.
- Resumes interrupted files with HTTP `Range`; state survives quits, crashes and reboots
  (SQLite in `<dest>/.synoshare/`).
- Retries with exponential backoff and jitter; adaptive concurrency (3 files, drops to 1
  when the server pushes back).
- Never overwrites: existing files are skipped, adopted or flagged as conflicts for you
  to resolve.
- Size verification after each file and on demand; free-space preflight before starting.
- Writes `.part` files, `F_FULLFSYNC`, then an atomic rename — safe on exFAT drives.
- Keeps the Mac awake while downloading; pauses when the destination drive is unplugged.
- Redacted log and summary report.

## Security

- The share password is typed by you at runtime. It is never read from arguments,
  environment variables or files, and never written to logs or the state database.
- Optional "Remember in Keychain" in the app (off by default).
- Talks only to Synology's QuickConnect servers and your NAS. No telemetry.
- Uses only the access the share link grants.

## Build

Requires Xcode 16+ (Swift 6).

```bash
swift test
scripts/build-app.sh            # builds and installs /Applications/SynoShare.app
APP_PATH=./SynoShare.app scripts/build-app.sh   # or build somewhere else
```

The app is ad-hoc signed. On first launch, right-click it and choose **Open**.

## CLI

```bash
swift build -c release --product synoshare
.build/release/synoshare download "https://gofile.me/<server>/<link>" --dest /Volumes/Drive/Share
```

```
synoshare probe        <share-url> --dest <folder>
synoshare list         <share-url> --dest <folder>
synoshare download     <share-url> --dest <folder> [--concurrency N] [--allow-sleep]
synoshare retry-failed <share-url> --dest <folder> [--concurrency N] [--allow-sleep]
synoshare speedtest    <share-url> --dest <folder> [--mib N]
synoshare status       --dest <folder>
synoshare verify       --dest <folder>
synoshare resolve      --dest <folder> <remote-path> replace|keep-both
synoshare files        --dest <folder> [--health <list>] [--broken] [--match <glob>] [--paths-from <file>]
synoshare deep-verify  --dest <folder> [--restart]
synoshare import-manifest --dest <folder> <manifest-file>
synoshare repair       <share-url> --dest <folder> [--broken] [--match <glob>] [--paths-from <file>]
```

`files` previews a selection; `repair` downloads again only the selected files (it needs
`--broken`, `--match` or `--paths-from`; `--paths-from` takes one relative path per
line, `-` for standard input, and adds to the other two). `deep-verify` hashes completed
files (SHA-256) and resumes after Ctrl-C.

Ctrl-C stops gracefully; run the same command again to resume. Do not run the app and
the CLI on the same destination at the same time.

## Notes

- Throughput through the QuickConnect relay is limited by Synology (about 0.6–0.9 MB/s
  in testing). Direct access to the NAS is much faster when available.
- The sharing API exposes no checksums. SynoShare records a SHA-256 while downloading and
  Deep Verify re-hashes files against it; an imported `sha256sum`/`md5sum` manifest is the
  only check against the original on the server.
- The protocol is undocumented; a DSM update may change it. See `docs/RESEARCH.md`.

## Acknowledgements

Protocol details were learned from
[shawnrancatore/synology-share-downloader](https://github.com/shawnrancatore/synology-share-downloader)
(Apache-2.0), extended here with QuickConnect relay support.

## License

Apache-2.0. See `LICENSE`.
