#!/usr/bin/env bash
#
# Converts a generated SwizGuard client into the config a Raspberry Pi router
# needs to carry an entire LAN through the tunnel.
#
#   sudo ./scripts/make-router-config.sh pi-router
#   sudo ./scripts/make-router-config.sh pi-router --wan-iface wan0 --out /tmp/config.json
#
# Run this on the VPS, where /etc/swizguard/clients/<name>/ lives. Copy the
# result to the Pi at /etc/sing-box/config.json and chmod 600 it.
#
# The desktop client is a SOCKS proxy that only the apps you point at it use.
# This is different: it is a TUN device that a router forwards a whole network
# into. Five fields have to change and each one is load-bearing. The reasons
# are in the pi5-privacy-router repo, config/singbox-router.md.
#
# This writes a file and nothing else. It does not touch the firewall, the
# routing table, or any running service.

set -euo pipefail

R='\033[91m' G='\033[92m' Y='\033[93m' B='\033[1m' X='\033[0m'
info() { echo -e "  ${B}[*]${X} $1"; }
ok()   { echo -e "  ${G}[+]${X} $1"; }
warn() { echo -e "  ${Y}[!]${X} $1"; }
fail() { echo -e "  ${R}[x]${X} $1" >&2; exit 1; }

CLIENT_NAME=""
WAN_IFACE="wan0"
TUN_IFACE="sb0"
OUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --wan-iface) WAN_IFACE="$2"; shift 2 ;;
        --tun-iface) TUN_IFACE="$2"; shift 2 ;;
        --out)       OUT="$2";       shift 2 ;;
        -h|--help)   sed -n '3,18p' "$0" | sed 's/^# \?//'; exit 0 ;;
        -*)          fail "unknown option: $1" ;;
        *)           CLIENT_NAME="$1"; shift ;;
    esac
done

[ -n "$CLIENT_NAME" ] || fail "usage: $0 <client-name> [--wan-iface wan0] [--out path]"
command -v python3 >/dev/null 2>&1 || fail "python3 is required to rewrite the config"

# Accept either a client name under /etc/swizguard or a path to the json.
if [ -f "$CLIENT_NAME" ]; then
    SRC="$CLIENT_NAME"
else
    SRC="/etc/swizguard/clients/${CLIENT_NAME}/singbox-client.json"
fi
[ -r "$SRC" ] || fail "cannot read $SRC. Run: sudo ./swizguard add $CLIENT_NAME"

OUT="${OUT:-/etc/swizguard/clients/${CLIENT_NAME}/singbox-router.json}"
info "source: $SRC"

python3 - "$SRC" "$OUT" "$WAN_IFACE" "$TUN_IFACE" <<'PY'
import json, sys, ipaddress

src, out, wan, tun = sys.argv[1:5]
c = json.load(open(src))

def first(seq, pred, what):
    for x in seq:
        if pred(x):
            return x
    sys.exit(f"  [x] no {what} in the source config. Is this a SwizGuard client?")

vless = first(c.get("outbounds", []), lambda o: o.get("type") == "vless", "vless outbound")
wgep  = first(c.get("endpoints", []), lambda e: e.get("type") == "wireguard", "wireguard endpoint")

# The client's tunnel address, IPv4 only. The router build runs with IPv6
# disabled at the kernel, because every nftables rule in that repo lives in the
# ip family and enabling v6 routes around all of them.
v4 = first(wgep.get("address", []),
           lambda a: ":" not in a, "IPv4 address on the wireguard endpoint")
wg_net = ipaddress.ip_network(v4, strict=False)
server_net = ipaddress.ip_network(f"{wg_net.network_address}/24", strict=False)

peer = wgep["peers"][0]

router = {
    "log": {"level": "warn", "timestamp": True},

    # AdGuard Home owns DNS on the router. sing-box must not answer any, and
    # must not hijack any: two resolvers answering the same queries means no
    # way to predict which one wins.
    "dns": {
        "servers": [{"tag": "local", "address": "127.0.0.1", "detour": "direct"}],
        "strategy": "ipv4_only",
        "disable_cache": True,
    },

    "inbounds": [{
        "type": "tun",
        "tag": "tun-in",
        "interface_name": tun,
        "address": ["172.19.0.1/30"],
        "mtu": 1280,
        # auto_route writes its own nftables table and ip rules. On a box whose
        # guarantee is that the ruleset has exactly one author, that is the one
        # thing it must not do. Routes come from sb0-routes.sh instead.
        "auto_route": False,
        "strict_route": False,
        # The system stack hands packets to the host's own TCP/IP stack, which
        # expects them to be addressed to the host. A router's packets are
        # addressed to someone else.
        "stack": "gvisor",
    }],

    "outbounds": [
        {
            "type": "vless",
            "tag": "proxy",
            "server": vless["server"],
            "server_port": vless.get("server_port", 443),
            "uuid": vless["uuid"],
            "flow": vless.get("flow", "xtls-rprx-vision"),
            "network": "tcp",
            "packet_encoding": vless.get("packet_encoding", "xudp"),
            "domain_strategy": "ipv4_only",
            "tls": vless["tls"],
        },
        {"type": "direct", "tag": "direct"},
    ],

    "endpoints": [{
        "type": "wireguard",
        "tag": "wg-out",
        "system": False,
        "mtu": wgep.get("mtu", 1280),
        "address": [v4],
        "private_key": wgep["private_key"],
        "peers": [{
            "address": peer["address"],
            "port": peer["port"],
            "public_key": peer["public_key"],
            "allowed_ips": ["0.0.0.0/0"],
            "persistent_keepalive_interval": peer.get(
                "persistent_keepalive_interval", 25),
        }],
        "detour": "proxy",
    }],

    "route": {
        "rules": [
            {"action": "sniff"},
            # Ahead of the private-address reject below, so a resolver you run
            # on the VPS stays reachable. Without this ordering the symptom is
            # total DNS failure with a tunnel that looks perfectly healthy.
            {"ip_cidr": [str(server_net)], "outbound": "wg-out"},
            # Everything else in RFC 1918 has no business crossing the
            # Atlantic. Rejecting keeps the LAN's address plan off the VPS and
            # turns a misroute into an error instead of a timeout.
            {"ip_is_private": True, "action": "reject"},
            {"inbound": "tun-in", "outbound": "wg-out"},
        ],
        "final": "wg-out",
        # This is what makes the routing loop impossible rather than merely
        # unlikely. sing-box's own socket to the VPS binds to the WAN device
        # and skips the routing table, so the default route can point at the
        # tunnel without the tunnel trying to carry itself.
        "default_interface": wan,
        "auto_detect_interface": False,
    },
}

json.dump(router, open(out, "w"), indent=4)
open(out, "a").write("\n")
print(f"  [+] wrote {out}")
print(f"  [*] server {vless['server']}:{vless.get('server_port', 443)}"
      f"  sni {vless['tls'].get('server_name')}")
print(f"  [*] tunnel address {v4}, VPS side reachable at {list(server_net.hosts())[0]}")
PY

chmod 600 "$OUT"
ok "mode 600 (it holds a WireGuard private key)"

cat <<NEXT

  On the Pi:

    sudo install -m 600 -D $OUT /etc/sing-box/config.json
    sudo sing-box check -c /etc/sing-box/config.json

  Then pick up at phase 5.4 of pi5-privacy-router/docs/build-phases-4-7.md.

NEXT
warn "This config binds sing-box's outbound socket to \"$WAN_IFACE\". If your"
warn "router names its WAN something else, the tunnel will not come up and the"
warn "log will not obviously say why."
