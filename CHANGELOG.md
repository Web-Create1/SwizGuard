# Changelog

All notable changes to SwizGuard will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Transparent router support.** `full-deployment.md` said routing a whole LAN
  through the VPS needed TUN setup this repo did not ship. It does now.
  `scripts/make-router-config.sh` converts a `swizguard add` client into the
  sing-box config a Raspberry Pi router uses to forward an entire network, and
  `docs/pi-router-integration.md` covers the build. It writes a file and
  nothing else: no service, no port, no firewall rule.
- **The collision table for running SwizGuard alongside a Pi router.** Both
  projects name their WireGuard interface `wg1` and both listen on UDP 51821,
  the generated `wg1.conf` PostUp adds MASQUERADE onto the WAN, and setup
  prefers UFW. Four of those five failures are silent. The rule that avoids all
  of them: the Pi runs the client, the VPS runs the server.

### Fixed
- **The first `swizguard add` on a fresh server always failed.** With no peers
  yet, the IP-allocation `grep` matched nothing and exited 1; under
  `set -o pipefail` that aborted the script before it printed anything. Every
  new install hit this on its first client.
- **VLESS share links and QR codes could never connect.** The URL omitted
  `flow=xtls-rprx-vision` while the server requires it, so fallback clients
  (Hiddify, Shadowrocket) failed the handshake with a flow mismatch.
- `swizguard status` exited early and skipped the camouflage summary whenever
  `ss | grep` matched nothing — the usual case when Xray is stopped, which is
  exactly when you run `status`. Zero-peer servers also printed a bogus entry.
- `swizguard regen` silently fell back to the hardcoded address `fd07::72` when
  it could not read a peer's IPv6, handing a second client an address another
  one already owned. It now derives the address from the client's IPv4 octet.
- `swizguard rekey` told you to recover with `swizguard add <name>`, which
  refuses to run for an existing client. It now points at `regen`.
- `setup-server.sh` aborted without its own error message when the public-IP,
  Xray-version or default-route lookups failed, and would unzip a failed
  download as if it were a release. `openssl`, used for the short ID, is now
  installed rather than assumed.

### Added
- Raspberry Pi support: `armv7l` builds, a NAT/CGNAT warning when no local
  interface holds the detected public IP, and a [Raspberry Pi guide](docs/raspberry-pi.md)
  covering port forwarding, DDNS and Pi-specific operational notes.
- `SERVER_IP` may now be preset to an IP or hostname before `setup`, for
  home servers behind NAT and for DDNS names that outlive a changing IP.
- `WG_SUBNET6` is recorded in `credentials.env` so `add` and `regen` share one
  source of truth for the IPv6 prefix.
- Client count is capped at 254 with a clear message instead of silently
  generating an invalid address.

## [1.0.0] — 2026-04-08

First public release.

### Added
- Full WireGuard + VLESS + REALITY + Vision chain, automated end to end
- Single-command server setup: `sudo ./swizguard setup`
- Client management commands: `add`, `regen`, `share`, `list`, `remove`
- Operational commands: `status`, `upgrade-vision`, `rekey`, `nuke`
- Desktop client generation (Xray JSON with `sockopt.dialerProxy` chain)
- Mobile client generation (sing-box JSON with `detour` chain) for iOS SFI and Android SFA
- VLESS share link + QR code output for fallback clients
- Vision flow (`xtls-rprx-vision`) enabled by default — closes TLS-in-TLS fingerprinting
- Auto-detect UFW and open only port 443/tcp when present
- Debian 13 (Trixie) compatibility including the new `ssh` service name and the LXC reload bug
- Default camouflage target: `www.microsoft.com` (Xray warns against Apple/iCloud targets)
- Access logging disabled on the server by default — no record of client destinations
- Userspace WireGuard on clients via gVisor (no sudo, no kernel module, no wg-quick)
- Systemwide proxy enable/disable helpers on macOS (`enable-system-proxy` / `disable-system-proxy`)
- Comprehensive documentation: README, how-it-works, setup-guide, troubleshooting
- MIT license, security policy, and disclaimer

### Technical details
- Server: Xray-core VLESS+REALITY+Vision inbound → freedom outbound → local WireGuard (`wg1` on `127.0.0.1:51821`)
- Desktop client: single Xray process, WireGuard outbound with `sockopt.dialerProxy` chaining through VLESS+REALITY+Vision
- Mobile client (iOS/Android): single sing-box process, `wireguard` endpoint with `detour` chaining through VLESS+REALITY+Vision
- Vision flow enabled on both sides with `"flow": "xtls-rprx-vision"` on VLESS client entries
- uTLS Chrome fingerprint on REALITY clients
- Sniffing enabled at server inbound with `routeOnly: true`

### Known limitations
- Shadowrocket (iOS) cannot do the chained outbound pattern — use SFI for full chain on iPhone
- Hiddify (iOS) only supports simple share links, not chained configs
- sing-box 1.12.2 has a DNS-through-proxy bug; use 1.12.3+ or 1.13.x
- SFI for iOS requires iOS 15+
- Full chain requires a client that supports raw sing-box or Xray JSON import

### Upstream dependencies
- Xray-core v26.x recommended (server and desktop client)
- sing-box 1.11+ required for `wireguard` endpoint form (mobile client)
- WireGuard (any modern version on Linux server)
