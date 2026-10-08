# gp-vpn

Connect to a Palo Alto GlobalProtect VPN without a separate login prompt, by
reusing the Okta SSO session already live in your Chrome profile — either on
this Mac, or on a remote Linux box you SSH into.

## How it works

1. [`gp_connect.py`](gp_connect.py) reads Chrome's cookie database, decrypts
   the Okta/company cookies using the macOS Keychain "Chrome Safe Storage"
   key, replays them in an automated browser (Playwright) to complete the
   GlobalProtect SAML flow, and captures the resulting `prelogin-cookie` +
   username to `auth.json`.
2. [`connect.sh`](connect.sh) reads that cookie and hands it to `openconnect
   --protocol=gp` to bring up the actual tunnel — either via a passwordless
   root helper ([`gp-tunnel`](gp-tunnel), installed once by
   [`install-privileged.sh`](install-privileged.sh)) or with a normal `sudo`
   prompt.
3. `auth.json` is deleted the moment the script exits (clean disconnect,
   Ctrl+C, or failure) — the cookie never lingers on disk.

No VPN password is ever entered manually; the SAML token comes from your
existing browser session.

For a remote Linux host, [`connect-remote.sh`](connect-remote.sh) does the same
capture on your Mac and hands the cookie to the host over the SSH channel's
stdin — see [Remote Linux hosts](#remote-linux-hosts) below.

## Requirements

- macOS, with Chrome signed into your org's Okta (this is always the machine
  that captures the cookie, even when the tunnel runs elsewhere)
- [`openconnect`](https://formulae.brew.sh/formula/openconnect) (`brew install openconnect`)
- [`uv`](https://docs.astral.sh/uv/), plus a Playwright browser:

```bash
uv sync
uv run playwright install chromium
```

## Setup

List your GlobalProtect gateways in `GP_SERVERS`, comma-separated, each either
a bare hostname or `name=hostname`. The first one is the default. (With only
one gateway, `GP_SERVER=vpn.example.com` works too.) Optionally set
`GP_COOKIE_DOMAINS` (comma-separated) if your Okta-fronted domains differ from
the gateway's own domain.

```bash
export GP_SERVERS="prod=vpn.example.com,fallback=vpn-fallback.example.com"
```

To avoid a `sudo` password prompt on every connect, install the scoped
root helper once:

```bash
sudo GP_SERVERS="$GP_SERVERS" ./install-privileged.sh
```

This installs a root-owned `gp-tunnel` (with the gateway hostnames baked in as
an allowlist), a copy of `vpnc-script`, and a `sudoers.d` rule that lets your
user run only that one helper without a password. Re-run it whenever you add
or remove a gateway.

## Usage

```bash
./connect.sh             # connect to the default (first) gateway
./connect.sh fallback    # connect to another one, by name or hostname
./connect.sh --list      # show the configured gateways
./connect.sh --stop      # disconnect, from any terminal
```

Running `./connect.sh <other>` while a tunnel is up switches to it: the new
gateway's cookie is captured first, and only then is the current tunnel taken
down, so a failed capture leaves you connected where you were.

Disconnect with Ctrl+C, or `--stop` (which needs no password with the helper
installed).

## Remote Linux hosts

To put a Linux server on the VPN using the Okta session in *your* Chrome, run
the one-time installer on that host (it needs `openconnect`, and the
`vpnc-scripts` package for sane routing/DNS):

```bash
./connect-remote.sh --install user@linux-host
```

That copies [`gp-tunnel-linux`](gp-tunnel-linux),
[`install-privileged-linux.sh`](install-privileged-linux.sh) and the HIP script
over, and installs the same root-owned-helper + scoped `NOPASSWD` sudoers
arrangement used on the Mac, with the same `GP_SERVERS` allowlist. It asks for
the remote sudo password once.

Then connect:

```bash
./connect-remote.sh user@linux-host                  # Ctrl+C to disconnect
./connect-remote.sh --server fallback user@host       # pick a gateway
./connect-remote.sh --background user@host            # detached
./connect-remote.sh --stop user@host                  # tear down
```

Extra ssh flags go in `GP_SSH_OPTS`, e.g. `GP_SSH_OPTS="-p 2222 -i ~/key.pem"`.

Three details make this work:

- **The cookie is bound to a client OS.** The remote capture requests prelogin
  with `clientos=Linux` (`gp_connect.py --client-os=Linux`) so the cookie
  matches the `openconnect --os=linux` that will redeem it.
- **The tunnel would otherwise cut your SSH session.** The gateway pushes a
  default route, which black-holes the connection that is feeding it the
  cookie. Before starting openconnect, the helper pins a host route back to
  the address the server sees you coming from, and removes it on disconnect.
  Set `GP_PIN_SSH_ROUTE=0` to skip that (only if you reach the host *through*
  the VPN already).
- **Ctrl+C has to reach across the SSH connection.** A non-tty SSH session
  sends no `SIGHUP` when the client disappears, and openconnect reads `SIGHUP`
  as "detach and keep running" — so a naive setup strands an orphaned tunnel
  holding the box's default route. Instead the client keeps the cookie pipe
  open for the life of the session and the helper watches it: EOF means the
  session is gone, and it `SIGTERM`s openconnect for a clean disconnect.

Only one tunnel at a time: if the host already has one up, `connect-remote.sh`
says so and exits *before* capturing a cookie, and the helper refuses to stack
a second openconnect over the first.

## Security notes

- The privileged helper only ever takes a username and a short-lived SAML
  cookie on stdin; all `openconnect` flags are hardcoded in the root-owned
  copy, and the gateway can only be chosen from the allowlist baked in at
  install time, not user-controllable beyond that. The Linux helper
  additionally accepts one literal mode word (`foreground`/`background`/`stop`)
  and validates the pinned SSH address as a bare IP literal before it reaches
  `ip route`.
- For remote hosts the cookie travels inside the SSH channel and is read from
  stdin; it is never written to the remote disk and never appears in an argv
  or `ps` listing on either machine.
- `auth.json` holds a live session cookie while a connection is being
  established — treat it like a credential (it's git-ignored by default and
  removed automatically).
- This tool only works if your Chrome profile already has a valid Okta
  session; it does not bypass or attack SSO in any way.
