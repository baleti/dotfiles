import QtQuick
import "../clipboard"

// The query -> rows -> columns logic of the global-menu picker (mod+a), kept apart from the layer-shell window so it can be unit-tested
// (qmltestrunner, ~/.config/quickshell/appmenu/tests) without a compositor. Same DSL engine as the clipboard and notification pickers:
// ClipboardQueryDsl (see ~/.config/docs/query-dsl.md). Entries come from `appmenu-atspi.py pick`:
//   { id, preview, haystack, src, fields: { item, menu, path, app, shortcut, state } }
QtObject {
    id: model

    property string query: ""
    property var entries: []

    readonly property var fieldNames: ["item", "menu", "path", "app", "shortcut", "state"]
    readonly property var fieldDescs: ({
        "item": "the menu item's own label",
        "menu": "the menus it sits under, outermost first",
        "path": "menu path and item label",
        "app": "the application that owns the menu",
        "shortcut": "its keyboard shortcut, when the app exposes one",
        "state": "checked or unchecked, for check and radio items"
    })
    // The full path is the row's preview text (the flexible left cell), so item/menu/path are only columns after `/at`.
    readonly property var defaultColumns: ["shortcut"]
    readonly property var columnLabels: ({
        "item": "item", "menu": "menu", "path": "path", "app": "app", "shortcut": "shortcut", "state": "state"
    })
    readonly property var columnWidths: ({
        "item": 200, "menu": 200, "path": 300, "app": 130, "shortcut": 110, "state": 80
    })
    function colWidth(name) { return model.columnWidths[name] || 90; }

    property var parsed: ClipboardQueryDsl.parse(model.query, model.fieldNames)
    readonly property var results: {
        const filtered = model.entries.filter(e => ClipboardQueryDsl.matches(e, model.parsed));
        return ClipboardQueryDsl.applySort(filtered, model.parsed, model.fieldNames);
    }
    readonly property var activeColumns: ClipboardQueryDsl.activeColumns(model.parsed, model.fieldNames, model.defaultColumns)
    readonly property real columnsWidth: model.activeColumns.reduce((sum, c) => sum + model.colWidth(c), 0)

    // First line {pid, title}, then one JSON row per line; anything that is not JSON is skipped.
    function parseStash(text) {
        const out = { pid: 0, title: "", rows: [] };
        for (const line of (text || "").split("\n")) {
            const l = line.trim();
            if (!l || l[0] !== "{") continue;
            try {
                const r = JSON.parse(l);
                if (r.fields && r.id !== undefined) out.rows.push(r);
                else if (r.pid !== undefined) { out.pid = r.pid; out.title = r.title || ""; }
            } catch (e) { /* skip */ }
        }
        return out;
    }
}
