import QtQuick
import qs.config
import qs.services
import qs.widgets
import "."

// The plugin's page in angelOS Settings (manifest `settings`, next to Network).
// It reuses the same tabbed body the standalone window shows.
Column {
    id: root

    property var plugin
    width: parent ? parent.width : Skin.px(560)
    spacing: Skin.spacing

    PxText {
        width: parent.width
        wrapMode: Text.Wrap
        text: I18n.t("Подписки Fortuna/Happ, выбор локации, пинг серверов, раздельное туннелирование и TUN-режим. Полное окно — шестерёнка на виджете рабочего стола или angelos run vpn settings.", "Fortuna/Happ subscriptions, location picker, server ping, split tunneling and TUN mode. The full window — the gear on the desktop widget or angelos run vpn settings.")
    }

    SettingsPanel {
        width: parent.width
        plugin: root.plugin
    }
}
