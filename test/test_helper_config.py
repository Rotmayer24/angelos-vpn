#!/usr/bin/env python3
"""Checks the privileged helper's sing-box config: rule order and engine validity.

The helper is root code with no other test home. This loads it as a module, builds a
config the way `up` would, and asserts the invariants the tunnel depends on; when
sing-box is present the config also goes through `sing-box check` — the same "the
engine accepts what we build" guarantee protocol_matrix.js gives the Xray side.
"""
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "..", "privileged", "angelos-vpn")

fails = []


def check(cond, msg):
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        fails.append(msg)


def load_helper():
    loader = importlib.machinery.SourceFileLoader("angelos_vpn_helper", HELPER)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def singbox():
    for cand in ("/opt/happ/bin/tun/sing-box", "/usr/bin/sing-box", "/usr/local/bin/sing-box"):
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return ""


mod = load_helper()
cfg = mod.build_config(11080, 12080, "191.40.4.184", "1.1.1.1",
                       ["telegram-desktop"], ["example.com"], False)
rules = cfg["route"]["rules"]

print("1) the rules the tunnel depends on are present, in the order that makes them work")
check(rules and rules[0].get("process_name") == ["xray"] and rules[0].get("outbound") == "direct",
      "the xray process itself is the first direct exemption (no routing loop)")
check(any(r.get("ip_cidr") == ["191.40.4.184/32"] and r.get("outbound") == "direct" for r in rules),
      "the server address is routed directly")
hijack = [i for i, r in enumerate(rules) if r.get("action") == "hijack-dns"]
check(len(hijack) == 1 and rules[hijack[0]].get("port") == 53,
      "DNS is hijacked on port 53 only (a bare hijack-dns rule would eat all TCP)")
check(any(r.get("ip_is_private") for r in rules),
      "private networks stay direct")
check(any(r.get("domain_suffix") == ["example.com"] for r in rules)
      and any(r.get("process_name") == ["telegram-desktop"] for r in rules),
      "split-tunnel domains and apps are direct")

print("2) QUIC is refused, and only after the direct exemptions")
quic = rules[-1]
check(quic == {"port": 443, "network": "udp", "action": "reject"},
      "the final rule rejects UDP 443 (QUIC) so browsers fall back to TCP at once")
check(all(r.get("outbound") == "direct" or r.get("action") for r in rules[:-1]),
      "every rule before it is a direct exemption or the DNS hijack — direct-marked apps keep their QUIC")

sb = singbox()
if sb:
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(cfg, f)
        path = f.name
    try:
        p = subprocess.run([sb, "check", "-c", path], capture_output=True, timeout=20)
        check(p.returncode == 0,
              "sing-box check accepts the built config" + (
                  "" if p.returncode == 0 else ": " + p.stderr.decode()[-200:]))
    finally:
        os.unlink(path)
else:
    print("  SKIP sing-box check — binary not found")

print()
print("3) Hysteria runs on sing-box alone — no Xray in the picture at all")
hy = {"server": "h.example", "port": 8443, "password": "pw", "sni": "s.example",
      "insecure": False, "obfsPw": "obfs"}
hcfg = mod.build_config(11080, 12080, "h.example", "1.1.1.1", [], [], False, hy)
hout = hcfg["outbounds"]
check(hout and hout[0].get("type") == "hysteria2",
      "the proxy outbound is Hysteria2, not a SOCKS hop into Xray")
check(all(o.get("type") != "socks" for o in hout),
      "no SOCKS outbound exists — there is no Xray to hand traffic to")
check(hout[0].get("server") == "h.example" and hout[0].get("server_port") == 8443,
      "the server and port come from the credentials file")
check(hout[0].get("password") == "pw", "the password reaches the config")
check(hout[0].get("tls", {}).get("server_name") == "s.example", "the SNI is passed through")
check(hout[0].get("obfs", {}).get("type") == "salamander",
      "salamander obfuscation is passed — without it the server drops the handshake")
hrules = hcfg["route"]["rules"]
check(not any(r.get("process_name") == ["xray"] for r in hrules),
      "no xray exemption rule: Xray is not running, and the tunnel must not route around one")
check(any(r.get("ip_cidr") == ["1.2.3.4/32"] or r.get("ip_is_private") for r in hrules),
      "the usual direct exemptions still apply")

# The same server without obfuscation: the field must be absent, not empty — sing-box rejects
# an empty password where a real one is expected.
hy2 = dict(hy, obfsPw="")
hcfg2 = mod.build_config(11080, 12080, "h.example", "1.1.1.1", [], [], False, hy2)
check("obfs" not in hcfg2["outbounds"][0],
      "no obfs block when the provider sent no obfuscation secret")

print()
print("4) the credentials file is validated before a root process reads it")


def refused(path):
    try:
        mod.read_hy_file(path)
        return False
    except SystemExit:
        return True


check(refused("/etc/shadow"), "a file the caller does not own is refused")
check(refused("relative/path.json"), "a relative path is refused")
check(refused("/tmp/definitely-absent-hy.json"), "a missing file is refused")

# A file the caller does own must be accepted wherever the plugin keeps its cache. Pinning the
# directory to ~/.cache broke every user who sets XDG_CACHE_HOME somewhere else: the plugin
# writes to $XDG_CACHE_HOME and the helper looked in the default, so Hysteria failed at the
# last step for them and for nobody else — the kind of bug that only shows up off this machine.
tmpdir = tempfile.mkdtemp()
creds = os.path.join(tmpdir, "hysteria.json")
with open(creds, "w") as f:
    json.dump({"server": "h.example", "port": 443, "password": "pw", "sni": "s.example",
               "insecure": False, "obfsPw": ""}, f)
os.chmod(creds, 0o600)
check(not refused(creds), "a file the caller owns is accepted wherever the cache lives")
check(not os.path.exists(creds), "and it is deleted once read")

# World-readable must be refused even when the caller owns it.
creds2 = os.path.join(tmpdir, "world.json")
with open(creds2, "w") as f:
    json.dump({"server": "h.example", "port": 443, "password": "pw", "sni": "",
               "insecure": False, "obfsPw": ""}, f)
os.chmod(creds2, 0o644)
check(refused(creds2), "a file other users can read is refused")
os.unlink(creds2)

# Under pkexec the caller is named by PKEXEC_UID, which polkit sets. A file owned by anyone
# other must be refused even when the plugin asked for it.
os.environ["PKEXEC_UID"] = "0"
# the file was already consumed above, so re-create it to prove ownership is what is checked
with open(creds, "w") as f:
    json.dump({"server": "h.example", "port": 443, "password": "pw", "sni": "",
               "insecure": False, "obfsPw": ""}, f)
os.chmod(creds, 0o600)
check(refused(creds), "ownership is checked against PKEXEC_UID, not the directory")
os.unlink(creds)
del os.environ["PKEXEC_UID"]
os.rmdir(tmpdir)

print()
print("FAILURES: %d" % len(fails) if fails else "all checks passed")
sys.exit(1 if fails else 0)
