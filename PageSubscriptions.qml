import QtQuick
import QtQuick.Layouts
import qs.config
import qs.services
import qs.widgets
import "."
import "Fmt.js" as Fmt

// Settings page: the subscriptions — add extra links, update, pick the active one.
Column {
    id: root

    property var plugin
    width: parent ? parent.width : Skin.px(540)
    spacing: Skin.spacing

    // which subscription's secret URL is currently shown in full (none by default)
    property string revealed: ""
    // scheme + host + "/…last few chars": enough to tell two links apart, not enough to use
    function maskUrl(u) {
        if (!u)
            return "";
        var m = String(u).match(/^(https?:\/\/[^\/?#]+)(\/.*)?$/i);
        if (!m)
            return I18n.t("скрытая ссылка", "hidden link");
        var tail = (m[2] || "");
        if (tail.length <= 5)
            return m[1] + "/…";
        return m[1] + "/…" + tail.slice(-4);
    }
    function toggleReveal(id) {
        root.revealed = (root.revealed === id) ? "" : id;
    }

    property int _tick: 0
    readonly property string dots: ".".repeat(1 + (root._tick % 3))

    // a gentle "..." so the caption visibly lives while the download runs
    Timer {
        running: Vpn.loadingSub
        interval: 380
        repeat: true
        onTriggered: root._tick++
    }

    function progressLabel() {
        var s = I18n.t("Обновляю список серверов", "Updating the server list") + root.dots;
        if (Vpn.fetchTotal > 0)
            s += "  " + Vpn.fetchIndex + "/" + Vpn.fetchTotal;
        return s;
    }

    PxGroup {
        width: parent.width
        title: I18n.t("Новая подписка", "New subscription")
        icon: "plug"
        PxField {
            id: urlField
            width: parent.width
            placeholder: I18n.t("https://… ссылка на подписку", "https://… subscription link")
            onAccepted: root.addSubscription()
        }
        PxField {
            id: nameField
            width: parent.width
            placeholder: I18n.t("Название (необязательно)", "Name (optional)")
        }
        PxField {
            id: hwidField
            width: parent.width
            placeholder: I18n.t("HWID устройства (оставь пустым — подставится свой)", "Device HWID (leave empty to use this machine's)")
            text: ""
        }
        RowLayout {
            width: parent.width
            spacing: Skin.px(8)
            PxButton {
                text: I18n.t("Добавить", "Add")
                icon: "check"
                accent: true
                enabled: urlField.text.trim().length > 0
                onClicked: root.addSubscription()
            }
            PxButton {
                text: I18n.t("Обновить активную", "Refresh active")
                icon: "refresh"
                enabled: !!Vpn.activeSub && !Vpn.loadingSub
                onClicked: Vpn.refresh()
            }
        }
        PxText {
            width: parent.width
            visible: Vpn.loadingSub
            color: Skin.accent
            wrapMode: Text.Wrap
            text: root.progressLabel()
        }
        // The device id is shown in About, where it belongs; repeating it here only spreads a
        // machine identifier across screenshots for no benefit.
    }

    function addSubscription() {
        if (urlField.text.trim().length === 0)
            return;
        Vpn.addSub(urlField.text, nameField.text, hwidField.text);
        urlField.text = "";
        nameField.text = "";
        hwidField.text = "";
    }

    PxText {
        width: parent.width
        dim: true
        visible: Vpn.subs.length === 0
        text: I18n.t("Подписок нет. Вставь ссылку выше — ключи Fortuna/Happ подходят без изменений.", "No subscriptions yet. Paste a link above — Fortuna/Happ keys work as-is.")
    }

    Repeater {
        model: Vpn.subs
        delegate: SkinCard {
            required property var modelData
            width: root.width
            Column {
                width: parent.width
                spacing: Skin.px(6)
                RowLayout {
                    width: parent.width
                    spacing: Skin.px(8)
                    Rectangle {
                        Layout.alignment: Qt.AlignVCenter
                        Layout.preferredWidth: Skin.px(9)
                        Layout.preferredHeight: Skin.px(9)
                        radius: width / 2
                        color: modelData.id === Vpn.activeSubId ? Skin.accent : "transparent"
                        border.width: modelData.id === Vpn.activeSubId ? 0 : 1
                        border.color: Skin.separator
                    }
                    PxText {
                        Layout.fillWidth: true
                        kind: "title"
                        text: modelData.name
                        elide: Text.ElideRight
                    }
                    PxText {
                        visible: modelData.id === Vpn.activeSubId
                        color: Skin.accent
                        text: I18n.t("активна", "active")
                    }
                }
                PxText {
                    width: parent.width
                    dim: true
                    elide: Text.ElideMiddle
                    // The URL carries the subscription's secret token. Showing it in full
                    // on an always-visible page leaks it into every screenshot, screen share
                    // and bug-report photo, so it stays masked until deliberately revealed.
                    text: root.revealed === modelData.id ? modelData.url : root.maskUrl(modelData.url)
                }
                PxText {
                    width: parent.width
                    dim: true
                    elide: Text.ElideRight
                    visible: root.revealed === modelData.id
                    text: I18n.t("ссылка — это ваш доступ к подписке, не показывайте её",
                        "this link is your access to the subscription, do not share it")
                }
                PxText {
                    width: parent.width
                    visible: !!root.info(modelData.id)
                    dim: true
                    text: root.trafficText(modelData.id)
                }
                PxText {
                    width: parent.width
                    visible: Vpn.loadingSub && Vpn.fetchSubId === modelData.id
                    color: Skin.accent
                    wrapMode: Text.Wrap
                    text: root.progressLabel()
                }
                RowLayout {
                    width: parent.width
                    spacing: Skin.px(8)
                    PxButton {
                        text: I18n.t("Сделать активной", "Make active")
                        enabled: modelData.id !== Vpn.activeSubId
                        onClicked: Vpn.selectSub(modelData.id)
                    }
                    PxButton {
                        text: I18n.t("Обновить", "Refresh")
                        icon: "refresh"
                        enabled: !Vpn.loadingSub
                        onClicked: Vpn.updateSub(modelData.id)
                    }
                    PxButton {
                        text: root.revealed === modelData.id ? I18n.t("Скрыть ссылку", "Hide link") : I18n.t("Показать ссылку", "Show link")
                        onClicked: root.toggleReveal(modelData.id)
                    }
                    PxButton {
                        text: I18n.t("Удалить", "Remove")
                        danger: true
                        onClicked: Vpn.removeSub(modelData.id)
                    }
                }
            }
        }
    }

    function info(id) {
        return Vpn.userinfo[id] || null;
    }
    function trafficText(id) {
        var u = root.info(id);
        if (!u)
            return "";
        var s = Fmt.bytes(u.download) + " / " + Fmt.bytes(u.total);
        if (u.expire > 0)
            s += " · " + Fmt.until(u.expire);
        return s;
    }
}
