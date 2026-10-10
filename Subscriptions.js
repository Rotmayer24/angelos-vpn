.pragma library

// Subscription parsing for the angelOS VPN plugin.
// Understands: an Xray config (object or array of objects), and a base64 list of
// vless:// vmess:// trojan:// ss:// URIs. Returns normalized Xray configs so the
// controller can run one engine (Xray) for every server.

var _B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

function b64decode(input) {
    if (!input)
        return "";
    var s = String(input).replace(/[\r\n\s]+/g, "").replace(/-/g, "+").replace(/_/g, "/");
    // Reject rather than skip characters that are not base64. Skipping them used to turn a
    // corrupted subscription into a plausible-looking string that then failed deep inside
    // Xray, far from the cause — a wrong answer is worse than none.
    if (!/^[A-Za-z0-9+/=]*$/.test(s))
        return null;
    while (s.length % 4)
        s += "=";
    var out = "";
    var buf = 0, bits = 0;
    for (var i = 0; i < s.length; i++) {
        var ch = s.charAt(i);
        if (ch === "=")
            break;
        var v = _B64.indexOf(ch);
        buf = (buf << 6) | v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out += String.fromCharCode((buf >> bits) & 0xff);
        }
    }
    return out;
}

function utf8(s) {
    // null/unused must not stringify into the literal text "null": a failed base64 decode
    // used to travel onward as a plausible-looking value
    if (s === null || s === undefined)
        return "";
    try {
        return decodeURIComponent(escape(String(s)));
    } catch (e) {
        return String(s);
    }
}

function parseQuery(q) {
    var o = {};
    if (!q)
        return o;
    var parts = String(q).split("&");
    for (var i = 0; i < parts.length; i++) {
        var kv = parts[i];
        var eq = kv.indexOf("=");
        var k = eq < 0 ? kv : kv.slice(0, eq);
        var v = eq < 0 ? "" : kv.slice(eq + 1);
        try { k = decodeURIComponent(k); } catch (e) {}
        try { v = decodeURIComponent(v); } catch (e) {}
        // The keys come from a remote response. __proto__/constructor are harmless here today
        // only because the result is never merged onto a prototype chain — do not rely on
        // that: an object with a null prototype cannot be reached this way.
        if (k === "__proto__" || k === "prototype" || k === "constructor")
            continue;
        o[k] = v;
    }
    return o;
}

function hostPort(rest) {
    var at = rest.lastIndexOf("@");
    if (at < 0)
        return null;
    var user = rest.slice(0, at);
    var hp = rest.slice(at + 1);
    var m = hp.match(/^\[([^\]]+)\]:(\d+)$/);
    if (m)
        return { user: user, host: m[1], port: parseInt(m[2], 10) };
    var c = hp.lastIndexOf(":");
    if (c < 0)
        return null;
    return { user: user, host: hp.slice(0, c), port: parseInt(hp.slice(c + 1), 10) };
}

function splitHead(u, scheme) {
    var rest = u.slice(scheme.length);
    var hash = "";
    var hi = rest.indexOf("#");
    if (hi >= 0) {
        hash = utf8(rest.slice(hi + 1));
        rest = rest.slice(0, hi);
    }
    var qi = rest.indexOf("?");
    var q = {};
    if (qi >= 0) {
        q = parseQuery(rest.slice(qi + 1));
        rest = rest.slice(0, qi);
    }
    return { rest: rest, q: q, name: hash };
}

function baseInbounds() {
    return [
        { tag: "socks", protocol: "socks", listen: "127.0.0.1", port: 10808, settings: { auth: "noauth", udp: true } },
        { tag: "http", protocol: "http", listen: "127.0.0.1", port: 10809, settings: {} }
    ];
}

function streamFromQuery(q) {
    var net = q.type || q.net || "tcp";
    var ss = { network: net };
    var sec = q.security || "none";
    if (sec === "tls") {
        ss.security = "tls";
        ss.tlsSettings = { serverName: q.sni || q.host || "", fingerprint: q.fp || "", allowInsecure: q.allowInsecure === "1" || q.insecure === "1" };
        if (q.alpn)
            ss.tlsSettings.alpn = q.alpn.split(",");
    } else if (sec === "reality") {
        ss.security = "reality";
        ss.realitySettings = {
            serverName: q.sni || q.host || "",
            fingerprint: q.fp || "chrome",
            publicKey: q.pbk || "",
            shortId: q.sid || "",
            spiderX: q.spx || ""
        };
    } else {
        ss.security = "none";
    }
    if (net === "ws")
        ss.wsSettings = { path: q.path || "/", headers: q.host ? { Host: q.host } : {} };
    else if (net === "grpc")
        ss.grpcSettings = { serviceName: q.serviceName || q.path || "" };
    else if (net === "http" || net === "h2") {
        ss.network = "http";
        ss.httpSettings = { host: q.host ? [q.host] : [], path: q.path || "/" };
    } else if (net === "xhttp") {
        ss.xhttpSettings = { path: q.path || "/", host: q.host || "", mode: q.mode || "auto" };
        if (q.extra) {
            try { ss.xhttpSettings.extra = JSON.parse(q.extra); } catch (e) {}
        }
    } else if (net === "tcp") {
        ss.tcpSettings = {};
        if (q.headerType === "http")
            ss.tcpSettings.header = { type: "http", request: { path: [q.path || "/"], headers: q.host ? { Host: [q.host] } : {} } };
    }
    return ss;
}

function vlessUri(u) {
    var h = splitHead(u, "vless://");
    var hp = hostPort(h.rest);
    if (!hp || !hp.host)
        return null;
    var user = { id: utf8(hp.user), encryption: h.q.encryption || "none" };
    if (h.q.flow)
        user.flow = h.q.flow;
    return {
        remarks: h.name || (hp.host + ":" + hp.port),
        inbounds: baseInbounds(),
        outbounds: [
            { tag: "proxy", protocol: "vless", settings: { vnext: [{ address: hp.host, port: hp.port, users: [user] }] }, streamSettings: streamFromQuery(h.q) },
            { tag: "direct", protocol: "freedom" },
            { tag: "block", protocol: "blackhole" }
        ]
    };
}

// Transports vmess links may carry. A link using anything else is reported as unsupported
// rather than turned into a config Xray will reject at connect time.
var VMESS_NETS = ["tcp", "ws", "grpc", "h2", "http", "xhttp"];

function vmessUri(u) {
    var body = u.slice("vmess://".length);
    var dec = b64decode(body);
    if (dec === null)
        return null;
    var j;
    try { j = JSON.parse(utf8(dec)); } catch (e) { return null; }
    if (!j || !j.add || !j.id)
        return null;
    var port = parseInt(j.port, 10);
    if (!(port > 0 && port < 65536))
        return null;
    var net = j.net || "tcp";
    if (VMESS_NETS.indexOf(net) < 0)
        return null;                      // unknown transport: Xray could never run it
    var tls = String(j.tls || "").toLowerCase();
    if (tls && tls !== "tls" && tls !== "reality" && tls !== "none")
        return null;                      // unknown security mode
    var ss = { network: net, security: tls === "none" ? "none" : tls };
    if (ss.security === "tls") {
        ss.tlsSettings = { serverName: j.sni || j.host || j.add, fingerprint: j.fp || "" };
    } else if (ss.security === "reality") {
        // reality was silently downgraded to "none" before, which produces a config that
        // parses fine and then fails to connect — the server looked present and broken.
        // Braces are required: without them only the assignment belongs to the else-if and
        // the publicKey check below would run for every link, crashing on plain ones.
        ss.realitySettings = {
            serverName: j.sni || j.host || j.add,
            fingerprint: j.fp || "chrome",
            publicKey: j.pbk || "",
            shortId: j.sid || "",
            spiderX: j.spx || ""
        };
        if (!ss.realitySettings.publicKey)
            return null;                  // no key means it cannot work: say unsupported
    }
    if (net === "ws")
        ss.wsSettings = { path: j.path || "/", headers: j.host ? { Host: j.host } : {} };
    else if (net === "grpc")
        ss.grpcSettings = { serviceName: j.path || "" };
    else if (net === "h2" || net === "http") {
        ss.network = "http";
        ss.httpSettings = { host: j.host ? [j.host] : [], path: j.path || "/" };
    } else if (net === "xhttp")
        ss.xhttpSettings = { path: j.path || "/", host: j.host || "" };
    var user = { id: utf8(j.id), alterId: parseInt(j.aid || "0", 10), security: j.scy || "auto" };
    return {
        remarks: j.ps || (j.add + ":" + port),
        inbounds: baseInbounds(),
        outbounds: [
            { tag: "proxy", protocol: "vmess", settings: { vnext: [{ address: j.add, port: port, users: [user] }] }, streamSettings: ss },
            { tag: "direct", protocol: "freedom" },
            { tag: "block", protocol: "blackhole" }
        ]
    };
}

function trojanUri(u) {
    var h = splitHead(u, "trojan://");
    var hp = hostPort(h.rest);
    if (!hp || !hp.host)
        return null;
    return {
        remarks: h.name || (hp.host + ":" + hp.port),
        inbounds: baseInbounds(),
        outbounds: [
            { tag: "proxy", protocol: "trojan", settings: { servers: [{ address: hp.host, port: hp.port, password: utf8(hp.user) }] }, streamSettings: streamFromQuery(h.q) },
            { tag: "direct", protocol: "freedom" },
            { tag: "block", protocol: "blackhole" }
        ]
    };
}

function decodeUserInfo(s) {
    // The userinfo of an ss:// link is either base64 ("user:pass") or, per SIP002, literal
    // percent-encoded text. Note that utf8() is for base64-decoded binary: escape() turns "%"
    // into "%25", so percent-escapes survive a round trip undecoded. Literal parts need
    // decodeURIComponent.
    var lit = "";
    try { lit = decodeURIComponent(String(s)); } catch (e) { lit = String(s); }
    if (lit.indexOf(":") >= 0)
        return lit;
    var dec = b64decode(s);
    return (dec === null) ? "" : utf8(dec);
}

function ssUri(u) {
    var h = splitHead(u, "ss://");
    var rest = h.rest;
    var creds = "";
    var hp = null;
    if (rest.indexOf("@") >= 0) {
        var at = rest.lastIndexOf("@");
        creds = decodeUserInfo(rest.slice(0, at));
        hp = hostPort(creds + rest.slice(at));
    } else {
        // entire thing is base64(method:pass@host:port)
        var dec = b64decode(rest);
        if (dec === null)
            return null;
        dec = utf8(dec);
        var at2 = dec.lastIndexOf("@");
        if (at2 < 0)
            return null;
        creds = dec.slice(0, at2);
        hp = hostPort(creds + dec.slice(at2));
    }
    if (!hp || !hp.host || creds.indexOf(":") < 0)
        return null;
    var colon = creds.indexOf(":");
    var method = creds.slice(0, colon);
    var password = utf8(creds.slice(colon + 1));
    var ss = { network: "tcp" };
    if (h.q.security === "tls" || h.q.type === "tls") {
        ss.security = "tls";
        ss.tlsSettings = { serverName: h.q.sni || hp.host };
    }
    if (h.q.type === "ws")
        ss.wsSettings = { path: h.q.path || "/", headers: h.q.host ? { Host: h.q.host } : {} };
    if (h.q.type === "grpc")
        ss.grpcSettings = { serviceName: h.q.serviceName || "" };
    return {
        remarks: h.name || (hp.host + ":" + hp.port),
        inbounds: baseInbounds(),
        outbounds: [
            { tag: "proxy", protocol: "shadowsocks", settings: { servers: [{ address: hp.host, port: hp.port, method: method, password: password }] }, streamSettings: ss },
            { tag: "direct", protocol: "freedom" },
            { tag: "block", protocol: "blackhole" }
        ]
    };
}

function uriToXray(u) {
    if (/^vless:\/\//i.test(u))
        return vlessUri(u);
    if (/^vmess:\/\//i.test(u))
        return vmessUri(u);
    if (/^trojan:\/\//i.test(u))
        return trojanUri(u);
    if (/^ss:\/\//i.test(u))
        return ssUri(u);
    return null;
}

// Protocols Xray actually implements. A subscription is remote input and can name anything;
// the core is started with whatever the provider wrote, and an outbound it does not know
// fails only at connect time — the plugin says "connected" and nothing works. That is worse
// than not offering the server. Hysteria (protocol "hysteria", version 2) belongs here since
// the engine learned it: the provider's entries arrive as complete configs with
// hysteriaSettings and a finalmask/salamander wrapper, and xray run -test validates them
// like any other outbound (test/protocol_matrix.js checks that on every run).
var CORE_PROTOCOLS = ["vless", "vmess", "trojan", "shadowsocks", "hysteria", "socks", "http", "wireguard", "dns", "freedom", "blackhole", "loopback"];

function coreCanRun(cfg) {
    var obs = (cfg && cfg.outbounds) || [];
    for (var i = 0; i < obs.length; i++) {
        var ob = obs[i];
        if (!ob || !ob.protocol) continue;
        if (CORE_PROTOCOLS.indexOf(String(ob.protocol)) < 0)
            return false;
    }
    return true;
}

function isXrayConfig(o) {
    return !!o && typeof o === "object" && (o.inbounds !== undefined || o.outbounds !== undefined);
}

function parseSubscription(text) {
    var t = String(text || "").trim();
    if (!t)
        return { configs: [], unsupported: 0, kind: "empty", error: "" };
    // The body arrives in three wrappings: raw JSON, a raw list of links, or base64 around
    // either. Strip the wrapper once, then branch on the shape — the old order ran the JSON
    // branch on the raw text only, so a base64-wrapped config list fell through to the link
    // parser and came back "unknown".
    var body = null, kindName = "base64";
    if (t.charAt(0) === "[" || t.charAt(0) === "{") {
        body = t;
        kindName = "json";
    } else if (t && t.indexOf("://") >= 0) {
        // A plain list of links is a valid subscription too — plenty of providers serve it
        // unencoded. The "://" test has to run against the raw body, not against the decoded
        // one: otherwise those subscriptions never reach the link parser and the user gets
        // "not base64" with an empty server list, which is exactly what they report when a
        // provider switches to plain text.
        body = t;
        kindName = "links";
    } else {
        var dec = b64decode(t);
        if (dec === null)
            return { configs: [], unsupported: 0, kind: "bad-base64", error: "not base64" };
        body = dec;
        if (body.charAt(0) === "[" || body.charAt(0) === "{")
            kindName = "json";
    }
    if (body.charAt(0) === "[" || body.charAt(0) === "{") {
        try {
            var j = JSON.parse(body);
            var arr = (j instanceof Array) ? j : [j];
            var usable = arr.filter(isXrayConfig);
            var cfgs = usable.filter(coreCanRun);
            if (cfgs.length)
                return { configs: cfgs, unsupported: arr.length - cfgs.length, kind: kindName, error: "" };
            // Parsed fine, but nothing in it can run on this client. Say that instead of
            // falling through to the base64 branch and blaming the encoding.
            if (usable.length)
                return { configs: [], unsupported: usable.length, kind: "unsupported", error: "" };
        } catch (e) {
            // It looked like JSON and was not. Say so instead of quietly falling through to
            // base64 and reporting an empty list, which told the user nothing.
            return { configs: [], unsupported: 0, kind: "json-error", error: String(e && e.message || e) };
        }
    }
    if (body && body.indexOf("://") >= 0) {
        var lines = body.split(/\r?\n/);
        var out = [], uns = 0;
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i].trim();
            if (!line)
                continue;
            var c = uriToXray(line);
            if (c && coreCanRun(c))
                out.push(c);
            else
                uns++;
        }
        if (out.length)
            return { configs: out, unsupported: uns, kind: kindName, error: "" };
        return { configs: [], unsupported: uns, kind: "empty-list", error: "" };
    }
    return { configs: [], unsupported: 0, kind: "unknown", error: "" };
}

// The server behind a config: its outbound tag "proxy" and where it points.
function serverInfo(cfg, index) {
    var obs = (cfg && cfg.outbounds) || [];
    var ob = null;
    for (var i = 0; i < obs.length; i++)
        if (obs[i].tag === "proxy") { ob = obs[i]; break; }
    if (!ob) {
        for (var j = 0; j < obs.length; j++)
            if (obs[j].protocol && obs[j].protocol !== "freedom" && obs[j].protocol !== "blackhole") { ob = obs[j]; break; }
    }
    if (!ob)
        ob = obs[0] || {};
    var s = ob.settings || {};
    var host = "", port = 0;
    if (s.vnext && s.vnext[0]) {
        host = s.vnext[0].address; port = s.vnext[0].port;
    } else if (s.servers && s.servers[0]) {
        host = s.servers[0].address; port = s.servers[0].port;
    } else if (s.address) {
        host = s.address; port = s.port;
    }
    var net = (ob.streamSettings && ob.streamSettings.network) || "";
    // Hysteria2 rides on sing-box directly, so no Xray runs for it at all. The credentials
    // are carried here rather than looked up later: the plugin hands them to the privileged
    // helper through a 0600 file, and by then it only has the server entry, not the config.
    var ss = ob.streamSettings || {};
    var hs = ss.hysteriaSettings || {};
    var tlsS = ss.tlsSettings || {};
    // Salamander obfuscation is a second secret the provider may require; without it the
    // server drops the handshake rather than answering.
    var obfsPw = "";
    var masks = (ss.finalmask && ss.finalmask.udp) || [];
    for (var m = 0; m < masks.length; m++)
        if (masks[m] && masks[m].type === "salamander")
            obfsPw = (masks[m].settings && masks[m].settings.password) || "";
    var engine = (ob.protocol === "hysteria") ? "sing-box" : "xray";
    return {
        index: index,
        name: (cfg && cfg.remarks) || (host ? host + ":" + port : ("#" + (index + 1))),
        protocol: ob.protocol || "?",
        host: host || "",
        port: port || 0,
        network: net || "tcp",
        ping: -1,
        engine: engine,
        hy: engine === "sing-box" ? {
            password: String(hs.auth || ""),
            sni: String(tlsS.serverName || ""),
            insecure: !!tlsS.allowInsecure,
            obfsPw: String(obfsPw)
        } : null
    };
}

function serversFrom(configs) {
    var out = [];
    for (var i = 0; i < configs.length; i++)
        out.push(serverInfo(configs[i], i));
    return out;
}

function clone(o) {
    return JSON.parse(JSON.stringify(o));
}

// A runnable config: local ports rewritten, stats API injected, split rules added.
function normalize(cfg, opts) {
    var c = clone(cfg);

    // A subscription is remote input. It must never get to choose what this machine listens
    // on: the inbound list is built from scratch here, so neither the provider nor anyone who
    // can answer the subscription URL can smuggle in an extra inbound — an unauthenticated
    // SOCKS on 0.0.0.0 would turn the machine into an open proxy for the whole LAN for as
    // long as the user stays connected. Everything below listens on loopback only.
    c.inbounds = [
        { tag: "socks", protocol: "socks", listen: "127.0.0.1", port: opts.socksPort, settings: { auth: "noauth", udp: true } },
        { tag: "http", protocol: "http", listen: "127.0.0.1", port: opts.httpPort, settings: {} },
        { tag: "api", listen: "127.0.0.1", port: opts.apiPort, protocol: "dokodemo-door", settings: { address: "127.0.0.1" } }
    ];

    // Same reasoning for the resolver: a subscription that points `dns` at its own host would
    // quietly own every lookup this client makes. The user's own setting wins instead.
    if (opts.dns)
        c.dns = { servers: [opts.dns], queryStrategy: "UseIPv4" };

    c.log = { loglevel: "warning" };
    c.api = { tag: "api", services: ["StatsService", "HandlerService"] };
    c.stats = {};
    c.policy = { system: { statsInboundUplink: true, statsInboundDownlink: true, statsOutboundUplink: true, statsOutboundDownlink: true } };

    c.routing = c.routing || {};
    if (!c.routing.rules)
        c.routing.rules = [];
    if (!c.routing.domainStrategy)
        c.routing.domainStrategy = "IPIfNonMatch";
    var rules = [{ type: "field", inboundTag: ["api"], outboundTag: "api" }];
    if (opts.directDomains && opts.directDomains.length)
        rules.push({ type: "field", domain: opts.directDomains.slice(), outboundTag: "direct" });
    if (opts.directApps && opts.directApps.length)
        rules.push({ type: "field", processName: opts.directApps.slice(), outboundTag: "direct" });
    c.routing.rules = rules.concat(c.routing.rules);
    return c;
}

// subscription-userinfo: upload=0; download=…; total=…; expire=…
function parseUserInfo(value) {
    var out = { upload: 0, download: 0, total: 0, expire: 0 };
    if (!value)
        return out;
    var parts = String(value).split(";");
    for (var i = 0; i < parts.length; i++) {
        var eq = parts[i].indexOf("=");
        if (eq < 0)
            continue;
        var k = parts[i].slice(0, eq).trim();
        var v = parseInt(parts[i].slice(eq + 1).trim(), 10);
        if (!isNaN(v) && out[k] !== undefined)
            out[k] = v;
    }
    return out;
}
