#!/usr/bin/env python3
"""GlobalProtect SAML auth by reusing the live Chrome profile's Okta session.

Reads the live Chrome cookie DB, decrypts the Okta/company cookies with the
macOS Keychain 'Chrome Safe Storage' key, injects them into an automation
browser, drives the GP SAML form, and captures the prelogin-cookie that
GlobalProtect returns. No separate VPN login — it rides on your normal Okta
session.

  python gp_connect.py <portal-host> [--headed] [--gateway]
  GP_COOKIE_DOMAINS=example.com,example.net python gp_connect.py vpn.example.com

Writes captured values to auth.json.
"""
import sys, os, ssl, base64, re, json, urllib.request, pathlib, time, subprocess, sqlite3, hashlib, shutil, tempfile
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.backends import default_backend

SERVER = os.environ.get("GP_SERVER", "vpn.example.com")
HEADED = "--headed" in sys.argv
GATEWAY = "--gateway" in sys.argv
for a in sys.argv[1:]:
    if not a.startswith("-"):
        SERVER = a
# portal SAML lives at /global-protect/prelogin.esp; gateway SAML at /ssl-vpn/prelogin.esp
PRELOGIN_PATH = "/ssl-vpn/prelogin.esp" if GATEWAY else "/global-protect/prelogin.esp"

HERE = pathlib.Path(__file__).parent
LIVE_COOKIES = pathlib.Path(os.path.expanduser(
    "~/Library/Application Support/Google/Chrome/Default/Cookies"))
OUT = HERE / "auth.json"
GP_HEADER_KEYS = ["saml-username", "prelogin-cookie", "portal-userauthcookie",
                  "saml-auth-status", "saml-slo"]
# Cookie domains involved in the Okta SSO -> GP SAML chain. Always includes
# okta.com plus your org's domain(s) (comma-separated env var, defaulting to
# the registrable domain of SERVER).
_default_domain = ".".join(SERVER.split(".")[-2:])
_extra_domains = [d.strip() for d in os.environ.get("GP_COOKIE_DOMAINS", _default_domain).split(",") if d.strip()]
def wanted(host):
    return host.endswith("okta.com") or any(host.endswith(d) for d in _extra_domains)

def get_saml_request(server):
    url = f"https://{server}{PRELOGIN_PATH}?tmp=tmp&clientVer=4100&clientos=Mac"
    req = urllib.request.Request(url, data=b"", headers={"User-Agent": "PAN GlobalProtect"})
    with urllib.request.urlopen(req, context=ssl.create_default_context(), timeout=20) as r:
        body = r.read().decode("utf-8", "replace")
    m = re.search(r"<saml-request>(.*?)</saml-request>", body, re.S)
    if not m:
        raise SystemExit("No <saml-request> in prelogin response:\n" + body[:400])
    return base64.b64decode(m.group(1)).decode("utf-8", "replace")

def keychain_key():
    pw = subprocess.check_output(
        ["security", "find-generic-password", "-w", "-s", "Chrome Safe Storage", "-a", "Chrome"]
    ).strip()
    return hashlib.pbkdf2_hmac("sha1", pw, b"saltysalt", 1003, dklen=16)

def decrypt(enc, key):
    if enc[:3] != b"v10":
        return None
    ct = enc[3:]
    d = Cipher(algorithms.AES(key), modes.CBC(b" " * 16), backend=default_backend()).decryptor()
    pt = d.update(ct) + d.finalize()
    pt = pt[:-pt[-1]]  # PKCS7
    for cand in ((pt[32:] if len(pt) > 32 else pt), pt):
        try:
            return cand.decode("utf-8")
        except Exception:
            continue
    return None

def load_cookies():
    key = keychain_key()
    # snapshot to avoid lock issues while Chrome runs
    tmp = pathlib.Path(tempfile.mkdtemp()) / "Cookies"
    shutil.copy2(LIVE_COOKIES, tmp)
    con = sqlite3.connect(str(tmp)); con.row_factory = sqlite3.Row
    rows = con.execute("""SELECT host_key,name,encrypted_value,path,is_secure,
                          is_httponly,samesite,expires_utc,has_expires FROM cookies""").fetchall()
    con.close()
    ss_map = {2: "Strict", 1: "Lax", 0: "None", -1: "Lax"}
    out = []
    for r in rows:
        host = r["host_key"]
        if not wanted(host.lstrip(".")):
            continue
        val = decrypt(r["encrypted_value"], key)
        if val is None:
            continue
        c = {
            "name": r["name"], "value": val,
            "domain": host, "path": r["path"] or "/",
            "secure": bool(r["is_secure"]), "httpOnly": bool(r["is_httponly"]),
            "sameSite": ss_map.get(r["samesite"], "Lax"),
        }
        if r["has_expires"] and r["expires_utc"]:
            c["expires"] = int(r["expires_utc"] / 1_000_000 - 11644473600)
        out.append(c)
    return out

def main():
    saml_html = get_saml_request(SERVER)
    print(f"[*] prelogin OK  form-bytes={len(saml_html)}", flush=True)
    cookies = load_cookies()
    okta = [c for c in cookies if "okta" in c["domain"]]
    print(f"[*] decrypted {len(cookies)} cookies ({len(okta)} okta) from live profile", flush=True)

    from playwright.sync_api import sync_playwright
    captured = {}

    def on_response(resp):
        try:
            h = resp.headers
        except Exception:
            return
        hit = {k: h[k] for k in GP_HEADER_KEYS if k in h}
        if hit:
            print(f"[+] GP headers on {resp.url[:70]} -> {list(hit)}", flush=True)
            captured.update(hit)

    with sync_playwright() as p:
        browser = p.chromium.launch(channel="chrome", headless=not HEADED,
                                    args=["--no-first-run", "--no-default-browser-check"])
        ctx = browser.new_context()
        try:
            ctx.add_cookies(cookies)
        except Exception as e:
            print("[!] add_cookies error:", e, flush=True)
            # retry per-cookie to skip any malformed entry
            ok = 0
            for c in cookies:
                try: ctx.add_cookies([c]); ok += 1
                except Exception: pass
            print(f"[*] injected {ok}/{len(cookies)} cookies individually", flush=True)
        page = ctx.new_page()
        ctx.on("response", on_response)
        page.set_content(saml_html, wait_until="domcontentloaded")
        mode = "headed" if HEADED else "headless"
        print(f"[*] SAML submitted ({mode}). Waiting for GP cookie...", flush=True)

        deadline = time.time() + (240 if HEADED else 40)
        while time.time() < deadline:
            if "prelogin-cookie" in captured or "portal-userauthcookie" in captured:
                time.sleep(1.0); break
            page.wait_for_timeout(500)
        try:
            print(f"[*] final URL: {page.url[:90]}", flush=True)
        except Exception:
            pass
        if "prelogin-cookie" not in captured and "portal-userauthcookie" not in captured:
            try:
                page.screenshot(path=str(HERE / "stall.png"))
                print("[dbg] page text >>>\n" + page.inner_text("body")[:600] + "\n<<<", flush=True)
            except Exception as e:
                print("[dbg] snapshot err:", e, flush=True)
        ctx.close(); browser.close()

    OUT.write_text(json.dumps({"server": SERVER, "captured": captured}, indent=2))
    if "prelogin-cookie" not in captured and "portal-userauthcookie" not in captured:
        print("[!] No prelogin-cookie captured. Captured:", list(captured)); raise SystemExit(2)
    print("[*] SUCCESS. Wrote", OUT)
    print(json.dumps({k: (v[:10] + "…" if "cookie" in k and len(v) > 10 else v)
                      for k, v in captured.items()}, indent=2))

if __name__ == "__main__":
    main()
