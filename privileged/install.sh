#!/bin/sh
# angelOS VPN: install the privileged TUN helper.
#
#   install.sh [dir] [--remove]     install / update / remove
#
# `dir` is the plugin's privileged/ directory (it defaults to the one this script sits in,
# which is only true for the copy inside the plugin). It is where angelos-vpn and the polkit
# policy are read from.
#
# Why this installs a copy of itself
# ----------------------------------
# This script has to run as root, and the plugin directory it lives in belongs to the user:
# anything running as that user could replace this file and get arbitrary root code the next
# time the user clicks "Install". So the first run copies this installer to
# /usr/local/libexec/angelos-vpn-install as well — root-owned, and bound by its own polkit
# action, so it is the version that handles every later install and remove. From then on the
# plugin calls that copy directly and this file is only the bootstrap.
#
# The helper itself is guarded the same way: the first install records its SHA-256 in a
# root-owned file, and any later install must match that record byte for byte. A helper
# swapped in between the prompt and the exec is refused. An update therefore means --remove
# and install again — the trade for not being able to bootstrap trust out of $HOME.
set -eu
[ "$(id -u)" = 0 ] || { echo "run as root (pkexec / sudo)" >&2; exit 1; }

die() { echo "$1" >&2; exit 1; }

libexec=/usr/local/libexec
bin=$libexec/angelos-vpn
binhash=$libexec/angelos-vpn.sha256
self=$libexec/angelos-vpn-install
policy=/usr/share/polkit-1/actions/org.angelos.vpn.policy

# the sources: the privileged/ directory of the plugin, passed in or next to this script
srcdir=""
action=install
while [ $# -gt 0 ]; do
    case "$1" in
        --remove) action=remove ;;
        -*) die "unknown option: $1" ;;
        *) srcdir="$1" ;;
    esac
    shift
done
[ -n "$srcdir" ] || srcdir="$(cd "$(dirname "$0")" && pwd)"

# not group- or world-writable: on a shared machine another local user must not be able to
# edit the sources between the prompt and the install
check_writable() {
    f="$1"
    [ -e "$f" ] || die "refusing: $f is missing"
    mode="$(stat -c %a "$f")"
    case "$mode" in
        *[2367]) die "refusing: $f is group/world-writable ($mode)" ;;
    esac
}

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

if [ "$action" = remove ]; then
    # bring a running tunnel down before we lose the helper
    if [ -x "$bin" ]; then
        "$bin" down >/dev/null 2>&1 || true
    fi
    rm -f "$bin" "$binhash" "$policy"
    # keep our own copy only if it is not the script currently running
    [ "$self" = "$(readlink -f "$0")" ] || rm -f "$self"
    rm -rf /run/angelos-vpn
    echo "removed"
    exit 0
fi

src="$srcdir/angelos-vpn"
pol="$srcdir/org.angelos.vpn.policy"
[ -f "$src" ] || die "refusing: $src is missing"
[ -f "$pol" ] || die "refusing: $pol is missing"
check_writable "$srcdir"
check_writable "$src"
check_writable "$pol"

actual="$(sha256_of "$src")"

if [ -f "$binhash" ]; then
    expected="$(cut -d' ' -f1 < "$binhash" 2>/dev/null || true)"
    if [ "$actual" != "$expected" ]; then
        die "refusing: $src does not match the helper recorded at install time
  actual   $actual
  recorded $expected
The installed helper is trusted and unchanged. To install a different build, remove the
helper first (--remove) and install again — that asks for the password once more."
    fi
fi

# stop anything that is up (config paths change with the update)
if [ -x "$bin" ]; then
    "$bin" down >/dev/null 2>&1 || true
fi
install -D -o root -g root -m 0755 "$src" "$bin"
install -D -o root -g root -m 0644 "$pol" "$policy"
# root-owned, 0444: the record an update has to match
printf '%s  %s\n' "$actual" "$bin" > "$binhash"
chmod 0444 "$binhash"
# the bootstrap becomes a root-owned installer, so later runs are no TOCTOU either
if [ "$self" != "$(readlink -f "$0")" ]; then
    install -D -o root -g root -m 0755 "$0" "$self"
fi
echo "installed: $bin"