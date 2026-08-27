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

    // "single" (series/color1), "overlay" (seriesList), "stacked" (stackedList)
    property string mode: "single"
    property list<real> series: []
    property var seriesList: []
    property var stackedList: []
    property real maxValue: 100
    property color color1: Theme.cyan

    // [{name, color}] -- shown under the graph when non-empty.
    property var legendItems: []
    // [{name, value}] -- top-10 list shown when non-empty.
    property var topProcs: []
    property string topUnit: ""

    property bool expanded: false
    readonly property bool hovered: hoverArea.containsMouse || expandPanel.hovered
    // Bar.qml reads this to size the window; 0 when collapsed.
    readonly property real overflowHeight: expandPanel.height

    onHoveredChanged: {
        if (hovered) {
            hideTimer.stop();
            expanded = true;
        } else {
            hideTimer.restart();
        }
    }

    Timer {
        id: hideTimer
        interval: 250
        onTriggered: root.expanded = false
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
            color: Theme.text
            width: root.compactTextWidth > 0 ? root.compactTextWidth : implicitWidth
            horizontalAlignment: Text.AlignRight
        }

        Text {
            text: root.icon
            font.family: Theme.iconFontFamily
            font.pixelSize: Theme.fontSize
            color: Theme.text
        }
    }

    MouseArea {
        id: hoverArea
        anchors.fill: parent
        hoverEnabled: true
    }

    // Overlay child, not in-flow: extends below root's own bounds without
    // affecting the row layout it sits in. No height animation -- animating
    // this resizes the actual layer-shell window every frame (via Bar.qml's
    // totalHeight), which was visibly choppy.
    Rectangle {
        id: expandPanel

        readonly property bool hovered: expandMouseArea.containsMouse

        anchors.top: root.bottom
        anchors.right: root.right
        anchors.topMargin: 6
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

            Graph {
                width: parent.width
                height: 300
                series: root.mode === "single" ? root.series : []
                seriesList: root.mode === "overlay" ? root.seriesList : []
                stackedList: root.mode === "stacked" ? root.stackedList : []
                maxValue: root.maxValue
                color1: root.color1
            }

            Text {
                width: parent.width
                text: qsTr("last 10 minutes")
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
                    text: qsTr("Top processes")
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
