import QtQuick
import Quickshell
import Quickshell.Io
import "../theme"

// CTRL+ALT+r panel: every Revit instance reachable through the Revit Ballet agents, one row each, in columns -- which VM / machine it
// runs on, Revit version, status (idle / busy / modal dialog), the agent's origin (installed / hot-reload / legacy) and build, the
// scripting engines it offers and its queue depth. Backed by `revit-remote status` (NDJSON, one row per instance; a VM that is down or
// has no Revit running gets a row of its own), re-run every pollMs while the panel is open -- it probes over ssh and takes ~3 s, so it
// never overlaps itself and nothing runs while the panel is closed. Same sibling-overlay shape as ClaudeUsageExpanded (collapses to 0
// height when closed, wired through Bar.qml's panel row), pin/Escape only -- there is no pill.
Rectangle {
    id: root

    property bool expanded: false
    property real panelWidth: 600
    property real maxPanelHeight: 700
    readonly property bool hovered: mouseArea.containsMouse

    readonly property string _bin: Quickshell.env("HOME") + "/bin/revit-remote"
    readonly property int pollMs: 8000

    // [{ label, width, role }] -- role picks the cell renderer below.
    readonly property var columns: [
        { label: "VM",      width: 90, key: "vm" },
        { label: "DISPLAY", width: 52, key: "display" },
        { label: "REVIT",   width: 42,  key: "year" },
        { label: "STATUS",  width: 190, key: "status" },
        { label: "AGENT",   width: 74,  key: "agent" },
        { label: "BUILD",   width: 140, key: "build" },
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
    property bool loading: false
    property string error: ""
    property double updatedMs: 0

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

    // "installed" / "hot-reload" come from /v1/info agent.loadedFrom; an agent too old to report it is a legacy one.
    function agentKind(r) { return r.agent ? r.agent : "legacy"; }

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
        if (!r.instance) return key === "build" && r.detail ? r.detail.replace(/[^\x20-\x7e]/g, "").trim() : "";
        switch (key) {
        case "year": return String(r.year);
        case "version": return r.version || "";
        case "agent": return root.agentKind(r);
        case "build": return r.build || "-";
        case "engine": return r.active_engine || (r.running ? "?" : "-");
        case "queued": return r.queued > 0 ? String(r.queued) : "-";
        case "pid": return String(r.pid);
        case "port": return String(r.port);
        }
        return "";
    }
    function cellColor(r, key) {
        if (key === "status") return root.statusColor(r);
        if (key === "agent") return r.instance && root.agentKind(r) === "legacy" ? Theme.orange : Theme.textDim;
        if (key === "display") return r.display === "gpu" ? Theme.cyan : Theme.textDim;
        if (key === "vm" || key === "year") return Theme.text;
        return Theme.textDim;
    }

    function parseRows(text) {
        const out = [];
        for (const line of (text || "").split("\n")) {
            const l = line.trim();
            if (!l || l[0] !== "{")
                continue;
            try {
                const r = JSON.parse(l);
                if (r && r.target)
                    out.push(r);
            } catch (e) { /* skip a stray non-JSON line */ }
        }
        // stable per-VM grouping: by VM, then Revit year (VMs without an instance row sort first within their own VM)
        out.sort((a, b) => (a.cid || 0) - (b.cid || 0) || a.target.localeCompare(b.target) || (a.year || 0) - (b.year || 0));
        return out;
    }

    Process {
        id: proc
        command: [root._bin, "status"]
        stdout: StdioCollector {
            id: collector
            onStreamFinished: {
                root.rows = root.parseRows(collector.text);
                root.error = root.rows.length === 0 ? "no Revit targets found (revit-remote targets)" : "";
                root.loaded = true;
                root.loading = false;
                root.updatedMs = Date.now();
            }
        }
        onExited: (code, status) => {
            if (code !== 0 && root.loading) {
                root.error = "revit-remote status failed (exit " + code + ")";
                root.loaded = true;
                root.loading = false;
            }
        }
    }
    function refresh() {
        if (proc.running)
            return;
        root.loading = true;
        proc.running = true;
    }

    // Poll while open, never while closed; a fresh open refreshes at once.
    onExpandedChanged: if (expanded) root.refresh()
    Timer {
        interval: root.pollMs
        repeat: true
        running: root.expanded
        onTriggered: root.refresh()
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
                readonly property int n: root.rows.filter(r => r.instance).length
                text: root.loaded ? (n + " running") + (root.loading ? "  · refreshing…" : "") : "probing VMs…"
                color: Theme.muted
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
        Text {
            visible: root.loaded
            text: "Esc / CTRL+ALT+r closes · refreshes every " + (root.pollMs / 1000) + " s"
            color: Theme.muted
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 3
        }
    }
}
