pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.config
import qs.services
import "Subscriptions.js" as Sub

// The VPN controller. One instance for the whole shell (qmldir: `singleton Vpn`).
// Main.qml hands it the plugin context; the desktop widget, the bar pill, the window and
// the settings page all read this. It owns the subscription fetch, the server list, the
// Xray core, the traffic stats and the privileged TUN helper.
Singleton {
    id: root

    // ---- attach ---------------------------------------------------------------
    property var plugin: null
    property bool loaded: false
    function attach(p) {
        if (!p)
            return;
        plugin = p;
        if (!loaded)
            load();
    }
    function get(k, d) {
        return plugin ? plugin.get(k, d) : d;
    }
    function put(k, v) {
        if (plugin)
            plugin.set(k, v);
    }
    function arr(v) {
        if (!v)
            return [];
        if (v instanceof Array)
            return v;
        var out = [];
        for (var i = 0; i < v.length; i++)
            out.push(v[i]);
        return out;
    }
    function tr(ru, en) {
        return I18n.t(ru, en);
    }

    // ---- logs (diagnostics) ---------------------------------------------------
    // Everything that can touch the network is narrated here; the Logs tab shows it live and
    // the whole buffer can be copied for a bug report.
    function log(msg) {
        if (!loggingOn)
            return;
        var line = Qt.formatDateTime(new Date(), "HH:mm:ss") + "  " + msg;
        var a = logs.slice();
        a.push(line);
        if (a.length > logLimit)
            a = a.slice(a.length - logLimit);
        logs = a;
        _logPending += line + "\n";
        logFlush.restart();
    }
    function fullLog() {
        var s = logs.join("\n");
        if (diagText)
            s += (s ? "\n\n" : "") + diagText;
        return s;
    }
    function flushLogs() {
        if (!_logPending)
            return;
        // The cache directory may not exist yet at startup (helperCheck logs within
        // milliseconds). Writing now would fail with ENOENT and the pending text has already
        // been cleared, so the line would be lost silently — wait for ensureProc instead.
        // This also avoids reaching for helperCheck from here, which may not exist yet.
        if (!_cacheReady) {
            logFlush.restart();
            return;
        }
        if (logWrite.running) {
            logFlush.restart();
            return;
        }
        var data = _logPending;
        _logPending = "";
        logWrite.command = writeFileCmd(logFile, data, true);
        logWrite.running = true;
    }
    // Writes `data` to `path` with 0600, as one argv.
    //
    // A single argument cannot exceed MAX_ARG_STRLEN — 32 pages, 128 KiB on Linux — and the
    // failure is silent: execve returns E2BIG, the shell never runs, and the file is simply
    // not there. The limits were never close, though: a 1000-server subscription is ~259 KB
    // and a full log dump ~145 KB, so `saveLogs` failed on a long session and a large
    // subscription was silently never cached — the plugin would just re-fetch it next time
    // and say nothing about it.
    //
    // The cap is per argument, not on the total: ARG_MAX is 2 MB, so the payload is split
    // into 60 KB pieces and appended in order. That lifts the ceiling to roughly 2 MB, which
    // is far past anything a subscription or a log dump reaches. stdin would avoid the split
    // entirely but was abandoned earlier — a writer can wedge open and stall the connect.
    function writeFileCmd(path, data, append) {
        var chunk = 60000;
        var script = "umask 077; " + (append ? "" : ": > \"$1\"; ");
        var cmd = ["sh", "-c", "", "sh", path];
        var n = 2;
        for (var i = 0; i < data.length; i += chunk) {
            // ${n} and not $n: with ten or more parts "$10" is not parameter ten — a POSIX
            // shell reads it as $1 followed by a literal "0", so the tenth chunk silently
            // became the output path. Anything past 500 KB, which is nine chunks and well
            // within ARG_MAX, lost its tail that way.
            script += "printf %s \"${" + n + "}\" >> \"$1\"; ";
            cmd.push(data.substring(i, i + chunk));
            n++;
        }
        if (append && data.length === 0)
            script = "umask 077; : >> \"$1\"; ";
        cmd[2] = script;
        return cmd;
    }
    function saveLogs() {
        // a second Save while the first is in flight would change a command that never runs,
        // and the user would get no file and no message
        if (logDump.running)
            return;
        logDump.command = writeFileCmd(logDumpPath, fullLog(), false);
        logDump.running = true;
    }
    function clearLogs() {
        logs = [];
        diagText = "";
        _logPending = "";
        // A logWrite that is already appending would land after the truncation and bring the
        // cleared lines straight back, so it is stopped first and the buffer is emptied once
        // the truncate is done.
        if (logWrite.running)
            logWrite.running = false;
        _logPending = "";
        logClear.running = true;
    }
    function copyLogs() {
        var s = fullLog();
        if (s)
            Quickshell.execDetached(["wl-copy", "--", s]);
        log("logs copied to the clipboard");
    }
    function collectDiagnostics() {
        if (diagRunning)
            return;
        diagRunning = true;
        log("collecting diagnostics…");
        diagProc.running = true;
    }
    // grab the live routes / sing-box state BEFORE tearing the TUN down, then fail
    function diagThenFail(msg) {
        _failAfterDiag = msg;
        if (!diagRunning) {
            diagRunning = true;
            diagProc.running = true;
        }
    }

    // ---- paths ----------------------------------------------------------------
    readonly property string helperPath: "/usr/local/libexec/angelos-vpn"
    // the root-owned copy of our installer: the plugin bootstraps it once, then always calls
    // that one, so no user-writable file sits between the password prompt and a root run
    readonly property string installerPath: "/usr/local/libexec/angelos-vpn-install"
    readonly property string policyPath: "/usr/share/polkit-1/actions/org.angelos.vpn.policy"
    readonly property string plugDir: {
        var u = Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "");
        return (u.length && u[u.length - 1] === "/") ? u : u + "/";
    }
    readonly property string cacheDir: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/angelos-vpn"
    readonly property string runPath: cacheDir + "/run.json"
    // Hysteria credentials, written 0600 and handed to the helper as a path rather than in
    // argv: argv is world-readable through /proc for as long as the tunnel is up, and this
    // password is the whole of the server's authentication.
    readonly property string hyCredPath: cacheDir + "/hysteria.json"
    readonly property string probePath: plugDir + "probe.py"
    readonly property string assetDir: xrayPath.substring(0, xrayPath.lastIndexOf("/"))

    // ---- settings (persisted on change) --------------------------------------
    property string mode: "proxy"              // proxy | tun
    property bool autoconnect: false
    property bool systemProxy: false
    property bool killSwitch: false
    property bool splitOn: false
    property string dns: "1.1.1.1"
    property int socksPort: 11080
    property int httpPort: 11081
    // defaults to socksPort + 1000, but the port scan may move it to a free one when that
    // default is taken (see portScan.onExited)
    property int apiPort: socksPort + 1000
    // Found at startup by findbins.py; an empty path means the engine is not installed. The user
    // can still point these somewhere else in the settings, and that wins over the search.
    property string xrayPath: ""
    property string singBoxPath: ""
    property var missingBins: []
    property var foundDeps: ({})
    property var subs: []
    property string activeSubId: ""
    property int selectedIndex: 0
    property var directApps: []
    property var directDomains: []
    property string hwid: ""

    // ---- runtime --------------------------------------------------------------
    property string status: "off"              // off | connecting | on | error
    property string message: ""
    property bool loadingSub: false
    property bool pinging: false
    property bool helperInstalled: false
    property bool installerReady: false
    // the cache directory exists and is private: the log writer waits for this
    property bool _cacheReady: false
    // how many times the post-connect health check may fail before we call the tunnel dead
    readonly property int healthTries: 3
    property int _healthTries: 0
    property bool helperInstalling: false
    // set when an install or remove ended non-zero, so the TUN page can say so instead of
    // letting the poll time out and look like a success
    property bool helperInstallFailed: false
    property bool settingsOpen: false
    property var servers: []
    property var userinfo: ({})            // sub id -> {upload, download, total, expire}
    property var _configs: []
    property real upSpeed: 0
    property real downSpeed: 0
    property real totalUp: 0
    property real totalDown: 0
    property double _lastUp: 0
    property double _lastDown: 0
    property double _lastStatsAt: 0
    property bool _stopping: false
    property bool _stopToOff: false
    property bool _reconnect: false
    property bool _queuedConnect: false
    property bool _tunDownQuiet: false
    property bool _autoPending: false
    property bool _needHwid: false
    property bool _sysProxyOn: false
    // the user's own proxy settings, captured before we change them (see applySystemProxy)
    property var _sysProxySaved: []
    property bool _staleCleaned: false
    property var _fetchSub: null
    property var _queuedSub: null
    property int fetchIndex: 0
    property int fetchTotal: 0
    property string fetchSubId: ""
    property string fetchPhase: ""
    property string _writeData: ""
    // the Hysteria credentials being written for the helper, kept apart from _writeData so a
    // subscription refresh landing at the same moment cannot clobber the file mid-connect
    property string _hyCredData: ""
    // the server the connect in flight was started for. Every step that reads the server list
    // afterwards compares against this, because a switch mid-connect otherwise leaves the
    // config written for one server and the tunnel built for another.
    property int _connectIndex: -1
    // the user asked to stop, whatever the status still says. Set by disconnect() and cleared
    // by the next beginConnect(), so a `up` that lands after a disconnect is recognised as a
    // cancelled attempt rather than a failure or a success.
    property bool _disconnecting: false
    // dropHyCreds() found the credentials writer still running: it wants a second removal once
    // that process is really gone, because the first one may have raced ahead of its redirection
    property bool _hyCredDrop: false
    // the subscription body being written to the cache (kept apart from _writeData, which
    // belongs to the run config)
    property string _subData: ""
    // a cache write that arrived while another was still running: { id, raw }
    property var _subPending: null
    // the server list as it was when the ping started; results are dropped if it changed
    property var _pingSnapshot: null
    property string _coreErr: ""
    property string _hdrSub: ""
    property string _unlinkId: ""
    property int readyTicks: 0

    // ---- logs (diagnostics) ---------------------------------------------------
    property var logs: []
    readonly property int logLimit: 1000
    property bool loggingOn: true
    property string diagText: ""
    property bool diagRunning: false
    property string _failAfterDiag: ""
    property string _logPending: ""
    readonly property string logFile: cacheDir + "/plugin.log"
    readonly property string logDumpPath: cacheDir + "/plugin-dump.txt"

    readonly property bool connected: status === "on"
    readonly property bool busy: status === "connecting"
    readonly property var currentServer: (selectedIndex >= 0 && selectedIndex < servers.length) ? servers[selectedIndex] : null
    readonly property string currentName: currentServer ? currentServer.name : tr("Нет сервера", "No server")
    readonly property var activeSub: {
        for (var i = 0; i < subs.length; i++)
            if (subs[i].id === activeSubId)
                return subs[i];
        return subs.length ? subs[0] : null;
    }

    // ---- load -----------------------------------------------------------------
    function load() {
        loaded = true;
        mode = get("mode", "proxy");
        autoconnect = get("autoconnect", false);
        systemProxy = get("systemProxy", false);
        killSwitch = get("killSwitch", false);
        splitOn = get("splitOn", false);
        dns = get("dns", "1.1.1.1");
        socksPort = get("socksPort", 11080);
        httpPort = get("httpPort", 11081);
        // a path the user chose by hand always wins; otherwise take what findbins.py found
        xrayPath = get("xrayPath", "");
        subs = arr(get("subs", []));
        activeSubId = get("activeSubId", "");
        selectedIndex = get("selectedIndex", 0);
        directApps = arr(get("directApps", []));
        directDomains = arr(get("directDomains", []));
        hwid = get("hwid", "");
        if (!activeSubId && subs.length) {
            activeSubId = subs[0].id;
            put("activeSubId", activeSubId);
        }
        if (autoconnect && activeSub)
            _autoPending = true;
        // The cache directory has to exist before anything logs into it. Rather than chain the
    // processes (which breaks because helperCheck is declared much later and may not exist
    // yet when ensureProc finishes), flushLogs() waits for _cacheReady. So both can start
    // here and the first log line is simply held back a moment.
        ensureProc.running = true;
        helperCheck.running = true;
        // the engines are looked up rather than assumed: the plugin has to run on a machine
        // that has no Happ installed
        findBins.running = true;
        if (!hwid) {
            _needHwid = true;
            machineId.running = true;
        } else {
            loadCache();
        }
    }

    function loadCache() {
        if (!activeSub)
            return;
        cacheRead.command = ["cat", cacheDir + "/sub-" + activeSub.id + ".json"];
        cacheRead.running = true;
    }

    function afterConfigs() {
        if (_autoPending) {
            _autoPending = false;
            Qt.callLater(connect);
        }
    }

    // ---- subscriptions --------------------------------------------------------
    function refresh(sub) {
        var s = sub || activeSub;
        if (!s) {
            message = tr("Сначала добавь подписку", "Add a subscription first");
            return;
        }
        if (fetchProc.running) {
            // never drop a request: run it right after the one in flight
            _queuedSub = s;
            return;
        }
        loadingSub = true;
        message = tr("Обновляю подписку…", "Refreshing subscription…");
        fetchIndex = 0;
        fetchTotal = 0;
        fetchSubId = s.id;
        fetchPhase = "resolve";
        _fetchSub = s;
        var h = (s.hwid || hwid || "").trim();
        // fetch.sh walks every resolved IPv4 and retries: one of Fortuna's A-records is often dead
        fetchProc.command = ["sh", plugDir + "fetch.sh", s.url, cacheDir + "/sub-" + s.id + ".hdr", h];
        fetchProc.running = true;
    }

    // fetch.sh narrates its steps on stderr: "angelos-fetch resolve" / "angelos-fetch try i n"
    function onFetchLine(line) {
        var t = String(line || "").trim();
        if (t.slice(0, 13) !== "angelos-fetch")
            return;
        var a = t.slice(13).trim().split(/\s+/);
        if (a[0] === "resolve") {
            fetchPhase = "resolve";
        } else if (a[0] === "try" && a.length >= 3) {
            fetchPhase = "try";
            fetchIndex = parseInt(a[1], 10) || 0;
            fetchTotal = parseInt(a[2], 10) || 0;
        }
    }

    function writeCache(id, raw) {
        // its own data slot: _writeData belongs to runWrite, and a subscription landing in
        // the middle of a connect would otherwise write itself over run.json
        _subData = raw;
        // `running = true` is a no-op while the process is busy, which would drop this write
        // and leave the subscription uncached until the next start
        if (subCacheWrite.running) {
            _subPending = { "id": id, "raw": raw };
            return;
        }
        subCacheWrite.command = writeFileCmd(cacheDir + "/sub-" + id + ".json", _subData, false);
        subCacheWrite.running = true;
    }

    function addSub(url, name, hw) {
        url = (url || "").trim();
        if (!url)
            return;
        // Only http(s). The IPC socket is reachable by anything in the session, and curl
        // happily services file://, dict:// and gopher://, so an unchecked URL would let a
        // local process read arbitrary files and have them written into the subscription cache.
        if (!/^https?:\/\/[^\s\/]+/i.test(url)) {
            message = tr("Нужна ссылка http:// или https://", "An http:// or https:// URL is required");
            log("rejected a subscription URL with an unsupported scheme");
            return;
        }
        var s = {
            "id": "s" + Date.now().toString(36) + Math.floor(Math.random() * 1e4).toString(36),
            "name": (name || "").trim() || tr("Подписка", "Subscription"),
            "url": url,
            "hwid": (hw || "").trim() || hwid
        };
        subs = subs.concat([s]);
        put("subs", subs);
        if (!activeSubId) {
            activeSubId = s.id;
            put("activeSubId", activeSubId);
        }
        refresh(s);
    }
    function removeSub(id) {
        subs = subs.filter(function (s) {
            return s.id !== id;
        });
        put("subs", subs);
        if (activeSubId === id) {
            activeSubId = subs.length ? subs[0].id : "";
            put("activeSubId", activeSubId);
        }
        if (!subs.length) {
            servers = [];
            _configs = [];
        }
        // a deleted subscription must stop being live data: drop its cached body (it holds
        // the server list with the real UUIDs) and stop an in-flight fetch from resurrecting it
        if (_fetchSub && _fetchSub.id === id)
            _fetchSub = null;
        if (_queuedSub && _queuedSub.id === id)
            _queuedSub = null;
        _unlinkId = id;
        unlinkCache.running = true;
    }
    function selectSub(id) {
        if (activeSubId === id)
            return;
        activeSubId = id;
        put("activeSubId", id);
        selectedIndex = 0;
        put("selectedIndex", 0);
        servers = [];
        _configs = [];
        for (var i = 0; i < subs.length; i++)
            if (subs[i].id === id) { refresh(subs[i]); return; }
    }
    function updateSub(id) {
        // refresh() queues behind a fetch that is already running and returns immediately. If we
        // set activeSubId here the label would change while servers/_configs still held the
        // previous subscription, and connecting in that window would start the old server under
        // the new subscription's name. The success path sets activeSubId itself, once the
        // servers it belongs to are actually in place.
        for (var i = 0; i < subs.length; i++)
            if (subs[i].id === id) { refresh(subs[i]); return; }
    }

    // ---- connect / disconnect -------------------------------------------------
    function connect() {
        log("connect request: mode=" + mode + " status=" + status + " server=" + currentName);
        if (status === "on" || status === "connecting") {
            // A stop may be in flight: the core has been asked to die but has not exited yet,
            // so the status still reads "on". Dropping the request here left the user with an
            // enabled-looking VPN that silently did nothing — queue it for finishStop().
            // _stopping covers the proxy-mode window where coreProc is no longer "running"
            // but the process has not reported its exit yet.
            if (status === "on" && (coreProc.running || downProc.running || _stopping)) {
                _queuedConnect = true;
                message = tr("Переподключаюсь…", "Reconnecting…");
            }
            return;
        }
        if (!servers.length) {
            if (activeSub)
                refresh();
            else
                message = tr("Добавь подписку", "Add a subscription");
            return;
        }
        if (selectedIndex < 0 || selectedIndex >= _configs.length)
            selectedIndex = 0;
        status = "connecting";
        message = tr("Проверяю порты…", "Checking ports…");
        _stopping = false;
        portScan.running = true;
    }
    // pick free ports so we never fight the Happ daemon (it holds 10808/10809)
    function portUsed(txt, p) {
        return txt.indexOf(":" + p + " ") >= 0;
    }
    function freePort(txt, start) {
        var p = start;
        while (p < 65535 && portUsed(txt, p))
            p++;
        return p < 65535 ? p : start;
    }
    function beginConnect() {
        // The user asked to stop while the port scan was still running. Nothing has been
        // started yet, so there is nothing to tear down either — carry on and the pipeline
        // would bring the tunnel up behind the user's back.
        if (_disconnecting) {
            _disconnecting = false;
            finishStop();
            return;
        }
        // Every later step of the connect reads the server list again — `helperUp()` needs the
        // host, the diagnostics need it for a route lookup. If the user switches servers while
        // this pipeline is running, those readers see the NEW server while the config written
        // just above belongs to the OLD one, and the helper then exempts only the new host from
        // the tunnel: Xray's own connection to the old server gets captured by the tunnel it is
        // serving, and the tunnel comes up dead. Pinning the index here is what every later
        // reader checks against, so the mismatch is caught rather than acted on.
        _connectIndex = selectedIndex;
        _disconnecting = false;
        // Hysteria runs on sing-box itself, so in TUN mode there is no core to start at all:
        // the helper brings up the tunnel with the Hysteria outbound already wired in. Starting
        // Xray as well would leave a second process holding the same port range, and its own
        // connection to the server would be captured by the tunnel it is meant to serve.
        if (mode === "tun" && (currentServer || {}).engine === "sing-box") {
            writeHyCreds();
            return;
        }
        var cfg = Sub.normalize(_configs[selectedIndex], {
            "socksPort": socksPort,
            "httpPort": httpPort,
            "apiPort": apiPort,
            // the subscription must not choose the resolver: the user's own setting wins
            "dns": dns,
            "directDomains": splitOn ? directDomains : [],
            "directApps": splitOn ? directApps : []
        });
        _writeData = JSON.stringify(cfg);
        log("starting core for " + currentName + " (socks " + socksPort + ", http " + httpPort + ")");
        message = tr("Запускаю ядро…", "Starting the core…");
        // the text goes in as an argv entry: a stdin writer (write() + stdinEnabled=false)
        // wedges open on some runs, which stalls the whole connect and then fails
        runWrite.command = writeFileCmd(runPath, _writeData, false);
        runWrite.running = true;
    }
    function disconnect() {
        if (status === "off")
            return;
        if (mode === "tun") {
            message = tr("Отключаю…", "Disconnecting…");
            // An explicit flag, because status is the wrong thing to test: in TUN mode this
            // returns without changing it, so `up` would still see "connecting" and report a
            // TUN failure over the disconnect the user just asked for.
            _disconnecting = true;
            // `up` is NOT killed here, and that is deliberate. Killing the client only kills
            // pkexec: the helper is already root by then, so it carries on and starts sing-box
            // anyway — after `down` has finished and torn the tunnel down. The machine ends up
            // with two sing-box processes and a tunnel nobody asked for. Instead `up` is left to
            // finish and `down` runs from its onExited, which serialises the two: the helper
            // that goes up is always the one that comes back down.
            //
            // The case where the connect is still earlier in its pipeline — the port scan, the
            // credentials — is the mirror of that: nothing is running yet, so `down` would go
            // first and the pipeline would then bring the tunnel up behind it. Every step that
            // could still call the helper therefore checks _disconnecting and abandons the
            // connect instead. Down is only run here when there is genuinely something to tear
            // down and nothing in flight that will report back.
            if (hyCredWrite.running || upProc.running || portScan.running || runWrite.running
                    || coreProc.running) {
                if (hyCredWrite.running)
                    hyCredWrite.running = false;
                return;
            }
            downProc.running = true;
        } else {
            stopCore();
        }
    }
    function toggle() {
        if (status === "on" || status === "connecting")
            disconnect();
        else
            connect();
    }
    function stopCore() {
        log("core stopped");
        readyTimer.running = false;
        statsTimer.running = false;
        if (coreProc.running) {
            // "off" used to be set right here, before the core was actually gone, and the
            // deferred connect() then started on a dying process — a tunnel that never came
            // up while the UI looked fine. The stop completes when the process really exits
            // (coreProc.onExited); only then may the next one start.
            _stopping = true;
            _stopToOff = true;
            coreProc.running = false;
            return;
        }
        finishStop();
    }
    function finishStop() {
        status = "off";
        message = "";
        upSpeed = 0;
        downSpeed = 0;
        // no connect is in flight any more; a stale index here would make the next guard
        // compare against a server that has nothing to do with this stop
        _connectIndex = -1;
        applySystemProxy(false);
        // finishStop is where every stop ends up, whichever route it took, so this is the one
        // place that reliably clears the credentials. teardownTun alone would miss the plain
        // disconnect, and the file is the server's only secret.
        dropHyCreds();
        if (_reconnect) {
            _reconnect = false;
            Qt.callLater(connect);
        }
        if (_queuedConnect) {
            _queuedConnect = false;
            Qt.callLater(connect);
        }
    }
    function fail(msg) {
        log("FAIL: " + msg);
        status = "error";
        message = msg;
        readyTimer.running = false;
        statsTimer.running = false;
        if (coreProc.running) {
            _stopping = true;
            coreProc.running = false;
        }
        applySystemProxy(false);
        // never leave a dead TUN behind: it would keep the whole network captive
        teardownTun();
    }
    // the emergency brake: stop everything at once, no matter what state we are in
    function forceOff() {
        _reconnect = false;
        _queuedConnect = false;
        _autoPending = false;
        _stopping = false;
        _stopToOff = false;
        readyTimer.running = false;
        statsTimer.running = false;
        helperPoll.running = false;
        helperInstalling = false;
        if (coreProc.running)
            coreProc.running = false;
        if (runWrite.running)
            runWrite.running = false;
        if (upProc.running)
            upProc.running = false;
        if (pingProc.running) {
            pingProc.running = false;
            _pingSnapshot = null;
        }
        // take our TUN down (if the helper is around) so the network always comes back
        if (helperInstalled && !downProc.running) {
            _tunDownQuiet = true;
            downProc.running = true;
        }
        status = "off";
        message = "";
        pinging = false;
        upSpeed = 0;
        downSpeed = 0;
        totalUp = 0;
        totalDown = 0;
        applySystemProxy(false);
    }
    // the core died while the TUN is up: take the TUN down, keep the error status
    function teardownTun() {
        dropHyCreds();
        if (mode === "tun" && !downProc.running) {
            _tunDownQuiet = true;
            downProc.running = true;
        }
    }
    // The helper deletes this file the moment it reads it, but a connect that fails before it
    // gets that far — a cancelled pkexec prompt, a bad password — would otherwise leave the
    // server's only credential sitting in the cache directory.
    //
    // Stopping the writer is not enough on its own, and returning early was the original bug:
    // `sh -c '… > "$2"'` creates and truncates the file before printf writes a byte, so killing
    // it leaves a file that is empty or half-written — and the early return meant nothing ever
    // removed it. Issuing the removal unconditionally instead closes that, with one gap left:
    // `running = false` only asks the process to stop, so an `rm` launched straight away can
    // finish first and a writer that had not yet reached its redirection creates the file
    // afterwards. Hence the flag: hyCredWrite removes it again on the way out, once the
    // process is really gone. Two removals, no window in between.
    function dropHyCreds() {
        if (hyCredWrite.running) {
            _hyCredDrop = true;
            hyCredWrite.running = false;
        }
        hyCredRemove.command = ["rm", "-f", hyCredPath];
        hyCredRemove.running = true;
    }
    function rmHyCreds() {
        hyCredRemove.command = ["rm", "-f", hyCredPath];
        hyCredRemove.running = true;
    }

    // The shell is going away gracefully (a session logout, a plugin reload). The helper's
    // watchdog is the real guarantee — `qs kill` ends the process natively, so this may
    // never run — but taking the tunnel down here keeps a normal exit immediate.
    function shutdown() {
        // a connect that was mid-flight when the shell exited never reached finishStop
        dropHyCreds();
        if (status !== "on" && status !== "connecting")
            return;
        if (mode === "proxy") {
            applySystemProxy(false);
            return;
        }
        if (!helperInstalled) {
            // no helper to ask: kill the core directly, it owns no privileges
            if (coreProc.running)
                coreProc.running = false;
            return;
        }
        log("shell is exiting: taking the TUN down");
        // no password is asked: the polkit rule allows the active session
        var p = Quickshell.execDetached(["pkexec", helperPath, "down"]);
        try {
            p.waitForFinished(3000);
        } catch (e) {
            // the shell is already tearing down; the helper's watchdog covers this
        }
    }
    Component.onDestruction: shutdown()
    function finalizeOn() {
        status = "on";
        log("connected: mode=" + mode + " server=" + currentName);
        message = "";
        startStats();
        if (plugin) {
            plugin.achieve("first-connect");
            if (mode === "tun")
                plugin.achieve("tun");
        }
        if (systemProxy && mode === "proxy") {
            // capture what the user had, so disconnecting can put it back
            if (!_sysProxySaved.length)
                readSystemProxy();
            applySystemProxy(true);
        }
        // TUN takes over the whole system: check that traffic actually flows, and if not,
        // bring it straight down again instead of leaving the machine without internet
        if (mode === "tun") {
            _healthTries = 0;
            healthTimer.restart();
        }
    }
    function coreReady() {
        if (mode === "tun")
            helperUp();
        else
            finalizeOn();
    }
    function writeHyCreds() {
        var s = currentServer || {};
        if (_disconnecting) {
            // cancelled before anything was written — see beginConnect
            _disconnecting = false;
            finishStop();
            return;
        }
        var hy = s.hy || {};
        if (!hy.password) {
            fail(tr("У сервера нет пароля Hysteria — подключиться нечем.",
                    "This server has no Hysteria password — there is nothing to connect with."));
            return;
        }
        _hyCredData = JSON.stringify({
            server: s.host || "",
            port: s.port || 443,
            password: hy.password,
            sni: hy.sni || "",
            insecure: !!hy.insecure,
            obfsPw: hy.obfsPw || ""
        });
        message = tr("Готовлю Hysteria…", "Preparing Hysteria…");
        hyCredWrite.command = writeFileCmd(hyCredPath, _hyCredData, false);
        hyCredWrite.running = true;
    }
    function helperUp() {
        // The last gate before root is reached. Both conditions matter: _disconnecting is the
        // user's explicit cancel, and the status check is the backstop for the window where the
        // cancel was already consumed — a `down` has run and set the status to "off", while the
        // pipeline is still walking towards this call. Either way nothing has been started, so
        // there is nothing to tear down afterwards.
        if (_disconnecting || status !== "connecting") {
            _disconnecting = false;
            finishStop();
            return;
        }
        // The connect in flight was started for _connectIndex. Reading currentServer here is
        // what caused the loop: the user can switch servers while the core starts or the
        // credentials are written, and the helper then exempts only the NEW server's address,
        // so the core's own connection to the server the config was built for gets captured by
        // the tunnel that depends on it. For Hysteria the same moment would pair the new
        // server with the previous one's password.
        var s = currentServer || {};
        if (_connectIndex >= 0 && s.index !== _connectIndex) {
            log("server changed mid-connect; dropping it (wanted " + _connectIndex
                + ", now " + s.index + ")");
            dropHyCreds();
            fail(tr("Сервер сменился, пока шла подготовка — попробуй ещё раз.",
                    "The server changed while it was being prepared — try again."));
            return;
        }
        message = tr("Поднимаю TUN…", "Bringing up the TUN…");
        var args = ["pkexec", helperPath, "up",
            String(socksPort), String(apiPort), (s.host || ""), dns,
            (splitOn ? directApps.join(",") : ""),
            (splitOn ? directDomains.join(",") : ""),
            (killSwitch ? "1" : "0"),
            // where findbins.py located sing-box; the helper validates it before running it
            (singBoxPath || "")];
        // The ninth argument exists only for Hysteria: the helper treats the file as the
        // instruction to build a sing-box config with a Hysteria outbound instead of Xray,
        // and deletes the file as soon as it has read it.
        if ((s.engine || "xray") === "sing-box")
            args.push(hyCredPath);
        upProc.command = args;
        upProc.running = true;
    }

    function selectServer(i) {
        if (i < 0 || i >= servers.length || i === selectedIndex)
            return;
        selectedIndex = i;
        put("selectedIndex", i);
        if (status === "on" || status === "connecting") {
            _reconnect = true;
            disconnect();
        }
    }

    // ---- traffic stats --------------------------------------------------------
    function startStats() {
        _lastStatsAt = 0;
        upSpeed = 0;
        downSpeed = 0;
        // Hysteria in TUN mode has no Xray — sing-box is the whole tunnel — so its numbers
        // come from sing-box's clash API instead, which reports the same cumulative totals.
        // In proxy mode that server still goes through Xray, so it keeps the Xray query.
        if (mode === "tun" && (currentServer || {}).engine === "sing-box")
            statsProc.command = ["curl", "-s", "-m", "4",
                "http://127.0.0.1:" + apiPort + "/connections"];
        else
            statsProc.command = [root.xrayPath, "api", "statsquery",
                "--server=127.0.0.1:" + root.apiPort];
        statsTimer.running = true;
        if (!statsProc.running)
            statsProc.running = true;
    }

    // ---- ping -----------------------------------------------------------------
    function pingAll() {
        if (pinging || !servers.length)
            return;
        pinging = true;
        // A snapshot of what was asked about. The results carry bare indices, so applying them
        // to a list that changed while we were measuring would paint another subscription's
        // servers with our timings. If the list moved underneath us, the results are dropped.
        _pingSnapshot = servers.slice();
        var args = ["python3", probePath, "2"];
        for (var i = 0; i < servers.length; i++) {
            args.push(String(i));
            args.push(servers[i].host || "127.0.0.1");
            args.push(String(servers[i].port || 443));
        }
        pingProc.command = args;
        pingProc.running = true;
    }
    // did the server list change while the ping was running?
    function pingStillApplies() {
        if (!_pingSnapshot || _pingSnapshot.length !== servers.length)
            return false;
        for (var i = 0; i < servers.length; i++)
            if ((servers[i].host || "") !== (_pingSnapshot[i].host || ""))
                return false;
        return true;
    }

    // ---- split tunneling ------------------------------------------------------
    function isDirectApp(name) {
        return directApps.indexOf(name) >= 0;
    }
    function setAppDirect(name, on) {
        var a = directApps.slice();
        var i = a.indexOf(name);
        if (on && i < 0)
            a.push(name);
        else if (!on && i >= 0)
            a.splice(i, 1);
        directApps = a;
        put("directApps", a);
        restackIfOn();
    }
    function addDirectDomain(d) {
        d = (d || "").trim();
        if (!d || directDomains.indexOf(d) >= 0)
            return;
        directDomains = directDomains.concat([d]);
        put("directDomains", directDomains);
        restackIfOn();
    }
    function removeDirectDomain(d) {
        directDomains = directDomains.filter(function (x) {
            return x !== d;
        });
        put("directDomains", directDomains);
        restackIfOn();
    }
    function restackIfOn() {
        if (status === "on") {
            _reconnect = true;
            disconnect();
        }
    }

    // ---- helper (privileged TUN) ---------------------------------------------
// The first install bootstraps from the plugin directory (the installer copies itself to
// /usr/local/libexec as root). Every later install and every remove goes through that
// root-owned copy, so nothing the user can write sits between the password prompt and a root
// run — and polkit shows the translated "install the VPN helper" dialog instead of the
// generic "Execute program".
    function runInstaller(remove) {
        helperInstalling = true;
        helperInstallFailed = false;
        // Both branches need pkexec. The installer refuses to run as anything but root, so
        // exec'ing the root-owned copy directly meant the run died on its first line — and
        // helperPoll then saw the still-present files and reported success. The root copy is
        // what keeps the user's own copy of the script out of the trusted path; pkexec is what
        // makes it root in the first place. Neither replaces the other.
        var flag = remove ? "--remove" : "";
        helperInstallProc.command = ["sh", "-c",
            "if test -x \"$1\"; then exec pkexec \"$1\" \"$2\" " + flag + "; else exec pkexec \"$3\" \"$2\" " + flag + "; fi",
            "sh", root.installerPath, plugDir + "privileged", plugDir + "privileged/install.sh"];
        helperInstallProc.running = true;
        helperPoll.ticks = 0;
        helperPoll.restart();
    }
    function installHelper() {
        runInstaller(false);
    }
    function removeHelper() {
        runInstaller(true);
    }
    // A refused or failed install used to end silently: the polkit dialog was cancelled, the
    // run died, and helperPoll gave up on its timeout while the files it was checking were
    // still sitting there from the previous install — reporting a success that never happened.
    // A Process rather than execDetached, so that the exit code is actually available.
    Process {
        id: helperInstallProc
        onExited: code => {
            if (code === 0)
                return;
            root.helperInstalling = false;
            root.helperInstallFailed = true;
            root.helperPoll.running = false;
            root.log("installer exited " + code);
            root.message = root.tr("Установка не удалась — возможно, запрос пароля был отменён.",
                                   "Install failed — the password prompt may have been cancelled.");
        }
    }
    function refreshHelper() {
        helperCheck.running = true;
    }

    // ---- system proxy (best effort, GNOME/KDE schema) --------------------------
// The user's own proxy settings are read before we change them and put back afterwards: a
// corporate proxy or a Tor/Privoxy setup must survive us turning the tunnel off. Setting
// mode back to "none" unconditionally would silently destroy it.
    function proxyBackend() {
        // only GNOME's gsettings and KDE's kwriteconfig are handled; say so instead of
        // reporting success on a desktop where nothing was changed
        var de = (Quickshell.env("XDG_CURRENT_DESKTOP") || "").toLowerCase();
        if (de.indexOf("kde") >= 0 || de.indexOf("plasma") >= 0)
            return "kde";
        if (de.indexOf("gnome") >= 0 || de.indexOf("unity") >= 0 || de.indexOf("cinnamon") >= 0)
            return "gnome";
        return "";          // unknown: gsettings may still exist, so try it, but do not promise
    }
    function applySystemProxy(on) {
        if (on === _sysProxyOn)
            return;
        // Quickshell ignores `running = true` while a Process is already busy, so the new
        // command would be dropped while _sysProxyOn said otherwise — a proxy left pointing
        // at a dead SOCKS port, with the UI reporting it is off. Retire the old run first.
        if (sysProxyProc.running)
            sysProxyProc.running = false;
        _sysProxyOn = on;
        if (on)
            sysProxyProc.command = proxySetCmd();
        else
            sysProxyProc.command = proxyRestoreCmd(_sysProxySaved);
        sysProxyProc.running = true;
    }
    // Reads the current values (into _sysProxySaved) before the first change.
    function readSystemProxy() {
        sysProxyRead.command = proxyReadCmd();
        sysProxyRead.running = true;
    }
    function proxyReadCmd() {
        var be = proxyBackend();
        if (be === "kde")
            return ["sh", "-c",
                "[ -x \"$(command -v kwriteconfig6 || command -v kwriteconfig)\" ] && kwriteconfig6 --file kdeglobals --group \"Proxy Settings\" || true"];
        return ["sh", "-c", "gsettings get org.gnome.system.proxy mode 2>/dev/null || echo none; \
gsettings get org.gnome.system.proxy.socks host 2>/dev/null || true; \
gsettings get org.gnome.system.proxy.socks port 2>/dev/null || true; \
gsettings get org.gnome.system.proxy.http host 2>/dev/null || true; \
gsettings get org.gnome.system.proxy.http port 2>/dev/null || true; \
gsettings get org.gnome.system.proxy.https host 2>/dev/null || true; \
gsettings get org.gnome.system.proxy.https port 2>/dev/null || true; true"];
    }
    function proxySetCmd() {
        var kdeCmd = "k=\"$(command -v kwriteconfig6 || command -v kwriteconfig)\"; \
[ -n \"$k\" ] && { \"$k\" --file kdeglobals --group \"Proxy Settings\" --key ProxyType Manual; \
\"$k\" --file kdeglobals --group \"Proxy Settings\" --key socksProxy 127.0.0.1; \
\"$k\" --file kdeglobals --group \"Proxy Settings\" --key socksProxyPort \"$1\"; \
\"$k\" --file kdeglobals --group \"Proxy Settings\" --key httpProxy 127.0.0.1; \
\"$k\" --file kdeglobals --group \"Proxy Settings\" --key httpProxyPort \"$2\"; }; true";
        var gnomeCmd = "gsettings set org.gnome.system.proxy mode manual 2>/dev/null; \
gsettings set org.gnome.system.proxy.socks host 127.0.0.1 2>/dev/null; \
gsettings set org.gnome.system.proxy.socks port \"$1\" 2>/dev/null; \
gsettings set org.gnome.system.proxy.http host 127.0.0.1 2>/dev/null; \
gsettings set org.gnome.system.proxy.http port \"$2\" 2>/dev/null; \
gsettings set org.gnome.system.proxy.https host 127.0.0.1 2>/dev/null; \
gsettings set org.gnome.system.proxy.https port \"$2\" 2>/dev/null; true";
        return proxyBackend() === "kde"
            ? ["sh", "-c", kdeCmd, "sh", String(socksPort), String(httpPort)]
            : ["sh", "-c", gnomeCmd, "sh", String(socksPort), String(httpPort)];
    }
    // The values restored here come back from `gsettings get`, so they are the user's own
    // stored settings — but "own" is not "safe to paste into a shell". A value holding a
    // space, a `;`, `$(...)` or a backtick either breaks the command or runs one, and this
    // executes on disconnect, when nobody is watching. Anything able to write the user's dconf
    // database — a roaming profile, another process on the machine — would be choosing what
    // runs. They go in as positional arguments, the way proxySetCmd passes its ports, so
    // nothing is ever re-parsed by the shell.
    function proxyRestoreCmd(saved) {
        var s = saved || [];
        var g = function (i, fallback) {
            var v = (s[i] || "").trim().replace(/^'|'$/g, "");
            return v.length ? v : fallback;
        };
        var args = [g(0, "none"), g(1, "127.0.0.1"), g(2, "1080"),
                    g(3, "127.0.0.1"), g(4, "8080"),
                    g(5, "127.0.0.1"), g(6, "443")];
        if (proxyBackend() === "kde")
            return ["sh", "-c",
                "k=\"$(command -v kwriteconfig6 || command -v kwriteconfig)\"; \
[ -n \"$k\" ] && \"$k\" --file kdeglobals --group \"Proxy Settings\" --key ProxyType \"$1\"; true",
                "sh", args[0]];
        return ["sh", "-c",
            "gsettings set org.gnome.system.proxy mode \"$1\" 2>/dev/null; \
gsettings set org.gnome.system.proxy.socks host \"$2\" 2>/dev/null; \
gsettings set org.gnome.system.proxy.socks port \"$3\" 2>/dev/null; \
gsettings set org.gnome.system.proxy.http host \"$4\" 2>/dev/null; \
gsettings set org.gnome.system.proxy.http port \"$5\" 2>/dev/null; \
gsettings set org.gnome.system.proxy.https host \"$6\" 2>/dev/null; \
gsettings set org.gnome.system.proxy.https port \"$7\" 2>/dev/null; true",
            "sh"].concat(args);
    }

    // ---- settings setters -----------------------------------------------------
    function setMode(m) {
        mode = m;
        put("mode", m);
        if (status === "on") {
            _reconnect = true;
            disconnect();
        }
    }
    function setAutoconnect(v) { autoconnect = v; put("autoconnect", v); }
    function setPorts(socks, http) {
        // The stats API port is socks + 1000, so a socks port near the top of the range
        // pushed it past 65535 and Xray died at connect time with a message that pointed
        // nowhere. Reject here instead, in the one place every path goes through.
        // Parse once and keep the numbers: validPortFor() parses internally, so validating
        // the raw string and then storing it let "11080abc" through — it became 11080 for
        // the check and stayed "11080abc" in the field, which the helper rejected at connect
        // time. That is the same late failure this validation exists to prevent.
        var sp = parseInt(socks, 10), hp = parseInt(http, 10);
        if (!validPortFor(sp) || !validPortFor(hp)
                || String(sp) !== String(socks).trim() || String(hp) !== String(http).trim()) {
            message = tr("Порты должны быть от 1024 до 64535 (для порта статистики +1000)", "Ports must be 1024–64535 (the stats port is socks + 1000)");
            log("rejected ports: socks=" + socks + " http=" + http);
            return false;
        }
        if (sp === hp) {
            message = tr("Порты SOCKS и HTTP должны различаться", "The SOCKS and HTTP ports must differ");
            log("rejected identical ports: " + sp);
            return false;
        }
        socksPort = sp;
        httpPort = hp;
        put("socksPort", sp);
        put("httpPort", hp);
        return true;
    }
    // leaves room for the derived api port and stays clear of the privileged range
    function validPortFor(p) {
        p = parseInt(p, 10);
        return p >= 1024 && p <= 64535;
    }
    function setDns(v) {
        v = (v || "").trim();
        // the helper validates this too, but it does so as root at connect time: a bad entry
        // then surfaced as "TUN failed (pkexec 2)" with nothing pointing at the field
        if (!/^[A-Za-z0-9._:-]+$/.test(v) || v.length > 255) {
            message = tr("Не похоже на адрес DNS", "That does not look like a DNS address");
            log("rejected a malformed DNS address");
            return false;
        }
        dns = v;
        put("dns", v);
        return true;
    }
    function setSystemProxy(v) {
        systemProxy = v;
        put("systemProxy", v);
        // switching it off must clear it even when we are in TUN mode: the proxy may still
        // be set from an earlier proxy-mode session, and leaving it on would point the
        // whole desktop at a dead SOCKS port
        if (status === "on" && v && mode !== "proxy")
            return;
        if (status === "on")
            applySystemProxy(v && mode === "proxy");
    }
    function setKillSwitch(v) { killSwitch = v; put("killSwitch", v); }
    function setSplitOn(v) { splitOn = v; put("splitOn", v); restackIfOn(); }

    function openSettings() {
        if (plugin && !loaded)
            attach(plugin);
        refreshHelper();
        settingsOpen = true;
        if (!servers.length && activeSub && !loadingSub)
            refresh();
    }
    function closeSettings() {
        settingsOpen = false;
    }

    // ======================= processes ==========================================

    // The cache holds the Xray config with the real VLESS UUIDs and the cached
    // subscriptions, so it is created private (0700) and chmod'ed on every start: a
    // directory that already exists keeps its old mode otherwise. -p with -m only applies
    // the mode to directories it actually creates.
    Process {
        id: ensureProc
        command: ["sh", "-c", "mkdir -p -m 700 \"$1\" 2>/dev/null || mkdir -p \"$1\"; chmod 700 \"$1\"", "sh", root.cacheDir]
        onExited: code => {
            root._cacheReady = (code === 0);
            if (code !== 0)
                root.message = root.tr("Не удалось создать папку кэша — логи и подписки не сохранятся",
                    "Could not create the cache folder — logs and subscriptions will not be saved");
            // a line queued while the directory was still being created goes out now
            if (root._cacheReady)
                logFlush.restart();
        }
    }

    // Where the engines and the required tools live. Not an error if something is missing: the
    // plugin still loads and the About tab says what it could not find, instead of a tool
    // quietly producing an empty StdioCollector at connect time.
    Process {
        id: findBins
        command: ["python3", plugDir + "findbins.py"]
        stdout: StdioCollector {
            id: findBinsOut
        }
        onExited: code => {
            if (code !== 0) {
                root.log("could not run findbins.py (exit " + code + ")");
                return;
            }
            var r;
            try {
                r = JSON.parse(findBinsOut.text || "{}");
            } catch (e) {
                root.log("findbins.py returned something unreadable");
                return;
            }
            root.foundDeps = r.deps || {};
            // only fill in what the user has not chosen for themselves
            if (!root.xrayPath && r.xray)
                root.xrayPath = r.xray;
            if (!root.singBoxPath && r.singbox)
                root.singBoxPath = r.singbox;
            root.missingBins = r.missing || [];
            if (root.missingBins.length)
                root.log("not found: " + root.missingBins.join(", "));
            else
                root.log("engines: xray=" + root.xrayPath + " sing-box=" + root.singBoxPath);
        }
    }

    // The device id, sent as X-HWID so the provider counts this as one device and never more.
    // /etc/machine-id is the canonical source, but it is absent on some minimal or container
    // installs; dbus keeps its own copy. If neither is readable we mint an id and persist it —
    // leaving it empty would silently make the provider see a different device on every
    // start, or hand back a different server set, with nothing to explain why.
    Process {
        id: machineId
        command: ["sh", "-c", "cat /etc/machine-id 2>/dev/null || cat /var/lib/dbus/machine-id 2>/dev/null || true"]
        stdout: StdioCollector {
            id: machineOut
        }
        onExited: code => {
            if (!root.hwid) {
                var v = (machineOut.text || "").trim();
                if (!v)
                    v = (Date.now().toString(36) + Math.floor(Math.random() * 1e9).toString(36));
                root.hwid = "angelos-" + v;
                root.put("hwid", root.hwid);
            }
            root._needHwid = false;
            root.loadCache();
        }
    }

    Process {
        id: fetchProc
        stdout: StdioCollector {
            id: fetchOut
        }
        stderr: SplitParser {
            onRead: line => root.onFetchLine(line)
        }
        onExited: code => {
            root.loadingSub = false;
            root.fetchPhase = "";
            root.fetchSubId = "";
            if (code !== 0) {
                root.message = root.tr("Не удалось получить подписку (curl ", "Could not fetch the subscription (curl ") + code + ")";
                if (root.status !== "on")
                    root.status = "error";
                root._queuedSub = null;
                return;
            }
            var res = Sub.parseSubscription(fetchOut.text);
            if (!res.configs.length) {
                // name the reason: "not recognised" on its own left the user guessing
                var why = "";
                if (res.kind === "json-error")
                    why = root.tr(": это JSON, но он повреждён", ": this is JSON but it is broken");
                else if (res.kind === "bad-base64")
                    why = root.tr(": это не base64 и не JSON", ": neither base64 nor JSON");
                else if (res.kind === "empty-list")
                    why = root.tr(": список ссылок пуст", ": the link list is empty");
                else if (res.kind === "unsupported")
                    why = root.tr(": серверы используют протоколы, которых нет в этом клиенте",
                                   ": the servers use protocols this client does not have");
                root.message = root.tr("Подписка не распознана", "Subscription not recognized") + why + (res.unsupported ? " (" + res.unsupported + ")" : "");
                root.log("subscription not recognized: kind=" + res.kind + (res.error ? " " + res.error : ""));
                return;
            }
            root._configs = res.configs;
            root.servers = Sub.serversFrom(res.configs);
            if (root._fetchSub) {
                root.activeSubId = root._fetchSub.id;
                root.put("activeSubId", root.activeSubId);
                root.writeCache(root._fetchSub.id, fetchOut.text);
                root._hdrSub = root._fetchSub.id;
                hdrRead.command = ["cat", root.cacheDir + "/sub-" + root._fetchSub.id + ".hdr"];
                hdrRead.running = true;
                root._fetchSub = null;
            }
            if (root.selectedIndex >= root.servers.length)
                root.selectedIndex = 0;
            root.message = "";
            root.afterConfigs();
            if (root._queuedSub) {
                var next = root._queuedSub;
                root._queuedSub = null;
                root.refresh(next);
            }
        }
    }

    Process {
        id: subCacheWrite
        onExited: code => {
            if (code !== 0)
                root.log("could not cache the subscription (exit " + code + ")");
            // a write that arrived while this one was busy still has to go out
            if (root._subPending)
                root.writeCache(root._subPending.id, root._subPending.raw);
        }
    }

    // A removed subscription leaves nothing behind: the cached body and its headers carry the
    // server list with the real credentials, so they go with it. A fetch that was still in
    // flight for it is cancelled in removeSub().
    Process {
        id: unlinkCache
        command: ["sh", "-c", "rm -f \"$1/sub-$2.json\" \"$1/sub-$2.hdr\"", "sh", root.cacheDir, root._unlinkId]
        onExited: code => {
            if (code !== 0)
                root.log("could not remove the cache of subscription " + root._unlinkId);
        }
    }

    Process {
        id: cacheRead
        stdout: StdioCollector {
            id: cacheOut
        }
        onExited: code => {
            if (code === 0) {
                var res = Sub.parseSubscription(cacheOut.text);
                if (res.configs.length) {
                    root._configs = res.configs;
                    root.servers = Sub.serversFrom(res.configs);
                    if (root.selectedIndex >= root.servers.length)
                        root.selectedIndex = 0;
                }
            } else if (root._autoPending) {
                root.refresh();
            }
            root.afterConfigs();
        }
    }

    // subscription-userinfo: upload=…; download=…; total=…; expire=…
    Process {
        id: hdrRead
        stdout: StdioCollector {
            id: hdrOut
        }
        onExited: code => {
            if (code !== 0 || !root._hdrSub)
                return;
            var lines = hdrOut.text.split("\n");
            for (var i = 0; i < lines.length; i++) {
                if (lines[i].toLowerCase().indexOf("subscription-userinfo:") === 0) {
                    var val = lines[i].slice(lines[i].indexOf(":") + 1).trim();
                    var u = Object.assign({}, root.userinfo);
                    u[root._hdrSub] = Sub.parseUserInfo(val);
                    root.userinfo = u;
                }
            }
        }
    }

    Process {
        id: runWrite
        onExited: code => {
            if (code !== 0) {
                root.fail(root.tr("Не удалось записать конфиг", "Could not write the config"));
                return;
            }
            root._coreErr = "";
            coreProc.running = true;
        }
    }

    Process {
        id: hyCredWrite
        onExited: code => {
            // the process is genuinely gone now, so the removal dropHyCreds() issued while it
            // was still alive can be repeated safely — and has to be, or a redirection that
            // landed after that first `rm` leaves the credentials behind
            if (root._hyCredDrop) {
                root._hyCredDrop = false;
                root.rmHyCreds();
                return;
            }
            // disconnected while the credentials were being written: there is nothing to bring
            // up, and nothing to bring down either — disconnect() saw this process running and
            // deferred, so the teardown is owed here to leave the state machine settled
            if (root._disconnecting) {
                root._disconnecting = false;
                root.finishStop();
                return;
            }
            if (code !== 0) {
                root.fail(root.tr("Не удалось записать учётные данные Hysteria",
                                  "Could not write the Hysteria credentials"));
                return;
            }
            root.helperUp();
        }
    }

    Process {
        id: coreProc
        command: [root.xrayPath, "run", "-c", root.runPath]
        environment: ({
            "XRAY_LOCATION_ASSET": root.assetDir
        })
        stderr: SplitParser {
            onRead: line => {
                if (!line)
                    return;
                root.log("xray: " + line);
                if (line.indexOf("[Warning]") < 0)
                    root._coreErr = line;
            }
        }
        onStarted: {
            root.log("xray process started");
            root.readyTicks = 0;
            readyTimer.running = true;
        }
        onExited: code => {
            root.log("xray process exited (code " + code + ")");
            readyTimer.running = false;
            if (root._stopping) {
                root._stopping = false;
                if (root._stopToOff) {
                    root._stopToOff = false;
                    root.finishStop();
                }
                return;
            }
            if (root.status === "on" || root.status === "connecting") {
                root.status = "error";
                root.message = root.tr("Ядро остановилось", "The core stopped") + (root._coreErr ? ": " + root._coreErr : "");
                statsTimer.running = false;
                root.teardownTun();
            }
        }
    }

    // before starting, make sure our ports are free (Happ's daemon holds 10808/10809)
    Process {
        id: portScan
        command: ["ss", "-ltnH"]
        stdout: StdioCollector {
            id: portScanOut
        }
        onExited: code => {
            if (root.status !== "connecting")
                return;
            var t = portScanOut.text || "";
            var s = root.portUsed(t, root.socksPort) ? root.freePort(t, root.socksPort) : root.socksPort;
            var h = root.portUsed(t, root.httpPort) ? root.freePort(t, root.httpPort) : root.httpPort;
            if (h === s)
                h = root.freePort(t, s + 1);
            // apiPort is a binding on socksPort + 1000, so moving socks moves it: it can land
            // on something that is already taken, and Xray would then exit at once with a bare
            // "the core stopped". Give it its own free port instead.
            var a = s + 1000;
            if (root.portUsed(t, a) || a === s || a === h)
                a = root.freePort(t, Math.max(h, s) + 1000);
            root.log("ports chosen: socks=" + s + " http=" + h + " api=" + a);
            root.socksPort = s;
            root.httpPort = h;
            root.apiPort = a;
            root.beginConnect();
        }
    }

    Process {
        id: portCheck
        command: ["ss", "-ltnH"]
        stdout: StdioCollector {
            id: portOut
        }
        onExited: code => {
            // This check is in flight while the user can cancel. Without the guard a
            // cancelled connect still reached coreReady() -> `pkexec up`, which raised a TUN
            // nobody was tracking: status "off", no UI state, and downProc never fired.
            if (root.status !== "connecting")
                return;
            if (portOut.text.indexOf(":" + root.socksPort + " ") < 0)
                return;
            readyTimer.running = false;
            root.coreReady();
        }
    }

    Timer {
        id: readyTimer
        interval: 350
        repeat: true
        onTriggered: {
            root.readyTicks++;
            if (root.readyTicks > 40) {
                running = false;
                root.fail(root.tr("Ядро не поднялось", "The core did not start"));
                return;
            }
            if (!portCheck.running)
                portCheck.running = true;
        }
    }

    Process {
        id: upProc
        stdout: StdioCollector {
            id: upOut
        }
        stderr: StdioCollector {
            id: upErr
        }
        onStarted: root.log("helper up: socks=" + root.socksPort + " api=" + root.apiPort + " host=" + ((root.currentServer || {}).host || "") + " dns=" + root.dns + " kill=" + root.killSwitch)
        onExited: code => {
            var o = (upOut.text || "").trim();
            var e = (upErr.text || "").trim();
            if (o)
                root.log("helper up out: " + o.split("\n").slice(-1)[0]);
            if (e)
                root.log("helper up err: " + e.split("\n").slice(-1)[0]);
            root.log("helper up exit=" + code);
            // A disconnect during the pkexec prompt leaves the user cancelling, not failing.
            // Reporting a TUN failure here would overwrite the "Disconnecting…" the user just
            // asked for — and finalizeOn() on success would set "connected" for a tunnel that
            // `down` has already taken away. The flag rather than the status, because in TUN
            // mode disconnect() returns without changing the status: the test the file already
            // uses for portCheck ("a cancelled connect must not reach the code that acts on
            // success") would not have fired here.
            if (root._disconnecting || root.status !== "connecting") {
                // The user asked to stop while this was in flight. `up` was deliberately not
                // killed (see disconnect()), so the helper may well have brought the tunnel up
                // anyway — run `down` now that it is finished. Doing it here rather than in
                // disconnect() is what keeps the two from overlapping as root processes.
                if (root._disconnecting && !downProc.running) {
                    // `downProc` unqualified: it is an id, not a property, so `root.downProc`
                    // does not resolve and throws a TypeError here — which aborts this handler
                    // before the teardown runs. The rest of the file already writes it bare.
                    //
                    // No _tunDownQuiet here: that flag is for the silent stale-TUN sweep at
                    // startup, and it makes downProc skip stopCore() — which would leave the
                    // status at "connecting" for ever, since nothing else moves it
                    downProc.running = true;
                }
                return;
            }
            if (code === 0) {
                root.finalizeOn();
            } else if (root.missingBins.indexOf("singbox") >= 0) {
                // caught here rather than passed through: the helper's own message would be
                // a root-side "sing-box not found at …", which tells the user nothing about
                // where to put the binary
                root.fail(root.tr("Не найден sing-box — TUN-режим не может работать. Поставь его или используй режим прокси.",
                    "sing-box not found — TUN mode cannot work. Install it, or use proxy mode."));
            } else if (root.missingBins.indexOf("xray") >= 0
                       && ((root.currentServer || {}).engine || "xray") !== "sing-box") {
                // only worth saying when Xray is the engine that was actually needed; a
                // Hysteria server runs on sing-box, so a missing Xray is not its problem
                root.fail(root.tr("Не найден Xray — подключиться нечем. Поставь Xray-core или добавь его в PATH.",
                    "Xray not found — there is nothing to connect with. Install Xray-core or put it in PATH."));
            } else {
                var why = e.split("\n").slice(-1)[0] || "";
                root.fail(root.tr("TUN не поднялся", "TUN failed") + " (pkexec " + code + ")" + (root.helperInstalled ? (why ? ": " + why : "") : root.tr(": установи помощника", ": install the helper")));
            }
        }
    }

    Process {
        id: hyCredRemove
    }

    Process {
        id: downProc
        command: ["pkexec", root.helperPath, "down"]
        onExited: code => {
            root.log("helper down exit=" + code);
            if (root._tunDownQuiet) {
                root._tunDownQuiet = false;
                return;
            }
            root.stopCore();
        }
    }

    // after a TUN connect: is there really internet through the tunnel?
    Process {
        id: healthProc
        command: ["curl", "-s", "-m", "6", "-o", "/dev/null", "-w", "%{http_code}", "https://1.1.1.1/cdn-cgi/trace"]
        stdout: StdioCollector {
            id: healthOut
        }
        onExited: code => {
            if (root.status !== "on" || root.mode !== "tun")
                return;
            var http = (healthOut.text || "").trim();
            root.log("health check: https://1.1.1.1 -> " + (http || "no answer") + (root._healthTries > 1 ? " (try " + root._healthTries + "/" + healthTries + ")" : "") + " (curl " + code + ")");
            if (http === "200" || http === "204") {
                root._healthTries = 0;
                return;
            }
            // One request failing is not proof the tunnel is broken: a cold start, a slow
            // handshake or a single TLS hiccup (curl 35) used to tear a working tunnel down.
            // Give it a few tries before concluding the machine is offline.
            if (root._healthTries < healthTries) {
                root.message = root.tr("Проверяю туннель…", "Checking the tunnel…");
                healthTimer.restart();
                return;
            }
            root._healthTries = 0;
            root.diagThenFail(root.tr("Туннель не пропускает трафик — отключил, сеть восстановлена. Если включён другой VPN (например Happ), выключи его и попробуй снова.", "The tunnel passes no traffic — disconnected, the network is back. If another VPN is on (e.g. Happ), turn it off and try again."));
        }
    }

    Timer {
        id: healthTimer
        interval: 4000
        repeat: false
        onTriggered: {
            if (root.status === "on" && root.mode === "tun" && !healthProc.running) {
                root._healthTries++;
                healthProc.running = true;
            }
        }
    }

    // ---- diagnostics plumbing -------------------------------------------------
    Timer {
        id: logFlush
        interval: 500
        repeat: false
        onTriggered: root.flushLogs()
    }
    Process {
        id: logWrite
        onExited: if (root._logPending)
            logFlush.restart()
    }
    Process {
        id: logDump
        onExited: code => {
            if (code !== 0)
                root.message = root.tr("Не удалось сохранить логи", "Could not save the logs");
        }
    }
    Process {
        id: logClear
        command: ["sh", "-c", ": > \"$1\"", "sh", root.logFile]
        onExited: code => {
            if (code !== 0) {
                root.message = root.tr("Не удалось очистить логи", "Could not clear the logs");
            }
        }
    }
    Process {
        id: diagProc
        command: ["pkexec", root.helperPath, "diag", ((root.currentServer || {}).host || "")]
        stdout: StdioCollector {
            id: diagOut
        }
        stderr: StdioCollector {
            id: diagErr
        }
        onExited: code => {
            root.diagRunning = false;
            var t = (diagOut.text || "").trim();
            var e = (diagErr.text || "").trim();
            root.diagText = t + (e ? "\n[stderr] " + e : "");
            root.log("diagnostics done (exit " + code + ", saved to " + root.logDumpPath + ")");
            // always persist: the live routes vanish the moment the TUN comes down
            root.saveLogs();
            if (root._failAfterDiag) {
                var m = root._failAfterDiag;
                root._failAfterDiag = "";
                root.fail(m);
            }
        }
    }

    Process {
        id: helperCheck
        command: ["sh", "-c",
            "test -x \"$1\" && test -f \"$2\" && echo helper-ok; test -x \"$3\" && echo installer-ok; true",
            "sh", root.helperPath, root.policyPath, root.installerPath]
        onExited: code => {
            // Two separate questions, and conflating them is how the emergency button stopped
            // working. "Is there a helper I can bring the TUN down with?" is what forceOff()
            // asks before it promises to restore the network — the helper and its policy, and
            // nothing else. "Is there a root-owned copy of the installer?" is only about how a
            // later install would be performed. Deriving the first from the second meant that
            // deleting /usr/local/libexec/angelos-vpn-install left a perfectly working helper
            // that forceOff() refused to use, holding the machine offline.
            var out = (helperOut.text || "");
            root.helperInstalled = out.indexOf("helper-ok") >= 0;
            root.installerReady = out.indexOf("installer-ok") >= 0;
            root.log("helper installed: " + root.helperInstalled + " (root installer: " + root.installerReady + ")");
            // a TUN left over from an earlier shell run would still hold the network captive:
            // take it down once, quietly, as soon as we know the helper is there
            if (root.helperInstalled && !root._staleCleaned) {
                root._staleCleaned = true;
                root._tunDownQuiet = true;
                downProc.running = true;
            }
        }
        stdout: StdioCollector {
            id: helperOut
        }
    }

    Timer {
        id: helperPoll
        interval: 800
        repeat: true
        property int ticks: 0
        onTriggered: {
            ticks++;
            // `running = true` does nothing while a check is still in flight, so a tick that
            // lands on a slow `test` would count as a try without ever having looked — and one
            // such tick at the end gives up a 32-second install that was nearly finished.
            if (!helperCheck.running)
                helperCheck.running = true;
            // give up only after a stretch of ticks in which no check ever got to run
            if (root.helperInstalled || (ticks > 40 && !helperCheck.running)) {
                running = false;
                root.helperInstalling = false;
                ticks = 0;
            }
        }
    }

    Timer {
        id: statsTimer
        interval: 2000
        repeat: true
        onTriggered: {
            if (!statsProc.running && root.status === "on")
                statsProc.running = true;
        }
    }

    Process {
        id: statsProc
        command: [root.xrayPath, "api", "statsquery", "--server=127.0.0.1:" + root.apiPort]
        stdout: StdioCollector {
            id: statsOut
        }
        onExited: code => {
            if (code !== 0)
                return;
            var j;
            try {
                j = JSON.parse(statsOut.text);
            } catch (e) {
                return;
            }
            var up = 0, down = 0;
            if (j && j.uploadTotal !== undefined) {
                // sing-box clash API: cumulative totals, already parsed
                up = parseInt(j.uploadTotal || 0, 10);
                down = parseInt(j.downloadTotal || 0, 10);
                if (!(up >= 0))
                    up = 0;
                if (!(down >= 0))
                    down = 0;
            } else {
                // Xray: a list of counters, the proxy's two of which are what the panel shows
                var st = j.stat || [];
                for (var i = 0; i < st.length; i++) {
                    if (st[i].name === "outbound>>>proxy>>>traffic>>>uplink")
                        up = parseInt(st[i].value || "0", 10);
                    else if (st[i].name === "outbound>>>proxy>>>traffic>>>downlink")
                        down = parseInt(st[i].value || "0", 10);
                }
            }
            var now = Date.now();
            if (root._lastStatsAt) {
                var dt = (now - root._lastStatsAt) / 1000;
                if (dt > 0) {
                    root.upSpeed = Math.max(0, (up - root._lastUp) / dt);
                    root.downSpeed = Math.max(0, (down - root._lastDown) / dt);
                }
            }
            root._lastUp = up;
            root._lastDown = down;
            root._lastStatsAt = now;
            root.totalUp = up;
            root.totalDown = down;
        }
    }

    Process {
        id: pingProc
        stdout: StdioCollector {
            id: pingOut
        }
        onExited: code => {
            root.pinging = false;
            if (!root.pingStillApplies()) {
                root._pingSnapshot = null;
                root.log("ping results dropped: the server list changed while measuring");
                return;
            }
            var lines = pingOut.text.split("\n");
            var list = root.servers.slice();
            for (var i = 0; i < lines.length; i++) {
                var t = lines[i].indexOf("\t");
                if (t < 0)
                    continue;
                var idx = parseInt(lines[i].slice(0, t), 10);
                var ms = parseInt(lines[i].slice(t + 1), 10);
                // a truncated or malformed line parses to NaN, and storing that would leave the
                // server showing a measurement forever. Leave the entry as it was instead.
                if (!(ms >= 0))
                    continue;
                if (idx >= 0 && idx < list.length)
                    list[idx] = Object.assign({}, list[idx], { "ping": ms });
            }
            root.servers = list;
            root._pingSnapshot = null;
        }
    }

    Process {
        id: sysProxyProc
    }

    // Snapshots the user's existing proxy configuration before we touch it, so disconnecting
    // restores what was there instead of forcing mode=none.
    Process {
        id: sysProxyRead
        stdout: StdioCollector {
            id: sysProxyReadOut
        }
        onExited: code => {
            if (code === 0 && !root._sysProxySaved.length)
                root._sysProxySaved = (sysProxyReadOut.text || "").split("\n");
        }
    }
}
