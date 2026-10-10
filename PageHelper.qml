import QtQuick
import QtQuick.Layouts
import qs.config
import qs.services
import qs.widgets
import "."

// Settings page: the privileged TUN helper — install once, then no password.
Column {
    id: root

    property var plugin
    width: parent ? parent.width : Skin.px(540)
    spacing: Skin.spacing

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
                    color: Vpn.helperInstalled ? Skin.ok : Skin.warn
                }
                PxText {
                    Layout.fillWidth: true
                    kind: "title"
                    text: Vpn.helperInstalled ? I18n.t("Помощник установлен", "Helper installed") : I18n.t("Помощник не установлен", "Helper not installed")
                }
            }
            PxText {
                width: parent.width
                wrapMode: Text.Wrap
                text: Vpn.helperInstalled ? I18n.t("TUN-режим готов: пароль больше не спросят. Подключение и отключение идут без запроса. Переустановка и удаление пароль спросят — это операции с правами root.", "TUN is ready: the password will not be asked again. Connecting and disconnecting run without a prompt. Reinstalling and removing ask for the password — they run as root.") : I18n.t("Для TUN-режима нужен привилегированный помощник. Установка запросит пароль один раз — дальше всё работает без него.", "TUN mode needs a privileged helper. Installing asks for the password once — after that everything runs without it.")
            }
            RowLayout {
                width: parent.width
                spacing: Skin.px(8)
                PxButton {
                    text: Vpn.helperInstalling ? I18n.t("Устанавливаю…", "Installing…") : Vpn.helperInstalled ? I18n.t("Переустановить", "Reinstall") : I18n.t("Установить помощник", "Install helper")
                    icon: "download"
                    accent: !Vpn.helperInstalled
                    enabled: !Vpn.helperInstalling
                    onClicked: Vpn.installHelper()
                }
                PxButton {
                    text: I18n.t("Проверить", "Check")
                    icon: "refresh"
                    enabled: !Vpn.helperInstalling
                    onClicked: Vpn.refreshHelper()
                }
                PxButton {
                    text: I18n.t("Удалить", "Remove")
                    danger: true
                    enabled: Vpn.helperInstalled && !Vpn.helperInstalling
                    onClicked: Vpn.removeHelper()
                }
            }
        }
    }

    PxGroup {
        width: parent.width
        title: I18n.t("Что устанавливается", "What gets installed")
        icon: "info"
        PxText {
            width: parent.width
            wrapMode: Text.Wrap
            text: I18n.t("Помощник — это небольшой скрипт с правами root и правило PolicyKit. Он принимает только провéренные параметры (порты, адрес сервера, DNS, списки приложений и домены) и сам собирает конфигурацию sing-box: TUN-интерфейс, маршрутизацию и split tunneling. Произвольную конфигурацию с правами root передать нельзя.", "The helper is a small root script plus a PolicyKit rule. It accepts only validated parameters (ports, server address, DNS, app and domain lists) and builds the sing-box config itself: the TUN interface, routing and split tunneling. No arbitrary root config can be passed.")
        }
    }

    PxGroup {
        width: parent.width
        title: I18n.t("Файлы", "Files")
        icon: "lock"
        PxText {
            width: parent.width
            wrapMode: Text.Wrap
            dim: true
            text: I18n.t("Помощник: ", "Helper: ") + Vpn.helperPath
        }
        PxText {
            width: parent.width
            wrapMode: Text.Wrap
            dim: true
            text: I18n.t("Правило PolicyKit: ", "PolicyKit rule: ") + Vpn.policyPath
        }
        PxText {
            width: parent.width
            wrapMode: Text.Wrap
            dim: true
            text: I18n.t("Скрипт: ", "Script: ") + Vpn.plugDir + "privileged/"
        }
    }

    PxGroup {
        width: parent.width
        title: I18n.t("Как это работает", "How it works")
        icon: "bolt"
        PxText {
            width: parent.width
            wrapMode: Text.Wrap
            text: I18n.t("Ядро Xray слушает локальный SOCKS-порт, а sing-box поднимает TUN и заворачивает в него трафик системы. Трафик до самого сервера и до Xray идёт напрямую, чтобы не зациклиться.", "The Xray core listens on a local SOCKS port, while sing-box brings up the TUN and funnels system traffic into it. Traffic to the server itself and to Xray goes directly, so it cannot loop.")
        }
    }
}
