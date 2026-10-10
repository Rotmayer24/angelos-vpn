// Checks the subscription parser against hostile, malformed and modern inputs.
// Subscriptions.js is a QML library (.pragma library), loaded here the way the shell loads
// it: the pragma is stripped and the functions are pulled out of the file's scope.
const fs = require('fs');
const path = require('path');

const here = __dirname;
let src = fs.readFileSync(path.join(here, '..', 'Subscriptions.js'), 'utf8');
src = src.replace('.pragma library', '');
const names = ['b64decode', 'utf8', 'parseQuery', 'hostPort', 'splitHead', 'baseInbounds',
    'streamFromQuery', 'vlessUri', 'vmessUri', 'trojanUri', 'decodeUserInfo',
    'ssUri', 'uriToXray', 'isXrayConfig', 'parseSubscription', 'normalize',
    'serverInfo', 'parseUserInfo'];
const mod = new Function(src + '\nreturn {' + names.join(',') + '};')();

const fails = [];
function check(cond, msg) {
    console.log((cond ? '  ok   ' : '  FAIL ') + msg);
    if (!cond) fails.push(msg);
}
const b64 = s => Buffer.from(s, 'utf8').toString('base64');
const vmess = kw => {
    const d = { v: '2', ps: 'n', add: 'v.example', port: '443', id: '11111111-1111-1111-1111-111111111111' };
    return 'vmess://' + b64(JSON.stringify(Object.assign(d, kw)));
};

console.log("1) b64decode rejects junk instead of silently skipping characters");
check(mod.b64decode(b64('hello world')) === 'hello world', 'a valid payload decodes');
check(mod.b64decode('not base64 !!!') === null, 'invalid characters -> null, not garbage');
check(mod.b64decode('') === '', 'empty input -> empty string');
check(mod.b64decode('dGVzdA=$$$') === null, 'a payload with junk in the middle -> null');

console.log("2) utf8 does not stringify null into the text 'null'");
check(mod.utf8(null) === '', 'utf8(null) is empty');
check(mod.utf8(undefined) === '', 'utf8(undefined) is empty');
check(mod.utf8('plain') === 'plain', 'utf8 of a plain string is unchanged');

console.log("3) parseQuery cannot write through prototype keys");
const q = mod.parseQuery('a=1&__proto__=evil&constructor=x&prototype=y&b=2');
check(q['a'] === '1' && q['b'] === '2', 'ordinary keys still parse');
// `in` walks the prototype chain, where __proto__ always exists: check own properties instead
const own = Object.getOwnPropertyNames(q);
check(!own.includes('__proto__') && !own.includes('constructor') && !own.includes('prototype'),
    'prototype keys are not set on the result');
check(Object.getPrototypeOf(q) === Object.prototype, 'the prototype was left alone');
check({}.evil === undefined, 'Object.prototype was not polluted');

console.log("4) parseSubscription reports *why* it failed");
const r = mod.parseSubscription('{not json at all');
check(r.kind === 'json-error', 'malformed JSON is named as such (was silently "unknown")');
check(!!r.error, 'with a message the UI can show');
check(mod.parseSubscription('').kind === 'empty', 'empty body stays "empty"');
check(mod.parseSubscription('$$$ not base64 $$$').kind === 'bad-base64', 'junk is "bad-base64"');
const ok = mod.parseSubscription(b64('vless://11111111-1111-1111-1111-111111111111@a.example:443?type=tcp#n'));
check(ok.kind === 'base64' && ok.configs.length === 1, 'a good subscription still parses');

console.log("5) ss:// understands the SIP002 literal-userinfo form");
const sip = mod.ssUri('ss://aes-256-gcm:secret%20pass@a.example:8388#node');
check(sip !== null, 'SIP002 link is accepted (it used to vanish)');
if (sip) {
    const s = sip.outbounds[0].settings.servers[0];
    check(s.method === 'aes-256-gcm', 'method parsed: ' + s.method);
    check(s.password === 'secret pass', 'password unescaped: ' + JSON.stringify(s.password));
    check(s.address === 'a.example' && s.port === 8388, 'host and port parsed');
}
const leg1 = mod.ssUri('ss://' + b64('aes-128-gcm:pw@b.example:1234') + '#legacy');
const leg2 = mod.ssUri('ss://' + b64('aes-128-gcm:pw') + '@c.example:1234');
check(leg1 && leg1.outbounds[0].settings.servers[0].address === 'b.example',
    'legacy whole-base64 form still works');
check(leg2 && leg2.outbounds[0].settings.servers[0].address === 'c.example',
    'legacy split-base64 form still works');

console.log("6) vmess:// keeps reality and xhttp instead of quietly dropping them");
const rc = mod.vmessUri(vmess({ tls: 'reality', sni: 'r.example', pbk: 'PUBKEY', sid: 'ab12' }));
check(rc !== null, 'a reality vmess link parses');
if (rc) {
    const ss = rc.outbounds[0].streamSettings;
    check(ss.security === 'reality', 'security stays "reality" (was downgraded to "none")');
    check(ss.realitySettings && ss.realitySettings.publicKey === 'PUBKEY', 'the public key is carried');
}
check(mod.vmessUri(vmess({ tls: 'reality', sni: 'r.example' })) === null,
    'reality without a public key is reported unsupported instead of built broken');

const xc = mod.vmessUri(vmess({ net: 'xhttp', path: '/x', host: 'h.example' }));
check(xc !== null, 'an xhttp vmess link parses');
if (xc) {
    const ss = xc.outbounds[0].streamSettings;
    check(ss.network === 'xhttp', 'network preserved');
    check(ss.xhttpSettings && ss.xhttpSettings.path === '/x', 'path carried');
}
check(mod.vmessUri(vmess({ net: 'quic-whatever' })) === null,
    'an unknown transport is refused up front, not left to fail at connect');
const plain = mod.vmessUri(vmess({ net: 'ws', path: '/w' }));
check(plain && plain.outbounds[0].streamSettings.network === 'ws', 'plain ws links are unaffected');

console.log("7) the rest of the parser still works");
const v = mod.vlessUri('vless://11111111-1111-1111-1111-111111111111@a.example:443?type=ws&security=tls&path=/p#n');
check(v && v.outbounds[0].protocol === 'vless', 'vless parses');
const t = mod.trojanUri('trojan://pw@a.example:443?security=tls#n');
check(t && t.outbounds[0].settings.servers[0].password === 'pw', 'trojan parses');
const ui = mod.parseUserInfo('upload=1; download=2; total=3; expire=4');
check(ui.download === 2 && ui.expire === 4, 'subscription-userinfo parses');

console.log();
console.log(fails.length ? 'FAILURES: ' + fails.length : 'all checks passed');
process.exit(fails.length ? 1 : 0);