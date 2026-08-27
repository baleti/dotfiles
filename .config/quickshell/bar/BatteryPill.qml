import QtQuick
import "../theme"
import "../services"

Rectangle {
    id: root

    visible: BatterySvc.present
    implicitWidth: visible ? row.implicitWidth + Theme.pillPadH * 2 : 0
    implicitHeight: Theme.barHeight - 10
    width: implicitWidth
    height: implicitHeight

    color: Theme.bgAlpha
    border.color: Theme.border
    border.width: 1
    radius: Theme.rounding

    readonly property color batColor: {
        if (BatterySvc.charging)
            return Theme.text;
        if (BatterySvc.percent <= 15)
            return Theme.red;
        if (BatterySvc.percent <= 30)
            return Theme.orange;
        return Theme.text;
    }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 4

        Text {
            text: Math.round(BatterySvc.percent) + "%"
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
            color: root.batColor
        }

        Text {
            font.family: Theme.iconFontFamily
            font.pixelSize: Theme.fontSize
            color: root.batColor
            text: BatterySvc.charging ? Icons.batteryCharging : Icons.levelIcon(Icons.batteryLevels, BatterySvc.percent / 100)
        }
    }
}
