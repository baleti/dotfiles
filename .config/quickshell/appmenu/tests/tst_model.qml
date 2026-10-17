import QtQuick
import QtTest
import ".."

// Unit tests for AppMenuModel. Run:  QT_QPA_PLATFORM=offscreen qmltestrunner -input ~/.config/quickshell/appmenu/tests
TestCase {
    id: tc
    name: "AppMenuModel"

    function row(menu, item, shortcut, state) {
        const path = menu + " › " + item;
        return { id: path, preview: path, haystack: (path + " writer " + shortcut + " " + state).toLowerCase(), src: "atspi",
                 fields: { item: item, menu: menu, path: path, app: "writer", shortcut: shortcut, state: state } };
    }
    function sample() {
        return [
            row("File", "Open", "Ctrl+o", ""),
            row("File", "Save", "Ctrl+s", ""),
            row("File › Recent", "notes.odt", "", ""),
            row("View", "Status Bar", "", "checked"),
            row("View", "Rulers", "", "unchecked")
        ];
    }
    Component { id: modelComp; AppMenuModel {} }
    function make(query) { return createTemporaryObject(modelComp, tc, { entries: sample(), query: query }); }
    function items(m) { return m.results.map(r => r.fields.item); }

    function test_empty_query_keeps_order_and_default_column() {
        const m = make("");
        compare(items(m), ["Open", "Save", "notes.odt", "Status Bar", "Rulers"]);
        compare(m.activeColumns, ["shortcut"]);
    }
    function test_bare_word_matches_path() { compare(items(make("recent")), ["notes.odt"]); }
    function test_scoped_filter() { compare(items(make('//state "checked"')), ["Status Bar"]); }
    function test_negation() { compare(items(make("!//menu file")), ["Status Bar", "Rulers"]); }
    function test_sort_item_desc() { compare(items(make("//menu view /s item desc")), ["Status Bar", "Rulers"]); }
    function test_add_column() { compare(make("/at menu").activeColumns, ["shortcut", "menu"]); }
    function test_parse_stash() {
        const st = make("").parseStash('{"pid": 42, "title": "T"}\n' + JSON.stringify(sample()[0]) + "\ngarbage\n");
        compare(st.pid, 42);
        compare(st.rows.length, 1);
    }
}
