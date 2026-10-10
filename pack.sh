#!/bin/sh
# Builds the release ZIP for the angelOS community registry.
#
# The registry rejects archives with more than one top-level manifest.json, with unsafe
# paths, with symlinks, or with an id/version that disagrees with its record. This produces
# exactly what it expects: the plugin's files flat at the archive root, no .git, no caches,
# no runtime state.
#
#   ./pack.sh [version]        defaults to the version in manifest.json
#   ./pack.sh 1.0.0            explicit, must match manifest.json
set -eu
cd "$(dirname "$0")"

id=$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' manifest.json | head -1)
ver_in=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' manifest.json | head -1)
ver="${1:-$ver_in}"

[ -n "$id" ] || { echo "cannot read id from manifest.json" >&2; exit 1; }
[ -n "$ver" ] || { echo "cannot read version from manifest.json" >&2; exit 1; }
if [ "$ver" != "$ver_in" ]; then
    echo "version $ver does not match manifest.json ($ver_in); edit the manifest first" >&2
    exit 1
fi

out="../$id-v$ver.zip"
rm -f "$out"

# The file list is explicit rather than "everything": a stray file must never end up in a
# release by accident.
files="manifest.json qmldir README.md LICENSE
Vpn.qml Main.qml Settings.qml SettingsPanel.qml SettingsWindow.qml
DesktopWidget.qml BarWidget.qml
PageAbout.qml PageConnection.qml PageHelper.qml PageLogs.qml PageServers.qml
PageSplit.qml PageSubscriptions.qml
Subscriptions.js Fmt.js
probe.py findbins.py fetch.sh
privileged/angelos-vpn privileged/install.sh privileged/org.angelos.vpn.policy
test/test_probe.py test/probe_deadline.py test/test_subscriptions.js
  test/protocol_matrix.js"

for f in $files; do
    [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }
done

zip -q -X "$out" $files

# the checks the installer performs, run here so a bad archive never reaches a release
count=$(unzip -Z1 "$out" | grep -c 'manifest.json$' || true)
[ "$count" = "1" ] || { echo "archive must contain exactly one manifest.json (found $count)" >&2; exit 1; }
unzip -t "$out" >/dev/null

echo "$out"
echo "  $(unzip -Z1 "$out" | wc -l) файлов, $(du -h "$out" | cut -f1)"
echo "  sha256: $(sha256sum "$out" | cut -d' ' -f1)"