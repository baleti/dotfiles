import QtQuick
import QtQuick.Layouts
import "../theme"
import "../components"

// Compact "value + icon" pill that expands down into a Graph on hover,
// backed by sysmond's rolling history (see services/SysmonSvc.qml) --
// same idea as the KDE Plasma network/cpu graph widgets this replaces,
// and visually matching the existing alt+mod+n/p/t/m sysmon-graph popups.
Rectangle {
    id: root

    property string icon: ""
    property string compactText: ""
    // > 0 fixes the compact value's width (right-aligned) so widgets whose
    // text length varies with magnitude (byte rates: "8 KB/s" vs "1.2
    // MB/s") don't constantly resize the whole pill as the value changes.
    property real compactTextWidth: -1
    property string title: ""
    property string valueLabel: ""

    // "single" (series/color1) or "overlay" (seriesList)
    property string mode: "single"
    property list<real> series: []
    property var seriesList: []
    property real maxValue: 100

    // 0..1 (or NaN to opt out): how "high" this metric currently is. Drives
    // the compact value/icon colour along Theme's calm->hot intensity ramp,
    // and -- in single mode -- the graph line/fill colour too.
    property real valueFraction: NaN
    readonly property bool graded: !isNaN(valueFraction)
    readonly property color gradedColor: graded ? Theme.rampColor(valueFraction) : Theme.text

    property color color1: graded ? gradedColor : Theme.cyan

    // Formats a raw value (0..maxValue) for the y-axis label column --
    // Bar.qml overrides per-widget (percent for cpu/mem, a byte-rate
    // string for net/disk, "N°C" for temperature).
    property var yAxisFormatter: v => Math.round(v)
    readonly property var gridFractions: [0, 0.25, 0.5, 0.75, 1.0]

    // [{name, color}] -- shown under the graph when non-empty.
    property var legendItems: []
    // [{name, value}] -- top-10 list shown when non-empty.
    property var topProcs: []
    property string topUnit: ""
    // Overrides the "Top processes" heading -- used by temperature, where
    // this is really "top CPU users" as a heat proxy, not a real per-
    // process temperature attribution (the kernel has no such thing).
    property string topLabel: qsTr("Top processes")

    // Time-range toggle row, shown only when tierCodes is non-empty --
    // Bar.qml wires this up for the 5 sysmond-backed metrics (net/cpu/mem/
    // disk/temp); media/calendar leave it empty and get no row.
    property var tierCodes: []
    property var tierLabels: ({})
    property string tier: "30m"
    signal tierRequested(string code)

    property bool expanded: false
    // Set by a click on the pill (or Bar.qml's IpcHandler, for the alt+t
    // style keybind toggles) -- while pinned, hovering off no longer closes
    // the panel; only clicking again (or the keybind again) does.
    property bool pinned: false
    readonly property bool hovered: hoverArea.containsMouse || expandPanel.hovered
    // Bar.qml reads this to size the window; 0 when collapsed.
    readonly property real overflowHeight: expandPanel.height
    // Bar.qml reads this to lay out multiple simultaneously-open panels
    // side by side instead of each self-positioning under its own pill
    // (which overlaps once more than one is expanded at once).
    readonly property real panelWidth: expandPanel.width
    // Set by Bar.qml when coordinating a multi-panel layout, so several
    // open panels stack side by side instead of overlapping. Both in
    // Bar.qml's own root coordinate space, since this pill lives inside
    // rightRow and doesn't know its own absolute position otherwise.
    // targetRight NaN falls back to this pill's own default (directly
    // below itself, right-aligned to its own right edge).
    property real groupX: 0
    property real targetRight: NaN

    onHoveredChanged: {
        if (hovered) {
            hideTimer.stop();
            expanded = true;
        } else if (!pinned) {
            hideTimer.restart();
        }
    }

    // 0, not a real debounce delay -- a bare `expanded = false` on hover-out
    // still works, but going through requestAnimationFrame-ish next-tick
    // timing here avoids a same-frame close+reopen flicker if the pointer
    // is exactly on the pill/panel boundary for an instant. Closes on the
    // very next event loop tick either way, i.e. instantly from a human
    // perspective -- the previous 250ms was what let sweeping the mouse
    // across several pills leave multiple panels open at once.
    Timer {
        id: hideTimer
        interval: 0
        onTriggered: root.expanded = false
    }

    // Click-to-pin: same persistence a keybind toggle already had (alt+t
    // etc, via Bar.qml's IpcHandler calling this too) -- stays open past
    // hover-out until clicked/toggled again, instead of closing the instant
    // the mouse leaves.
    function togglePin(): void {
        pinned = !pinned;
        if (pinned) {
            hideTimer.stop();
            expanded = true;
        } else if (!hovered) {
            hideTimer.stop();
            expanded = false;
        }
    }

    implicitWidth: compactRow.implicitWidth + Theme.pillPadH * 2
    implicitHeight: Theme.barHeight - 10
    width: implicitWidth
    height: implicitHeight

    color: Theme.bgAlpha
    border.color: Theme.border
    border.width: 1
    radius: Theme.rounding

    Row {
        id: compactRow
        anchors.centerIn: parent
        spacing: 4

        Text {
            text: root.compactText
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
            color: root.gradedColor
            width: root.compactTextWidth > 0 ? root.compactTextWidth : implicitWidth
            horizontalAlignment: Text.AlignRight
        }

        Text {
            text: root.icon
            font.family: Theme.iconFontFamily
            font.pixelSize: Theme.fontSize
            color: root.gradedColor
        }
    }

    MouseArea {
        id: hoverArea
        anchors.fill: parent
        hoverEnabled: true
        onClicked: root.togglePin()
    }

    // Overlay child, not in-flow: extends below root's own bounds without
    // affecting the row layout it sits in. No height animation -- animating
    // this resizes the actual layer-shell window every frame (via Bar.qml's
    // totalHeight), which was visibly choppy.
    Rectangle {
        id: expandPanel

        readonly property bool hovered: expandMouseArea.containsMouse

        y: root.height + 6
        x: isNaN(root.targetRight) ? (root.width - width) : (root.targetRight - width - root.groupX - root.x)
        width: 480
        height: root.expanded ? content.implicitHeight + 24 : 0
        visible: height > 0
        clip: true

        color: Theme.bgAlpha
        border.color: Theme.border
        border.width: 1
        radius: Theme.rounding

        MouseArea {
            id: expandMouseArea
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.AllButtons
            onWheel: wheel => wheel.accepted = true
        }

        Column {
            id: content
            x: 12
            y: 12
            width: parent.width - 24
            spacing: 8

            Item {
                width: parent.width
                height: titleText.implicitHeight

                Text {
                    id: titleText
                    anchors.left: parent.left
                    text: root.title
                    color: Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize
                    font.bold: true
                }

                Text {
                    anchors.right: parent.right
                    text: root.valueLabel
                    color: Theme.textDim
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize
                }
            }

            Row {
                width: parent.width
                height: 300
                spacing: 6

                // Y-axis: labels the same gridFractions the Graph draws
                // faint horizontal lines at, so "what height corresponds
                // to what value" is readable directly off the graph
                // instead of only knowing the single top-of-scale number.
                Item {
                    id: yAxis
                    width: 38
                    height: parent.height

                    Repeater {
                        model: root.gridFractions

                        Text {
                            required property real modelData
                            y: (1 - modelData) * (yAxis.height - implicitHeight)
                            anchors.right: yAxis.right
                            text: root.yAxisFormatter(modelData * root.maxValue)
                            color: Theme.textDim
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 4
                        }
                    }
                }

                Graph {
                    width: parent.width - yAxis.width - parent.spacing
                    height: parent.height
                    series: root.mode === "single" ? root.series : []
                    seriesList: root.mode === "overlay" ? root.seriesList : []
                    maxValue: root.maxValue
                    color1: root.color1
                    gridFractions: root.gridFractions
                }
            }

            Row {
                width: parent.width
                spacing: 6
                layoutDirection: Qt.RightToLeft
                visible: root.tierCodes.length > 0

                Repeater {
                    model: root.tierCodes

                    Rectangle {
                        id: tierBtn
                        required property string modelData
                        readonly property bool active: modelData === root.tier

                        width: tierLabel.implicitWidth + 10
                        height: tierLabel.implicitHeight + 4
                        radius: Theme.rounding - 4
                        color: active ? Theme.cyan : "transparent"
                        border.color: Theme.border
                        border.width: active ? 0 : 1

                        Text {
                            id: tierLabel
                            anchors.centerIn: parent
                            text: tierBtn.modelData
                            color: tierBtn.active ? Theme.bg : Theme.textDim
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 3
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: root.tierRequested(tierBtn.modelData)
                        }
                    }
                }
            }

            Text {
                width: parent.width
                text: root.tierLabels[root.tier] ?? ""
                visible: text.length > 0
                color: Theme.textDim
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 2
                horizontalAlignment: Text.AlignRight
            }

            Flow {
                width: parent.width
                spacing: 10
                visible: root.legendItems.length > 0

                Repeater {
                    model: root.legendItems

                    Row {
                        id: legendRow
                        spacing: 5
                        required property var modelData

                        Rectangle {
                            width: 9
                            height: 9
                            radius: 2
                            anchors.verticalCenter: parent.verticalCenter
                            color: legendRow.modelData.color
                        }

                        Text {
                            text: legendRow.modelData.name
                            color: Theme.textDim
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                        }
                    }
                }
            }

            Column {
                width: parent.width
                spacing: 3
                visible: root.topProcs.length > 0

                Rectangle {
                    width: parent.width
                    height: 1
                    color: Theme.border
                }

                Text {
                    text: root.topLabel
                    color: Theme.textDim
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                    topPadding: 3
                }

                Repeater {
                    model: root.topProcs

                    Item {
                        required property var modelData
                        width: parent.width
                        height: procName.implicitHeight

                        Text {
                            id: procName
                            anchors.left: parent.left
                            width: parent.width - procValue.width - 8
                            text: parent.modelData.name
                            color: Theme.text
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 1
                            elide: Text.ElideRight
                        }

                        Text {
                            id: procValue
                            anchors.right: parent.right
                            text: parent.modelData.value.toFixed(1) + root.topUnit
                            color: Theme.textDim
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 1
                        }
                    }
                }
            }
        }
    }
}
