import QtQuick
import QtQuick.Layouts
import qs.config
import qs.services
import qs.widgets
import "."

// Settings page: the live diagnostics log. Everything the VPN does that can touch the
// network is written here, and the privileged helper adds the sing-box log, routes,
// policy rules and DNS state on demand — so a broken network can actually be explained.
Column {
    id: root

    property var plugin
    width: parent ? parent.width : Skin.px(560)
    spacing: Skin.spacing

    PxGroup {
        width: parent.width
        title: I18n.t("Логи и диагностика", "Logs & diagnostics")
        icon: "terminal"
        RowLayout {
            width: parent.width
            spacing: Skin.px(8)
            PxButton {
                text: I18n.t("Собрать диагностику", "Collect diagnostics")
                icon: "refresh"
                enabled: !Vpn.diagRunning && Vpn.helperInstalled
                onClicked: Vpn.collectDiagnostics()
            }
            PxButton {
                text: I18n.t("Копировать", "Copy")
                icon: "check"
                enabled: Vpn.logs.length > 0
                onClicked: Vpn.copyLogs()
            }
            PxButton {
                text: I18n.t("Сохранить", "Save")
                icon: "doc"
                enabled: Vpn.logs.length > 0
                onClicked: Vpn.saveLogs()
            }
            PxButton {
                text: I18n.t("Очистить", "Clear")
                danger: true
                onClicked: Vpn.clearLogs()
            }
        }
        PxTextArea {
            id: view
            width: parent.width
            implicitHeight: Skin.px(320)
            readOnly: true
            monospace: true
            placeholder: I18n.t("Здесь появятся события VPN…", "VPN events will show up here…")
            text: Vpn.fullLog()
        }
        PxText {
            width: parent.width
            wrapMode: Text.Wrap
            dim: true
            text: I18n.t("Логи пишутся в ", "Logs are written to ") + Vpn.logFile + I18n.t(". Если сеть пропала — нажми «Собрать диагностику» и скопируй всё сюда.", ". If the network broke, press Collect diagnostics and copy it here.")
        }
    }

    // follow the tail while the log grows
    Connections {
        target: view.input
        function onTextChanged() {
            view.input.cursorPosition = view.input.length;
        }
    }
}
