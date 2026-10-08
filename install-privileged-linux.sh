#!/bin/bash
# One-time privileged setup on a Linux VPN host, so that a cookie handed over
# SSH can bring the tunnel up with NO password prompt.
#
# Run once, on the Linux host:
#   sudo GP_SERVERS="prod=vpn.example.com,fallback=vpn-fallback.example.com" ./install-privileged-linux.sh
#
# Or, from your Mac, which copies these files over and runs it for you:
#   GP_SERVERS=... ./connect-remote.sh --install user@linux-host
#
# GP_SERVER=vpn.example.com works for a single gateway. Every listed gateway is
# baked into the helper's allowlist; re-run this to add or remove one.
#
# Installs:
#   /usr/local/sbin/gp-tunnel        root-owned tunnel helper (hardcoded flags)
#   /usr/local/sbin/gp-vpnc-script   root-owned copy of vpnc-script
#   /usr/local/sbin/gp-hipreport.sh  root-owned HIP report script
#   /etc/sudoers.d/gp-tunnel         NOPASSWD rule scoped to gp-tunnel only
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Please run with sudo: sudo $0" >&2; exit 1; }

REAL_USER="${GP_TUNNEL_USER:-${SUDO_USER:-$(logname 2>/dev/null || echo root)}}"
SRC="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=gp-servers.sh
. "$SRC/gp-servers.sh"
HOSTS="$(gp_server_hosts)" || exit 1

OC="$(command -v openconnect || true)"
[ -n "$OC" ] && [ -x "$OC" ] || {
  echo "openconnect not found on PATH. Install it first, e.g." >&2
  echo "  apt-get install -y openconnect vpnc-scripts   # Debian/Ubuntu" >&2
  echo "  dnf install -y openconnect vpnc-script        # Fedora/RHEL" >&2
  exit 1
}
[ -f "$SRC/gp-tunnel-linux" ] || { echo "gp-tunnel-linux not found next to installer" >&2; exit 1; }

mkdir -p /usr/local/sbin

echo "[*] Installing root-owned tunnel helper (gateways: $HOSTS, openconnect=$OC)..."
TMP_HELPER="$(mktemp)"
sed -e "s|__GP_SERVERS__|$HOSTS|" -e "s|__OPENCONNECT__|$OC|" \
    "$SRC/gp-tunnel-linux" > "$TMP_HELPER"
install -o root -g root -m 0755 "$TMP_HELPER" /usr/local/sbin/gp-tunnel
rm -f "$TMP_HELPER"

# Prefer whatever vpnc-script the distro shipped; fall back to a copy bundled
# next to this installer. (The macOS-patched gp-vpnc-script in this repo is not
# copied over by connect-remote.sh — it is tuned for Darwin.)
VPNC_SRC=""
for cand in /etc/vpnc/vpnc-script /usr/share/vpnc-scripts/vpnc-script \
            /usr/local/etc/vpnc/vpnc-script "$SRC/vpnc-script"; do
  [ -f "$cand" ] && { VPNC_SRC="$cand"; break; }
done
if [ -n "$VPNC_SRC" ]; then
  echo "[*] Installing root-owned vpnc-script copy (from $VPNC_SRC)..."
  install -o root -g root -m 0755 "$VPNC_SRC" /usr/local/sbin/gp-vpnc-script
else
  echo "[!] No vpnc-script found; openconnect's built-in default will be used."
  echo "    If routing/DNS misbehave, install the 'vpnc-scripts' package."
fi

if [ -f "$SRC/gp-hipreport.sh" ]; then
  echo "[*] Installing root-owned HIP report script..."
  install -o root -g root -m 0755 "$SRC/gp-hipreport.sh" /usr/local/sbin/gp-hipreport.sh
else
  echo "[i] No gp-hipreport.sh found; HIP report will not be submitted."
fi

echo "[*] Installing scoped NOPASSWD sudoers rule for $REAL_USER..."
VISUDO="$(command -v visudo || echo /usr/sbin/visudo)"
[ -x "$VISUDO" ] || { echo "visudo not found; cannot safely install sudoers rule" >&2; exit 1; }
grep -qE '^[[:space:]]*#?includedir[[:space:]]+/etc/sudoers.d' /etc/sudoers \
  || grep -qE '^[[:space:]]*@includedir[[:space:]]+/etc/sudoers.d' /etc/sudoers \
  || echo "[!] /etc/sudoers does not appear to include /etc/sudoers.d; the rule may be ignored." >&2

mkdir -p /etc/sudoers.d
RULE="/etc/sudoers.d/gp-tunnel"
TMP="$(mktemp)"
printf '%s ALL=(root) NOPASSWD: /usr/local/sbin/gp-tunnel\n' "$REAL_USER" > "$TMP"
# validate BEFORE installing so we never leave a broken sudoers file
if "$VISUDO" -cf "$TMP" >/dev/null 2>&1; then
  install -o root -g root -m 0440 "$TMP" "$RULE"
  rm -f "$TMP"
  echo "[✓] Done. '$REAL_USER' can now bring up the tunnel with no password."
else
  rm -f "$TMP"
  echo "[!] sudoers validation failed; nothing installed for sudo." >&2
  exit 1
fi
