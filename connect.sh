#!/bin/bash
# Connect to a GlobalProtect VPN by reusing your live Chrome Okta session.
#   1. headless-captures a fresh gateway SAML cookie (no VPN login needed)
#   2. brings up the openconnect tunnel (needs sudo for the tun device)
#
# Usage:
#   ./connect.sh [GATEWAY]   connect to GATEWAY, a name or hostname from
#                            GP_SERVERS (default: the first one). If a tunnel
#                            is already up, switch it over to GATEWAY.
#   ./connect.sh --list      show the configured gateways
#   ./connect.sh --stop      disconnect, from any terminal
#
# Env:
#   GP_SERVERS="prod=vpn.example.com,fallback=vpn-fallback.example.com"
#   (or GP_SERVER=vpn.example.com for a single gateway)
#
# Disconnect: Ctrl+C in this terminal, or --stop.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER=/usr/local/sbin/gp-tunnel
# shellcheck source=gp-servers.sh
. "$DIR/gp-servers.sh"

helper_ok() { [ -x "$HELPER" ] && sudo -n -l "$HELPER" >/dev/null 2>&1; }
# Helpers installed before multi-gateway support hardcode one server and would
# silently ignore the gateway we ask for.
helper_current() { grep -q '^SERVERS=' "$HELPER" 2>/dev/null; }

tunnel_up() { pgrep -x openconnect >/dev/null 2>&1; }

stop_tunnel() {
  if helper_ok && helper_current; then
    sudo -n "$HELPER" stop
  else
    echo "[*] Disconnecting (sudo password required)..."
    sudo kill -INT $(pgrep -x openconnect)
    for _ in $(seq 1 20); do tunnel_up || break; sleep 1; done
  fi
  if tunnel_up; then
    echo "[!] openconnect is still running; not starting another tunnel." >&2
    exit 1
  fi
}

case "${1:-}" in
  --list)
    gp_require_servers
    echo "Gateways (use: $0 NAME):"
    gp_list_servers
    exit 0 ;;
  --stop)
    if tunnel_up; then stop_tunnel; else echo "[i] No tunnel is running."; fi
    exit 0 ;;
  -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
  -*) echo "[!] unknown option: $1 (see --help)" >&2; exit 64 ;;
esac
[ $# -le 1 ] || { echo "[!] give at most one gateway (see --help)" >&2; exit 64; }

SERVER=$(gp_resolve_server "${1:-}")

if helper_ok && ! helper_current; then
  echo "[!] The installed gp-tunnel helper predates gateway switching." >&2
  echo "    Reinstall it once: sudo GP_SERVERS=\"\$GP_SERVERS\" $DIR/install-privileged.sh" >&2
  exit 1
fi

# Never leave the captured cookie on disk: remove it whenever this script exits
# (clean disconnect, Ctrl+C, or capture failure). The cookie is held in shell
# variables for the tunnel, so the file isn't needed after it's read.
trap 'rm -f "$DIR/auth.json"' EXIT INT TERM HUP
cd "$DIR"

echo "[*] Capturing GlobalProtect gateway cookie for $SERVER via your Chrome Okta session..."
uv run gp_connect.py "$SERVER" --gateway

USER_ID=$(python3 -c "import json;d=json.load(open('auth.json'));c=d.get('captured',d);print(c['saml-username'])")
COOKIE=$(python3 -c "import json;d=json.load(open('auth.json'));c=d.get('captured',d);print(c['prelogin-cookie'])")
rm -f "$DIR/auth.json"

if [ -z "${COOKIE:-}" ]; then
  echo "[!] No cookie captured. Is Chrome logged into Okta? Try: uv run gp_connect.py $SERVER --gateway --headed"
  exit 1
fi

# Switching: only drop the current tunnel once the new cookie is in hand, so a
# failed capture leaves you connected where you were.
if tunnel_up; then
  echo "[*] A tunnel is already up; disconnecting it to switch to $SERVER..."
  stop_tunnel
fi

if helper_ok; then
  echo "[*] Cookie OK for $USER_ID. Bringing up tunnel to $SERVER (passwordless helper)..."
  printf '%s\n%s\n' "$USER_ID" "$COOKIE" | sudo -n "$HELPER" "$SERVER"
else
  echo "[*] Cookie OK for $USER_ID. Bringing up tunnel to $SERVER (sudo password required)."
  echo "    Tip: run 'sudo GP_SERVERS=\"\$GP_SERVERS\" $DIR/install-privileged.sh' once to make this passwordless."
  printf '%s\n' "$COOKIE" | sudo openconnect \
    --protocol=gp --user="$USER_ID" \
    --usergroup=gateway:prelogin-cookie --passwd-on-stdin "$SERVER"
fi
