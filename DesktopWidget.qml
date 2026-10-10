import QtQuick
import QtQuick.Layouts
import qs.config
import qs.services
import qs.widgets
import "."
import "Fmt.js" as Fmt

// Desktop widget: status, the chosen server, live speed and a switch.
// The host draws the frame ("vpn.exe" in pixel, a glass card in the macOS
// widget style); this is only the content. See PLUGINS.md, Theme API.
Item {
    id: root

    property var plugin
    property string screenName
    property var widget

    readonly property bool mac: DesktopWidgets.macLook
    readonly property bool hell: Theme.hell

    readonly property color ink: root.hell ? Theme.hellText : root.mac ? DesktopWidgets.macLabel : Theme.text
    readonly property color dim: root.hell ? Theme.hellTextDim : root.mac ? DesktopWidgets.macSecondary : Theme.textDim
    readonly property color acc: root.hell ? Theme.hellAccent : Skin.accent
    readonly property color good: root.hell ? Theme.hellAccent : Skin.ok
    readonly property color bad: root.hell ? Theme.hellBlood : Skin.danger
    readonly property color dot: root.on ? root.good : root.busy ? root.acc : Vpn.status === "error" ? root.bad : (root.mac ? DesktopWidgets.macTertiary : Skin.textFaint)

    readonly property bool on: Vpn.connected
    readonly property bool busy: Vpn.busy
    readonly property string line: root.on ? "↓ " + Fmt.rate(Vpn.downSpeed) + "   ↑ " + Fmt.rate(Vpn.upSpeed) : root.busy ? I18n.t("Подключение…", "Connecting…") : Vpn.status === "error" ? (Vpn.message || I18n.t("Ошибка", "Error")) : I18n.t("Отключено", "Off")
    readonly property string buttonText: root.busy ? I18n.t("Отмена", "Cancel") : root.on ? I18n.t("Отключить", "Disconnect") : I18n.t("Подключить", "Connect")

    implicitWidth: root.mac ? DesktopWidgets.mpx(200) : Theme.u * 102
    implicitHeight: root.mac ? macCol.implicitHeight : col.implicitHeight

    // The host owns widget instantiation and may hand `plugin` over after the widget is
    // built. Listening only to onCompleted left the widget permanently "Отключено" with a
    // dead button — the controller never loaded and no error was ever shown.
    Component.onCompleted: if (plugin)
        Vpn.attach(plugin)
    onPluginChanged: if (plugin)
        Vpn.attach(plugin)

    // ---------------- macOS widget ----------------
    Column {
        id: macCol
        visible: root.mac
        width: root.width
        spacing: DesktopWidgets.mpx(6)

        RowLayout {
            width: parent.width
            spacing: DesktopWidgets.mpx(6)
            Rectangle {
                Layout.alignment: Qt.AlignVCenter
                Layout.preferredWidth: DesktopWidgets.mpx(9)
                Layout.preferredHeight: DesktopWidgets.mpx(9)
                radius: width / 2
                color: root.dot
            }
            MacWidgetText {
                Layout.fillWidth: true
                text: "VPN"
                size: 13
                weight: Font.DemiBold
            }
            Item {
                Layout.alignment: Qt.AlignVCenter
                Layout.preferredWidth: DesktopWidgets.mpx(20)
                Layout.preferredHeight: DesktopWidgets.mpx(20)
                MacIcon {
                    anchors.centerIn: parent
                    name: "settings"
                    size: DesktopWidgets.mpx(15)
                    color: root.dim
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Vpn.openSettings()
                }
            }
        }
        MacWidgetText {
            width: parent.width
            text: Vpn.currentName
            size: 12
            role: "secondary"
        }
        MacWidgetText {
            width: parent.width
            text: root.line
            size: 12
            role: "secondary"
        }
        Rectangle {
            width: parent.width
            height: DesktopWidgets.mpx(30)
            radius: height / 2
            color: root.on ? DesktopWidgets.macFill : root.acc
            border.width: root.on ? 1 : 0
            border.color: DesktopWidgets.macSeparator
            Text {
                anchors.centerIn: parent
                text: root.buttonText
                color: root.on ? root.ink : (root.hell ? Theme.hellBody : "#ffffff")
                font.family: DesktopWidgets.macFamily(13)
                font.pixelSize: DesktopWidgets.mpx(13)
                font.weight: Font.DemiBold
                renderType: Text.QtRendering
            }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.busy ? Vpn.forceOff() : Vpn.toggle()
            }
        }
    }

    // ---------------- pixel / hell widget ----------------
    Column {
        id: col
        visible: !root.mac
        width: root.width
        spacing: Theme.u * 2

        RowLayout {
            width: parent.width
            spacing: Theme.u * 2
            Rectangle {
                Layout.alignment: Qt.AlignVCenter
                Layout.preferredWidth: Theme.u * 4
                Layout.preferredHeight: Theme.u * 4
                color: root.dot
                border.width: root.hell ? 1 : 0
                border.color: Theme.hellRim
            }
            PxText {
                Layout.fillWidth: true
                text: "VPN"
                kind: "title"
                color: root.ink
            }
            PxIcon {
                name: "gear"
                ink: root.dim
                fill: root.acc
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Vpn.openSettings()
                }
            }
        }
        PxText {
            width: parent.width
            text: Vpn.currentName
            color: root.ink
            elide: Text.ElideRight
        }
        PxText {
            width: parent.width
            text: root.line
            color: root.on ? root.good : Vpn.status === "error" ? root.bad : root.dim
            elide: Text.ElideRight
        }
        PxButton {
            width: parent.width
            hell: root.hell
            accent: !root.on
            danger: root.on
            text: root.buttonText
            onClicked: root.busy ? Vpn.forceOff() : Vpn.toggle()
        }
    }
}
