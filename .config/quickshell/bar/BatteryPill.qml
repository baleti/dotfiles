import QtQuick
import "../theme"
import "../services"

// Only shown while actually running on battery power (unplugged) -- on AC
// it's dead information (always pinned near 100%), so it hides entirely
// rather than sitting there showing a number nobody needs. Re-added
// 2026-08-28 after being removed outright; the user's actual complaint was
// that it showed even while charging, not that it existed at all.
Rectangle {
    id: root

    visible: BatterySvc.present && BatterySvc.onBattery
    implicitWidth: visible ? row.implicitWidth + Theme.pillPadH * 2 : 0
    implicitHeight: Theme.barHeight - 10
    width: implicitWidth
    height: implicitHeight

    color: Theme.bgAlpha
    border.color: Theme.border
    border.width: 1
    radius: Theme.rounding

    // Calm text at a healthy charge; slides up the calm->hot intensity ramp
    // as it drains, only starting to warm below ~50% and going fully hot near
    // empty. (Inverse of the other metrics -- here "low" is the alarming end.)
    readonly property color batColor: BatterySvc.percent >= 50
        ? Theme.text
        : Theme.rampColor(Theme.norm(50 - BatterySvc.percent, 0, 42))

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 4

        Text {
            font.family: Theme.iconFontFamily
            font.pixelSize: Theme.fontSize
            color: root.batColor
            text: Icons.levelIcon(Icons.batteryLevels, BatterySvc.percent / 100)
        }

        Text {
            text: Math.round(BatterySvc.percent) + "%"
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
            color: root.batColor
        }
    }
}
