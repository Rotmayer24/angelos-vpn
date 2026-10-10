import QtQuick
import Quickshell
import qs.config
import qs.services
import qs.widgets
import "."

// The standalone VPN window, opened by the desktop widget's gear, the bar pill or
// `vpn settings`. A real toplevel with its own frame, like angelOS Settings.
FloatingWindow {
    id: win

    property var plugin

    title: Shell.appTitle + " · " + I18n.t("VPN", "VPN")
    visible: Vpn.settingsOpen
    color: "transparent"
    implicitWidth: Skin.px(700)
    implicitHeight: Skin.px(760)
    minimumSize: Qt.size(Skin.px(520), Skin.px(460))
    // only onClosed: onVisibleChanged also fires when the compositor merely hides the window
    // (a workspace switch, for instance), which silently dismissed the user's settings
    onClosed: Vpn.closeSettings()

    // The settings skin for every Px* control inside (Only SettingsView sets it otherwise).
    Item {
        id: frame
        anchors.fill: parent
        property string settingsSkin: Skin.settingsSkin

        SkinCard {
            anchors.fill: parent
            anchors.margins: Skin.px(6)

            Column {
                anchors.fill: parent
                spacing: Skin.px(6)

                Item {
                    id: titleBar
                    width: parent.width
                    height: Skin.px(26)

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.SizeAllCursor
                        onPressed: win.startSystemMove()
                    }
                    PxText {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        kind: "title"
                        text: Skin.title("vpn")
                    }
                    PxButton {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        icon: "close"
                        compact: true
                        onClicked: Vpn.closeSettings()
                    }
                }

                Item {
                    width: parent.width
                    height: parent.height - titleBar.height - parent.spacing

                    Flickable {
                        id: flick
                        anchors.fill: parent
                        contentWidth: width
                        contentHeight: panel.height
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        flickDeceleration: 4000
                        maximumFlickVelocity: 3000

                        SettingsPanel {
                            id: panel
                            width: flick.width
                            plugin: win.plugin
                        }
                    }

                    Rectangle {
                        visible: flick.contentHeight > flick.height + 1
                        x: parent.width - Skin.px(5)
                        width: Skin.px(3)
                        radius: width / 2
                        color: Skin.textFaint
                        height: Math.max(Skin.px(24), flick.height * (flick.height / Math.max(1, flick.contentHeight)))
                        y: (flick.height - height) * (flick.contentY / Math.max(1, flick.contentHeight - flick.height))
                    }
                }
            }
        }
    }

    RightClickGuard {}
}
