#!/usr/bin/env python3
"""TCP-connect latency probe for the angelOS VPN plugin.

Called as:  probe.py <timeout-seconds> <index> <host> <port> [<index> <host> <port> ...]
Prints one line per target:  <index>\t<ms>   (ms = -1 on failure).

Targets are probed concurrently, so a long subscription no longer costs
`len(targets) * timeout` seconds: a few hundred servers finish in about one timeout.
A deadline caps the whole run as well, and SIGTERM (the plugin's cancel) ends it cleanly.
"""
import concurrent.futures
import os
import socket
import sys
import time


def probe(host: str, port: int, timeout: float) -> int:
    try:
        infos = socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP)
    except OSError:
        return -1
    if not infos:
        return -1
    best = -1
    for family, socktype, proto, _canon, sockaddr in infos:
        s = socket.socket(family, socktype, proto)
        s.settimeout(timeout)
        try:
            t0 = time.perf_counter()
            s.connect(sockaddr)
            ms = int((time.perf_counter() - t0) * 1000)
            # report the first address that answers; a server with several A-records is
            # usable as soon as one of them takes the connection
            if best < 0 or ms < best:
                best = ms
        except OSError:
            pass
        finally:
            try:
                s.close()
            except OSError:
                pass
    return best


def parse_targets(args):
    """(index, host, port) triples. A malformed entry is skipped rather than guessed:
    defaulting a broken port to 443 would probe an unrelated service on the machine."""
    out = []
    i = 0
    # i, i+1 and i+2 must all exist: the old `i + 2 < len + 1 and i + 2 <= len` reduced to
    # `i + 2 <= len`, which let a dangling "index host" pair at the end run off the array
    while i + 2 < len(args):
        idx, host, raw_port = args[i], args[i + 1], args[i + 2]
        try:
            port = int(raw_port)
        except ValueError:
            i += 3
            continue
        if not (1 <= port <= 65535) or not host:
            i += 3
            continue
        out.append((idx, host, port))
        i += 3
    return out


def main() -> int:
    args = sys.argv[1:]
    if not args:
        return 2
    try:
        timeout = float(args[0])
    except ValueError:
        timeout = 2.0
    if timeout <= 0:
        timeout = 2.0
    targets = parse_targets(args[1:])
    if not targets:
        return 0

    # generous but bounded: long enough for a slow address, short enough that the user is not
    # left watching a stuck spinner
    deadline = max(2.0, timeout * 3)
    workers = min(32, len(targets))
    # not a `with` block: leaving it would wait for every still-running thread, which is the
    # opposite of what the deadline is for. Each probe is bounded by the socket timeout in
    # normal operation, so this only matters when a resolver wedges.
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=workers)
    futures = {pool.submit(probe, host, port, timeout): idx
               for idx, host, port in targets}
    try:
        for fut in concurrent.futures.as_completed(futures, timeout=deadline):
            idx = futures[fut]
            try:
                ms = fut.result()
            except Exception:  # noqa: BLE001 - a probe must never take the plugin down
                ms = -1
            sys.stdout.write("%s\t%d\n" % (idx, ms))
            sys.stdout.flush()
        pool.shutdown(wait=False)
        return 0
    except concurrent.futures.TimeoutError:
        # report what is still running as unreachable so the UI gets a complete answer, then
        # leave immediately: waiting on threads that may be wedged is what we are avoiding
        for fut, idx in futures.items():
            if not fut.done():
                sys.stdout.write("%s\t-1\n" % idx)
        sys.stdout.flush()
        try:
            pool.shutdown(wait=False, cancel_futures=True)
        except TypeError:  # python < 3.9 has no cancel_futures
            pool.shutdown(wait=False)
        os._exit(0)
    except KeyboardInterrupt:
        pool.shutdown(wait=False)
        return 0


if __name__ == "__main__":
    sys.exit(main())