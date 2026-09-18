# SwizGuard Setup Guide

End-to-end walkthrough. Fresh VPS to working tunnel on your Mac and iPhone in about five minutes if you've done it before, ten if you haven't.

This guide assumes you've already got a VPS provisioned and you can SSH into it. If you don't have a VPS yet, grab a $5 box from Vultr, Linode, Hetzner, or DigitalOcean. Pick a location that makes sense for your threat model and your latency.

## What you need

### On the server side
- Debian 12 or 13, or Ubuntu 22.04 or 24.04 (amd64 or arm64 — both work)
- Root access via SSH
- Port 443/tcp open to the internet (the only port you need exposed)
- Strongly recommended: a hardening script run BEFORE SwizGuard. See the deployment order section below.

### Desktop client
- macOS, Linux, or Windows
- `xray-core` v1.8 or newer (v26.x recommended for the kernel splice optimization)
- macOS: `brew install xray`
- Linux: download from `https://github.com/XTLS/Xray-core/releases` and put `xray` in your PATH
- Windows: same releases page, add `xray.exe` to PATH

### iPhone
- iOS 15 or later
- **SFI (Sing-Box For iOS)** from the App Store
- Heads up: sing-box 1.12.2 has a known DNS bug. 1.12.3+ or 1.13.x is fine. The App Store version of SFI usually ships a recent build, but if it gives you trouble the TestFlight build typically has the latest core.

### Android
- **SFA (Sing-Box For Android)** from Play Store, OR
- **v2rayNG** from Play Store (which supports raw Xray JSON with chained outbounds)

## Step 1 — deploy the server

I always run my hardening script first on a fresh VPS before installing anything else. If you haven't done that, do it now (see the README for the link to VPS-Lock-Figuration). It creates a non-root user, locks down SSH, enables UFW, installs fail2ban — all the basic stuff you should be doing on any internet-facing box.

Once the box is hardened, SSH in as your non-root user with sudo access:

```bash
git clone https://github.com/Web-Create1/SwizGuard.git
cd SwizGuard
sudo ./swizguard setup
```

The setup script will:

1. Install WireGuard, Xray-core, and dependencies
2. Detect your architecture (amd64/arm64) and public IP
3. Generate a fresh REALITY x25519 keypair
4. Generate a fresh WireGuard server keypair
5. Generate a unique client UUID and short ID
6. Configure WireGuard server on `127.0.0.1:51821` (never externally exposed — that's the whole point)
7. Configure Xray VLESS+REALITY+Vision on `:443` camouflaged as `www.microsoft.com`
8. Enable both as systemd services so they survive reboots
9. Save credentials to `/etc/swizguard/credentials.env`
10. Auto-detect UFW (from your hardening script) and open port 443/tcp

When it's done, you'll see a summary block with your server's details. Note the camouflage target, client UUID, REALITY public key, and WG server pubkey — they'll appear in client configs.

## Step 2 — add a client for every device

Every device that connects needs a client entry. Run this once per device:

```bash
sudo ./swizguard add macbook
sudo ./swizguard add iphone
sudo ./swizguard add work-laptop
sudo ./swizguard add partner-phone
```

Each `add` command creates a directory at `/etc/swizguard/clients/<name>/` containing:

```
<name>/
├── xray-client.json        # Full chain config for desktop (Xray-core)
├── singbox-client.json     # Full chain config for mobile (sing-box via SFI/SFA)
├── connect-<name>.sh       # Launcher script for desktop
├── private.key             # The client's WireGuard private key
└── public.key              # The client's WireGuard public key
```

The script also prints out:
- A VLESS share link (for clients that only support share URLs like Hiddify or Shadowrocket fallback)
- A QR code that encodes the share link
- Detailed deployment instructions for desktop, iPhone, and Android

Each client gets its own WireGuard keypair and a unique tunnel IP (`10.7.0.2`, `10.7.0.3`, etc.). They can all be online at the same time.

## Step 3 — connect a desktop

### 3a. Install xray-core locally

macOS:
```bash
brew install xray
```

Linux:
```bash
curl -L -o xray.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
unzip xray.zip xray
sudo mv xray /usr/local/bin/
```

Windows: download `Xray-windows-64.zip` from the releases page, extract, add the directory containing `xray.exe` to your PATH.

### 3b. Make the private key SCP'able

By default, SwizGuard sets `chmod 600` on the client private key, which means only root can read it. If you SCP as a non-root user (which you should be doing post-hardening), you'll get a permission denied error. Loosen the perms once on the server:

```bash
sudo chmod 644 /etc/swizguard/clients/macbook/private.key
```

This is fine because the file lives inside `/etc/swizguard/` which is itself root-owned. The private key isn't going anywhere unauthorized.

### 3c. SCP the client folder to your machine

From your local machine:

```bash
scp -P 13337 -i YOUR_KEY YOUR_USER@YOUR_VPS:/etc/swizguard/clients/macbook ~/Downloads/swizguard-macbook
```

Adjust the port if you used something other than 13337 in your hardening script.

**Watch out for the scp-into-existing-directory trap.** If `~/Downloads/swizguard-macbook` already exists when you scp into it, scp creates a NESTED `swizguard-macbook` inside the existing directory instead of replacing the contents. If you've ever SCP'd this folder before, delete it first:

```bash
rm -rf ~/Downloads/swizguard-macbook
```

Then re-run the scp command.

### 3d. Start the tunnel

```bash
cd ~/Downloads/swizguard-macbook
bash connect-macbook.sh
```

You should see:

```
[*] Starting SwizGuard (macbook)...
[+] SwizGuard running (PID 12345)

    SOCKS5 proxy: 127.0.0.1:10808
    HTTP proxy:   127.0.0.1:10809
```

No sudo required. Xray runs as your user.

### 3e. Verify the tunnel works

```bash
curl --socks5 127.0.0.1:10808 -4 ifconfig.me
```

That should return your VPS's public IP. If it does, the full chain is working.

### 3f. System-wide proxy on macOS (optional but useful)

By default, only apps that explicitly use the SOCKS5/HTTP proxy at 127.0.0.1 will go through SwizGuard. If you want EVERY app on your Mac to route through it (Safari, Mail, Messages, iCloud, software updates — everything that respects system proxy):

```bash
bash connect-macbook.sh enable-system-proxy
```

This sets SOCKS5 + HTTP/HTTPS proxies on your active Wi-Fi interface using `networksetup`. It needs sudo because it modifies system network preferences.

To turn it off:

```bash
bash connect-macbook.sh disable-system-proxy
```

A note on curl: macOS curl doesn't read system proxy settings (it's not built with that support). So plain `curl ifconfig.me` will still show your real IP even with system proxy enabled. Safari and other GUI apps WILL go through the tunnel. To make curl honor the proxy, either use the explicit `--socks5` flag every time, or set environment variables (`export ALL_PROXY=socks5://127.0.0.1:10808`). The Safari test is the definitive "is system proxy working" check.

### 3g. Stop the tunnel

```bash
bash connect-macbook.sh stop
```

If you enabled system proxy, disable that FIRST so your Mac doesn't try to route through a now-dead proxy:

```bash
bash connect-macbook.sh disable-system-proxy
bash connect-macbook.sh stop
```

## Step 4 — connect an iPhone (the full chain)

This is the part nobody had a turnkey solution for. Most "VPN on iPhone" guides either tell you to use Hiddify (which only does VLESS+REALITY, not the full chain) or to jailbreak. Neither is what you want.

The trick is **SFI (Sing-Box For iOS)**. SFI imports raw sing-box JSON configs, which means it supports the chained outbound pattern that gives you the full WireGuard + VLESS+REALITY+Vision chain on iPhone.

### 4a. Install SFI

App Store search: "sing-box". The app you want is the official one from SagerNet. If the App Store version looks dated or has bugs, the latest core is usually available via TestFlight (requires a sponsor invite from the SagerNet community).

### 4b. Get the sing-box config onto your iPhone

The annoying part is SFI only imports from a **file**, not from a QR code or clipboard paste, because the config is a full sing-box JSON with chained outbounds — too long to fit in a QR reliably and not formatted as a share link.

On your Mac first, SCP it down:

```bash
scp -P 13337 -i YOUR_KEY YOUR_USER@YOUR_VPS:/etc/swizguard/clients/iphone/singbox-client.json ~/Downloads/
```

Then pick one of these to get it from your Mac to your iPhone:

**AirDrop (easiest):** right-click `singbox-client.json` in Finder → Share → AirDrop → your iPhone. On iPhone, save to Files (iCloud Drive or On My iPhone).

**iCloud Drive:** on Mac, `cp ~/Downloads/singbox-client.json ~/Library/Mobile\ Documents/com~apple~CloudDocs/`. On iPhone, open Files → iCloud Drive — the file should appear.

**iMessage to yourself:** attach the file and send. On iPhone, tap the attachment → Save to Files.

**What I would NOT do:** never spin up an HTTP server on your VPS to serve the config, even briefly. That's the kind of "convenience" that turns into a security incident.

### 4c. Import into SFI

1. Open SFI
2. Tap **Profiles** tab (bottom)
3. Tap **+** (top right) → **Local**
4. Browse to the saved JSON file and select it
5. Back out to the **Dashboard** tab
6. Select the new profile in the list
7. Tap the big **Start** toggle
8. iOS prompts: "SFI Would Like to Add VPN Configurations" → tap **Allow**
9. Authenticate with Face ID / Touch ID / passcode

### 4d. Verify the tunnel

Open Safari and visit `ifconfig.me`. It should return your VPS's public IP.

For the definitive check that the FULL chain is running (not just VLESS+REALITY), SSH to the VPS and run:

```bash
sudo wg show wg1
```

You should see the iphone peer with:
- `endpoint: 127.0.0.1:xxxxx` (the loopback port is the critical indicator — it means WG traffic is arriving via the REALITY unwrap path)
- `latest handshake: recent`
- `transfer: X KiB received, X KiB sent` with non-zero values

If the endpoint shows `127.0.0.1:xxxxx`, you're running the full WG + VLESS + REALITY + Vision chain on iPhone. This is the moment that makes the whole project worth it.

### 4e. iOS tips

- **Always-on / kill switch:** in SFI's profile settings, enable "Include All Networks". If the tunnel drops, traffic stops instead of falling back to direct.
- **Battery:** SFI is efficient, but the chained encryption uses slightly more battery than plain VPN. Toggle off when you don't need it.
- **Background:** iOS keeps SFI running as a NetworkExtension as long as traffic is flowing. If the tunnel drops, swipe down and reconnect.
- **Multiple profiles:** you can have multiple SwizGuard servers as separate profiles in SFI. Useful if you have boxes in different jurisdictions.

## Step 5 — connect Android

### 5a. SFA (full chain, recommended)

1. Install **SFA (Sing-Box For Android)** from Play Store
2. Transfer `singbox-client.json` to your phone (Google Drive, email, USB, whatever)
3. In SFA: Profiles → + → Import from file → select the JSON
4. Dashboard → select → Start → grant VPN permission

### 5b. v2rayNG (full chain via Xray)

1. Install **v2rayNG** from Play Store
2. Transfer `xray-client.json` to your phone
3. v2rayNG: menu → Import config from File → select
4. Tap the V icon to connect, grant VPN permission

Both options give you the full chain. Pick whichever feels nicer to you.

## Step 6 — verify everything end to end

This is the part where you get to confirm with your own eyes that everything works.

### Check your public IP

```bash
# Desktop
curl --socks5 127.0.0.1:10808 -4 ifconfig.me

# Or with system proxy enabled (Safari, browser, etc.)
# Visit ifconfig.me in your browser

# Mobile: visit ifconfig.me in Safari
```

Should return your VPS IP, not your real IP.

### Check for DNS leaks

Visit `https://dnsleaktest.com` through the tunnel. You should see Cloudflare or Google DNS servers — NOT your ISP's. If you see Comcast, Verizon, AT&T, etc. in the list, your DNS is leaking. (See the troubleshooting guide for fixes.)

### Verify the camouflage

This is the most satisfying check. From a machine NOT connected to the tunnel:

```bash
curl -I --resolve www.microsoft.com:443:YOUR_VPS_IP https://www.microsoft.com
```

You should see something like:

```
HTTP/2 200
server: AkamaiGHost
mime-version: 1.0
content-type: text/html
content-length: 421
expires: Wed, 08 Apr 2026 21:58:27 GMT
cache-control: max-age=0, no-cache, no-store
pragma: no-cache
date: Wed, 08 Apr 2026 21:58:27 GMT
```

What just happened: you told curl "resolve `www.microsoft.com` to my VPS IP", then requested the URL. Your VPS received the TLS ClientHello with SNI `www.microsoft.com`, REALITY checked for a valid auth token (curl has none), so it proxied the entire handshake to the real microsoft.com edge. The response came back from Akamai's actual CDN infrastructure with a real DigiCert-signed certificate.

That's what any prober — a censor, a scanner, an IP reputation service — sees when they look at your server. A real Microsoft endpoint, served through Akamai, with a real Microsoft TLS certificate. There's nothing synthetic about it because it literally IS Microsoft's infrastructure responding to the probe.

### Why visiting your VPS IP in a browser shows a cert error

If you visit `https://YOUR_VPS_IP` in Firefox or Chrome, you'll get an `SSL_ERROR_BAD_CERT_DOMAIN` warning saying the certificate is only valid for `www.microsoft.com`, `privacy.microsoft.com`, and related Microsoft domains.

This is a feature, not a bug. REALITY is returning Microsoft's real certificate, which by definition is issued for `*.microsoft.com` and doesn't match a bare IP. This is the same behavior you'd get hitting any Akamai-hosted Microsoft edge server directly by IP — Akamai shared infrastructure never matches IPs to certs, only domains.

An observer inspecting your VPS sees it behave identically to Akamai/Microsoft edge infrastructure. There is no way to distinguish your server from a real Microsoft CDN node through standard network probing.

### Server status

On the VPS:

```bash
sudo ./swizguard status
```

Shows running services, connected peers, and camouflage target.

## Maintenance

### Add a new client later

```bash
sudo ./swizguard add tablet
```

Generates a fresh client package. No need to restart the server or touch existing clients.

### Remove a client

```bash
sudo ./swizguard remove tablet
```

Removes the WireGuard peer, deletes the client directory. Existing clients are unaffected.

### Regenerate a client's configs

If you change server settings (camouflage target, enable Vision, etc.) you need to regen all existing clients so their configs match the new server. Their WireGuard keys and tunnel IPs stay the same:

```bash
sudo ./swizguard regen macbook
sudo ./swizguard regen iphone
```

The script prints detailed redeploy instructions after each regen.

### Upgrade an existing deployment to Vision flow

If you installed SwizGuard before Vision was the default, or you need to enable it on an older server:

```bash
sudo ./swizguard upgrade-vision
```

This rewrites the server config to enable `xtls-rprx-vision` flow. It's destructive to existing clients — you need to regen each one and redeploy. The script warns you before proceeding.

### Rotate REALITY keys

Good practice every 3-6 months:

```bash
sudo ./swizguard rekey
```

Generates a new REALITY x25519 keypair on the server. All clients stop working until you regen and redeploy each one. Don't do this casually — set aside time to regen all your devices afterwards.

### Update Xray-core on the server

```bash
XRAY_VERSION=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | grep '"tag_name"' | cut -d'"' -f4)
curl -sLO "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip"
unzip -o Xray-linux-64.zip xray -d /usr/local/bin/
sudo systemctl restart xray
```

### Full uninstall

```bash
sudo ./swizguard nuke
```

Requires typing "NUKE" to confirm. Removes services, configs, keys, credentials, the wg1 interface, the Xray binary. Clean slate.

## Changing the camouflage target

The default is `www.microsoft.com`. Xray specifically warns against `www.apple.com` and `www.icloud.com` because those have been flagged in some DPI systems — that's why I went with Microsoft as the default.

To change: edit `CAMOUFLAGE_DEST` in `scripts/setup-server.sh` BEFORE running setup, or manually edit `/usr/local/etc/xray/config.json` afterward and restart Xray. You'll also need to regen all clients so their `serverName` field matches the new target.

Good alternatives I'd consider:
- `www.cloudflare.com`
- `www.bing.com`
- `www.github.com`
- `www.amazon.com`

What to avoid:
- `www.apple.com`, `www.icloud.com` — Xray actively warns these may get your IP flagged
- Small or obscure sites — suspicious if your VPS only talks to one weird destination
- CDN-fronted sites with variable IPs — handshake instability
