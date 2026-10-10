.pragma library

// Small formatting helpers for the VPN UI.

function bytes(n) {
    n = Number(n) || 0;
    if (n < 1)
        return "0 B";
    var units = ["B", "KB", "MB", "GB", "TB"];
    var i = Math.floor(Math.log(n) / Math.log(1024));
    if (i < 0)
        i = 0;
    if (i > units.length - 1)
        i = units.length - 1;
    var v = n / Math.pow(1024, i);
    return (i === 0 ? Math.round(v) : v.toFixed(v >= 100 ? 0 : v >= 10 ? 1 : 2)) + " " + units[i];
}

function rate(bytesPerSec) {
    return bytes(bytesPerSec) + "/s";
}

function ping(v) {
    if (v === undefined || v === null || v < 0)
        return "—";
    return Math.round(v) + " ms";
}

function until(epochSec) {
    var t = Number(epochSec) || 0;
    if (t <= 0)
        return "";
    var d = new Date(t * 1000);
    var now = new Date();
    var days = Math.round((d - now) / 86400000);
    var date = ("0" + d.getDate()).slice(-2) + "." + ("0" + (d.getMonth() + 1)).slice(-2) + "." + d.getFullYear();
    return date + (days >= 0 ? " · " + days + " " + (days % 10 === 1 && days % 100 !== 11 ? "день" : "дн.") : "");
}
