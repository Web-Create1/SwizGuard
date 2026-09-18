# Carrying a whole LAN: SwizGuard behind a Raspberry Pi router

[full-deployment.md](full-deployment.md) ends by saying that routing the Pi's
entire system, or other devices in the house, through the VPS needs
transparent-proxy or TUN setup this repo does not ship. This is that setup.

It lives here because it starts with a SwizGuard client, and the rest of it
lives in [`Web-Create1/pi5-privacy-router`](https://github.com/Web-Create1/pi5-privacy-router),
which owns the firewall, DNS and routing on the Pi.

---

## First: which Pi are you building?

There are two completely different jobs and they do not go on the same box.

| | **Home-access Pi** | **Router Pi** |
|---|---|---|
| What it is | a SwizGuard **server** at home | a SwizGuard **client** that forwards a LAN |
| Runbook | [full-deployment.md](full-deployment.md) phase 2 | this page |
| Needs inbound 443 | yes, forwarded from the gateway | **no** |
| Owns `wg1` | yes, SwizGuard's | yes, the dial-in server's, and they collide |
| Firewall | UFW | nftables, sole author |
| Exit IP for your browsing | your Spectrum address | your VPS |

If you want both a router and a way back into your house, the way back is the
dial-in WireGuard server in `pi5-privacy-router`, not a second SwizGuard
install. Read the next section before deciding otherwise.

---

## Do not run `swizguard setup` on the router Pi

Five things collide, and four of them are silent.

| # | What happens | Why it matters |
|---|---|---|
| 1 | `setup-server.sh` writes `/etc/wireguard/wg1.conf` unconditionally | `pi5-privacy-router` already uses `wg1` for its dial-in server. Your way back into the house is gone and you find out the next time you travel |
| 2 | Both projects chose UDP **51821** | Even renaming the interface does not separate them |
| 3 | The generated `wg1.conf` PostUp adds `iptables -t nat -A POSTROUTING -o <wan> -j MASQUERADE` | That router's design has **no** translation onto the WAN, on purpose, so that a routing mistake produces a dead connection instead of a leak. This adds one |
| 4 | Setup prefers UFW and writes iptables rules | That router's kill switch is the absence of a rule. It only means anything while nftables has exactly one author |
| 5 | Xray listens on TCP 443 and the gateway has to forward it | The router's input chain accepts exactly one thing from the WAN. Adding a TCP service makes it an exposed host |

`scripts/make-router-config.sh` touches none of this. It reads a client config
and writes a file. It does not install a service, open a port, or write a
firewall rule.

The router's `scripts/verify.sh` fails if `ufw` appears or if
`/etc/wireguard/wg1.conf` ever contains `MASQUERADE`, which is what having run
`swizguard setup` on that box looks like afterwards.

---

## What the router build actually does

```
LAN client
   |
   v
Pi: nftables forward policy DROP, one accept: lan0 -> sb0
   |
   v
sb0  sing-box TUN
       WireGuard          <- the inner tunnel, keys from `swizguard add`
         inside VLESS     <- authentication
           inside REALITY <- TLS that answers probes with Microsoft's real cert
             with Vision  <- closes the TLS-in-TLS fingerprint
   |
   v  (one TCP session on 443, bound to wan0)
VPS: Xray unwraps REALITY, hands WireGuard to wg1 on localhost, exits
```

Same chain the phone gets. The difference is that a phone tunnels itself and
this tunnels everyone else.

---

## Build it

### 1. On the VPS, add a client for the router

```bash
sudo ./swizguard add pi-router
```

Name it distinctly. You will have several profiles and telling them apart later
is worth the extra typing.

### 2. Convert it

```bash
sudo ./scripts/make-router-config.sh pi-router
```

Writes `/etc/swizguard/clients/pi-router/singbox-router.json`, mode 600. Pass
`--wan-iface` if the router's WAN is not called `wan0`.

### 3. Copy it to the Pi

```bash
# from the Pi
scp -P YOUR_SSH_PORT USER@VPS:/etc/swizguard/clients/pi-router/singbox-router.json /tmp/
sudo install -m 600 -D /tmp/singbox-router.json /etc/sing-box/config.json
shred -u /tmp/singbox-router.json
sudo sing-box check -c /etc/sing-box/config.json
```

`scp` of a 600 file needs root on the VPS side or a readable copy. If you
loosen the mode to copy it, tighten it again immediately. It holds a WireGuard
private key.

### 4. Everything else is in the other repo

`pi5-privacy-router/docs/build-phases-4-7.md`, phase 5.2 onward: install
sing-box, install the unit, prove the tunnel carries traffic, then cut the
firewall over.

---

## The five fields that differ from the phone config

Set by `make-router-config.sh`. Full reasoning in
`pi5-privacy-router/config/singbox-router.md`.

| Field | Phone | Router | Why |
|---|---|---|---|
| `auto_route` | `true` | `false` | auto_route writes its own nftables table and ip rules. The router's guarantee is that nothing else does |
| `stack` | `system` | `gvisor` | the system stack expects packets addressed to the host. A router's are addressed to someone else |
| `default_interface` | auto-detected | `wan0`, detection off | binds the outbound socket to the WAN so the tunnel cannot try to carry itself. Detection reads the default route, which by then says `sb0` |
| DNS | `hijack-dns` inside the tunnel | none | AdGuard Home owns :53 on the router. Two resolvers answering the same queries means no way to predict which wins |
| private IPs | `-> direct` | `-> reject`, except the VPS tunnel subnet | keeps the LAN's address plan off the VPS. The exception is ahead of it so a resolver on the VPS stays reachable |

---

## Verify

Run these on the Pi, in order. Stop at the first failure.

```bash
ip -br link show sb0                             # UP
ip route get 1.1.1.1                             # dev sb0
curl -4 -s ifconfig.me                           # the VPS IP
curl -4 -s --interface wan0 ifconfig.me          # your Spectrum IP
```

The last two must differ. Identical values mean the tunnel is up and carrying
nothing, which is the failure that looks healthiest.

From a machine that is not the Pi and not the VPS:

```bash
curl -I --resolve www.microsoft.com:443:YOUR_VPS_IP https://www.microsoft.com
```

`HTTP/2 200` and `server: AkamaiGHost`. Re-run this after every sing-box or
Xray upgrade. REALITY's camouflage depends on the TLS fingerprint the client
presents, and that changes between releases.

Then, from a LAN client:

```bash
curl -4 -s ifconfig.me                           # the VPS IP
```

And the one that matters:

```bash
sudo systemctl stop sing-box
#   LAN client: no internet at all, within 5 seconds. Not slow. None.
sudo systemctl start sing-box
```

If the LAN still reaches the internet with sing-box stopped, something has
added a path to the WAN and none of this is protecting anything.

---

## What this does not give you

- **Anonymity.** The exit IP is yours alone and is billed to your name. This
  hides your traffic from Spectrum and from any network you are on. It does not
  put you in a crowd. Mullvad's shared exit does that and gives up the stealth
  instead. Pick on purpose.
- **A way into your house.** That is the dial-in WireGuard server in the other
  repo, on `wg1`. Not this.
- **Filtering.** AdGuard Home does that, before packets reach `sb0`.
- **Protection if the VPS is down.** The LAN loses internet. That is the design.
  The alternative is failing open.
