#!/bin/sh
# angelOS VPN: robust subscription download.
#
# Some providers (Fortuna) publish several A-records where one address can be dead or fail
# TLS. A single curl picks one address and gives up, so the list randomly comes up empty.
# Here we resolve every IPv4 address and try each in turn, twice, until one returns a body.
#
# Progress goes to stderr, one line per step, so the UI can show what is happening:
#   angelos-fetch resolve          resolving the host name
#   angelos-fetch try <i> <n>      trying address i of n
#
# Usage: fetch.sh <url> <headers-file> [hwid]
#   stdout = subscription body, exit 0 on success.

url="$1"
hdr="$2"
hw="$3"
[ -n "$url" ] || exit 2
# http(s) only. curl also services file://, dict://, gopher:// and friends, and this script
# writes whatever comes back into the subscription cache — so an unchecked URL would be a
# local file read primitive.
case "$url" in
    http://*|https://*) ;;
    *) echo "angelos-fetch unsupported URL scheme" >&2; exit 2 ;;
esac

host=$(printf '%s' "$url" | sed -E 's#^[a-zA-Z]+://([^/:]+).*#\1#')
port=$(printf '%s' "$url" | sed -nE 's#^[a-zA-Z]+://[^/:]+:([0-9]+).*#\1#p')
[ -n "$port" ] || port=443

echo "angelos-fetch resolve" >&2
ips=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u)
[ -n "$ips" ] || ips=$(getent hosts "$host" 2>/dev/null | awk '{print $1}' | sort -u)
[ -n "$ips" ] || ips="$host"
total=$(printf '%s\n' $ips | grep -c .)
[ "$total" -gt 0 ] || total=1

fetch_ip() {
    if [ -n "$hw" ]; then
        curl -fsS --connect-timeout 8 --max-time 40 -A "v2rayNG/1.8.5" \
            -H "X-HWID: $hw" --resolve "$host:$port:$1" -D "$hdr" "$url" 2>/dev/null
    else
        curl -fsS --connect-timeout 8 --max-time 40 -A "v2rayNG/1.8.5" \
            --resolve "$host:$port:$1" -D "$hdr" "$url" 2>/dev/null
    fi
}

round=0
while [ "$round" -lt 2 ]; do
    i=0
    for ip in $ips; do
        i=$((i + 1))
        echo "angelos-fetch try $i $total" >&2
        if fetch_ip "$ip"; then
            exit 0
        fi
    done
    round=$((round + 1))
done
exit 1
