# ClipShare

A native macOS menu bar app that shares your clipboard with
[omaclip](https://github.com/rhemvi/omaclip) running on Omarchy (or any Linux box).
It speaks omaclip's sync protocol (v2) directly, so Linux keeps running stock omaclip
and the Mac gets a small, fast, native client instead of the Wails app.

## What it does

- Lives in the menu bar, with no Dock icon or window until you ask for one.
- **⌥⌘V** opens a Spotlight-style history panel with everything copied on this Mac and on your
  peers. Type to search; use ↑/↓, Return, ⌘1–9 or Tab to switch between All / This Mac / Peers.
  Choosing an entry copies it and (optionally) pastes it into the app you were in.
- **⌃⌥⌘V** pastes the newest entry from any peer straight into the front app.
- **Auto-Copy from Peers** (menu toggle) puts every new Linux copy onto the Mac clipboard as it arrives.
- Shares the Mac's newest copies (5 by default) back to omaclip, so they show up in its
  remote clipboard list on Linux.
- Skips items that password managers mark as concealed or transient.

## Build and run

Requires macOS 14+ and Xcode 16.3 or newer (Swift 6.1 toolchain).

```bash
./scripts/build-app.sh            # builds build/ClipShare.app
./scripts/build-app.sh --install  # also copies it to /Applications and launches it
swift test                        # protocol tests (Argon2/TLS/JSON vectors from omaclip, server round trip)
```

On first launch, Settings opens. Enter the same passphrase you use for omaclip. If omaclip was
ever set up on this Mac, ClipShare imports `~/.config/omaclip/config.json` automatically.

macOS will ask for:

- **Local Network** access, so Bonjour can find omaclip and omaclip can reach the Mac.
- **Accessibility** access, only if you use paste-after-choosing or ⌃⌥⌘V (it sends ⌘V for you).
  Rebuilding re-signs the app ad hoc, so you may need to toggle it off and on again after a rebuild.

## Networking

By default ClipShare discovers peers with Bonjour (`_omaclip._tcp`) like omaclip's mDNS does.
For Tailscale or other routed networks, give both sides a fixed port and list each other:

```bash
# Linux
omaclip --sync-server-port=36742 --peers-list=mac@100.64.0.2:36742
```

and in ClipShare Settings › Network set port `36742` and manual peers
`omarchy@100.64.0.3:36742`. Settings shows this Mac's addresses and port for copy-pasting.

## How the protocol works

Every peer runs an HTTPS server and polls the others every 2 seconds:

1. `GET /api/clipboard/checksum` and stop if it hasn't changed.
2. `GET /api/clipboard` returns a newest-first manifest (`id`, `checksum`, `contentType`, `imageMimeType`, `timestamp`).
3. `GET /api/clipboard/{id}/content` for any payload not already held, verified against its SHA-256.

Security comes entirely from the shared passphrase:

- Argon2id(passphrase, salt = passphrase reversed, t=1, m=64 MiB, p=4) gives a 32-byte key.
  Its hex goes in the `X-Omaclip-Pass` header, and its first 16 hex characters go in the mDNS TXT record (`ph=`).
- HKDF-SHA256(key, salt `omaclip-ca-v1`) deterministically derives a P-256 CA key. Each peer signs a
  random leaf certificate for its IPv4 addresses with it, and peers trust only that CA.

## Layout

- `Sources/OmaclipKit`: protocol, crypto, HTTPS server (SwiftNIO), peer client and Bonjour discovery.
- `Sources/ClipShare`: the AppKit/SwiftUI menu bar app.
- `Sources/CArgon2`: the reference Argon2 implementation (CC0/Apache-2.0), vendored from
  [P-H-C/phc-winner-argon2](https://github.com/P-H-C/phc-winner-argon2) at `f57e61e`.
