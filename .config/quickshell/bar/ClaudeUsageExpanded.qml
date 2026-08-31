import QtQuick
import QtQuick.Layouts
import Quickshell
import "../theme"
import "../services"

// Detail panel for ClaudeUsagePill: session%/weekly% (+ reset time) for
// each of the 3 Claude Code accounts on this machine, plus the poller's
// current adaptive-interval tier so it's obvious why a number looks stale.
// Same sibling-overlay / collapses-to-0-height-when-closed shape as
// MediaExpanded/CalendarExpanded, but click/CTRL+ALT+c-toggled only -- no
// hover-open, and no real keyboard focus grab (nothing here needs arrow-key
// navigation, so it deliberately stays out of shell.qml's
// HyprlandFocusGrab/holdsFocus machinery Bar.qml's other panels use).
Rectangle {
    id: root

    property bool expanded: false
    property real panelWidth: 320
    // Set from Bar.qml (root.maxPanelHeight, screen-height-derived, same
    // as CalendarExpanded); this fallback only matters for a standalone
    // preview. "As tall as the monitor allows" per-request -- no fixed
    // small cap -- but real per-account process counts (20-40 alive here)
    // routinely exceed even that, so perGroupRowBudget below still has to
    // truncate with a "+N more" line rather than ever actually fitting
    // everything unconditionally.
    property real maxPanelHeight: 700

    width: panelWidth
    implicitHeight: expanded ? Math.min(content.implicitHeight + 24, root.maxPanelHeight) : 0
    height: implicitHeight
    visible: height > 0
    clip: true
    radius: Theme.rounding
    color: Theme.bgAlpha
    border.color: Theme.border
    border.width: 1

    readonly property bool hovered: mouseArea.containsMouse

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.AllButtons
        onWheel: wheel => wheel.accepted = true
    }

    // Coarse "Xd Yh" / "Xh Ym" / "Xm" / "<1m" for a delta in seconds --
    // shared by the per-limit reset countdown and the backoff/staleness
    // lines below.
    function fmtDelta(deltaS) {
        if (deltaS <= 0)
            return qsTr("<1m");
        const days = Math.floor(deltaS / 86400);
        deltaS -= days * 86400;
        const hours = Math.floor(deltaS / 3600);
        deltaS -= hours * 3600;
        const mins = Math.floor(deltaS / 60);
        if (days > 0)
            return qsTr("%1d %2h").arg(days).arg(hours);
        if (hours > 0)
            return qsTr("%1h %2m").arg(hours).arg(mins);
        if (mins > 0)
            return qsTr("%1m").arg(mins);
        return qsTr("<1m");
    }

    // "resets in Xd Yh" -- ISO8601 in. null (an account whose tier wasn't
    // returned, e.g. it's disabled) reads as "--", not "resets in NaN".
    function fmtResets(iso) {
        if (!iso)
            return "--";
        const target = new Date(iso).getTime();
        if (isNaN(target))
            return "--";
        const deltaS = Math.round((target - Date.now()) / 1000);
        return deltaS <= 0 ? qsTr("resetting") : qsTr("resets in %1").arg(root.fmtDelta(deltaS));
    }

    // "12s ago" / "4m ago" -- same coarse style, for the daemon's own
    // updated_at (staleness indicator, not a countdown).
    function fmtAgo(iso) {
        if (!iso)
            return qsTr("never");
        const t = new Date(iso).getTime();
        if (isNaN(t))
            return qsTr("never");
        const deltaS = Math.max(0, Math.round((Date.now() - t) / 1000));
        if (deltaS < 60)
            return qsTr("%1s ago").arg(deltaS);
        if (deltaS < 3600)
            return qsTr("%1m ago").arg(Math.floor(deltaS / 60));
        return qsTr("%1h ago").arg(Math.floor(deltaS / 3600));
    }

    readonly property string homeDir: Quickshell.env("HOME") || ""

    // "/home/user1/foo" -> "~/foo" (or "~" for the home dir itself); left
    // as-is otherwise. Paired with Text.ElideLeft at the call site so a
    // long path still shows its most identifying (rightmost) part.
    function shortCwd(cwd) {
        if (!cwd)
            return "";
        if (cwd === root.homeDir)
            return "~";
        if (root.homeDir && cwd.startsWith(root.homeDir + "/"))
            return "~" + cwd.slice(root.homeDir.length);
        return cwd;
    }

    // 274308 -> "274k", 850 -> "850", null/undefined -> "--". Context
    // tokens routinely run into the hundreds of thousands here, so this
    // stays readable at a glance instead of a long raw digit string.
    function fmtTokens(n) {
        if (typeof n !== "number")
            return "--";
        if (n < 1000)
            return String(n);
        return (n / 1000).toFixed(n < 10000 ? 1 : 0) + "k";
    }

    function fmtAgoMs(ms) {
        return ms ? root.fmtAgo(new Date(ms).toISOString()) : qsTr("never");
    }

    readonly property var statusColors: ({
        "busy": Theme.red,
        "waiting": Theme.orange,
        "idle": Theme.muted,
    })
    function statusColor(status) {
        return root.statusColors[status] || Theme.textDim;
    }
    // "waiting" is visibly wider than "busy"/"idle" -- abbreviated so the
    // fixed-width status column in each single-line process row doesn't
    // have it run into the pid field right after it with no gap (a real
    // bug the first version of this row layout had).
    readonly property var statusLabels: ({
        "busy": qsTr("busy"),
        "waiting": qsTr("wait"),
        "idle": qsTr("idle"),
    })
    function statusLabel(status) {
        return root.statusLabels[status] || status || "?";
    }

    readonly property var pollModeLabels: ({
        "locked": qsTr("polling hourly (locked/screen off)"),
        "active": qsTr("polling every 2m (active)"),
        "idle": qsTr("polling every 5m (idle)"),
    })

    // Backoff isn't a fixed label like the other 3 tiers -- it's a live
    // countdown to when polling resumes, computed from updated_at (when
    // this backoff started) + poll_interval_s (how long it runs), same
    // pair every other mode uses for its own bookkeeping.
    function modeLine() {
        if (ClaudeUsageSvc.pollMode === "backoff") {
            const resumeMs = new Date(ClaudeUsageSvc.updatedAt).getTime() + ClaudeUsageSvc.pollIntervalS * 1000;
            const deltaS = Math.round((resumeMs - Date.now()) / 1000);
            return qsTr("rate limited (429) -- retrying in %1").arg(root.fmtDelta(Math.max(0, deltaS)));
        }
        return root.pollModeLabels[ClaudeUsageSvc.pollMode] || qsTr("Claude usage");
    }

    // Re-render the relative-time strings once a second while open -- they
    // read off Date.now()/live deltas, which QML has no binding source for
    // on its own.
    Timer {
        interval: 1000
        running: root.expanded
        repeat: true
        onTriggered: root.tick = root.tick + 1
    }
    property int tick: 0

    // Per-account collapse state, keyed by account name -- missing/absent
    // means expanded (so a brand new account name defaults open). Persists
    // across the panel's own open/close (this Rectangle instance is never
    // destroyed, only its height collapses to 0 -- same "sibling overlay"
    // pattern as Media/CalendarExpanded), so a click on the pill or
    // CTRL+ALT+c re-opens it exactly as you left it.
    property var groupExpanded: ({})
    function isGroupExpanded(name) {
        return root.groupExpanded[name] !== false;
    }
    function toggleGroup(name) {
        const next = Object.assign({}, root.groupExpanded);
        next[name] = !root.isGroupExpanded(name);
        root.groupExpanded = next;
    }

    // How many process rows each *expanded* account group gets to show,
    // derived from the real remaining vertical budget rather than a fixed
    // count -- so one account open alone gets to show many more than when
    // all 3 are open together. The header/row heights below are rough
    // rendered-size estimates (not measured live -- doing that without a
    // two-pass layout would mean each group's budget depending on its
    // siblings' actual process counts, which themselves depend on their
    // own budget: circular), so this is a heuristic, not a guarantee of
    // zero clipping -- the 20px safety margin exists to bias it toward
    // under-filling rather than over-filling.
    readonly property int rowH: 20
    readonly property int groupHeaderH: 78
    readonly property int collapsedH: 20

    // Shared column widths -- the process-list header row and every data
    // row below it bind to these same values so the two stay aligned
    // without hardcoding the same number twice.
    // Sized for the "status" header label (6 chars), not the shorter
    // idle/busy/wait values it holds -- the header row hit the exact same
    // "wider label overflows a value-sized column" bug the status *value*
    // column itself had before "waiting" got abbreviated to "wait".
    readonly property int colStatusW: 44
    readonly property int colPidW: 68
    readonly property int colTokensW: 56
    readonly property int colAgoW: 42
    readonly property int expandedGroupCount: {
        let n = 0;
        for (const a of ClaudeUsageSvc.accounts)
            if (root.isGroupExpanded(a.account))
                n++;
        return n;
    }
    readonly property real processAreaBudget: {
        const collapsedCount = ClaudeUsageSvc.accounts.length - root.expandedGroupCount;
        const fixedOverhead = 40 + 24 + 20
            + root.expandedGroupCount * root.groupHeaderH
            + collapsedCount * root.collapsedH;
        return Math.max(0, root.maxPanelHeight - fixedOverhead);
    }
    readonly property int perGroupRowBudget: root.expandedGroupCount > 0
        ? Math.max(1, Math.floor(root.processAreaBudget / root.expandedGroupCount / root.rowH))
        : 0

    Column {
        id: content
        x: 12
        y: 12
        width: parent.width - 24
        spacing: 10

        Text {
            width: parent.width
            text: root.tick >= 0 ? root.modeLine() + " -- " + qsTr("updated %1").arg(root.fmtAgo(ClaudeUsageSvc.updatedAt)) : ""
            color: Theme.textDim
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 2
            elide: Text.ElideRight
        }

        Repeater {
            model: ClaudeUsageSvc.accounts

            delegate: Column {
                id: acctCol
                width: content.width
                spacing: 2

                required property var modelData
                readonly property bool hasSession: typeof modelData.session_pct === "number"
                readonly property bool hasWeekly: typeof modelData.weekly_pct === "number"
                readonly property bool groupOpen: root.isGroupExpanded(modelData.account)
                // Every alive process for this account, most-recently-active
                // first (claude-usage-daemon.py's list_sessions()) -- 20-40
                // of these routinely exist per account here, almost all idle
                // resumed shells, so visibleProcs below is what actually
                // renders; procs.length (the real total) drives "+N more".
                readonly property var procs: ClaudeUsageSvc.sessions[modelData.account] || []
                readonly property var visibleProcs: groupOpen ? procs.slice(0, root.perGroupRowBudget) : []
                readonly property int hiddenProcCount: groupOpen ? Math.max(0, procs.length - root.perGroupRowBudget) : 0

                Item {
                    id: heading
                    width: headingRow.width
                    height: headingRow.height

                    Row {
                        id: headingRow
                        spacing: 6

                        Text {
                            // Folded (collapsed): points right. Unfolded
                            // (expanded): points down. Plain Unicode
                            // triangles, not a Nerd Font glyph -- no
                            // icon-font dependency needed for two shapes
                            // this simple.
                            text: acctCol.groupOpen ? "▾" : "▸"
                            color: Theme.textDim
                            font.pixelSize: Theme.fontSize - 2
                            anchors.verticalCenter: nameText.verticalCenter
                        }
                        Text {
                            id: nameText
                            text: acctCol.modelData.account || ""
                            color: Theme.text
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize
                            font.bold: true
                        }
                    }

                    // MouseArea deliberately lives on this wrapping Item,
                    // not inside headingRow itself -- a MouseArea with
                    // anchors.fill: parent whose parent is the Row it's
                    // also a child of creates a layout cycle (the Row's
                    // own size depends on its children, one of which then
                    // depends back on the Row's size), which silently
                    // collapsed this whole heading to zero size the first
                    // time this was written that way.
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.toggleGroup(acctCol.modelData.account)
                    }
                }

                // A stale reading still shows its (dimmed) numbers below --
                // this is just the "why" note, not a replacement for them.
                // Only a genuinely never-fetched account has no numbers to
                // dim, in which case this is the only line shown.
                Text {
                    visible: parent.groupOpen && !!modelData.error
                    width: parent.width
                    text: parent.hasSession || parent.hasWeekly
                        ? qsTr("%1 -- showing last known values").arg(modelData.error)
                        : qsTr("error: %1").arg(modelData.error)
                    color: Theme.red
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                    elide: Text.ElideRight
                }

                RowLayout {
                    visible: parent.groupOpen && parent.hasSession
                    opacity: modelData.stale ? 0.55 : 1
                    width: parent.width
                    spacing: 10

                    Text {
                        text: qsTr("session %1%").arg(Math.round(modelData.session_pct))
                        color: Theme.rampColor(modelData.session_pct / 100)
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 1
                    }
                    Text {
                        text: root.tick >= 0 ? root.fmtResets(modelData.session_resets_at) : ""
                        color: Theme.textDim
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 2
                    }
                    Item { Layout.fillWidth: true }
                }

                RowLayout {
                    visible: parent.groupOpen && parent.hasWeekly
                    opacity: modelData.stale ? 0.55 : 1
                    width: parent.width
                    spacing: 10

                    Text {
                        text: qsTr("weekly %1%").arg(Math.round(modelData.weekly_pct))
                        color: Theme.rampColor(modelData.weekly_pct / 100)
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 1
                    }
                    Text {
                        text: root.tick >= 0 ? root.fmtResets(modelData.weekly_resets_at) : ""
                        color: Theme.textDim
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 2
                    }
                    Item { Layout.fillWidth: true }
                }

                // Column headers, once per group -- shares its widths with
                // every data row below via root.col*W so the two stay
                // aligned without repeating "pid"/"tok"/"tmux" on every
                // single row.
                RowLayout {
                    visible: parent.groupOpen && parent.procs.length > 0
                    width: content.width
                    spacing: 6

                    Text {
                        text: qsTr("status")
                        color: Theme.muted
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 3
                        Layout.preferredWidth: root.colStatusW
                    }
                    Text {
                        text: qsTr("pid")
                        color: Theme.muted
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 3
                        Layout.preferredWidth: root.colPidW
                    }
                    Text {
                        text: qsTr("tokens")
                        color: Theme.muted
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 3
                        Layout.preferredWidth: root.colTokensW
                    }
                    Text {
                        text: qsTr("location")
                        color: Theme.muted
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 3
                        Layout.fillWidth: true
                    }
                    Text {
                        text: qsTr("active")
                        color: Theme.muted
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 3
                        horizontalAlignment: Text.AlignRight
                        Layout.preferredWidth: root.colAgoW
                    }
                }

                Repeater {
                    model: parent.visibleProcs

                    delegate: RowLayout {
                        required property var modelData
                        width: content.width
                        spacing: 6

                        Text {
                            text: root.statusLabel(modelData.status)
                            color: root.statusColor(modelData.status)
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                            Layout.preferredWidth: root.colStatusW
                        }
                        Text {
                            text: String(modelData.pid)
                            color: Theme.text
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                            Layout.preferredWidth: root.colPidW
                        }
                        Text {
                            text: root.fmtTokens(modelData.context_tokens)
                            color: Theme.textDim
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                            Layout.preferredWidth: root.colTokensW
                        }
                        Text {
                            text: root.shortCwd(modelData.cwd) + (modelData.tmux ? qsTr(" · %1").arg(modelData.tmux) : "")
                            color: Theme.muted
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 3
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                        Text {
                            text: root.tick >= 0 ? root.fmtAgoMs(modelData.updated_at_ms) : ""
                            color: Theme.muted
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 3
                            horizontalAlignment: Text.AlignRight
                            Layout.preferredWidth: root.colAgoW
                        }
                    }
                }

                // Real remaining count, not a vague "more" -- perGroupRowBudget
                // is a fit-estimate (see its own comment), so this can be
                // slightly off if a row rendered shorter/taller than assumed,
                // but it's always derived from procs.length, the true total
                // the daemon sent, never silently dropped.
                Text {
                    visible: parent.hiddenProcCount > 0
                    text: qsTr("+%1 more").arg(parent.hiddenProcCount)
                    color: Theme.muted
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                    topPadding: 1
                }
            }
        }

        Text {
            visible: !ClaudeUsageSvc.hasData
            width: parent.width
            text: qsTr("waiting for claude-usage-daemon...")
            color: Theme.muted
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 1
        }
    }
}
