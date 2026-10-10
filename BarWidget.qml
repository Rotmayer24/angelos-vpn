import QtQuick
import qs.config
import qs.services
import qs.widgets
import "."

// The VPN pill. Pixel: a flat PxButton. Mac look (Skin.mac, the Golden Gate menu bar):
// a line icon and the word in the bar's ink, like a menu bar extra.
// Left click connects / disconnects, right click opens the window.
Item {
    id: root

    property var plugin
    property string screenName
    property var barWindow
    // the pixel bar's hooks (BarItem): padding and the hell bar's ink go to the button
    property int hpad: -1
    property bool barInk: false

    readonly property bool mac: Skin.mac
    readonly property bool on: Vpn.connected
    readonly property bool busy: Vpn.busy

    implicitWidth: root.mac ? macRow.implicitWidth : btn.implicitWidth
    implicitHeight: root.mac ? Skin.px(18) : btn.implicitHeight

    // as in DesktopWidget: the bar widget may get `plugin` after it was built, and without this
    // the pill would show "Off" forever with nothing to click
    Component.onCompleted: if (plugin)
        Vpn.attach(plugin)
    onPluginChanged: if (plugin)
        Vpn.attach(plugin)

    PxButton {
        id: btn
        visible: !root.mac
        anchors.fill: parent
        compact: true
        flat: true
        hpad: root.hpad
        barInk: root.barInk
        icon: root.on ? "bolt" : "lock"
        text: "VPN"
        checked: root.on || root.busy
        onClicked: root.busy ? Vpn.forceOff() : Vpn.toggle()
        onRightClicked: Vpn.openSettings()
    }

    Row {
        id: macRow
        visible: root.mac
        anchors.centerIn: parent
        spacing: Skin.px(4)
        MacIcon {
            anchors.verticalCenter: parent.verticalCenter
            name: root.on ? "zap" : "lock"
            size: Skin.px(15)
            stroke: 2
            color: root.on ? Skin.accent : Skin.ink(root.screenName)
        }
        MacText {
            anchors.verticalCenter: parent.verticalCenter
            text: "VPN"
            color: Skin.ink(root.screenName)
        }
    }

    MouseArea {
        visible: root.mac
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: mouse => {
            if (mouse.button === Qt.RightButton)
                Vpn.openSettings();
            else
                root.busy ? Vpn.forceOff() : Vpn.toggle();
        }
    }
}
