import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
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
// click a day = open its task list, Escape = clear that selection then
// close the panel) and the year-picker (Tab opened it; all four arrows
// move the highlight within the 2-column 10-cell grid - Left/Right by one,
// Up/Down by a row - Backspace zooms out a level among the 10/20/50/100-
// year spans, Enter drills into a coarse cell or confirms a single year,
// Escape/Tab cancel back to month view unchanged).
//
// Day cells carry accent dots when ~/notes/orgzly/todo.org has anything
// scheduled that day (accent-coloured = something still open, grey = all
// done); clicking a day opens a list of that day's entries below the grid.
Rectangle {
    id: root

    property bool expanded: false
    readonly property bool hovered: mouseArea.containsMouse

    readonly property date today: new Date()
    property int viewYear: today.getFullYear()
    property int viewMonth: today.getMonth() // 0-11
    // Clicked day: drawn as a ring (not a fill - today's own fill wins when
    // they're the same day) and drives the task list at the bottom of the
    // panel. Cleared on close and by the first Escape press.
    property var selectedDate: null

    // ------------------------------------------------------------------
    // Org agenda: ~/notes/orgzly/todo.org parsed by
    // scripts/org-agenda.py into { "YYYY-MM-DD": [ {text,done,time,kind} ] }.
    // Re-run each time the panel opens (and every 5 min while it stays
    // open) so edits synced down from orgzly show up without a restart.
    // ------------------------------------------------------------------
    property var agendaDays: ({})

    function dateKey(d: date): string {
        const m = d.getMonth() + 1;
        const day = d.getDate();
        return d.getFullYear() + "-" + (m < 10 ? "0" : "") + m + "-" + (day < 10 ? "0" : "") + day;
    }
    function tasksFor(d): var {
        return (d && root.agendaDays[root.dateKey(d)]) || [];
    }

    Process {
        id: agendaProc
        command: ["python3", Quickshell.env("HOME") + "/.config/quickshell/scripts/org-agenda.py"]
        stdout: StdioCollector {
            id: agendaOut
            onStreamFinished: {
                try {
                    const parsed = JSON.parse(agendaOut.text);
                    root.agendaDays = parsed.days || {};
                } catch (e) {
                    // Keep whatever we had; a transient parse/read failure
                    // just means the accents don't refresh this cycle.
                }
            }
        }
    }

    Timer {
        interval: 5 * 60 * 1000
        repeat: true
        running: root.expanded
        onTriggered: agendaProc.running = true
    }

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
        if (expanded) {
            agendaProc.running = true;
        } else {
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
                root.yearPickerMove(-2);
                event.accepted = true;
            } else if (event.key === Qt.Key_Down) {
                root.yearPickerMove(2);
                event.accepted = true;
            } else if (event.key === Qt.Key_Backspace) {
                root.yearPickerZoomOut();
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
                // First Escape drops an open day list, second closes.
                if (root.selectedDate)
                    root.selectedDate = null;
                else
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

    // Set from outside by Bar.qml (root.panelWidth -- shared with media and
    // the sysmon graph pills via the same row-wrapping layout pool, same
    // pattern as GraphPill's `expandWidth`; see quickshell-bar.md's "Panel
    // width sizing" section). 300 is only the standalone-preview fallback.
    property real panelWidth: 300
    // "Big mode": opened via the mod+CTRL+c keybind / clock click (Bar.qml
    // binds this to clockPinned), as opposed to a passing hover. Widens the
    // panel to `bigWidth` and switches the month grid from dot-only cells to
    // tall cells that print each day's event titles underneath the number,
    // month-view style. Hover stays the compact dot version.
    property bool bigMode: false
    property real bigWidth: 660
    readonly property real effectiveWidth: bigMode ? Math.max(panelWidth, bigWidth) : panelWidth
    width: effectiveWidth
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
            columnSpacing: root.bigMode ? 3 : 0
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

                    readonly property var dayTasks: root.tasksFor(modelData)
                    readonly property bool hasOpenTask: dayTasks.some(t => !t.done)

                    Layout.fillWidth: true
                    Layout.preferredHeight: root.bigMode ? 66 : 28
                    radius: Theme.rounding - 4
                    color: isToday ? Theme.cyan
                        : (root.bigMode && inMonth ? Qt.rgba(1, 1, 1, 0.03) : "transparent")
                    border.color: isSelected ? Theme.cyan : "transparent"
                    border.width: isSelected ? 1 : 0

                    Text {
                        anchors.centerIn: root.bigMode ? undefined : parent
                        anchors.top: root.bigMode ? parent.top : undefined
                        anchors.left: root.bigMode ? parent.left : undefined
                        anchors.topMargin: 3
                        anchors.leftMargin: 4
                        text: cell.modelData.getDate()
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 1
                        font.bold: cell.isToday
                        color: {
                            if (cell.isToday)
                                return "#1a1a1a";
                            if (!cell.inMonth)
                                return Theme.muted;
                            return cell.isWeekend ? Theme.textDim : Theme.text;
                        }
                    }

                    // Big mode: each day's event titles, stacked under the
                    // number (time prefix when the entry has one). Capped at
                    // 3 with a "+N" overflow line; full list is still one
                    // click away in the day-list panel below the grid.
                    Column {
                        visible: root.bigMode && cell.dayTasks.length > 0
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.topMargin: 19
                        anchors.leftMargin: 3
                        anchors.rightMargin: 3
                        spacing: 1

                        Repeater {
                            model: Math.min(3, cell.dayTasks.length)

                            Text {
                                required property int index
                                readonly property var task: cell.dayTasks[index]
                                width: parent.width
                                elide: Text.ElideRight
                                maximumLineCount: 1
                                textFormat: Text.PlainText
                                text: (task.time ? task.time + " " : "") + task.text
                                color: cell.isToday ? "#1a1a1a"
                                    : (task.done || !cell.inMonth ? Theme.muted
                                        : (task.kind === "deadline" ? Theme.red : Theme.text))
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 4
                                font.strikeout: task.done
                            }
                        }

                        Text {
                            visible: cell.dayTasks.length > 3
                            text: "+" + (cell.dayTasks.length - 3)
                            color: cell.isToday ? "#1a1a1a" : Theme.textDim
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 4
                        }
                    }

                    // Accent dots: one per task that day, capped at 3. The
                    // theme's secondary accent while anything's still open,
                    // muted grey once the day is all-done. On today's
                    // filled cell they switch to the dark ink colour so
                    // they stay visible against the fill.
                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 2
                        spacing: 2
                        visible: !root.bigMode && cell.dayTasks.length > 0

                        Repeater {
                            model: Math.min(3, cell.dayTasks.length)

                            Rectangle {
                                width: 3
                                height: 3
                                radius: 1.5
                                color: cell.isToday
                                    ? "#1a1a1a"
                                    : (cell.hasOpenTask ? Theme.green : Theme.muted)
                            }
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
                ? qsTr("↑↓←→ move · Enter select · ⌫ zoom out · Esc cancel")
                : qsTr("←→ month · ↑↓ year · Tab year · click a day")
        }

        // Day task list: opens under the grid when a day is clicked,
        // showing that day's org entries (or "Nothing scheduled"). Grows
        // the panel downward - Bar.qml's overflow math keys off
        // calendarExpanded.height, so nothing else needs to know.
        Rectangle {
            id: dayList
            width: parent.width
            visible: root.selectedDate !== null && !root.yearPickerActive
            implicitHeight: visible ? dayListCol.implicitHeight + 16 : 0
            height: implicitHeight
            clip: true
            radius: Theme.rounding - 4
            color: Theme.bg
            border.color: Theme.border
            border.width: 1

            readonly property var tasks: root.selectedDate ? root.tasksFor(root.selectedDate) : []

            Column {
                id: dayListCol
                x: 8
                y: 8
                width: parent.width - 16
                spacing: 5

                Text {
                    width: parent.width
                    elide: Text.ElideRight
                    text: root.selectedDate
                        ? Qt.formatDate(root.selectedDate, "ddd d MMM yyyy")
                        : ""
                    color: Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 1
                    font.bold: true
                }

                Text {
                    width: parent.width
                    visible: dayList.tasks.length === 0
                    text: qsTr("Nothing scheduled")
                    color: Theme.muted
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                }

                // Scrolls internally once a day has more entries than fit;
                // capped so a very full day can't push the panel off-screen.
                ListView {
                    width: parent.width
                    height: Math.min(contentHeight, 176)
                    visible: dayList.tasks.length > 0
                    clip: true
                    interactive: contentHeight > height
                    boundsBehavior: Flickable.StopAtBounds
                    model: dayList.tasks
                    spacing: 4

                    delegate: Row {
                        required property var modelData
                        width: ListView.view.width
                        spacing: 6

                        Text {
                            width: 34
                            horizontalAlignment: Text.AlignRight
                            text: modelData.time
                                ? modelData.time
                                : (modelData.kind === "deadline" ? "due" : "·")
                            color: modelData.kind === "deadline" ? Theme.red : Theme.textDim
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                        }

                        Text {
                            width: parent.width - 40
                            wrapMode: Text.WordWrap
                            textFormat: Text.PlainText
                            text: modelData.text
                            color: modelData.done ? Theme.muted : Theme.text
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                            font.strikeout: modelData.done
                        }
                    }
                }
            }
        }
    }
}
