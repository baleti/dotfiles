import QtQuick
import Quickshell
import "../theme"
import "../services"

// One notification card. notifyd (headless) owns the lifetime -- this just
// draws whatever's in NotifSvc.popups and forwards clicks. Visuals port the
// old notifyd.toml: 2px frame in the cyan accent (red for critical),
// translucent dark card, 10px rounding, JetBrains Mono, 32px icon on the
// left, bold summary above the body, action buttons along the bottom.
//
// Mouse (matches the old dunstrc bindings): left = default action (or
// dismiss if there is none), middle = dismiss this card, right = dismiss
// all. None of these destroy the notification -- notifyd keeps it invokable.
Rectangle {
    id: root

    required property var notification
    property real cardWidth: 360

    readonly property int urgency: notification.urgency ?? 1
    readonly property bool critical: urgency === 2
    readonly property bool low: urgency === 0
    readonly property bool isRss: (notification.app_name ?? "") === "rssd"
    readonly property string defaultAction: notification.default_action ?? ""
    // Buttons for every action except the invisible "default" one.
    readonly property var buttonActions:
        (notification.actions ?? []).filter(a => a.key !== "default")

    width: cardWidth
    implicitHeight: {
        let bottom = bodyFlick.y + (bodyFlick.visible ? bodyFlick.height : 0);
        if (leadImage.visible)
            bottom = leadImage.y + leadImage.height;
        if (buttons.visible)
            bottom = buttons.y + buttons.height;
        return Math.max(bottom + 12, icon.y + icon.height + 12);
    }
    radius: Theme.rounding
    color: root.critical ? Qt.rgba(0.11, 0.06, 0.06, 0.94) : Theme.bgAlpha
    border.width: 2
    border.color: root.critical ? Theme.red : (root.low ? Theme.muted : Theme.cyan)

    // notifyd already resolved the icon to a themed name, an absolute path,
    // or a PNG it wrote from an image-data hint. Turn a bare path into a
    // file:// url; look a themed name up in the icon theme.
    readonly property string iconSource: {
        const ic = (root.notification.icon ?? "").toString();
        if (ic.length === 0)
            return Quickshell.iconPath(root.critical ? "dialog-warning" : "dialog-information", "");
        if (ic.startsWith("file://"))
            return ic;
        if (ic.startsWith("/"))
            return "file://" + ic;
        return Quickshell.iconPath(ic, root.critical ? "dialog-warning" : "dialog-information");
    }

    // The card's "large image" (article art). notifyd keeps it separate from
    // `icon`; skip it when it's the same file the icon already shows.
    readonly property string imageSource: {
        const im = (root.notification.image ?? "").toString();
        if (im.length === 0 || im === (root.notification.icon ?? "").toString())
            return "";
        if (im.startsWith("file://"))
            return im;
        if (im.startsWith("/"))
            return "file://" + im;
        return "";
    }

    Image {
        id: icon
        x: 12
        y: 12
        width: 32
        height: 32
        fillMode: Image.PreserveAspectFit
        smooth: true
        asynchronous: true
        visible: status === Image.Ready
        source: root.iconSource
        sourceSize.width: 64
        sourceSize.height: 64

        // rssd cards: source favicon (this Image) + a small RSS badge, so a
        // glance says "feed item from <source>" before you read the text.
        Rectangle {
            visible: root.isRss
            width: 16
            height: 16
            radius: 8
            color: root.critical ? Qt.rgba(0.11, 0.06, 0.06, 1) : Theme.bg
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.rightMargin: -4
            anchors.bottomMargin: -4

            Text {
                anchors.centerIn: parent
                text: Icons.rss
                font.family: Theme.iconFontFamily
                font.pixelSize: 10
                color: Theme.orange
            }
        }
    }

    Text {
        id: summary
        x: icon.visible ? 56 : 12
        y: 12
        width: root.width - x - 12
        text: root.notification.summary ?? ""
        textFormat: Text.PlainText
        elide: Text.ElideRight
        maximumLineCount: 2
        wrapMode: Text.WordWrap
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize
        font.bold: true
        color: root.critical ? "#ffffff" : (root.low ? Theme.textDim : Theme.text)
    }

    Flickable {
        id: bodyFlick
        x: summary.x
        y: summary.y + summary.height + (bodyText.text.length > 0 ? 4 : 0)
        width: summary.width
        height: Math.min(bodyText.implicitHeight, 260)
        visible: bodyText.text.length > 0
        contentHeight: bodyText.implicitHeight
        clip: true
        interactive: contentHeight > height
        boundsBehavior: Flickable.StopAtBounds

        Text {
            id: bodyText
            width: bodyFlick.width
            text: root.notification.body ?? ""
            textFormat: Text.StyledText
            wrapMode: Text.WordWrap
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 1
            color: root.critical ? "#f5f5f5" : (root.low ? Theme.muted : Theme.textDim)
            onLinkActivated: link => Qt.openUrlExternally(link)
        }
    }

    // Article lead image (rssd, and any app that sends an image hint).
    Rectangle {
        id: leadImage
        x: summary.x
        y: bodyFlick.y + (bodyFlick.visible ? bodyFlick.height : 0)
                       + (root.imageSource !== "" ? 8 : 0)
        width: summary.width
        height: visible ? 132 : 0
        radius: Theme.rounding - 4
        clip: true
        color: "transparent"
        visible: root.imageSource !== "" && img.status === Image.Ready

        Image {
            id: img
            anchors.fill: parent
            source: root.imageSource
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            smooth: true
            sourceSize.width: 640
        }
    }

    // Action buttons.
    Row {
        id: buttons
        x: summary.x
        y: {
            if (leadImage.visible)
                return leadImage.y + leadImage.height + 8;
            if (bodyFlick.visible)
                return bodyFlick.y + bodyFlick.height + 8;
            return bodyFlick.y;
        }
        width: summary.width
        spacing: 6
        visible: root.buttonActions.length > 0

        Repeater {
            model: root.buttonActions

            Rectangle {
                id: btn
                required property var modelData
                height: 24
                width: Math.min(label.implicitWidth + 18, root.width - summary.x - 12)
                radius: Theme.rounding - 4
                color: btnArea.containsMouse ? Theme.cyan : "transparent"
                border.color: btnArea.containsMouse ? Theme.cyan : Theme.border
                border.width: 1

                Text {
                    id: label
                    anchors.centerIn: parent
                    text: btn.modelData.label
                    elide: Text.ElideRight
                    width: parent.width - 14
                    horizontalAlignment: Text.AlignHCenter
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                    color: btnArea.containsMouse ? Theme.bg : Theme.text
                }

                MouseArea {
                    id: btnArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        NotifSvc.invokeKey(root.notification.id, btn.modelData.key);
                        NotifSvc.dismiss(root.notification.id);
                    }
                }
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
        propagateComposedEvents: true
        // Sit behind the buttons / body links.
        z: -1
        onClicked: mouse => {
            if (mouse.button === Qt.LeftButton) {
                if (root.defaultAction.length > 0)
                    NotifSvc.invokeDefault(root.notification.id);
                else
                    NotifSvc.dismiss(root.notification.id);
            } else if (mouse.button === Qt.MiddleButton) {
                NotifSvc.dismiss(root.notification.id);
            } else if (mouse.button === Qt.RightButton) {
                NotifSvc.closeAll();
            }
        }
    }

    opacity: 0
    Component.onCompleted: opacity = 1
    Behavior on opacity { NumberAnimation { duration: 120 } }
}
