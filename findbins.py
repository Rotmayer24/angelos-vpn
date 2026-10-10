#!/usr/bin/env python3
"""Locate the engines and the tools the angelOS VPN plugin needs.

Called once at startup; prints one JSON object on stdout:

    {"xray": "...", "singbox": "...", "deps": {"curl": "/usr/bin/curl", ...},
     "missing": ["pkexec"], "searched": ["xray", ...]}

Nothing here is fatal: the plugin loads either way and shows what it could not find, because a
missing tool otherwise shows up much later as an empty StdioCollector and a silent failure.
Paths are reported as absolute, in the order most specific first, so a wrong binary inside
/opt (a partial install) cannot shadow the one in PATH.
"""
import json
import os
import shutil
import sys

# where an engine may live. Happ ships its own copies under /opt; a distribution or a manual
# install puts them in the usual system locations.
SEARCH = [
    "/usr/local/bin",
    "/usr/bin",
    "/bin",
    "/opt/happ/bin/core",
    "/opt/happ/bin/tun",
    "/opt/xray",
    "/usr/local/libexec",
]

ENGINES = {
    # a name in PATH, then the places it is usually installed to
    "xray": ["xray", "/opt/happ/bin/core/xray", "/usr/local/bin/xray", "/usr/bin/xray"],
    "singbox": ["sing-box", "/opt/happ/bin/tun/sing-box",
                "/usr/local/bin/sing-box", "/usr/bin/sing-box"],
}

# what has to exist for the plugin to work at all, and where it is used
DEPS = {
    "python3": "writes run.json, the helper and the ping probe",
    "curl": "health check and subscription download",
    "ss": "free-port scan before connecting",
    "pkexec": "the privileged TUN helper",
    "getent": "resolves the subscription host (fetch.sh)",
    "sh": "runs the helper scripts",
}


def usable(path):
    try:
        return bool(path) and os.path.isfile(path) and os.access(path, os.X_OK)
    except OSError:
        return False


def find(name, extra):
    """First usable match: an explicit path, then PATH, then the usual install locations."""
    for cand in extra:
        if cand and cand.startswith("/"):
            if usable(cand):
                return cand
    for d in SEARCH:
        cand = os.path.join(d, name)
        if usable(cand):
            return cand
    return shutil.which(name) or ""


def main():
    out = {"xray": "", "singbox": "", "deps": {}, "missing": []}
    for key, extra in ENGINES.items():
        path = find(key, extra)
        out[key] = path
        if not path:
            out["missing"].append(key)
    for tool in DEPS:
        path = shutil.which(tool) or ""
        out["deps"][tool] = path
        if not path:
            out["missing"].append(tool)
    json.dump(out, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())