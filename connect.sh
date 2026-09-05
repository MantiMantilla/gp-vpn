#!/bin/bash
# Connect to a GlobalProtect VPN by reusing your live Chrome Okta session.
#   1. headless-captures a fresh gateway SAML cookie (no VPN login needed)
#   2. brings up the openconnect tunnel (needs sudo for the tun device)
#
# Usage:  GP_SERVER=vpn.example.com ~/gp-vpn/connect.sh
# Disconnect: Ctrl+C in this terminal.
set -euo pipefail

DIR="$HOME/gp-vpn"
SERVER="${GP_SERVER:?Set GP_SERVER to your VPN gateway hostname, e.g. vpn.example.com}"
cd "$DIR"

# Never leave the captured cookie on disk: remove it whenever this script exits
# (clean disconnect, Ctrl+C, or capture failure). The cookie is held in shell
# variables for the tunnel, so the file isn't needed after it's read.
trap 'rm -f "$DIR/auth.json"' EXIT

echo "[*] Capturing GlobalProtect gateway cookie via your Chrome Okta session..."
uv run gp_connect.py "$SERVER" --gateway

USER_ID=$(python3 -c "import json;d=json.load(open('auth.json'));c=d.get('captured',d);print(c['saml-username'])")
COOKIE=$(python3 -c "import json;d=json.load(open('auth.json'));c=d.get('captured',d);print(c['prelogin-cookie'])")

if [ -z "${COOKIE:-}" ]; then
  echo "[!] No cookie captured. Is Chrome logged into Okta? Try: uv run gp_connect.py $SERVER --gateway --headed"
  exit 1
fi

if [ -x /usr/local/sbin/gp-tunnel ] && sudo -n -l /usr/local/sbin/gp-tunnel >/dev/null 2>&1; then
  echo "[*] Cookie OK for $USER_ID. Bringing up tunnel (passwordless helper)..."
  printf '%s\n%s\n' "$USER_ID" "$COOKIE" | sudo -n /usr/local/sbin/gp-tunnel
else
  echo "[*] Cookie OK for $USER_ID. Bringing up tunnel (sudo password required)."
  echo "    Tip: run 'sudo ~/gp-vpn/install-privileged.sh' once to make this passwordless."
  printf '%s\n' "$COOKIE" | sudo openconnect \
    --protocol=gp --user="$USER_ID" \
    --usergroup=gateway:prelogin-cookie --passwd-on-stdin "$SERVER"
fi
