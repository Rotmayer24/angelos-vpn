// Does the core actually accept what the plugin builds? The parser tests check that a
// subscription becomes the right shape; this one checks that xray starts on it. A protocol
// the parser handles but the core refuses is worse than an unsupported one: the UI says
// connected and nothing works.
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFileSync } = require('child_process');

const here = __dirname;
let src = fs.readFileSync(path.join(here, '..', 'Subscriptions.js'), 'utf8');
src = src.replace('.pragma library', '');
const names = ['parseSubscription', 'normalize', 'serverInfo', 'serversFrom'];
const mod = new Function(src + '\nreturn {' + names.join(',') + '};')();

function xray() {
  // Where the engines live differs per machine; the plugin finds them at runtime.
  if (process.env.VPN_XRAY && fs.existsSync(process.env.VPN_XRAY))
    return process.env.VPN_XRAY;
  const candidates = ['/opt/happ/bin/core/xray', '/usr/bin/xray', '/usr/local/bin/xray'];
  for (const c of candidates) if (fs.existsSync(c)) return c;
  return candidates[0];
}

// One representative subscription body per protocol the parser claims to support: a URI
// link where the protocol has one, a JSON config where the provider serves one — hysteria
// comes only in the Xray-config form, never as a URI.
const links = {
  vless: 'vless://11111111-2222-3333-4444-555555555555@ex.example:443?encryption=none&security=tls&sni=ex.example&type=xhttp&path=%2Fapi%2Fv1&host=ex.example#vless-xhttp',
  vmess: 'vmess://eyJ2IjoiMiIsInBzIjoidm1lc3MtYmFzZS02NG1kIiwiYWRkIjoiZXguZXhhbXBsZSIsInBvcnQiOjQ0MywiaWQiOiJhYmMifQ',
  trojan: 'trojan://p%40ss%3Aword@ex.example:443?security=tls&sni=ex.example&type=tcp#trojan-tcp',
  ss: 'ss://YWVzLTI1Ni1nY206c2VjcmV0K3Bhc3M@ex.example:8388#ss-legacy',
  hysteria: JSON.stringify([{
    inbounds: [],
    outbounds: [
      { tag: 'proxy', protocol: 'hysteria',
        settings: { address: 'ex.example', port: 443, version: 2 },
        streamSettings: { network: 'hysteria',
          hysteriaSettings: { version: 2, auth: 'probe-password' },
          security: 'tls',
          tlsSettings: { serverName: 'ex.example', fingerprint: 'chrome', alpn: ['h3'] },
          finalmask: { udp: [{ type: 'salamander', settings: { password: 'obfs-pass' } }] } } },
      { tag: 'direct', protocol: 'freedom' }
    ]
  }]),
};

const out = [];
let fails = 0;

function log(msg) { console.log(msg); out.push(msg); }

for (const [name, link] of Object.entries(links)) {
  if (!link) { log(`  SKIP ${name} — no parser branch`); continue; }
  let cfg;
  try {
    // encoded, the way a provider actually serves it
    const r = mod.parseSubscription(Buffer.from(link, 'utf8').toString('base64'));
    if (!r.configs.length) { log(`  FAIL ${name} — parser returned ${r.kind} with no configs`); fails++; continue; }
    cfg = mod.normalize(r.configs[0], { socksPort: 21080, httpPort: 21081, apiPort: 22080, dns: '1.1.1.1' });
  } catch (e) {
    log(`  FAIL ${name} — parser threw: ${e.message}`); fails++; continue;
  }
  const f = path.join(os.tmpdir(), `vpn-proto-${name}.json`);
  fs.writeFileSync(f, JSON.stringify(cfg));
  try {
    execFileSync(xray(), ['run', '-test', '-c', f], { stdio: 'pipe', timeout: 20000 });
    const proto = cfg.outbounds[0].protocol;
    const net = (cfg.outbounds[0].streamSettings || {}).network || '-';
    log(`  ok   ${name.padEnd(9)} xray accepts it (protocol=${proto}, network=${net})`);
  } catch (e) {
    const msg = (e.stderr || Buffer.alloc(0)).toString().split('\n').filter(l => l.trim()).slice(-1)[0] || e.message;
    log(`  FAIL ${name.padEnd(9)} xray refused: ${msg.slice(0, 110)}`);
    fails++;
  } finally {
    fs.unlinkSync(f);
  }
}

log(fails ? `\n  FAILURES: ${fails}` : '\n  every protocol the parser builds is accepted by the core');
process.exit(fails ? 1 : 0);