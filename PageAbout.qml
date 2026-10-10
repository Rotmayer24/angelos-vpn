import QtQuick
import qs.config
import qs.services
import qs.widgets
import "."

// Settings page: about the plugin, the engine and the device id.
Column {
    id: root

    property var plugin
    width: parent ? parent.width : Skin.px(540)
    spacing: Skin.spacing

    PxGroup {
        width: parent.width
        title: I18n.t("VPN", "VPN")
        icon: "lock"
        PxText {
            width: parent.width
            wrapMode: Text.Wrap
            text: I18n.t("Клиент Xray для angelOS: подписки Fortuna/Happ, выбор локации, пинг серверов, раздельное туннелирование и TUN-режим с одним вводом пароля.", "An Xray client for angelOS: Fortuna/Happ subscriptions, location picker, server ping, split tunneling and a TUN mode with a one-time password.")
        }
        PxText {
            width: parent.width
            dim: true
            // The host may hand over a plugin context without a manifest; reading it unguarded threw
            // a TypeError during binding evaluation. No hard-coded fallback version either: it
            // would drift away from manifest.json.
            text: I18n.t("Версия ", "Version ") + (root.plugin && root.plugin.manifest ? root.plugin.manifest.version : "?")
        }
    }

    PxGroup {
        width: parent.width
        title: I18n.t("Устройство", "Device")
        icon: "info"
        PxText {
            width: parent.width
            wrapMode: Text.Wrap
            text: I18n.t("HWID: ", "HWID: ") + Vpn.hwid
        }
        PxText {
            width: parent.width
            wrapMode: Text.Wrap
            dim: true
            text: I18n.t("HWID постоянный (берётся из /etc/machine-id) и отправляется провайдеру как один и тот же компьютер. Лимит устройств не обходится.", "The HWID is stable (derived from /etc/machine-id) and sent to the provider as the same machine. The device limit is not bypassed.")
        }
    }

    PxGroup {
        width: parent.width
        title: I18n.t("Движок", "Engine")
        icon: "bolt"
        PxText {
            width: parent.width
            wrapMode: Text.Wrap
            dim: true
            text: "Xray: " + Vpn.xrayPath
        }
        PxText {
            width: parent.width
            wrapMode: Text.Wrap
            dim: true
            text: I18n.t("TUN: ", "TUN: ") + "/opt/happ/bin/tun/sing-box"
        }
        PxText {
            width: parent.width
            wrapMode: Text.Wrap
            dim: true
            text: I18n.t("Кэш: ", "Cache: ") + Vpn.cacheDir
        }
    }

    PxGroup {
        width: parent.width
        title: I18n.t("Команды", "Commands")
        icon: "gear"
        PxText {
            width: parent.width
            wrapMode: Text.Wrap
            text: I18n.t("Из терминала: angelos run vpn toggle | connect | disconnect | settings | refresh | ping. Метка IPC — vpn.", "From a terminal: angelos run vpn toggle | connect | disconnect | settings | refresh | ping. IPC target — vpn.")
        }
    }

    PxGroup {
        width: parent.width
        title: I18n.t("Благодарности", "Credits")
        icon: "heart"
        PxText {
            width: parent.width
            wrapMode: Text.Wrap
            dim: true
            text: I18n.t("Ядро — Xray-core. TUN-слой — sing-box. Оформление — Theme API angelOS.", "Core — Xray-core. TUN layer — sing-box. Look — the angelOS Theme API.")
        }
    }
}
