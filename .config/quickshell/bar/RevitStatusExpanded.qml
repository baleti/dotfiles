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
        { label: "VM",      width: 90, key: "vm" },
        { label: "DISPLAY", width: 52, key: "display" },
        { label: "REVIT",   width: 42,  key: "year" },
        { label: "STATUS",  width: 190, key: "status" },
        { label: "ENGINE",  width: 80,  key: "engine" },
        { label: "QUEUE",   width: 42,  key: "queued" },
        { label: "PID",     width: 46,  key: "pid" },
        { label: "PORT",    width: 42,  key: "port" }
    ]
    readonly property int colGap: 8
    readonly property int rowHeight: 17
    readonly property real naturalContentWidth: columns.reduce((s, c) => s + c.width + root.colGap, 0) + 24

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
        if (key === "status") return root.statusText(r);
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

        Row {
            spacing: root.colGap
            Repeater {
                model: root.columns
                delegate: Text {
                    required property var modelData
                    width: modelData.width
                    text: modelData.label
                    color: Theme.muted
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                    font.bold: true
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
                        text: (modelData.key === "vm" || modelData.key === "display") && rowItem.repeatsVm ? "" : root.cellText(rowItem.modelData, modelData.key)
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
}
