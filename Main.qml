import QtQuick
import Quickshell
import Quickshell.Io
import qs.services
import "."

// The plugin's background service (manifest `main`). It attaches the shared Vpn
// singleton to the plugin context, answers the `vpn` IPC and owns the standalone
// VPN window (opened by the desktop widget's gear, the bar pill, or `vpn settings`).
Item {
    id: root

    property var plugin

    function attach(p) {
        if (p)
            Vpn.attach(p);
    }
    Component.onCompleted: attach(plugin)
    onPluginChanged: attach(plugin)

    IpcHandler {
        target: "vpn"

        function toggle(): void {
            Vpn.toggle();
        }
        function connect(): void {
            Vpn.connect();
        }
        function disconnect(): void {
            Vpn.disconnect();
        }
        function panic(): void {
            Vpn.forceOff();
        }
        function settings(): void {
            Vpn.openSettings();
        }
        function refresh(): void {
            Vpn.refresh();
        }
        function addsub(url: string): void {
            Vpn.addSub(url, "", "");
        }
        function ping(): void {
            Vpn.pingAll();
        }
        function status(): void {
            Vpn.message = Vpn.status;
        }
        function logs(): void {
            Vpn.saveLogs();
        }
    }

    LazyLoader {
        id: windowLoader
        active: Vpn.settingsOpen
        source: Qt.resolvedUrl("SettingsWindow.qml")
    }
}
