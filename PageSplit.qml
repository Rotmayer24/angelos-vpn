import QtQuick
import QtQuick.Layouts
import qs.config
import qs.services
import qs.widgets
import "."

// Settings page: split tunneling — apps and domains that skip the VPN (TUN mode).
Column {
    id: root

    width: parent ? parent.width : Skin.px(540)
    spacing: Skin.spacing

    readonly property var common: [
        "chrome", "chromium", "firefox", "brave", "vivaldi", "opera",
        "telegram-desktop", "discord", "element-desktop", "thunderbird",
        "steam", "qbittorrent", "transmission-gtk", "spotify", "code",
        "yandex-browser", "tor-browser", "lutris", "wine", "prismlauncher"
    ]
    readonly property var extras: Vpn.directApps.filter(a => root.common.indexOf(a) < 0)

    PxGroup {
        width: parent.width
        title: I18n.t("Раздельное туннелирование", "Split tunneling")
        icon: "eye"
        SettingRow {
            label: I18n.t("Пускай выбранные приложения и домены напрямую", "Send chosen apps and domains directly")
            PxToggle {
                checked: Vpn.splitOn
                enabled: Vpn.mode === "tun"
                onToggled: checked => Vpn.setSplitOn(checked)
            }
        }
        PxText {
            width: parent.width
            wrapMode: Text.Wrap
            dim: true
            text: Vpn.mode === "tun" ? I18n.t("Отмеченные приложения (по имени процесса) и домены пойдут мимо VPN. Остальное — через туннель. Работает в режиме TUN.", "Marked apps (by process name) and domains go around the VPN. Everything else goes through the tunnel. TUN mode only.") : I18n.t("Раздельное туннелирование работает в режиме TUN. Переключи режим на вкладке «Подключение» или используй прокси-режим.", "Split tunneling works in TUN mode. Switch the mode on the Connection tab, or use proxy mode.")
        }
    }

    PxGroup {
        width: parent.width
        title: I18n.t("Приложения напрямую", "Apps direct")
        icon: "power"
        Flow {
            width: parent.width
            spacing: Skin.px(6)
            Repeater {
                model: root.common
                delegate: PxButton {
                    required property string modelData
                    text: modelData
                    checkable: true
                    checked: Vpn.isDirectApp(modelData)
                    enabled: Vpn.splitOn && Vpn.mode === "tun"
                    onClicked: Vpn.setAppDirect(modelData, !Vpn.isDirectApp(modelData))
                }
            }
        }
        PxText {
            width: parent.width
            dim: true
            visible: root.extras.length > 0
            text: I18n.t("Добавленные вручную:", "Added by hand:")
        }
        Flow {
            width: parent.width
            spacing: Skin.px(6)
            Repeater {
                model: root.extras
                delegate: PxButton {
                    required property string modelData
                    text: modelData
                    checkable: true
                    checked: true
                    danger: true
                    enabled: Vpn.splitOn && Vpn.mode === "tun"
                    onClicked: Vpn.setAppDirect(modelData, false)
                }
            }
        }
        PxField {
            id: appField
            width: parent.width
            placeholder: I18n.t("Имя процесса, напр. telegram-desktop", "Process name, e.g. telegram-desktop")
            onAccepted: root.addApp()
        }
        PxButton {
            text: I18n.t("Добавить приложение", "Add app")
            icon: "check"
            enabled: appField.text.trim().length > 0
            onClicked: root.addApp()
        }
    }

    PxGroup {
        width: parent.width
        title: I18n.t("Домены напрямую", "Domains direct")
        icon: "wifi"
        PxField {
            id: domainField
            width: parent.width
            placeholder: I18n.t("example.com или .ru", "example.com or .ru")
            onAccepted: root.addDomain()
        }
        PxButton {
            text: I18n.t("Добавить домен", "Add domain")
            icon: "check"
            enabled: domainField.text.trim().length > 0
            onClicked: root.addDomain()
        }
        Column {
            width: parent.width
            spacing: Skin.px(2)
            Repeater {
                model: Vpn.directDomains
                delegate: RowLayout {
                    required property string modelData
                    width: parent.width
                    spacing: Skin.px(8)
                    PxText {
                        Layout.fillWidth: true
                        text: modelData
                        elide: Text.ElideRight
                    }
                    PxButton {
                        text: I18n.t("Убрать", "Remove")
                        danger: true
                        onClicked: Vpn.removeDirectDomain(modelData)
                    }
                }
            }
        }
        PxText {
            width: parent.width
            dim: true
            visible: Vpn.directDomains.length === 0
            text: I18n.t("Домены и их поддомены (суффиксы). Например, .ru пропустит все российские сайты напрямую.", "Domains and their subdomains (suffixes). For example .ru sends Russian sites directly.")
        }
    }

    function addApp() {
        var v = appField.text.trim();
        if (v.length === 0)
            return;
        Vpn.setAppDirect(v, true);
        appField.text = "";
    }
    function addDomain() {
        var v = domainField.text.trim();
        if (v.length === 0)
            return;
        Vpn.addDirectDomain(v);
        domainField.text = "";
    }
}
