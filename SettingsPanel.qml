import QtQuick
import qs.config
import qs.services
import qs.widgets
import "."

// The tabbed VPN settings body. Shared by the standalone window and by the plugin's
// page inside angelOS Settings. Top nav, one page loaded at a time.
Column {
    id: root

    property var plugin
    property string tab: "connection"

    width: parent ? parent.width : Skin.px(560)
    spacing: Skin.spacing

    readonly property var tabs: [
        {
            "id": "connection",
            "label": I18n.t("Связь", "Connection"),
            "icon": "plug"
        },
        {
            "id": "servers",
            "label": I18n.t("Серверы", "Servers"),
            "icon": "wifi"
        },
        {
            "id": "subs",
            "label": I18n.t("Подписки", "Subscriptions"),
            "icon": "refresh"
        },
        {
            "id": "split",
            "label": I18n.t("Приложения", "Apps"),
            "icon": "eye"
        },
        {
            "id": "helper",
            "label": "TUN",
            "icon": "lock"
        },
        {
            "id": "logs",
            "label": I18n.t("Логи", "Logs"),
            "icon": "terminal"
        },
        {
            "id": "about",
            "label": I18n.t("О программе", "About"),
            "icon": "info"
        }
    ]

    PxSegmented {
        width: parent.width
        model: root.tabs.map(t => ({
                    "label": t.label,
                    "value": t.id,
                    "icon": t.icon
                }))
        currentValue: root.tab
        onActivated: value => root.tab = value
    }

    Loader {
        id: page
        width: parent.width
        height: item ? item.implicitHeight : 0
        sourceComponent: root.tab === "connection" ? connC : root.tab === "servers" ? srvC : root.tab === "subs" ? subC : root.tab === "split" ? splitC : root.tab === "helper" ? helperC : root.tab === "logs" ? logsC : aboutC
    }

    // Only PageAbout reads the plugin context (for the version). Passing it to every page as
    // well was plumbing nobody used, and it invited the next reader to trust a property that
    // may be null depending on how the panel was opened.
    Component {
        id: connC
        PageConnection {
        }
    }
    Component {
        id: srvC
        PageServers {
            onRequestTab: tab => root.tab = tab
        }
    }
    Component {
        id: subC
        PageSubscriptions {
        }
    }
    Component {
        id: splitC
        PageSplit {
        }
    }
    Component {
        id: helperC
        PageHelper {
        }
    }
    Component {
        id: aboutC
        PageAbout {
            plugin: root.plugin
        }
    }
    Component {
        id: logsC
        PageLogs {
        }
    }
}
