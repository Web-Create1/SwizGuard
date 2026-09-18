# Full deployment: Hetzner VPS + Raspberry Pi 5 on Spectrum

The complete two-server build. One SwizGuard install on a VPS gives you a
stealth exit node for privacy and unblocking; a second install on the Pi at home
gives you a way back into your own network. Same repo, same commands, two
different jobs.

**Do Phase 0 before you pay for anything.** It tells you whether the home half
is possible on your connection at all.

---

## Why two servers

These are different problems and one box cannot do both.

| | You want | Exit IP | Who sees your browsing |
|---|---|---|---|
| **VPS** | Privacy, unblocking, hostile wifi | Hetzner datacenter | Nobody who matters — not Spectrum, not the hotel |
| **Pi at home** | Reach your NAS/home lab from away | Your Spectrum IP | Spectrum, in full |

Routing your daily browsing through the Pi would hand Spectrum a complete log of
it and stamp your home IP on everything. Routing your home-lab access through
the VPS would not reach your house at all. So: both, used for different things.

---

## Phase 0 — can your Spectrum line host anything?

Two things can kill the home half. Find out now.

### 0a. Are you behind CGNAT?

On the Pi:

```bash
curl -4 -s ifconfig.me          # what the internet sees
```

Now open your Spectrum gateway (`http://192.168.1.1`, or the My Spectrum app →
Services → Router) and find the **WAN / Internet IP**.

- **They match** → you have a real public IP. Good, continue.
- **Gateway shows `100.64.x.x` – `100.127.x.x`** → CGNAT. Port forwarding cannot
  work; the connection never reaches your router. Spectrum residential is
  usually not CGNAT, but if yours is, call them and ask for a public IPv4 — it is
  normally free on request. If they refuse, skip the home half entirely and run
  VPS-only.

### 0b. Does Spectrum let inbound 443 through?

This is the real risk. Some residential ISPs block inbound 80/443, and REALITY's
camouflage depends on living on 443 — moving it to 8443 makes your traffic the
only thing on the internet doing stealth-TLS on a weird port, which defeats the
entire point.

Test it before you build anything. On the Pi:

```bash
sudo apt install -y netcat-openbsd
sudo nc -l -p 443              # leave this running
```

Forward TCP 443 to the Pi in your gateway first (see Phase 2b), then **from your
phone with wifi OFF, on mobile data**:

```bash
# any terminal app, or use a friend's connection
curl -v --max-time 10 http://YOUR_WAN_IP
```

- The `nc` window prints an HTTP request → **443 is open. You are clear.**
- Times out or connection refused → either the forward is wrong, or Spectrum is
  blocking it. Re-check the forward, then call Spectrum and ask whether inbound
  443 is blocked on your plan.

Testing from inside your own house proves nothing — many gateways do not loop a
forwarded port back internally. Mobile data only.

---

## Phase 1 — the VPS (privacy half)

### 1a. Create it

[Hetzner Cloud](https://console.hetzner.cloud) → new project → new server.

- **Location:** Ashburn VA or Hillsboro OR for US latency. Falkenstein/Helsinki
  if you specifically want an EU exit IP.
- **Image:** Ubuntu 24.04
- **Type:** CPX11 (US) or CAX11 (EU, ARM — this repo builds `arm64-v8a`, it works
  fine and is cheaper). Around $5/month either way; check current pricing.
- **SSH key:** paste your public key. Do not enable password login.
- Leave the Hetzner cloud firewall off for now; UFW on the box will handle it.

Hetzner may ask for ID verification on new accounts. That is normal and usually
clears within hours.

### 1b. Harden it first

```bash
ssh root@YOUR_VPS_IP
```

Run the hardening pass the README recommends before installing anything —
non-root user, SSH keys only, custom SSH port, UFW, fail2ban, unattended
upgrades. SwizGuard detects UFW and opens only 443/tcp on top of it.

Whatever you use, confirm these before moving on:

```bash
sudo ufw status                                   # active
sudo grep -E 'PasswordAuthentication|PermitRootLogin|^Port' /etc/ssh/sshd_config
timedatectl                                       # NTP synced — REALITY needs
                                                  # clocks within ~30 seconds
```

That last one matters more than it looks. Clock skew is the single most common
cause of "REALITY handshake failed" with no other symptom.

### 1c. Install SwizGuard

```bash
git clone https://github.com/Web-Create1/SwizGuard.git
cd SwizGuard
sudo ./swizguard setup
```

A VPS owns its public IP, so setup auto-detects it correctly and you should
**not** see the NAT warning here. If you do, something is wrong with the network
config — stop and investigate.

### 1d. Add a client per device

```bash
sudo ./swizguard add macbook
sudo ./swizguard add iphone
sudo ./swizguard add pi
```

Each writes a folder to `/etc/swizguard/clients/<name>/`. Keep the names
distinct from the Pi's clients in Phase 2 — you will have two profiles on each
device and you need to tell them apart. `vps-macbook` / `home-macbook` is worth
the extra typing.

### 1e. Verify the camouflage from somewhere else

From your laptop, not from the VPS:

```bash
curl -I --resolve www.microsoft.com:443:YOUR_VPS_IP https://www.microsoft.com
```

`HTTP/2 200` and `server: AkamaiGHost` means REALITY is answering probes with
Microsoft's real certificate. That is the whole product working.

---

## Phase 2 — the Pi (home-access half)

Only if Phase 0 passed.

### 2a. Prepare the Pi

Raspberry Pi OS **64-bit** Bookworm or newer.

```bash
sudo apt update && sudo apt full-upgrade -y
sudo reboot
```

Give it a static LAN address — a forwarded port aimed at an address that moves
on reboot is the most common way this breaks:

```bash
sudo nmcli con mod "Wired connection 1" \
  ipv4.addresses 192.168.1.50/24 \
  ipv4.gateway 192.168.1.1 \
  ipv4.dns "1.1.1.1,9.9.9.9" \
  ipv4.method manual
sudo nmcli con up "Wired connection 1"
```

Use ethernet. Every client packet crosses this link twice. Harden the Pi the
same way as the VPS, and check `timedatectl` here too.

### 2b. Forward the port on Spectrum

Spectrum gateway (`192.168.1.1`) or the My Spectrum app → Advanced → Port
Forwarding:

- External TCP **443** → **192.168.1.50** port **443**

Do **not** forward 51821. WireGuard is reached through REALITY and must stay on
localhost. If your gateway's own admin page occupies 443, move the admin page,
not SwizGuard.

### 2c. DDNS, because Spectrum IPs move

Spectrum addresses are dynamic. They change rarely, but when it happens every
client config pointing at the old IP goes dead at once.

Register a free hostname at [duckdns.org](https://www.duckdns.org), then on the
Pi:

```bash
mkdir -p ~/duckdns && cat > ~/duckdns/duck.sh <<'SH'
#!/bin/bash
curl -sk "https://www.duckdns.org/update?domains=YOURNAME&token=YOUR_TOKEN&ip=" -o ~/duckdns/duck.log
SH
chmod 700 ~/duckdns/duck.sh
( crontab -l 2>/dev/null; echo "*/5 * * * * ~/duckdns/duck.sh >/dev/null 2>&1" ) | crontab -
~/duckdns/duck.sh && cat ~/duckdns/duck.log   # should print: OK
```

### 2d. Install, pointed at the hostname

```bash
git clone https://github.com/Web-Create1/SwizGuard.git
cd SwizGuard
sudo SERVER_IP=yourname.duckdns.org ./swizguard setup
```

`SERVER_IP` is what goes into every client config. Giving it the DDNS hostname
means clients follow your IP when Spectrum rotates it. Without it, setup pins
whatever your address is today.

You **will** see the NAT warning here. That is correct and expected — it is
telling you the port forward from 2b is load-bearing.

```bash
sudo ./swizguard add home-macbook
sudo ./swizguard add home-iphone
```

### 2e. Verify from mobile data

```bash
curl -I --resolve www.microsoft.com:443:YOUR_WAN_IP https://www.microsoft.com
sudo ./swizguard status      # on the Pi
```

---

## Phase 3 — the Pi as a client too

You picked "both server and client", so the Pi also sends its own outbound
traffic through the VPS.

Good news: **these do not fight.** The concern with running both is usually a
default-route conflict, but SwizGuard's desktop client is a userspace SOCKS/HTTP
proxy on `127.0.0.1:10808`/`10809` — it never claims the default route and never
creates a system tunnel. The Pi's server side (Xray on :443 plus `wg1`) and the
Pi's client side (Xray on :10808 dialling out to Hetzner) are separate processes
on separate ports that ignore each other.

Copy the `pi` client folder down from the **VPS**:

```bash
# on the VPS, so a non-root scp can read the key
sudo chmod 644 /etc/swizguard/clients/pi/private.key

# on the Pi
scp -P YOUR_SSH_PORT -i YOUR_KEY USER@YOUR_VPS_IP:/etc/swizguard/clients/pi ~/swizguard-vps
cd ~/swizguard-vps && bash connect-pi.sh
curl --socks5 127.0.0.1:10808 -4 ifconfig.me    # must print your VPS IP
```

`xray` is already on the Pi at `/usr/local/bin/xray` from the Phase 2 install, so
there is nothing extra to install.

To start it at boot:

```bash
sudo tee /etc/systemd/system/swizguard-client.service <<'SVC'
[Unit]
Description=SwizGuard client (outbound via VPS)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/xray run -config /home/YOUR_USER/swizguard-vps/xray-client.json
Restart=on-failure
RestartSec=5
User=YOUR_USER

[Install]
WantedBy=multi-user.target
SVC
sudo systemctl daemon-reload
sudo systemctl enable --now swizguard-client
```

Only apps pointed at the SOCKS proxy use it. To send a specific command through:

```bash
export ALL_PROXY=socks5://127.0.0.1:10808
```

Routing the Pi's *entire* system through the VPS, or routing other devices in the
house through it, needs transparent-proxy or TUN setup that this repo does not
ship. Ask if you want that built.

---

## Phase 4 — your devices

Each device ends up with **two profiles**. Pick per situation:

| Situation | Use |
|---|---|
| Hotel, airport, cafe, work wifi | **VPS** profile |
| Need a file off the NAS while away | **Home** profile |
| Normal use at home | Neither |

**Mac/Linux:** scp the client folder, `bash connect-<name>.sh`, optionally
`bash connect-<name>.sh enable-system-proxy`. Run only one at a time — both
bind 10808.

**iPhone:** install SFI (Sing-Box For iOS), get each `singbox-client.json` onto
the phone via AirDrop, import both under Profiles, switch between them on the
Dashboard.

**Android:** SFA or v2rayNG, same two-profile pattern.

Full per-platform detail is in [setup-guide.md](setup-guide.md).

---

## Going stronger

- **Rotate REALITY keys** every 3-6 months on both boxes: `sudo ./swizguard rekey`,
  then `sudo ./swizguard regen <name>` for each client and redeploy.
- **Never reuse a client** across people or devices. One `add` per device — a
  shared UUID means one leaked config burns everyone.
- **Keep the boxes patched.** `unattended-upgrades` on both.
- **Re-verify the camouflage** after any Xray upgrade, with the `--resolve` curl
  from 1e.
- **Watch what the Pi half actually gives away.** Traffic exiting your home
  tunnel is attributable to your household. Use it to reach your things, not to
  hide.
- **Consider dropping the Pi's public exposure** when you are not travelling —
  removing the port forward closes the only inbound path to it.

## If something breaks

[troubleshooting.md](troubleshooting.md) covers the failure modes by symptom.
The three that account for most of them: clock skew, a client config that was not
regenerated after a server change, and — on the Pi specifically — testing from
inside your own LAN and believing the result.
