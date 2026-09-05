# gp-vpn

Connect to a Palo Alto GlobalProtect VPN on macOS without a separate login
prompt, by reusing the Okta SSO session already live in your Chrome profile.

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

## Requirements

- macOS, with Chrome signed into your org's Okta
- [`openconnect`](https://formulae.brew.sh/formula/openconnect) (`brew install openconnect`)
- [`uv`](https://docs.astral.sh/uv/), plus a Playwright browser:

```bash
uv sync
uv run playwright install chromium
```

## Setup

Set `GP_SERVER` to your GlobalProtect gateway hostname (e.g.
`vpn.example.com`). Optionally set `GP_COOKIE_DOMAINS` (comma-separated) if
your Okta-fronted domains differ from the gateway's own domain.

```bash
export GP_SERVER=vpn.example.com
```

To avoid a `sudo` password prompt on every connect, install the scoped
root helper once:

```bash
sudo GP_SERVER=$GP_SERVER ./install-privileged.sh
```

This installs a root-owned `gp-tunnel` (with the server hostname baked in),
a copy of `vpnc-script`, and a `sudoers.d` rule that lets your user run only
that one helper without a password.

## Usage

```bash
GP_SERVER=vpn.example.com ./connect.sh
```

Disconnect with Ctrl+C.

## Security notes

- The privileged helper only ever takes a username and a short-lived SAML
  cookie on stdin; the VPN server and all `openconnect` flags are hardcoded
  in the root-owned copy, not user-controllable at run time.
- `auth.json` holds a live session cookie while a connection is being
  established — treat it like a credential (it's git-ignored by default and
  removed automatically).
- This tool only works if your Chrome profile already has a valid Okta
  session; it does not bypass or attack SSO in any way.
