import QtQuick
import Quickshell
import Quickshell.Io
import "../theme"

// CTRL+ALT+r panel: every Revit instance reachable through the Revit Ballet agents, one row each, in columns -- VM and its display hardware
// (GPU passthrough / QXL), Revit year, status (idle / busy / modal dialog), the engine of the running job, queue depth, pid and
// port. Reads the state file kept current by revit-status-daemon (~/.config/revit-status, adaptive probe interval), so the last known view
// shows the moment the panel opens; while open it touches the daemon's watch file to get fast refreshes. Same sibling-overlay shape as
// ClaudeUsageExpanded (collapses to 0 height when closed, wired through Bar.qml's panel row); pin/Escape only -- there is no pill.
Rectangle {
    id: root

    property bool expanded: false
    property real panelWidth: 600
    property real maxPanelHeight: 700
    readonly property bool hovered: mouseArea.containsMouse


    // [{ label, width, role }] -- role picks the cell renderer below.
    readonly property var columns: [
        { label: "VM",      width: 90, key: "vm" , tip: "VM running this Revit" },
        { label: "DISPLAY", width: 52, key: "display" , tip: "GPU = passthrough, QXL = emulated" },
        { label: "REVIT",   width: 42,  key: "year" , tip: "Revit version" },
        { label: "STATUS",  width: 190, key: "status" , tip: "idle, busy, or blocking dialog" },
        { label: "ENGINE",  width: 80,  key: "engine" , tip: "engine of the running job" },
        { label: "QUEUE",   width: 42,  key: "queued" , tip: "queued jobs" },
        { label: "PID",     width: 46,  key: "pid" , tip: "Revit process id" },
        { label: "PORT",    width: 42,  key: "port" , tip: "agent port" },
        // the "host3" group: the live Claude Code session on this machine that last ran a command naming the VM (shown on the VM's first row)
        { label: "TITLE",   width: 230, key: "claudeTitle", group: true , tip: "last Claude session to use this VM" },
        { label: "SESS",    width: 34,  key: "tmuxSession", group: true , tip: "tmux session" },
        { label: "WIN",     width: 34,  key: "tmuxWindow",  group: true , tip: "tmux window" },
        { label: "PANE",    width: 36,  key: "tmuxPane",    group: true , tip: "tmux pane" }
    ]
    readonly property var plainColumns: columns.filter(c => !c.group)
    readonly property real plainWidth: plainColumns.reduce((s, c) => s + c.width + root.colGap, 0)
    readonly property real groupWidth: columns.filter(c => c.group).reduce((s, c) => s + c.width + root.colGap, 0) - root.colGap
    readonly property int colGap: 8
    readonly property int rowHeight: 17
    readonly property real naturalContentWidth: columns.reduce((s, c) => s + c.width + root.colGap, 0) + 24

    // Cursor-following hover hint for the column headers (same shape as ClaudeUsageExpanded's hintPopup).
    property string hintText: ""
    property point hintPos: Qt.point(0, 0)

    property var host: null

    // Pills for the VM host's own stats (cpu, memory, the passed-through GPU read inside its VM, the disks the VMs live on): [{ label, value, pct }].
    readonly property var hostPills: {
        const h = root.host;
        if (!h)
            return [];
        const gb = mb => (mb / 1024).toFixed(mb >= 10240 ? 0 : 1);
        const tb = g => (g / 1024).toFixed(2);
        const out = [];
        if (h.cpu_pct !== undefined)
            out.push({ label: "cpu", value: h.cpu_pct + "%", pct: h.cpu_pct });
        if (h.mem_total_mb)
            out.push({ label: "mem", value: gb(h.mem_total_mb - h.mem_avail_mb) + "/" + gb(h.mem_total_mb) + "G",
                       pct: 100 * (h.mem_total_mb - h.mem_avail_mb) / h.mem_total_mb });
        if (h.swap_total_mb)
            out.push({ label: "swap", value: gb(h.swap_total_mb - h.swap_free_mb) + "/" + gb(h.swap_total_mb) + "G",
                       pct: 100 * (h.swap_total_mb - h.swap_free_mb) / h.swap_total_mb });
        if (h.gpu)
            out.push({ label: "gpu", value: h.gpu.util + "% " + gb(h.gpu.mem_used_mb) + "/" + gb(h.gpu.mem_total_mb) + "G " + h.gpu.temp_c + "\u00b0",
                       pct: h.gpu.util });
        for (const d of (h.disks || []))
            out.push({ label: d.label, value: d.pct + "% " + tb(d.used_gb) + "/" + tb(d.size_gb) + "T", pct: d.pct });
        return out;
    }

    property var rows: []
    property bool loaded: false
    property string error: ""

    width: panelWidth
    implicitHeight: expanded ? Math.min(content.implicitHeight + 20, root.maxPanelHeight) : 0
    height: implicitHeight
    visible: height > 0
    clip: true
    radius: Theme.rounding
    color: Theme.bgAlpha
    border.color: Theme.border
    border.width: 1

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.AllButtons
        onWheel: wheel => wheel.accepted = true
    }

    // ---------------------------------------------------------------- data

    // The VM column: a CI VM's long generated name is shortened to its cid, a named VM stays as is.
    function vmLabel(r) {
        const n = r.vm || r.target;
        return n.startsWith("ci-") && r.cid ? "cid" + r.cid : n;
    }

    function statusText(r) {
        if (!r.instance)
            return r.state === "unreachable" ? "unreachable" : "no Revit running";
        if (r.state === "modal")
            return "dialog: " + (r.dialog || "?");
        if (!r.responsive)
            return "not responding";
        if (r.running)
            return "busy";
        return r.state || "?";
    }
    function statusColor(r) {
        if (!r.instance)
            return r.state === "unreachable" ? Theme.red : Theme.muted;
        if (r.state === "modal" || !r.responsive || r.hung_compiles > 0)
            return Theme.orange;
        if (r.running)
            return Theme.cyan;
        return Theme.green;
    }

    function cellText(r, key) {
        if (key === "vm") return root.vmLabel(r);
        if (key === "claudeTitle") return r.claude ? r.claude.title : "";
        if (key === "tmuxSession") return r.claude ? r.claude.tmux_session : "";
        if (key === "tmuxWindow") return r.claude ? r.claude.tmux_window : "";
        if (key === "tmuxPane") return r.claude ? r.claude.tmux_pane : "";
        if (key === "status") return root.statusText(r);
        if (key === "claudeTitle") return Theme.text;
        if (key === "display") return r.display === "gpu" ? "GPU" : r.display === "qxl" ? "QXL" : "";
        if (!r.instance) return "";
        switch (key) {
        case "year": return String(r.year);
        case "version": return r.version || "";
        case "engine": return r.active_engine || (r.running ? "?" : "-");
        case "queued": return r.queued > 0 ? String(r.queued) : "-";
        case "pid": return String(r.pid);
        case "port": return String(r.port);
        }
        return "";
    }
    function cellColor(r, key) {
        if (key === "status") return root.statusColor(r);
        if (key === "display") return r.display === "gpu" ? Theme.cyan : Theme.textDim;
        if (key === "vm" || key === "year") return Theme.text;
        return Theme.textDim;
    }

    // stable per-VM grouping: by VM, then Revit year (a VM without an instance row sorts on its own)
    function sortRows(rows) {
        return rows.filter(r => r && r.target).sort((a, b) => (a.cid || 0) - (b.cid || 0) || a.target.localeCompare(b.target) || (a.year || 0) - (b.year || 0));
    }

    // The rows come from revit-status-daemon's state file (~/.cache/revit-status/state.json), so the last known view is on screen the
    // instant the panel opens. While open, the panel touches the daemon's watch file so it drops to its fast probe interval.
    readonly property string _stateFile: Quickshell.env("HOME") + "/.cache/revit-status/state.json"
    readonly property string _watchFile: Quickshell.env("HOME") + "/.cache/revit-status/watch"
    property bool probeOk: true

    FileView {
        id: stateFile
        path: root._stateFile
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                const d = JSON.parse(stateFile.text());
                root.rows = root.sortRows(d.rows || []);
                root.probeOk = d.ok !== false;
                root.host = d.host || null;
                root.error = root.rows.length === 0 ? "no Revit targets found (revit-remote targets)" : "";
                root.loaded = true;
            } catch (e) {
                console.warn("RevitStatusExpanded: bad state.json:", e);
            }
        }
        onLoadFailed: {}
    }
    Process {
        id: touchWatch
        command: ["touch", root._watchFile]
    }
    function touchWatchFile() {
        if (!touchWatch.running)
            touchWatch.running = true;
    }
    onExpandedChanged: if (expanded) { root.touchWatchFile(); stateFile.reload(); }
    Timer {
        interval: 8000
        repeat: true
        running: root.expanded
        onTriggered: root.touchWatchFile()
    }

    // ---------------------------------------------------------------- UI

    Column {
        id: content
        x: 12
        y: 10
        width: parent.width - 24
        spacing: 2

        Row {
            width: parent.width
            Text {
                text: "Revit instances"
                color: Theme.text
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 1
                font.bold: true
            }
            Item { width: 12; height: 1 }
            Text {
                visible: root.loaded && !root.probeOk
                text: "last known view - VM host unreachable"
                color: Theme.orange
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 3
                anchors.baseline: parent.children[0].baseline
            }
        }

        // second line: the VM host's stats
        Row {
            visible: root.hostPills.length > 0
            spacing: 6
            opacity: root.probeOk ? 1 : 0.55
            Text {
                text: root.host ? root.host.name : ""
                color: Theme.muted
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 3
                anchors.verticalCenter: parent.verticalCenter
            }
            Repeater {
                model: root.hostPills
                delegate: Rectangle {
                    id: pill
                    required property var modelData
                    implicitWidth: pillRow.implicitWidth + 14
                    implicitHeight: pillRow.implicitHeight + 6
                    radius: height / 2
                    color: Theme.bgAlpha
                    border.color: Theme.border
                    border.width: 1
                    Row {
                        id: pillRow
                        anchors.centerIn: parent
                        spacing: 5
                        Text {
                            text: pill.modelData.label
                            color: Theme.muted
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 3
                        }
                        Text {
                            text: pill.modelData.value
                            color: Theme.rampColor(pill.modelData.pct / 100)
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 3
                            font.bold: true
                        }
                    }
                }
            }
        }

        Row {
            spacing: 0
            Item { width: root.plainWidth; height: 1 }
            Text {
                id: groupLabel
                text: "host3"
                width: root.groupWidth
                color: Theme.muted
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 3
                horizontalAlignment: Text.AlignHCenter
                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: {
                        root.hintText = "Claude sessions on this machine";
                        root.hintPos = groupLabel.mapToItem(root, mouseX + 12, mouseY + 16);
                    }
                    onPositionChanged: mouse => root.hintPos = groupLabel.mapToItem(root, mouse.x + 12, mouse.y + 16)
                    onExited: root.hintText = ""
                }
                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 1
                    color: Theme.border
                }
            }
        }

        Row {
            spacing: root.colGap
            Repeater {
                model: root.columns
                delegate: Text {
                    id: headerCell
                    required property var modelData
                    width: modelData.width
                    text: modelData.label
                    color: Theme.muted
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                    font.bold: true
                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: {
                            root.hintText = headerCell.modelData.tip;
                            root.hintPos = headerCell.mapToItem(root, mouseX + 12, mouseY + 16);
                        }
                        onPositionChanged: mouse => root.hintPos = headerCell.mapToItem(root, mouse.x + 12, mouse.y + 16)
                        onExited: root.hintText = ""
                    }
                }
            }
        }
        Rectangle { width: parent.width; height: 1; color: Theme.border }

        Repeater {
            model: root.rows
            delegate: Row {
                id: rowItem
                required property var modelData
                required property int index
                // the VM name is printed on a VM's first row only, so a VM running seven Revits reads as one group
                readonly property bool repeatsVm: index > 0 && root.rows[index - 1].target === modelData.target
                spacing: root.colGap
                height: root.rowHeight

                Repeater {
                    model: root.columns
                    delegate: Text {
                        required property var modelData
                        width: modelData.width
                        height: root.rowHeight
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideRight
                        text: (modelData.key === "vm" || modelData.key === "display" || modelData.group === true) && rowItem.repeatsVm ? "" : root.cellText(rowItem.modelData, modelData.key)
                        color: root.cellColor(rowItem.modelData, modelData.key)
                        font.family: Theme.fontFamily
                        font.pixelSize: modelData.key === "vm" || modelData.key === "year" || modelData.key === "status" || modelData.key === "display" ? Theme.fontSize - 2 : Theme.fontSize - 3
                        font.bold: modelData.key === "status"
                    }
                }
            }
        }

        Text {
            visible: root.error !== ""
            text: root.error
            color: Theme.red
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 2
        }
        Row {
            visible: root.loaded
            spacing: 6
            Rectangle {
                implicitWidth: sigmaText.implicitWidth + 16
                implicitHeight: sigmaText.implicitHeight + 6
                radius: height / 2
                color: Theme.bgAlpha
                border.color: Theme.border
                border.width: 1
                Text {
                    id: sigmaText
                    anchors.centerIn: parent
                    text: "Σ " + root.rows.filter(r => r.instance).length
                    color: Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 1
                    font.bold: true
                }
            }
        }
    }

    Rectangle {
        visible: root.hintText.length > 0
        x: Math.max(4, Math.min(root.hintPos.x, root.width - width - 4))
        y: Math.min(root.hintPos.y, root.height - height - 4)
        z: 100
        width: hintPopupText.implicitWidth + 8
        height: hintPopupText.implicitHeight + 4
        radius: 3
        color: Theme.bg
        border.color: Theme.border
        border.width: 1
        Text {
            id: hintPopupText
            anchors.centerIn: parent
            text: root.hintText
            color: Theme.text
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 3
        }
    }
}
