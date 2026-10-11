import QtQuick
import QtQuick.Layouts
import qs.config
import qs.services
import qs.widgets
import "."
import "Fmt.js" as Fmt

// Settings page: the connection — status, mode, behaviour, ports, traffic.
Column {
    id: root

    width: parent ? parent.width : Skin.px(540)
    spacing: Skin.spacing

    readonly property bool on: Vpn.connected
    readonly property bool busy: Vpn.busy
    readonly property color stateColor: root.on ? Skin.ok : root.busy ? Skin.warn : Vpn.status === "error" ? Skin.danger : Skin.textFaint

    // The endpoint of the connected server: "80.66.65.172:443". A subscription may put a
    // hostname in that field instead of an address, so it is printed verbatim — calling a
    // hostname an IP would be a lie the user could act on.
    readonly property string endpoint: {
        var s = Vpn.currentServer;
        if (!s || !s.host)
            return "";
        if (!s.port)
            return s.host;
        // an IPv6 literal needs brackets, or the trailing :port reads as part of the address
        return s.host.indexOf(":") >= 0 ? "[" + s.host + "]:" + s.port : s.host + ":" + s.port;
    }

    SkinCard {
        width: parent.width
        Column {
            width: parent.width
            spacing: Skin.px(10)

            RowLayout {
                width: parent.width
                spacing: Skin.px(10)
                Rectangle {
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredWidth: Skin.px(12)
                    Layout.preferredHeight: Skin.px(12)
                    radius: width / 2
                    color: root.stateColor
                }
                PxText {
                    Layout.fillWidth: true
                    kind: "title"
                    text: root.on ? I18n.t("Подключено", "Connected") : root.busy ? I18n.t("Подключение…", "Connecting…") : Vpn.status === "error" ? I18n.t("Ошибка", "Error") : I18n.t("Отключено", "Disconnected")
                }
                PxText {
                    visible: root.on
                    dim: true
                    text: (Vpn.currentServer ? Vpn.currentServer.protocol : "") + (Vpn.mode === "tun" ? " · TUN" : " · proxy")
                }
                PxText {
                    // where we are actually connected: the address from the subscription and
                    // the port. Not always an IP (a subscription may carry a hostname), so it is
                    // shown as-is rather than pretending to be a number.
                    visible: root.on && root.endpoint !== ""
                    kind: "mono"
                    dim: true
                    text: root.endpoint
                }
            }

            PxText {
                width: parent.width
                wrapMode: Text.Wrap
                visible: Vpn.message !== ""
                color: Vpn.status === "error" ? Skin.danger : Skin.textDim
                text: Vpn.message
            }

            PxText {
                width: parent.width
                visible: !!Vpn.currentServer
                text: I18n.t("Сервер: ", "Server: ") + Vpn.currentName
                elide: Text.ElideRight
            }

            Row {
                visible: root.on
                spacing: Skin.px(16)
                PxText {
                    text: "↓ " + Fmt.rate(Vpn.downSpeed)
                    color: Skin.ok
                }
                PxText {
                    text: "↑ " + Fmt.rate(Vpn.upSpeed)
                    color: Skin.accent
                }
                PxText {
                    dim: true
                    text: I18n.t("всего ", "total ") + Fmt.bytes(Vpn.totalDown + Vpn.totalUp)
                }
            }

            PxButton {
                width: parent.width
                height: Skin.controlHeight
                accent: !root.on
                danger: root.on
                text: root.busy ? I18n.t("Отменить", "Cancel") : root.on ? I18n.t("Отключить", "Disconnect") : I18n.t("Подключить", "Connect")
                // After a failure the button already reads "Connect", so it must connect: a bare forceOff()
                // only reset the state and made the user click twice to retry.
                onClicked: {
                    if (root.busy) {
                        Vpn.forceOff();
                    } else if (Vpn.status === "error") {
                        Vpn.forceOff();
                        Qt.callLater(Vpn.connect);
                    } else {
                        Vpn.toggle();
                    }
                }
            }
        }
    }

    PxGroup {
        width: parent.width
        title: I18n.t("Режим", "Mode")
        icon: "plug"
        PxSegmented {
            width: parent.width
            model: [
                {
                    "label": I18n.t("Прокси", "Proxy"),
                    "value": "proxy",
                    "icon": "plug"
                },
                {
                    "label": I18n.t("TUN", "TUN"),
                    "value": "tun",
                    "icon": "lock"
                }
            ]
            currentValue: Vpn.mode
            onActivated: value => Vpn.setMode(value)
        }
        PxText {
            width: parent.width
            wrapMode: Text.Wrap
            dim: true
            text: Vpn.mode === "tun" ? I18n.t("TUN поднимает виртуальный интерфейс и пускает через него весь трафик системы. Нужен установленный помощник — вкладка TUN. Пароль спросят один раз.", "TUN brings up a virtual interface and routes all system traffic through it. The helper must be installed — see the TUN tab. The password is asked once.") : I18n.t("Прокси-режим: приложения сами подключаются к ", "Proxy mode: apps connect to ") + "127.0.0.1:" + Vpn.socksPort + " (SOCKS5) " + I18n.t("или", "or") + " 127.0.0.1:" + Vpn.httpPort + " (HTTP)."
        }
    }

    PxGroup {
        width: parent.width
        title: I18n.t("Поведение", "Behaviour")
        icon: "gear"
        SettingRow {
            label: I18n.t("Подключаться при запуске", "Connect at startup")
            PxToggle {
                checked: Vpn.autoconnect
                onToggled: checked => Vpn.setAutoconnect(checked)
            }
        }
        SettingRow {
            label: I18n.t("Прописывать системный прокси (GNOME)", "Set the system proxy (GNOME)")
            PxToggle {
                checked: Vpn.systemProxy
                enabled: Vpn.mode === "proxy"
                onToggled: checked => Vpn.setSystemProxy(checked)
            }
        }
        SettingRow {
            label: I18n.t("Аварийное отключение сети", "Kill switch")
            PxToggle {
                checked: Vpn.killSwitch
                enabled: Vpn.mode === "tun"
                onToggled: checked => Vpn.setKillSwitch(checked)
            }
        }
        PxText {
            width: parent.width
            wrapMode: Text.Wrap
            dim: true
            text: I18n.t("Kill switch блокирует трафик, если туннель или ядро падают, — ничего не утечёт мимо. Работает в режиме TUN.", "The kill switch blocks traffic if the tunnel or core drops, so nothing leaks around it. TUN mode only.")
        }
    }

    PxGroup {
        width: parent.width
        title: I18n.t("Порты и DNS", "Ports and DNS")
        icon: "wifi"
        SettingRow {
            label: "SOCKS5"
            PxField {
                id: socksField
                width: Skin.px(130)
                text: String(Vpn.socksPort)
                onAccepted: {
                    // the setter validates and reports; on refusal the field snaps back so the
                    // stored value and what is on screen never disagree.
                    // The raw text, not parseInt(text): the setter's own guard is
                    // `String(port) === text.trim()`, which is what rejects "11080abc". Handing
                    // it an already-parsed number made that comparison an identity and the
                    // garbage through — the field would then keep showing it while the stored
                    // value was right.
                    if (!Vpn.setPorts(text, Vpn.httpPort))
                        text = String(Vpn.socksPort);
                }
            }
        }
        SettingRow {
            label: "HTTP"
            PxField {
                id: httpField
                width: Skin.px(130)
                text: String(Vpn.httpPort)
                onAccepted: {
                    // raw text again, for the same reason as the socks field above
                    if (!Vpn.setPorts(Vpn.socksPort, text))
                        text = String(Vpn.httpPort);
                }
            }
        }
        SettingRow {
            label: I18n.t("DNS в TUN", "DNS in TUN")
            PxField {
                id: dnsField
                width: Skin.px(170)
                text: Vpn.dns
                placeholder: "1.1.1.1"
                onAccepted: {
                    if (!Vpn.setDns(text.trim()))
                        text = Vpn.dns;
                }
            }
        }
        PxText {
            width: parent.width
            wrapMode: Text.Wrap
            dim: true
            text: I18n.t("Порт API статистики: 127.0.0.1:", "Stats API port: 127.0.0.1:") + Vpn.apiPort + I18n.t(". Меняется вместе с SOCKS.", ". Follows the SOCKS port.")
        }
    }

    // always at the very bottom: the panic switch. Whatever state the VPN is in, this
    // stops the core and tears the TUN down, so normal internet comes back.
    PxButton {
        width: parent.width
        danger: true
        text: I18n.t("Аварийно отключить и восстановить интернет", "Emergency disconnect and restore internet")
        onClicked: Vpn.forceOff()
    }
    PxText {
        width: parent.width
        wrapMode: Text.Wrap
        dim: true
        text: I18n.t("Снимает TUN и маршруты, глушит ядро и убирает системный прокси. Если интернет пропал после подключения — нажми сюда.", "Tears down the TUN and its routes, stops the core and clears the system proxy. If the internet died after connecting, press this.")
    }
}
