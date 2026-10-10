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
print("FAILURES: %d" % len(fails) if fails else "all checks passed")
sys.exit(1 if fails else 0)
