import QtQuick
import QtQuick.Layouts
import qs.config
import qs.services
import qs.widgets
import "."
import "Fmt.js" as Fmt

// Settings page: the server list — pick a location, ping them all.
Column {
    id: root

    signal requestTab(string tab)

    property var plugin
    width: parent ? parent.width : Skin.px(540)
    spacing: Skin.spacing

    readonly property var list: {
        var q = search.text.trim().toLowerCase();
        var out = [];
        for (var i = 0; i < Vpn.servers.length; i++) {
            var s = Vpn.servers[i];
            if (!q || (s.name || "").toLowerCase().indexOf(q) >= 0 || (s.host || "").toLowerCase().indexOf(q) >= 0)
                out.push(s);
        }
        return out;
    }

    function pingColor(ms) {
        if (ms === undefined || ms === null || ms < 0)
            return Skin.textFaint;
        if (ms < 120)
            return Skin.ok;
        if (ms < 320)
            return Skin.warn;
        return Skin.danger;
    }

    RowLayout {
        width: parent.width
        spacing: Skin.px(8)
        PxField {
            id: search
            Layout.fillWidth: true
            placeholder: I18n.t("Поиск сервера…", "Search servers…")
            icon: "search"
        }
        PxButton {
            text: Vpn.pinging ? I18n.t("Пингую…", "Pinging…") : I18n.t("Пинг всех", "Ping all")
            icon: "refresh"
            enabled: !Vpn.pinging && Vpn.servers.length > 0
            onClicked: Vpn.pingAll()
        }
        PxButton {
            text: I18n.t("Обновить", "Refresh")
            icon: "download"
            enabled: !Vpn.loadingSub
            onClicked: Vpn.refresh()
        }
    }

    PxText {
        width: parent.width
        dim: true
        visible: Vpn.servers.length > 0
        text: Vpn.servers.length + I18n.t(" серверов", " servers") + (Vpn.loadingSub ? I18n.t(" · обновляю подписку…", " · refreshing subscription…") : "")
    }

    SkinCard {
        width: parent.width
        visible: Vpn.servers.length === 0
        Column {
            width: parent.width
            spacing: Skin.px(8)
            PxText {
                width: parent.width
                wrapMode: Text.Wrap
                text: Vpn.loadingSub ? I18n.t("Загружаю список серверов…", "Loading the server list…") : I18n.t("Серверов пока нет. Добавь подписку на вкладке «Подписки» и обнови.", "No servers yet. Add a subscription on the Subscriptions tab and refresh.")
            }
            PxButton {
                text: I18n.t("Добавить подписку", "Add a subscription")
                icon: "plug"
                onClicked: root.requestTab("subs")
            }
        }
    }

    Column {
        width: parent.width
        spacing: Skin.px(2)

        Repeater {
            model: root.list
            delegate: Rectangle {
                id: row
                required property var modelData
                width: root.width
                height: Skin.px(40)
                radius: Skin.radius
                color: modelData.index === Vpn.selectedIndex ? Skin.hover : "transparent"

                Rectangle {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: Skin.px(3)
                    height: parent.height - Skin.px(10)
                    radius: width / 2
                    color: modelData.index === Vpn.selectedIndex ? Skin.accent : "transparent"
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Skin.px(10)
                    anchors.rightMargin: Skin.px(8)
                    spacing: Skin.px(8)
                    PxText {
                        Layout.fillWidth: true
                        text: modelData.name
                        elide: Text.ElideRight
                    }
                    PxText {
                        dim: true
                        text: (modelData.protocol || "").toUpperCase()
                    }
                    PxText {
                        text: rowHover.hovered ? I18n.t("Выбрать", "Select") : ""
                        color: Skin.accent
                    }
                    PxText {
                        text: Fmt.ping(modelData.ping)
                        color: root.pingColor(modelData.ping)
                    }
                }

                HoverHandler {
                    id: rowHover
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Vpn.selectServer(modelData.index)
                }
            }
        }
    }
}
