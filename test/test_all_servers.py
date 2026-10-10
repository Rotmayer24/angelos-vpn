#!/usr/bin/env python3
"""Проверить каждый сервер подписки на живом соединении, а не на валидности конфига.

`xray run -test` проверяет только синтаксис: протокол, который ядро не умеет, проходит
проверку и молча не везёт. Поэтому здесь для каждого сервера поднимается отдельный xray на
свободном порту и идут настоящие запросы.

Использование: test_all_servers.py [попыток] [таймаут_на_попытку]
"""
import json
import os
import socket
import subprocess
import sys
import time
import glob

SUBS = sorted(x for x in glob.glob(os.path.expanduser('~/.cache/angelos-vpn/sub-*.json'))
              if 'hdr' not in x)
XRAY = next((p for p in ('/opt/happ/bin/core/xray', '/usr/bin/xray', '/usr/local/bin/xray')
             if os.path.exists(p)), '/opt/happ/bin/core/xray')
TRIES = int(sys.argv[1]) if len(sys.argv) > 1 else 3
TMO = int(sys.argv[2]) if len(sys.argv) > 2 else 6


def free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    p = s.getsockname()[1]
    s.close()
    return p


def probe_via_socks(port):
    ok = 0
    times = []
    for _ in range(TRIES):
        t0 = time.time()
        r = subprocess.run(['curl', '-s', '-m', str(TMO), '-o', '/dev/null',
                            '-w', '%{http_code}',
                            '--socks5-hostname', f'127.0.0.1:{port}',
                            'https://speed.cloudflare.com/__down?bytes=100'],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=TMO + 4)
        ms = int((time.time() - t0) * 1000)
        if r.stdout.decode().strip() == '200':
            ok += 1
            times.append(ms)
    return ok, times


def main():
    if not SUBS:
        print('  подписка не найдена')
        return 1
    subs = json.load(open(SUBS[-1]))
    total = len(subs)
    print(f'  подписка: {os.path.basename(SUBS[-1])} | серверов: {total} | xray: {XRAY}')
    print(f'  попыток на сервер: {TRIES}, таймаут {TMO}с\n')

    print(f'  {"idx":<4}{"протокол":<11}{"результат":<12}{"p50":<8}{"сервер"}')
    print('  ' + '-' * 78)

    bad = []
    for i, s in enumerate(subs):
        name = s.get('remarks', '?')
        cfg = json.loads(json.dumps(s))
        port = free_port()
        cfg['inbounds'] = [{'tag': 'socks', 'protocol': 'socks', 'listen': '127.0.0.1',
                            'port': port, 'settings': {'auth': 'noauth', 'udp': True}}]
        cfg['log'] = {'loglevel': 'warning'}
        for k in ('dns', 'routing', 'api', 'stats', 'policy'):
            cfg.pop(k, None)
        path = f'/tmp/_srv_{port}.json'
        with open(path, 'w') as f:
            json.dump(cfg, f)

        proc = subprocess.Popen([XRAY, 'run', '-c', path],
                                stdout=subprocess.DEVNULL,
                                stderr=open('/tmp/_srv_err.log', 'wb'))
        time.sleep(3.5)
        ok, times = probe_via_socks(port)
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        os.unlink(path)

        proto = cfg['outbounds'][0].get('protocol', '?')
        p50 = f'{sorted(times)[len(times)//2]}мс' if times else '—'
        verdict = 'РАБОТАЕТ' if ok == TRIES else ('частично' if ok else 'НЕ РАБОТАЕТ')
        print(f'  {i:<4}{proto:<11}{str(ok) + "/" + str(TRIES):<12}{p50:<8}{name[:34]}')
        if ok < TRIES:
            bad.append((i, name, ok))

    print('\n  --- итог ---')
    good = total - len(bad)
    print(f'  полностью работают: {good}/{total}')
    if bad:
        print('  проблемные:')
        for i, n, ok in bad:
            print(f'    [{i}] {n[:38]} — {ok}/{TRIES}')
    return 0


if __name__ == '__main__':
    sys.exit(main())