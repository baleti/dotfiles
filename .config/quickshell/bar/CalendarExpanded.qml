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
// Hyprland submap needed. Two modes:
//
//   month view - Left/Right or h/l move the day cursor ±1 day, Up/Down or
//   k/j ±1 week (the cursor carries the view into adjacent months); hold
//   Shift with any of those to grow a multi-day selection out from the
//   anchor. Ctrl is the "bigger jump" modifier: Ctrl+Left/Right (Ctrl+h/l)
//   page a whole month, Ctrl+Up (Ctrl+k) zooms out into the year-picker.
//   Escape closes.
//
//   year-picker - all four arrows / h j k l move the highlight within the
//   2-column 10-cell grid (Left/Right by one, Up/Down by a row). Ctrl+Up
//   (Ctrl+k) or Backspace zooms out one level among the 10/20/50/100-year
//   spans; Ctrl+Down (Ctrl+j) or Enter zooms back in, and on the finest
//   1-year grid confirms the year and returns to the month view. Escape
//   cancels back unchanged.
//
// The day cursor (ring) is always on some day - today when the panel
// opens - and the agenda list below the grid always shows the selected
// day(s), grouped by day with each day's ~/notes/orgzly/todo.org entries
// in chronological order (no click needed). In the compact hover view,
// days with entries also carry accent dots (accent-coloured = something
// still open, grey = all done); the keybind view prints the entry titles
// straight into the day cells instead. Panel width always flexes evenly
// with the bar's other panels (shared panelWidth), never fixed.
Rectangle {
    id: root

    property bool expanded: false
    readonly property bool hovered: mouseArea.containsMouse

    readonly property date today: new Date()
    property int viewYear: today.getFullYear()
    property int viewMonth: today.getMonth() // 0-11
    // Day cursor + selection. cursorDate is the moving end (ring); anchorDate
    // is the fixed end of a multi-day selection. Plain arrows / h j k l move
    // both together (single-day selection); Shift+ the same keys moves only
    // the cursor, so the selection grows/shrinks between anchor and cursor.
    // The task list below the grid shows every day in [selStart, selEnd],
    // grouped by day. Both reset to today on close; never null while open.
    property var cursorDate: today
    property var anchorDate: today

    readonly property date selStart: (cursorDate < anchorDate) ? cursorDate : anchorDate
    readonly property date selEnd: (cursorDate < anchorDate) ? anchorDate : cursorDate
    readonly property bool hasRange: selStart.toDateString() !== selEnd.toDateString()

    function midnight(d: date): date {
        return new Date(d.getFullYear(), d.getMonth(), d.getDate());
    }
    function cursorOn(d: date): bool {
        return root.cursorDate && d.toDateString() === root.cursorDate.toDateString();
    }
    function inSelection(d: date): bool {
        const t = root.midnight(d).getTime();
        return t >= root.midnight(root.selStart).getTime() && t <= root.midnight(root.selEnd).getTime();
    }

    // Move the cursor by whole days (±1 = h/l/←/→, ±7 = k/j/↑/↓). Follows the
    // cursor into an adjacent month so it never lands off-grid. extend=false
    // (plain key) drags the anchor along too; extend=true (Shift) leaves the
    // anchor put so the selection spans out to the cursor.
    function moveCursor(deltaDays: int, extend: bool): void {
        const c = root.cursorDate || root.today;
        const n = new Date(c.getFullYear(), c.getMonth(), c.getDate() + deltaDays);
        root.cursorDate = n;
        if (!extend)
            root.anchorDate = n;
        if (n.getMonth() !== root.viewMonth || n.getFullYear() !== root.viewYear) {
            root.viewMonth = n.getMonth();
            root.viewYear = n.getFullYear();
        }
    }

    // Days in the current selection, each with its entries sorted
    // chronologically (timed first by time, then untimed). Drives the
    // grouped list at the bottom of the panel.
    readonly property var selectionGroups: {
        const out = [];
        let d = root.midnight(root.selStart);
        const end = root.midnight(root.selEnd);
        // Guard against a pathological range blowing up the loop.
        for (let i = 0; i < 366 && d.getTime() <= end.getTime(); i++) {
            const tasks = root.tasksFor(d).slice().sort((a, b) => {
                if (!!a.time !== !!b.time)
                    return a.time ? -1 : 1;
                return a.time < b.time ? -1 : (a.time > b.time ? 1 : 0);
            });
            out.push({ date: new Date(d.getTime()), tasks: tasks });
            d = new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1);
        }
        return out;
    }

    // ------------------------------------------------------------------
    // Agenda sources: three independent scripts, each printing
    // { "YYYY-MM-DD": [ {text,done,time,kind} ] } in the same shape -
    //   org-agenda.py       -> ~/notes/orgzly/todo.org      (kind: scheduled/deadline/timestamp)
    //   gcal-agenda.py      -> krajnik.dan's Google Calendar (kind: "google")
    //   uk-holidays-agenda.py -> UK public holidays feed     (kind: "holiday")
    // Kept as three separate properties (not merged in-place) so one
    // source's async result never clobbers another's; agendaDays merges
    // them reactively. Re-run each time the panel opens (and every 5 min
    // while it stays open) so edits/new events show up without a restart.
    // ------------------------------------------------------------------
    property var orgDays: ({})
    property var googleDays: ({})
    property var holidayDays: ({})

    readonly property var agendaDays: {
        const out = {};
        const merge = src => {
            for (const k in src)
                out[k] = (out[k] || []).concat(src[k]);
        };
        // Holiday first, then Google, then org - sets the default
        // per-day source grouping order the day-list panel renders in.
        merge(root.holidayDays);
        merge(root.googleDays);
        merge(root.orgDays);
        return out;
    }

    function dateKey(d: date): string {
        const m = d.getMonth() + 1;
        const day = d.getDate();
        return d.getFullYear() + "-" + (m < 10 ? "0" : "") + m + "-" + (day < 10 ? "0" : "") + day;
    }
    function tasksFor(d): var {
        return (d && root.agendaDays[root.dateKey(d)]) || [];
    }
    // "org" is intentionally not a source label shown in the UI - it's
    // the default/home source and the original single-source behaviour,
    // only "google"/"holiday" entries need calling out as different.
    function sourceLabel(kind: string): string {
        if (kind === "google") return "Google Calendar";
        if (kind === "holiday") return "UK Holiday";
        return "";
    }
    // fallbackColor covers every existing org kind (scheduled/timestamp
    // pass their caller's normal/done/dimmed color through unchanged) -
    // only google/holiday/deadline get an override here.
    function colorForKind(kind: string, fallbackColor: color): color {
        if (kind === "deadline") return Theme.red;
        if (kind === "google") return Theme.cyan;
        if (kind === "holiday") return Theme.orange;
        return fallbackColor;
    }

    function runAgendaProcs(): void {
        agendaProc.running = true;
        gcalProc.running = true;
        holidayProc.running = true;
    }

    Process {
        id: agendaProc
        command: ["python3", Quickshell.env("HOME") + "/.config/quickshell/scripts/org-agenda.py"]
        stdout: StdioCollector {
            id: agendaOut
            onStreamFinished: {
                try {
                    root.orgDays = JSON.parse(agendaOut.text).days || {};
                } catch (e) {
                    // Keep whatever we had; a transient parse/read failure
                    // just means the accents don't refresh this cycle.
                }
            }
        }
    }

    Process {
        id: gcalProc
        command: ["python3", Quickshell.env("HOME") + "/.config/quickshell/scripts/gcal-agenda.py"]
        stdout: StdioCollector {
            id: gcalOut
            onStreamFinished: {
                try {
                    root.googleDays = JSON.parse(gcalOut.text).days || {};
                } catch (e) {
                    // Same as above - keep the last good data.
                }
            }
        }
    }

    Process {
        id: holidayProc
        command: ["python3", Quickshell.env("HOME") + "/.config/quickshell/scripts/uk-holidays-agenda.py"]
        stdout: StdioCollector {
            id: holidayOut
            onStreamFinished: {
                try {
                    root.holidayDays = JSON.parse(holidayOut.text).days || {};
                } catch (e) {
                    // Same as above - keep the last good data.
                }
            }
        }
    }

    Timer {
        interval: 5 * 60 * 1000
        repeat: true
        running: root.expanded
        onTriggered: root.runAgendaProcs()
    }

    // Mouse ‹/› and Ctrl+Left/Right (Ctrl+h/l): shift the month and carry
    // the cursor along by the same one-month step (clamped to the month's
    // length) so the ring and its task list stay put relative to the grid.
    function shiftMonth(delta: int): void {
        let m = viewMonth + delta;
        let y = viewYear;
        while (m < 0) { m += 12; y -= 1; }
        while (m > 11) { m -= 12; y += 1; }
        viewMonth = m;
        viewYear = y;
        const c = root.cursorDate || root.today;
        const lastDay = new Date(y, m + 1, 0).getDate();
        const moved = new Date(y, m, Math.min(c.getDate(), lastDay));
        root.cursorDate = moved;
        root.anchorDate = moved;
    }
    function prevMonth(): void { shiftMonth(-1); }
    function nextMonth(): void { shiftMonth(1); }
    function goToday(): void {
        viewYear = today.getFullYear();
        viewMonth = today.getMonth();
        root.cursorDate = today;
        root.anchorDate = today;
    }

    // Closing (mod+CTRL+c again, or Escape) resets state rather than
    // leaving it wherever it was, so reopening always starts back at the
    // current month/year, not last time's - including out of the
    // year-picker if it was left open.
    onExpandedChanged: {
        if (expanded) {
            root.runAgendaProcs();
        } else {
            root.goToday();
            root.exitYearPicker();
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
            // Carry the cursor to the same month/day in the chosen year so
            // the ring and its task list stay on-grid.
            const c = root.cursorDate || root.today;
            const lastDay = new Date(root.viewYear, root.viewMonth + 1, 0).getDate();
            const moved = new Date(root.viewYear, root.viewMonth, Math.min(c.getDate(), lastDay));
            root.cursorDate = moved;
            root.anchorDate = moved;
            root.exitYearPicker();
        } else {
            yearPickerZoomIn();
        }
    }

    function handleKey(event): void {
        const k = event.key;
        const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
        const shift = (event.modifiers & Qt.ShiftModifier) !== 0;
        const isLeft = k === Qt.Key_Left || k === Qt.Key_H;
        const isRight = k === Qt.Key_Right || k === Qt.Key_L;
        const isUp = k === Qt.Key_Up || k === Qt.Key_K;
        const isDown = k === Qt.Key_Down || k === Qt.Key_J;

        if (root.yearPickerActive) {
            // Ctrl+Up / Ctrl+k zoom OUT to wider year ranges (1->2->5->10
            // years per cell); Ctrl+Down / Ctrl+j / Enter zoom IN, and on
            // the finest grid confirm the year and drop back to the month.
            if (ctrl && isUp) {
                root.yearPickerZoomOut();
                event.accepted = true;
            } else if (ctrl && isDown) {
                root.yearPickerConfirm();
                event.accepted = true;
            } else if (isLeft) {
                root.yearPickerMove(-1);
                event.accepted = true;
            } else if (isRight) {
                root.yearPickerMove(1);
                event.accepted = true;
            } else if (isUp) {
                root.yearPickerMove(-2);
                event.accepted = true;
            } else if (isDown) {
                root.yearPickerMove(2);
                event.accepted = true;
            } else if (k === Qt.Key_Backspace) {
                root.yearPickerZoomOut();
                event.accepted = true;
            } else if (k === Qt.Key_Return || k === Qt.Key_Enter) {
                root.yearPickerConfirm();
                event.accepted = true;
            } else if (k === Qt.Key_Escape) {
                root.exitYearPicker();
                event.accepted = true;
            }
        } else {
            // Plain arrows / vim h j k l move the day cursor (±1 day
            // horizontally, ±1 week vertically); Shift keeps the anchor put
            // so the selection grows out to the cursor (multi-day range).
            // Ctrl+Left/Right (or Ctrl+h/l) page a whole month; Ctrl+Up (or
            // Ctrl+k) zooms out into the year picker. Escape closes.
            if (ctrl && isLeft) {
                root.prevMonth();
                event.accepted = true;
            } else if (ctrl && isRight) {
                root.nextMonth();
                event.accepted = true;
            } else if (ctrl && isUp) {
                root.enterYearPicker();
                event.accepted = true;
            } else if (ctrl && isDown) {
                // Nothing finer than the month grid to zoom into - swallow
                // it so it doesn't fall through to a cursor move.
                event.accepted = true;
            } else if (isLeft) {
                root.moveCursor(-1, shift);
                event.accepted = true;
            } else if (isRight) {
                root.moveCursor(1, shift);
                event.accepted = true;
            } else if (isUp) {
                root.moveCursor(-7, shift);
                event.accepted = true;
            } else if (isDown) {
                root.moveCursor(7, shift);
                event.accepted = true;
            } else if (k === Qt.Key_Escape) {
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
    // binds this to clockPinned), as opposed to a passing hover. Switches
    // the month grid from dot-only cells to tall cells that print each
    // day's event titles underneath the number, month-view style. Hover
    // stays the compact dot version. Width is NOT special-cased - the panel
    // flexes with the bar's other panels through the shared even-division
    // panelWidth, same as media / the graph pills.
    property bool bigMode: false
    // Hard height ceiling for the whole panel, set by Bar.qml from the fixed
    // layer-shell window height. The agenda list clamps its scroll area so
    // the panel never renders past this (and shows a scrollbar past it).
    // 700 is only the standalone-preview fallback.
    property real maxPanelHeight: 700
    width: panelWidth
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
                    readonly property bool isCursor: root.cursorOn(modelData)
                    readonly property bool inSel: root.inSelection(modelData)
                    // Only ring the cursor day itself when it's part of a
                    // wider range; a lone cursor already reads as selected
                    // from its fill, and today's own fill should win.
                    readonly property bool ringed: (isCursor && !isToday) || (root.hasRange && isCursor)

                    readonly property var dayTasks: root.tasksFor(modelData)
                    readonly property bool hasOpenTask: dayTasks.some(t => !t.done)

                    Layout.fillWidth: true
                    Layout.preferredHeight: root.bigMode ? 66 : 28
                    radius: Theme.rounding - 4
                    color: isToday ? Theme.cyan
                        : (inSel ? Qt.rgba(Theme.cyan.r, Theme.cyan.g, Theme.cyan.b, 0.18)
                            : (root.bigMode && inMonth ? Qt.rgba(1, 1, 1, 0.03) : "transparent"))
                    border.color: ringed ? Theme.cyan : "transparent"
                    border.width: ringed ? 1 : 0

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
                                        : root.colorForKind(task.kind, Theme.text))
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
                                required property int index
                                width: 3
                                height: 3
                                radius: 1.5
                                color: cell.isToday
                                    ? "#1a1a1a"
                                    : root.colorForKind(cell.dayTasks[index].kind,
                                        (cell.hasOpenTask ? Theme.green : Theme.muted))
                            }
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: mouse => {
                            // Clicking a leading/trailing day from the
                            // adjacent month navigates the view to it, same
                            // as prev/nextMonth would - every visible cell
                            // ends up clickable to *some* date.
                            if (!cell.inMonth) {
                                root.viewMonth = cell.modelData.getMonth();
                                root.viewYear = cell.modelData.getFullYear();
                            }
                            root.cursorDate = cell.modelData;
                            // Shift+click extends the selection from the
                            // anchor, mirroring Shift+arrows.
                            if (!(mouse.modifiers & Qt.ShiftModifier))
                                root.anchorDate = cell.modelData;
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
                ? qsTr("←→↑↓ / hjkl move · ctrl+↑ wider range · ctrl+↓ / Enter pick · Esc back")
                : qsTr("←→↑↓ / hjkl day+week · ⇧ range · ctrl+←→ month · ctrl+↑ year")
        }

        // Agenda list: always on (not click-gated). Shows every day in the
        // current selection (single day, or a Shift-arrows range), each as
        // a bold date header followed by that day's org entries in
        // chronological order - or "Nothing scheduled". Grows the panel
        // downward; Bar.qml's overflow math keys off calendarExpanded.height.
        Rectangle {
            id: dayList
            width: parent.width
            visible: !root.yearPickerActive
            implicitHeight: visible ? dayListView.height + 16 : 0
            height: implicitHeight
            clip: true
            radius: Theme.rounding - 4
            color: Theme.bg
            border.color: Theme.border
            border.width: 1

            // How tall the scroll area may grow: everything left in the
            // panel's height ceiling once the month grid + chrome above it
            // and this box's own padding are accounted for. dayList.y is set
            // by the Column above and doesn't depend on this box's height
            // (it's the last child), so there's no loop.
            readonly property real maxViewHeight:
                Math.max(120, root.maxPanelHeight - dayList.y - 40)

            // Flat row model: one {type:"header"} per selected day, then its
            // {type:"task"} rows (or a {type:"none"} placeholder). Built off
            // root.selectionGroups, which already sorts each day's entries.
            readonly property var rows: {
                const groups = root.selectionGroups;
                const multi = groups.length > 1;
                const out = [];
                for (const g of groups) {
                    out.push({
                        type: "header",
                        label: Qt.formatDate(g.date, multi ? "ddd d MMM" : "ddd d MMM yyyy")
                    });
                    // A source label row precedes each run of same-source
                    // tasks (org's own label is "", so plain org entries -
                    // the default/pre-existing behaviour - never get one).
                    // Re-emitted on every transition, so interleaved
                    // sources each get their own header rather than only
                    // the first run.
                    let lastLabel = null;
                    for (const t of g.tasks) {
                        const lbl = root.sourceLabel(t.kind);
                        if (lbl && lbl !== lastLabel)
                            out.push({ type: "source", label: lbl, kind: t.kind });
                        lastLabel = lbl;
                        out.push({ type: "task", time: t.time, text: t.text, done: t.done, kind: t.kind });
                    }
                    if (g.tasks.length === 0)
                        out.push({ type: "none" });
                }
                return out;
            }

            ListView {
                id: dayListView
                x: 8
                y: 8
                // Constant width (scrollBar overlays the right edge rather
                // than reserving space) - making width depend on
                // scrollBar.visible would loop through contentHeight.
                width: parent.width - 16
                // Grows with its content up to whatever fits under the fixed
                // layer-shell window; scrolls internally (scrollBar) past that.
                height: Math.min(contentHeight, dayList.maxViewHeight)
                clip: true
                interactive: contentHeight > height
                boundsBehavior: Flickable.StopAtBounds
                flickDeceleration: 6000
                model: dayList.rows
                spacing: 3

                // Mouse wheel: bigger step than the Flickable default so a
                // long selection scrolls in a few notches. Touchpads fall
                // through to the native pixel-precise scroll (not boosted).
                WheelHandler {
                    acceptedDevices: PointerDevice.Mouse
                    onWheel: event => {
                        const maxY = Math.max(0, dayListView.contentHeight - dayListView.height);
                        const notches = event.angleDelta.y / 120;
                        dayListView.contentY = Math.max(0, Math.min(maxY,
                            dayListView.contentY - notches * 120));
                    }
                }

                delegate: Item {
                    required property var modelData
                    required property int index
                    width: ListView.view.width
                    implicitHeight: group.implicitHeight + group.anchors.topMargin

                    Column {
                        id: group
                        width: parent.width
                        anchors.top: parent.top
                        // Breathing room above each day header except the
                        // first, and a smaller gap above each source-label
                        // group (including one right after a day header -
                        // a little extra space there is fine).
                        anchors.topMargin: (modelData.type === "header" && index > 0) ? 8
                            : (modelData.type === "source" ? 4 : 0)

                        Text {
                            visible: modelData.type === "header"
                            width: parent.width
                            elide: Text.ElideRight
                            text: modelData.label || ""
                            color: Theme.text
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 1
                            font.bold: true
                        }

                        Text {
                            visible: modelData.type === "source"
                            width: parent.width
                            elide: Text.ElideRight
                            text: (modelData.label || "").toUpperCase()
                            color: root.colorForKind(modelData.kind, Theme.textDim)
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 4
                            font.bold: true
                        }

                        Text {
                            visible: modelData.type === "none"
                            width: parent.width
                            text: qsTr("Nothing scheduled")
                            color: Theme.muted
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                        }

                        Row {
                            visible: modelData.type === "task"
                            width: parent.width
                            spacing: 6

                            Text {
                                width: 34
                                horizontalAlignment: Text.AlignRight
                                text: modelData.time
                                    ? modelData.time
                                    : (modelData.kind === "deadline" ? "due" : "·")
                                color: root.colorForKind(modelData.kind, Theme.textDim)
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 2
                            }

                            Text {
                                width: parent.width - 40
                                wrapMode: Text.WordWrap
                                textFormat: Text.PlainText
                                text: modelData.text || ""
                                color: modelData.done ? Theme.muted : Theme.text
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 2
                                font.strikeout: modelData.done === true
                            }
                        }
                    }
                }
            }

            // Hand-rolled vertical scrollbar (no QtQuick.Controls anywhere in
            // this project) - visible only when the list overflows. The thumb
            // is click-and-drag; clicking the empty track jumps there.
            Rectangle {
                id: scrollBar
                visible: dayListView.contentHeight > dayListView.height + 1
                anchors.right: parent.right
                anchors.rightMargin: 3
                y: dayListView.y
                width: 8
                height: dayListView.height
                radius: 4
                color: Qt.rgba(1, 1, 1, 0.06)

                readonly property real thumbH: Math.max(28, dayListView.visibleArea.heightRatio * height)
                readonly property real travel: Math.max(1, height - thumbH)
                readonly property real maxContentY: Math.max(0, dayListView.contentHeight - dayListView.height)

                // Drive contentY from a thumb-top position (px, 0..travel).
                function scrollToThumbTop(ty: real): void {
                    const clamped = Math.max(0, Math.min(scrollBar.travel, ty));
                    dayListView.contentY = (clamped / scrollBar.travel) * scrollBar.maxContentY;
                }

                Rectangle {
                    id: thumb
                    width: parent.width
                    radius: 4
                    height: scrollBar.thumbH
                    y: Math.min(scrollBar.travel, dayListView.visibleArea.yPosition * scrollBar.height)
                    color: sbArea.pressed ? Theme.text
                        : (sbArea.containsMouse ? Theme.textDim : Qt.rgba(1, 1, 1, 0.28))
                }

                MouseArea {
                    id: sbArea
                    anchors.fill: parent
                    // Widen the hit area well past the 8px bar so it's easy
                    // to grab with the mouse.
                    anchors.leftMargin: -14
                    anchors.topMargin: -4
                    anchors.bottomMargin: -4
                    hoverEnabled: true
                    preventStealing: true
                    property real grabOffset: 0

                    onPressed: mouse => {
                        const ty = mouse.y + anchors.topMargin; // back to scrollBar coords
                        if (ty >= thumb.y && ty <= thumb.y + thumb.height) {
                            grabOffset = ty - thumb.y;
                        } else {
                            grabOffset = thumb.height / 2;
                            scrollBar.scrollToThumbTop(ty - grabOffset);
                        }
                    }
                    onPositionChanged: mouse => {
                        if (pressed)
                            scrollBar.scrollToThumbTop(mouse.y + anchors.topMargin - grabOffset);
                    }
                }
            }
        }
    }
}
