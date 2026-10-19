// Self-contained SDDM theme: QtQuick + QtQuick.Controls only, no KDE/Kirigami
// imports, so Plasma upgrades cannot break it (the stock-breeze-derived
// eos-breeze theme died when KDE removed VirtualKeyboardLoader).
// Colours/wallpaper come from theme.conf, rewritten by gen-theme.py.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects
import SddmComponents 2.0 as Sddm

Rectangle {
    id: root
    width: 1920
    height: 1080
    color: cfg("surface", "#1f1b16")

    function cfg(key, fallback) {
        var v = config[key];
        return (v === undefined || v === "") ? fallback : v;
    }
    readonly property color cSurface: cfg("surface", "#1f1b16")
    readonly property color cCard: cfg("surfaceContainer", "#4f4539")
    readonly property color cText: cfg("onSurface", "#ebe1d9")
    readonly property color cMuted: cfg("onSurfaceVariant", "#d3c4b4")
    readonly property color cOutline: cfg("outline", "#9c8f80")
    readonly property color cPrimary: cfg("primary", "#ffb957")
    readonly property color cOnPrimary: cfg("onPrimary", "#462b00")
    readonly property color cError: cfg("error", "#ffb4ab")

    property int userIndex: Math.max(0, userModel.lastIndex)
    property int sessionIndex: Math.max(0, sessionModel.lastIndex)
    property bool failed: false
    property string userName: userModel.data(userModel.index(userIndex, 0), 257) || userModel.lastUser || ""
    property string realName: userModel.data(userModel.index(userIndex, 0), 258) || userName

    Image {
        id: bg
        anchors.fill: parent
        source: cfg("background", "wallpaper.png")
        fillMode: Image.PreserveAspectCrop
        asynchronous: false
    }
    MultiEffect {
        anchors.fill: bg
        source: bg
        blurEnabled: true
        blurMax: 48
        blur: 1.0
    }
    Rectangle {
        anchors.fill: parent
        color: root.cSurface
        opacity: parseFloat(cfg("background_dim", "0.45"))
    }

    // clock
    Column {
        anchors.horizontalCenter: parent.horizontalCenter
        y: parent.height * 0.12
        spacing: 4
        Text {
            id: clock
            anchors.horizontalCenter: parent.horizontalCenter
            color: root.cText
            font.pixelSize: 88
            font.weight: Font.Light
            text: Qt.formatTime(new Date(), "HH:mm")
        }
        Text {
            id: date
            anchors.horizontalCenter: parent.horizontalCenter
            color: root.cMuted
            font.pixelSize: 22
            text: Qt.formatDate(new Date(), "dddd, d MMMM")
        }
        Timer {
            interval: 1000; running: true; repeat: true
            onTriggered: { clock.text = Qt.formatTime(new Date(), "HH:mm"); date.text = Qt.formatDate(new Date(), "dddd, d MMMM"); }
        }
    }

    // login card
    Rectangle {
        id: card
        anchors.centerIn: parent
        anchors.verticalCenterOffset: 60
        width: 380
        height: col.implicitHeight + 56
        radius: 28
        color: Qt.rgba(root.cCard.r, root.cCard.g, root.cCard.b, 0.82)
        border.color: Qt.rgba(root.cOutline.r, root.cOutline.g, root.cOutline.b, 0.5)
        border.width: 1

        ColumnLayout {
            id: col
            anchors.fill: parent
            anchors.margins: 28
            spacing: 16

            Rectangle {
                Layout.alignment: Qt.AlignHCenter
                width: 96; height: 96; radius: 48
                color: root.cPrimary
                Text {
                    anchors.centerIn: parent
                    text: (root.realName || "?").charAt(0).toUpperCase()
                    color: root.cOnPrimary
                    font.pixelSize: 44
                }
            }
            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: 12
                visible: userModel.count > 1
                ToolButton {
                    text: "‹"; onClicked: { root.userIndex = (root.userIndex + userModel.count - 1) % userModel.count; pw.forceActiveFocus() }
                    contentItem: Text { text: parent.text; color: root.cText; font.pixelSize: 24; horizontalAlignment: Text.AlignHCenter }
                    background: null
                }
                ToolButton {
                    text: "›"; onClicked: { root.userIndex = (root.userIndex + 1) % userModel.count; pw.forceActiveFocus() }
                    contentItem: Text { text: parent.text; color: root.cText; font.pixelSize: 24; horizontalAlignment: Text.AlignHCenter }
                    background: null
                }
            }
            Text {
                Layout.alignment: Qt.AlignHCenter
                text: root.realName
                color: root.cText
                font.pixelSize: 22
            }

            TextField {
                id: pw
                Layout.fillWidth: true
                Layout.preferredHeight: 48
                echoMode: TextInput.Password
                placeholderText: "Password"
                placeholderTextColor: root.cOutline
                color: root.cText
                font.pixelSize: 16
                leftPadding: 18
                focus: true
                background: Rectangle {
                    radius: 24
                    color: Qt.rgba(root.cSurface.r, root.cSurface.g, root.cSurface.b, 0.7)
                    border.width: pw.activeFocus ? 2 : 1
                    border.color: root.failed ? root.cError : (pw.activeFocus ? root.cPrimary : root.cOutline)
                }
                onAccepted: doLogin()
                onTextEdited: root.failed = false
                Keys.onEscapePressed: pw.clear()
            }
            Text {
                Layout.alignment: Qt.AlignHCenter
                visible: root.failed || keyboard.capsLock
                text: root.failed ? "Login failed" : "Caps Lock is on"
                color: root.failed ? root.cError : root.cMuted
                font.pixelSize: 14
            }
            Button {
                Layout.fillWidth: true
                Layout.preferredHeight: 46
                text: "Log in"
                onClicked: doLogin()
                contentItem: Text { text: parent.text; color: root.cOnPrimary; font.pixelSize: 16; font.weight: Font.Medium; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                background: Rectangle { radius: 23; color: parent.down ? Qt.darker(root.cPrimary, 1.2) : root.cPrimary }
            }
        }
    }

    function doLogin() {
        if (pw.text.length === 0) return;
        sddm.login(root.userName, pw.text, root.sessionIndex);
    }

    Connections {
        target: sddm
        function onLoginFailed() { root.failed = true; pw.clear(); pw.forceActiveFocus(); }
        function onLoginSucceeded() { }
    }

    // bottom bar: session picker, keyboard layout, power
    RowLayout {
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: 24
        spacing: 12

        ComboBox {
            id: sessionBox
            model: sessionModel
            textRole: "name"
            currentIndex: root.sessionIndex
            onActivated: root.sessionIndex = currentIndex
            implicitWidth: 240
            contentItem: Text { leftPadding: 14; text: sessionBox.displayText; color: root.cText; font.pixelSize: 14; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight }
            background: Rectangle { radius: 20; color: Qt.rgba(root.cCard.r, root.cCard.g, root.cCard.b, 0.7) }
        }
        Text {
            visible: keyboard.layouts.length > 1
            text: keyboard.layouts[keyboard.currentLayout] ? keyboard.layouts[keyboard.currentLayout].shortName : ""
            color: root.cMuted
            font.pixelSize: 14
            MouseArea { anchors.fill: parent; onClicked: keyboard.currentLayout = (keyboard.currentLayout + 1) % keyboard.layouts.length }
        }
        Item { Layout.fillWidth: true }
        Repeater {
            model: [
                { label: "Sleep", ok: sddm.canSuspend, act: function() { sddm.suspend() } },
                { label: "Restart", ok: sddm.canReboot, act: function() { sddm.reboot() } },
                { label: "Shut down", ok: sddm.canPowerOff, act: function() { sddm.powerOff() } }
            ]
            delegate: Button {
                visible: modelData.ok
                text: modelData.label
                onClicked: modelData.act()
                contentItem: Text { text: parent.text; color: root.cText; font.pixelSize: 14; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                background: Rectangle { radius: 20; color: Qt.rgba(root.cCard.r, root.cCard.g, root.cCard.b, parent.hovered ? 0.95 : 0.7) }
            }
        }
    }

    Component.onCompleted: pw.forceActiveFocus()
}
