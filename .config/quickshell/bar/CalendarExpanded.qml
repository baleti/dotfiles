import QtQuick
import QtQuick.Layouts
import "../theme"

// Hover-down expansion of the clock: a month calendar grid, today
// highlighted, with prev/next navigation -- same self-contained overlay
// pattern as MediaExpanded/GraphPill (sibling overlay, no window-resize
// animation, shown/hidden by Bar.qml's hover-linger wiring).
//
// mod+CTRL+c (keybinds.lua) opens this with real keyboard focus (same
// WlrKeyboardFocus.OnDemand mechanism the media panel already uses for its
// own arrow-seek), so bare keys reach handleKey() below directly - no
// Hyprland submap needed. Two modes: plain month view (Left/Right =
// prev/next month, Up/Down = prev/next year, Tab = enter the year-picker,
// Escape = close the panel) and the year-picker (Tab opened it; Left/Right
// move the highlight within a 10-cell grid, Up/Down zoom out/in a level
// among 10/20/50/100-year spans, Enter drills into a coarse cell or
// confirms a single year, Escape/Tab cancel back to month view unchanged).
Rectangle {
    id: root

    property bool expanded: false
    readonly property bool hovered: mouseArea.containsMouse

    readonly property date today: new Date()
    property int viewYear: today.getFullYear()
    property int viewMonth: today.getMonth() // 0-11
    // Clicked day, purely a visual marker (ring, not fill - today's own
    // fill takes priority when they're the same day). Nothing downstream
    // reads this yet; it's just mouse feedback that the click landed.
    property var selectedDate: null

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

    // Closing (mod+CTRL+c again, or Escape) resets state rather than
    // leaving it wherever it was, so reopening always starts back at the
    // current month/year, not last time's - including out of the
    // year-picker if it was left open.
    onExpandedChanged: {
        if (!expanded) {
            root.goToday();
            root.exitYearPicker();
            root.selectedDate = null;
        }
    }

    // ------------------------------------------------------------------
    // Year picker: a 10-cell grid at one of 4 spans (10/20/50/100 years
    // total, so 1/2/5/10 years per cell respectively) - always 10 cells,
    // just a wider or narrower span per cell as you zoom out.
    // ------------------------------------------------------------------

    property bool yearPickerActive: false
    property int yearPickerSpan: 10
    property int yearPickerGridStart: today.getFullYear()
    property int yearPickerHighlight: 0

    readonly property var yearPickerSpans: [10, 20, 50, 100]

    function yearPickerCellYears(): int {
        return root.yearPickerSpan / 10;
    }
    function yearPickerCellStart(i: int): int {
        return root.yearPickerGridStart + i * yearPickerCellYears();
    }
    function yearPickerCellLabel(i: int): string {
        const start = yearPickerCellStart(i);
        const cy = yearPickerCellYears();
        return cy === 1 ? String(start) : (start + "-" + (start + cy - 1));
    }

    function enterYearPicker(): void {
        root.yearPickerSpan = 10;
        root.yearPickerGridStart = Math.floor(root.viewYear / 10) * 10;
        root.yearPickerHighlight = Math.max(0, Math.min(9, root.viewYear - root.yearPickerGridStart));
        root.yearPickerActive = true;
    }
    function exitYearPicker(): void {
        root.yearPickerActive = false;
    }
    // delta is always ±1 (single arrow press). Past either edge of the
    // 10-cell grid, this pages the whole grid to the previous/next period
    // rather than clamping - landing on the opposite edge, so holding
    // Left/Right keeps paging continuously through periods.
    function yearPickerMove(delta: int): void {
        let idx = root.yearPickerHighlight + delta;
        if (idx < 0) {
            root.yearPickerGridStart -= root.yearPickerSpan;
            idx += 10;
        } else if (idx > 9) {
            root.yearPickerGridStart += root.yearPickerSpan;
            idx -= 10;
        }
        root.yearPickerHighlight = idx;
    }
    // Re-centers the grid on whatever's currently highlighted before
    // changing span, so zooming in/out stays anchored to where you were
    // looking rather than jumping back to the current real year.
    function yearPickerRezoom(newSpan: int): void {
        const centerYear = yearPickerCellStart(root.yearPickerHighlight);
        root.yearPickerSpan = newSpan;
        const cellYears = yearPickerCellYears();
        root.yearPickerGridStart = Math.floor(centerYear / newSpan) * newSpan;
        root.yearPickerHighlight = Math.max(0, Math.min(9, Math.floor((centerYear - root.yearPickerGridStart) / cellYears)));
    }
    function yearPickerZoomOut(): void {
        const i = root.yearPickerSpans.indexOf(root.yearPickerSpan);
        if (i < root.yearPickerSpans.length - 1)
            yearPickerRezoom(root.yearPickerSpans[i + 1]);
    }
    function yearPickerZoomIn(): void {
        const i = root.yearPickerSpans.indexOf(root.yearPickerSpan);
        if (i > 0)
            yearPickerRezoom(root.yearPickerSpans[i - 1]);
    }
    // Enter: drill into a coarse cell (zoom in one level, re-centered on
    // it), or on the finest (single-year) grid, confirm - jump the month
    // view to that year (keeping whatever month was already showing) and
    // close the picker.
    function yearPickerConfirm(): void {
        if (root.yearPickerSpan === 10) {
            root.viewYear = yearPickerCellStart(root.yearPickerHighlight);
            root.exitYearPicker();
        } else {
            yearPickerZoomIn();
        }
    }

    function handleKey(event): void {
        if (root.yearPickerActive) {
            if (event.key === Qt.Key_Left) {
                root.yearPickerMove(-1);
                event.accepted = true;
            } else if (event.key === Qt.Key_Right) {
                root.yearPickerMove(1);
                event.accepted = true;
            } else if (event.key === Qt.Key_Up) {
                root.yearPickerZoomOut();
                event.accepted = true;
            } else if (event.key === Qt.Key_Down) {
                root.yearPickerZoomIn();
                event.accepted = true;
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.yearPickerConfirm();
                event.accepted = true;
            } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Tab) {
                root.exitYearPicker();
                event.accepted = true;
            }
        } else {
            if (event.key === Qt.Key_Left) {
                root.prevMonth();
                event.accepted = true;
            } else if (event.key === Qt.Key_Right) {
                root.nextMonth();
                event.accepted = true;
            } else if (event.key === Qt.Key_Up) {
                root.viewYear -= 1;
                event.accepted = true;
            } else if (event.key === Qt.Key_Down) {
                root.viewYear += 1;
                event.accepted = true;
            } else if (event.key === Qt.Key_Tab) {
                root.enterYearPicker();
                event.accepted = true;
            } else if (event.key === Qt.Key_Escape) {
                root.expanded = false;
                event.accepted = true;
            }
        }
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
                visible: !root.yearPickerActive
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
                text: root.yearPickerActive
                    ? (root.yearPickerSpan === 10 ? qsTr("Pick a year") : qsTr("Pick a period"))
                    : Qt.locale().monthName(root.viewMonth) + " " + root.viewYear
                color: Theme.text
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
                font.bold: true
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -4
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (!root.yearPickerActive) root.goToday()
                }
            }

            Text {
                anchors.right: parent.right
                visible: !root.yearPickerActive
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
            visible: !root.yearPickerActive

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
                    readonly property bool isSelected: !isToday && root.selectedDate
                        && modelData.toDateString() === root.selectedDate.toDateString()

                    Layout.fillWidth: true
                    Layout.preferredHeight: 28
                    radius: Theme.rounding - 4
                    color: isToday ? Theme.cyan : "transparent"
                    border.color: isSelected ? Theme.cyan : "transparent"
                    border.width: isSelected ? 1 : 0

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

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            // Clicking a leading/trailing day from the
                            // adjacent month navigates the view to it, same
                            // as prev/nextMonth would - every visible cell
                            // ends up clickable to *some* date.
                            if (!cell.inMonth) {
                                root.viewMonth = cell.modelData.getMonth();
                                root.viewYear = cell.modelData.getFullYear();
                            }
                            root.selectedDate = cell.modelData;
                        }
                    }
                }
            }
        }

        GridLayout {
            width: parent.width
            // 2 columns (5 rows), not 5 columns (2 rows): a "2020-2029"
            // label needs real width - 5-across packed them too tight to
            // read (confirmed, labels overlapping).
            columns: 2
            rowSpacing: 6
            columnSpacing: 8
            visible: root.yearPickerActive

            Repeater {
                model: 10

                Rectangle {
                    id: periodCell
                    required property int index
                    readonly property bool isHighlighted: index === root.yearPickerHighlight

                    Layout.fillWidth: true
                    Layout.preferredHeight: 34
                    radius: Theme.rounding - 4
                    color: isHighlighted ? Theme.cyan : (cellMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.06) : "transparent")
                    border.color: isHighlighted ? "transparent" : Theme.border
                    border.width: isHighlighted ? 0 : 1

                    Text {
                        anchors.centerIn: parent
                        text: root.yearPickerCellLabel(periodCell.index)
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 1
                        color: periodCell.isHighlighted ? "#1a1a1a" : Theme.text
                    }

                    MouseArea {
                        id: cellMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.yearPickerHighlight = periodCell.index;
                            root.yearPickerConfirm();
                        }
                    }
                }
            }
        }

        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            color: Theme.muted
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 3
            text: root.yearPickerActive
                ? qsTr("←→ move · ↑↓ zoom · Enter/click select · Esc/Tab cancel")
                : qsTr("←→ month · ↑↓ year · Tab pick year · click a date")
        }
    }
}
