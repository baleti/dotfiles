import QtQuick
import "../clipboard"

// The query -> rows -> columns logic of the Revit command picker (mod+`), kept apart from the layer-shell window so it can be unit-tested
// (qmltestrunner, ~/.config/quickshell/revitremote/tests) without a compositor. Same DSL engine as the clipboard and notification
// pickers: ClipboardQueryDsl (see ~/.config/docs/query-dsl.md). Entries come from `revit-remote rows`:
//   { id, preview, haystack, target, port, command, fields: { command, class, input, output, target, instance, year, pid, state } }
QtObject {
    id: model

    property string query: ""
    property var entries: []

    readonly property var fieldNames: ["command", "class", "input", "output", "target", "instance", "year", "pid", "state"]
    readonly property var fieldDescs: ({
        "command": "the command's display name",
        "class": "the command's class name",
        "input": "what must be selected or open before it runs",
        "output": "what it produces",
        "target": "the machine or VM the Revit instance runs on",
        "instance": "target, Revit year and process id of the instance",
        "year": "Revit version",
        "pid": "Revit process id",
        "state": "idle, busy, or the title of the dialog blocking it"
    })
    // The command's own name is the row's preview text (the flexible left cell), so it is not a column by default; `/at command` adds it.
    readonly property var defaultColumns: ["input", "instance"]
    readonly property var columnLabels: ({
        "command": "command", "class": "class", "input": "input", "output": "output", "target": "target",
        "instance": "instance", "year": "year", "pid": "pid", "state": "state"
    })
    readonly property var columnWidths: ({
        "command": 190, "class": 170, "input": 80, "output": 90, "target": 150, "instance": 230, "year": 50, "pid": 60, "state": 150
    })
    function colWidth(name) { return model.columnWidths[name] || 90; }

    property var parsed: ClipboardQueryDsl.parse(model.query, model.fieldNames)
    readonly property var results: {
        const filtered = model.entries.filter(e => ClipboardQueryDsl.matches(e, model.parsed));
        return ClipboardQueryDsl.applySort(filtered, model.parsed, model.fieldNames);
    }
    readonly property var activeColumns: ClipboardQueryDsl.activeColumns(model.parsed, model.fieldNames, model.defaultColumns)
    readonly property real columnsWidth: model.activeColumns.reduce((sum, c) => sum + model.colWidth(c), 0)

    // One NDJSON line per row -> entries; a line that is not JSON (a ssh banner, a warning) is skipped.
    function parseRows(text) {
        const rows = [];
        for (const line of (text || "").split("\n")) {
            const l = line.trim();
            if (!l || l[0] !== "{") continue;
            try {
                const r = JSON.parse(l);
                if (r && r.id !== undefined && r.fields) rows.push(r);
            } catch (e) { /* skip */ }
        }
        return rows;
    }
}
