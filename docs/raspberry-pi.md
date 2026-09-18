# Running SwizGuard on a Raspberry Pi 5

A Pi 5 makes a good SwizGuard server. Raspberry Pi OS (Bookworm) *is* Debian 12,
the Pi 5 is `aarch64`, so `setup-server.sh` picks the `arm64-v8a` Xray build with
no changes. A 16GB Pi 5 is wildly over-specced for this — SwizGuard idles in tens
of megabytes and the ceiling is your home upload speed, not the board.

The one thing that is genuinely different from a VPS: **a VPS owns its public IP,
a Pi does not.** Everything below is about closing that gap.

## Before you start: can your connection do this at all?

SwizGuard needs TCP 443 reachable from the internet. Check whether your ISP gives
you a real public address:

```bash
curl -4 -s ifconfig.me          # your WAN address as the internet sees it
ip -4 addr show                 # your Pi's address on the LAN
```

Then look at your router's WAN/status page. Compare:

- **Router WAN IP == `ifconfig.me`** → you have a routable IP. Port forwarding
  will work. Continue.
- **Router WAN IP is `100.64.x.x` – `100.127.x.x`, or `10.x`/`192.168.x`** →
  you are behind **CGNAT**. Port forwarding is impossible; your router never
  receives the connection. Options: ask your ISP for a public IPv4 (often free,
  sometimes a small fee), use IPv6 if your ISP provides it properly, or put
  SwizGuard on a cheap VPS instead and keep the Pi as a client.

`setup-server.sh` prints a warning when it detects this, but it cannot tell
CGNAT apart from ordinary NAT — only the router page can.

## 1. Prepare the Pi

Use **Raspberry Pi OS (64-bit)**, Bookworm or newer. The 32-bit image works
(`arm32-v7a`) but there is no reason to choose it on a Pi 5.

```bash
sudo apt update && sudo apt full-upgrade -y
sudo reboot
```

Give the Pi a **static LAN address**, or a DHCP reservation on the router. A
forwarded port pointing at an address that changes on reboot is the most common
way this setup breaks.

```bash
# Bookworm uses NetworkManager
sudo nmcli con mod "Wired connection 1" \
  ipv4.addresses 192.168.1.50/24 \
  ipv4.gateway 192.168.1.1 \
  ipv4.dns "1.1.1.1,9.9.9.9" \
  ipv4.method manual
sudo nmcli con up "Wired connection 1"
```

Wired beats Wi-Fi here. Every client packet crosses this link twice.

Run a hardening pass before exposing anything (see the README's deployment order
section). At minimum: SSH keys only, no password auth, and UFW enabled —
SwizGuard detects UFW and opens only 443/tcp.

## 2. Forward port 443 to the Pi

In your router: forward **external TCP 443 → 192.168.1.50 : 443** (or whatever
static address you assigned).

If your router's own admin UI sits on 443, move the admin UI, not SwizGuard.
REALITY's camouflage depends on being on the port real HTTPS lives on — moving
SwizGuard to 8443 makes the traffic stand out, which defeats the point.

Do **not** forward 51821. The WireGuard layer is reached through REALITY and
must stay bound to localhost.

## 3. Handle a changing home IP

Residential IPs move. If yours does, clients will point at a stale address.

Get a dynamic DNS hostname (duckdns.org, or your registrar's DDNS), point it at
your connection, then hand that hostname to SwizGuard instead of a bare IP:

```bash
sudo SERVER_IP=myhome.duckdns.org ./swizguard setup
```

`SERVER_IP` accepts an IP or a hostname and is written straight into every client
config, so the clients follow the DDNS record when your address changes. Without
it, setup auto-detects the current WAN IP and pins that.

## 4. Install

```bash
git clone https://github.com/Web-Create1/SwizGuard.git
cd SwizGuard
sudo ./swizguard setup            # or: sudo SERVER_IP=myhome.duckdns.org ./swizguard setup
sudo ./swizguard add macbook
sudo ./swizguard add iphone
```

## 5. Verify from outside the house

LAN testing will mislead you — many routers do not loop a forwarded port back
from inside (no NAT hairpinning), so a failure indoors does not mean a failure
outdoors. Test from mobile data with Wi-Fi off:

```bash
curl -I --resolve www.microsoft.com:443:YOUR_WAN_IP https://www.microsoft.com
```

A `HTTP/2 200` from `AkamaiGHost` means REALITY is answering and the forward is
correct. Then connect a real client and check `ifconfig.me` returns your home IP.

On the Pi:

```bash
sudo ./swizguard status
sudo wg show wg1        # peers should show endpoint 127.0.0.1:xxxxx
```

## Pi-specific notes

**Storage.** Run from an NVMe HAT or a decent USB SSD if you can. SD cards die
under a service that logs and writes continuously, and a Pi 5 makes NVMe easy.

**Power.** Use the official 27W USB-C supply. Under-volting shows up as random
network drops that look exactly like a VPN problem. Check with
`vcgencmd get_throttled` — anything other than `throttled=0x0` means power or
heat, not SwizGuard.

**Cooling.** Sustained ChaCha20 on all four cores warms the board. The active
cooler is worth it; a throttled Pi loses throughput.

**Throughput.** The Pi 5 handles a saturated home uplink comfortably. Your
bottleneck will be your ISP's *upload* speed, because everything you download
through the tunnel is uploaded by the Pi. A 20 Mbps upload means roughly 20 Mbps
through the tunnel, no matter what the Pi can do.

**Reboots.** Both services are enabled at install, so they come back on their
own. Confirm after your first reboot:

```bash
systemctl is-active xray wg-quick@wg1
```

**You are the exit node.** Traffic through this tunnel leaves from your home IP
and is attributable to your household. That is exactly what you want for
reaching your own network from a hotel, and exactly what you do not want if your
threat model involves hiding from your ISP — your ISP is the one carrying it.
See the threat model in [how-it-works.md](how-it-works.md).

If you want both — a stealth exit node *and* access back home — you need a
second install off-site, because one box cannot be both. See
[full-deployment.md](full-deployment.md) for the two-server build.
