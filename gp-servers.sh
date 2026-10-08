# Gateway selection shared by connect.sh, connect-remote.sh and the installers.
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
