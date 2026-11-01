# Gateway selection (and stale-route cleanup) shared by connect.sh,
# connect-remote.sh and the installers.
# Sourced, not executed. Must stay bash-3.2 compatible (macOS /bin/bash).
#
# GP_SERVERS lists the gateways you can connect to, comma-separated, each
# either a bare hostname or name=hostname. The first entry is the default:
#
#   GP_SERVERS="prod=vpn.example.com,fallback=vpn-fallback.example.com"
#
# A single GP_SERVER=vpn.example.com still works when there is only one.

# One entry per line, from GP_SERVERS (or GP_SERVER).
gp_server_entries() {
  printf '%s\n' "${GP_SERVERS:-${GP_SERVER:-}}" | tr ', ' '\n\n' | sed '/^$/d'
}

gp_require_servers() {
  [ -n "${GP_SERVERS:-${GP_SERVER:-}}" ] && return 0
  echo "[!] Set GP_SERVERS to your gateway(s), e.g." >&2
  echo "    GP_SERVERS=\"prod=vpn.example.com,fallback=vpn-fallback.example.com\"" >&2
  return 1
}

# Hostname part of an entry, rejected unless it is a bare hostname: it gets
# baked into a root-owned helper and passed to openconnect.
_gp_entry_host() {
  local host="${1#*=}"
  case "$host" in
    ''|*[!A-Za-z0-9.-]*) echo "[!] '$host' is not a bare hostname (in GP_SERVERS)" >&2; return 1 ;;
  esac
  printf '%s\n' "$host"
}

# Print the hostname for a name, a hostname, or (no argument) the default.
gp_resolve_server() {
  local want="${1:-}" entry name host
  gp_require_servers || return 1
  while read -r entry; do
    name="${entry%%=*}"
    host=$(_gp_entry_host "$entry") || return 1
    if [ -z "$want" ] || [ "$want" = "$name" ] || [ "$want" = "$host" ]; then
      printf '%s\n' "$host"
      return 0
    fi
  done < <(gp_server_entries)
  echo "[!] Unknown VPN '$want'. Known gateways:" >&2
  gp_list_servers >&2
  return 1
}

# All hostnames, comma-separated, for baking into a helper's allowlist.
gp_server_hosts() {
  local entry host hosts=""
  gp_require_servers || return 1
  while read -r entry; do
    host=$(_gp_entry_host "$entry") || return 1
    hosts="${hosts:+$hosts,}$host"
  done < <(gp_server_entries)
  printf '%s\n' "$hosts"
}

# --- Stale gateway routes (macOS) --------------------------------------------
# A tunnel pins a host route to its gateway via the LAN router. If openconnect
# dies without its teardown (sleep, crash, kill) or the Mac changes networks
# mid-session, that route outlives the tunnel and points at a router that is no
# longer there, so even the cookie capture can't reach the gateway
# ("Can't assign requested address").

# IPv4 addresses of gateway $1 that have a host route via something other
# than the current default gateway.
gp_stale_gateway_routes() {
  local def ip out gw
  def=$(route -n get default 2>/dev/null | awk '/gateway:/ {print $2}')
  for ip in $(dscacheutil -q host -a name "$1" | awk '/^ip_address:/ {print $2}'); do
    out=$(route -n get "$ip" 2>/dev/null) || continue
    printf '%s\n' "$out" | grep -q "destination: $ip\$" || continue
    gw=$(printf '%s\n' "$out" | awk '/gateway:/ {print $2}')
    [ -n "$gw" ] && [ "$gw" != "$def" ] && printf '%s\n' "$ip"
  done
  return 0
}

# Remove them before capturing a cookie for gateway $1. Skipped while a local
# tunnel is up, since that tunnel needs its route. Uses the passwordless
# helper when it is new enough, else plain sudo.
gp_clear_stale_gateway_routes() {
  local helper=/usr/local/sbin/gp-tunnel stale ip
  [ "$(uname -s)" = Darwin ] || return 0
  pgrep -x openconnect >/dev/null 2>&1 && return 0
  stale=$(gp_stale_gateway_routes "$1")
  [ -n "$stale" ] || return 0
  echo "[*] Found a stale route to $1 left by an earlier tunnel; removing it..."
  if grep -q 'gp-tunnel unroute' "$helper" 2>/dev/null && sudo -n "$helper" unroute "$1"; then
    return 0
  fi
  for ip in $stale; do
    sudo route -n delete -host "$ip" >/dev/null ||
      echo "[!] Could not remove the route to $ip; the capture will likely fail." >&2
  done
}

gp_list_servers() {
  local entry first=1
  while read -r entry; do
    case "$entry" in
      *=*) printf '    %-10s %s' "${entry%%=*}" "${entry#*=}" ;;
      *)   printf '    %s' "$entry" ;;
    esac
    [ "$first" = 1 ] && printf '  (default)'
    printf '\n'
    first=0
  done < <(gp_server_entries)
}
