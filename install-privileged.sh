#!/bin/bash
# One-time privileged setup so future VPN connects need NO password.
# Run once:   sudo GP_SERVER=vpn.example.com ~/gp-vpn/install-privileged.sh
#
# Installs:
#   /usr/local/sbin/gp-tunnel        root-owned tunnel helper (hardcoded flags)
#   /usr/local/sbin/gp-vpnc-script   root-owned copy of vpnc-script
#   /etc/sudoers.d/gp-tunnel         NOPASSWD rule scoped to gp-tunnel only
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Please run with sudo: sudo $0" >&2; exit 1; }

: "${GP_SERVER:?Set GP_SERVER to your VPN gateway hostname, e.g. sudo GP_SERVER=vpn.example.com $0}"

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
SRC="$(cd "$(dirname "$0")" && pwd)"
VPNC_SRC="/opt/homebrew/etc/vpnc/vpnc-script"
OC="/opt/homebrew/bin/openconnect"

[ -x "$OC" ] || { echo "openconnect not found at $OC" >&2; exit 1; }
[ -f "$SRC/gp-tunnel" ] || { echo "gp-tunnel not found next to installer" >&2; exit 1; }

mkdir -p /usr/local/sbin

echo "[*] Installing root-owned tunnel helper (server=$GP_SERVER)..."
sed "s/__GP_SERVER__/$GP_SERVER/" "$SRC/gp-tunnel" > "$SRC/.gp-tunnel.tmp"
install -o root -g wheel -m 0755 "$SRC/.gp-tunnel.tmp" /usr/local/sbin/gp-tunnel
rm -f "$SRC/.gp-tunnel.tmp"

# Prefer our patched copy (guards the noisy networksetup DNS fallback); else stock.
if [ -f "$SRC/gp-vpnc-script" ]; then
  echo "[*] Installing root-owned patched vpnc-script..."
  install -o root -g wheel -m 0755 "$SRC/gp-vpnc-script" /usr/local/sbin/gp-vpnc-script
elif [ -f "$VPNC_SRC" ]; then
  echo "[*] Installing root-owned vpnc-script copy (stock)..."
  install -o root -g wheel -m 0755 "$VPNC_SRC" /usr/local/sbin/gp-vpnc-script
else
  echo "[!] No vpnc-script found; openconnect default script will be used."
fi

if [ -f "$SRC/gp-hipreport.sh" ]; then
  echo "[*] Installing root-owned HIP report script..."
  install -o root -g wheel -m 0755 "$SRC/gp-hipreport.sh" /usr/local/sbin/gp-hipreport.sh
else
  echo "[i] No gp-hipreport.sh found; HIP report will not be submitted."
fi

echo "[*] Installing scoped NOPASSWD sudoers rule for $REAL_USER..."
RULE="/etc/sudoers.d/gp-tunnel"
TMP="$(mktemp)"
printf '%s ALL=(root) NOPASSWD: /usr/local/sbin/gp-tunnel\n' "$REAL_USER" > "$TMP"
# validate BEFORE installing so we never leave a broken sudoers file
if visudo -cf "$TMP" >/dev/null 2>&1; then
  install -o root -g wheel -m 0440 "$TMP" "$RULE"
  rm -f "$TMP"
  echo "[✓] Done. '$REAL_USER' can now bring up the tunnel with no password."
else
  rm -f "$TMP"
  echo "[!] sudoers validation failed; nothing installed for sudo." >&2
  exit 1
fi
