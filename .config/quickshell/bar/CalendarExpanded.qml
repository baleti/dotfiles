import QtQuick
import QtQuick.Layouts
import "../theme"

// Hover-down expansion of the clock: a month calendar grid, today
// highlighted, with prev/next navigation -- same self-contained overlay
// pattern as MediaExpanded/GraphPill (sibling overlay, no window-resize
// animation, shown/hidden by Bar.qml's hover-linger wiring).
Rectangle {
    id: root

    property bool expanded: false
    readonly property bool hovered: mouseArea.containsMouse

    readonly property date today: new Date()
    property int viewYear: today.getFullYear()
    property int viewMonth: today.getMonth() // 0-11

    function prevMonth(): void {
        if (viewMonth === 0) { viewMonth = 11; viewYear -= 1; } else { viewMonth -= 1; }
    }
    function nextMonth(): void {
        if (viewMonth === 11) { viewMonth = 0; viewYear += 1; } else { viewMonth += 1; }
    }
    function goToday(): void {
        viewYear = today.getFullYear();
        viewMonth = today.getMonth();
    }

    // Monday-first 6x7 grid, including the leading/trailing days of the
    // adjacent months so every week row is full.
    readonly property var cells: {
        const first = new Date(viewYear, viewMonth, 1);
        // getDay(): 0=Sun..6=Sat -> convert to 0=Mon..6=Sun
        const leadIn = (first.getDay() + 6) % 7;
        const start = new Date(viewYear, viewMonth, 1 - leadIn);
        const out = [];
        for (let i = 0; i < 42; i++) {
            const d = new Date(start.getFullYear(), start.getMonth(), start.getDate() + i);
            out.push(d);
        }
        return out;
    }

    width: 300
    implicitHeight: expanded ? content.implicitHeight + 24 : 0
    height: implicitHeight
    visible: height > 0
    clip: true

    color: Theme.bgAlpha
    border.color: Theme.border
    border.width: 1
    radius: Theme.rounding

    MouseArea {
        id: mouseArea
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
            height: monthLabel.implicitHeight

            Text {
                id: prevBtn
                anchors.left: parent.left
                text: "‹"
                color: Theme.textDim
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize + 4
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -4
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.prevMonth()
                }
            }

            Text {
                id: monthLabel
                anchors.horizontalCenter: parent.horizontalCenter
                text: Qt.locale().monthName(root.viewMonth) + " " + root.viewYear
                color: Theme.text
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
                font.bold: true
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -4
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.goToday()
                }
            }

            Text {
                anchors.right: parent.right
                text: "›"
                color: Theme.textDim
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize + 4
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -4
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.nextMonth()
                }
            }
        }

        GridLayout {
            width: parent.width
            columns: 7
            rowSpacing: 4
            columnSpacing: 0

            Repeater {
                model: [qsTr("Mo"), qsTr("Tu"), qsTr("We"), qsTr("Th"), qsTr("Fr"), qsTr("Sa"), qsTr("Su")]

                Text {
                    required property string modelData
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: modelData
                    color: Theme.textDim
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                }
            }

            Repeater {
                model: root.cells

                Rectangle {
                    id: cell

                    required property date modelData
                    readonly property bool isToday: modelData.toDateString() === root.today.toDateString()
                    readonly property bool inMonth: modelData.getMonth() === root.viewMonth
                    readonly property bool isWeekend: [0, 6].includes(modelData.getDay())

                    Layout.fillWidth: true
                    Layout.preferredHeight: 28
                    radius: Theme.rounding - 4
                    color: isToday ? Theme.cyan : "transparent"

                    Text {
                        anchors.centerIn: parent
                        text: cell.modelData.getDate()
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 1
                        color: {
                            if (cell.isToday)
                                return "#1a1a1a";
                            if (!cell.inMonth)
                                return Theme.muted;
                            return cell.isWeekend ? Theme.textDim : Theme.text;
                        }
                    }
                }
            }
        }
    }
}
