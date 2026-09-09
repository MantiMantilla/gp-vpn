#!/bin/bash
# Bring up the GlobalProtect VPN on a *remote Linux host*, using the Okta
# session live in Chrome on *this Mac*.
#
# The cookie is captured locally (exactly as ./connect.sh does) and pushed to
# the remote root helper over the SSH channel's stdin, so it never touches the
# remote disk and never appears in an argv / `ps` listing on either side.
#
# Usage:
#   GP_SERVER=vpn.example.com ./connect-remote.sh [options] user@linux-host
#
# Options:
#   --install      copy the helper files to the host and run the one-time
#                  privileged installer there (asks for the remote sudo
#                  password once), then exit
#   --background   start the tunnel detached on the host and return
#   --stop         tear down a backgrounded tunnel on the host and exit
#
# Env:
#   GP_SSH_OPTS         extra ssh options, e.g. GP_SSH_OPTS="-p 2222 -i ~/k.pem"
#   GP_PIN_SSH_ROUTE=0  don't pin a route back to this Mac on the remote host
#                       (only do this if you reach the host through the VPN)
#
# Disconnect: Ctrl+C (foreground) or --stop (background).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER=/usr/local/sbin/gp-tunnel

ACTION=connect
MODE=foreground
TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --install)            ACTION=install ;;
    --stop)               ACTION=stop ;;
    --background|--detach) MODE=background ;;
    -h|--help)            sed -n '2,25p' "$0"; exit 0 ;;
    -*)  echo "[!] unknown option: $1 (pass ssh flags via GP_SSH_OPTS)" >&2; exit 64 ;;
    *)   [ -z "$TARGET" ] || { echo "[!] more than one ssh target given" >&2; exit 64; }
         TARGET="$1" ;;
  esac
  shift
done
: "${TARGET:?Give an ssh target, e.g. ./connect-remote.sh user@linux-host}"

SERVER="${GP_SERVER:?Set GP_SERVER to your VPN gateway hostname, e.g. vpn.example.com}"
case "$SERVER" in
  *[!A-Za-z0-9.-]*) echo "[!] GP_SERVER must be a bare hostname" >&2; exit 1 ;;
esac

SSH_OPTS=()
[ -n "${GP_SSH_OPTS:-}" ] && read -r -a SSH_OPTS <<< "$GP_SSH_OPTS"
ssh_run() { ssh ${SSH_OPTS[@]+"${SSH_OPTS[@]}"} "$TARGET" "$@"; }

# --- one-time install -------------------------------------------------------
if [ "$ACTION" = install ]; then
  echo "[*] Copying helper files to $TARGET..."
  RTMP=$(ssh_run 'mktemp -d /tmp/gp-vpn.XXXXXXXX')
  # gp-vpnc-script is deliberately not shipped: it is the macOS-patched copy.
  # The remote installer picks up the distro's own vpnc-script instead.
  tar -cf - -C "$DIR" gp-tunnel-linux install-privileged-linux.sh gp-hipreport.sh \
    | ssh_run "tar -xf - -C $RTMP"
  echo "[*] Running the one-time privileged installer (remote sudo password may be needed)..."
  ssh -t ${SSH_OPTS[@]+"${SSH_OPTS[@]}"} "$TARGET" \
    "cd $RTMP && sudo GP_SERVER=$SERVER bash ./install-privileged-linux.sh; rm -rf $RTMP"
  echo "[✓] $TARGET is ready. Connect with: GP_SERVER=$SERVER $0 $TARGET"
  exit 0
fi

# --- stop -------------------------------------------------------------------
if [ "$ACTION" = stop ]; then
  ssh_run "sudo -n $HELPER stop"
  exit 0
fi

# --- connect ----------------------------------------------------------------
# One round trip that both checks the remote side is ready — *before* burning a
# short-lived cookie on it — and reports the address the host sees us at.
PROBE='[ -x HELPER ] && sudo -n -l HELPER >/dev/null 2>&1 || exit 0
if pgrep -x openconnect >/dev/null 2>&1; then s=busy; else s=free; fi
printf "ready %s %s\n" "${SSH_CLIENT%% *}" "$s"'
PREFLIGHT=$(ssh_run "/bin/sh -c '${PROBE//HELPER/$HELPER}'" 2>/dev/null || true)
# shellcheck disable=SC2086
set -- $PREFLIGHT
if [ "${1:-}" != ready ]; then
  echo "[!] $TARGET has no passwordless gp-tunnel helper installed." >&2
  echo "    Run once:  GP_SERVER=$SERVER $0 --install $TARGET" >&2
  exit 1
fi
PEER="${2:-}"
if [ "${3:-}" = busy ]; then
  echo "[!] $TARGET already has a tunnel up; not capturing a second cookie." >&2
  echo "    Tear it down first:  GP_SERVER=$SERVER $0 --stop $TARGET" >&2
  exit 1
fi
[ "${GP_PIN_SSH_ROUTE:-1}" = 0 ] && PEER=""

# The cookie reaches ssh through a FIFO rather than a plain pipe so we can keep
# the write end open (fd 9) for the whole session. A named pipe holds no data
# on disk; this is purely so the remote helper can tell, by EOF, that the SSH
# session went away and the tunnel should come down with it.
FIFO_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gp-vpn.XXXXXXXX")
chmod 700 "$FIFO_DIR"
FIFO="$FIFO_DIR/creds"
mkfifo -m 600 "$FIFO"

# Never leave the captured cookie on disk: remove it whenever this script exits
# (clean disconnect, Ctrl+C, or capture failure).
trap 'rm -rf "$FIFO_DIR"; rm -f "$DIR/auth.json"' EXIT INT TERM HUP
cd "$DIR"

echo "[*] Capturing GlobalProtect gateway cookie via your Chrome Okta session..."
# clientos must match the machine that redeems the cookie, not this Mac.
uv run gp_connect.py "$SERVER" --gateway --client-os=Linux

USER_ID=$(python3 -c "import json;d=json.load(open('auth.json'));c=d.get('captured',d);print(c['saml-username'])")
COOKIE=$(python3 -c "import json;d=json.load(open('auth.json'));c=d.get('captured',d);print(c['prelogin-cookie'])")

if [ -z "${COOKIE:-}" ]; then
  echo "[!] No cookie captured. Is Chrome logged into Okta? Try: uv run gp_connect.py $SERVER --gateway --client-os=Linux --headed" >&2
  exit 1
fi

echo "[*] Cookie OK for $USER_ID. Bringing up the tunnel on $TARGET ($MODE)..."
# Opened read-write so this never blocks waiting for ssh to become the reader;
# fd 9 is only ever written to, and closing it at exit is what gives the remote
# helper its EOF.
exec 9<>"$FIFO"
printf '%s\n%s\n%s\n' "$USER_ID" "$COOKIE" "$PEER" >&9
ssh_run "sudo -n $HELPER $MODE" <"$FIFO"
