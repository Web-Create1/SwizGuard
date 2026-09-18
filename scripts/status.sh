#!/bin/bash
#
# SwizGuard status — quick health check
#
# Usage: sudo bash status.sh

set -euo pipefail

R='\033[91m' G='\033[92m' Y='\033[93m' C='\033[96m' B='\033[1m' X='\033[0m'

echo -e "${C}${B}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║              SwizGuard status                       ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${X}"

# Xray
if systemctl is-active --quiet xray 2>/dev/null; then
    echo -e "  ${G}[+]${X} Xray:      running"
else
    echo -e "  ${R}[✗]${X} Xray:      stopped"
fi

# WireGuard
if ip link show wg1 &>/dev/null; then
    echo -e "  ${G}[+]${X} WireGuard: running"
    PEER_LIST=$(wg show wg1 peers || true)
    PEERS=$(printf '%s' "$PEER_LIST" | grep -c . || true)
    echo -e "  ${C}[*]${X} Peers:     $PEERS configured"

    # Show connected peers (those with recent handshake)
    echo ""
    echo -e "  ${B}Connected peers:${X}"
    if [ -z "$PEER_LIST" ]; then
        echo "    (none yet — add one with: sudo ./swizguard add <name>)"
    fi
    while IFS= read -r peer; do
        [ -n "$peer" ] || continue
        LAST=$(wg show wg1 latest-handshakes | grep -F "$peer" | awk '{print $2}' || true)
        NAME=$(grep -B1 -F "$peer" /etc/wireguard/wg1.conf 2>/dev/null | grep "^#" | sed 's/^# //' || echo "unknown")
        NOW=$(date +%s)
        if [ -n "$LAST" ] && [ "$LAST" -ne 0 ]; then
            AGO=$(( NOW - LAST ))
            if [ $AGO -lt 180 ]; then
                echo -e "    ${G}●${X} $NAME — last handshake ${AGO}s ago"
            else
                echo -e "    ${Y}○${X} $NAME — last handshake ${AGO}s ago"
            fi
        else
            echo -e "    ${R}○${X} $NAME — never connected"
        fi
    done <<< "$PEER_LIST"
else
    echo -e "  ${R}[✗]${X} WireGuard: stopped"
fi

# Ports
echo ""
echo -e "  ${B}Listening ports:${X}"
ss -tlnp 2>/dev/null | { grep -E "(xray|wireguard)" || true; } | while read -r line; do
    echo "    $line"
done

# REALITY check — verify camouflage is working
echo ""
SWIZ_DIR="/etc/swizguard"
if [ -f "$SWIZ_DIR/credentials.env" ]; then
    source "$SWIZ_DIR/credentials.env"
    echo -e "  ${B}Camouflage:${X}  $CAMOUFLAGE_DEST"
    echo -e "  ${B}Server IP:${X}   $SERVER_IP"
    echo -e "  ${B}REALITY port:${X} $XRAY_PORT/tcp"
fi

echo ""
