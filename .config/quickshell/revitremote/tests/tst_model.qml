import QtQuick
import QtTest
import ".."

// Unit tests for RevitRemoteModel: the DSL (ClipboardQueryDsl, query-dsl.md) over the rows `revit-remote rows` produces.
// Run:  QT_QPA_PLATFORM=offscreen qmltestrunner -input ~/.config/quickshell/revitremote/tests
TestCase {
    id: tc
    name: "RevitRemoteModel"

    function row(target, port, cls, display, input, output, year, pid, state) {
        const inst = target + " · " + year + " · " + pid;
        return {
            id: target + "|" + port + "|" + cls, preview: display, target: target, port: port, command: cls,
            haystack: (display + " " + cls + " " + target + " " + year).toLowerCase(),
            fields: { command: display, "class": cls, input: input, output: output, target: target, instance: inst,
                      year: String(year), pid: String(pid), state: state }
        };
    }
    function sample() {
        return [
            row("host2/cid20", 23717, "DeselectRandomly", "Deselect Randomly", "Any", "", 2026, 5728, "idle"),
            row("host2/cid20", 23717, "ExportToPDF", "Export To PDF", "", "PDF", 2026, 5728, "idle"),
            row("host2/cid21", 23717, "DeselectRandomly", "Deselect Randomly", "Any", "", 2026, 4700, "idle"),
            row("host2/cid21", 23717, "ExportToPDF", "Export To PDF", "", "PDF", 2026, 4700, "idle"),
            row("host2/revit-win", 23721, "ExportToPDF", "Export To PDF", "", "PDF", 2023, 17864, "dialog: Autodesk Revit 2023"),
            row("host2/revit-win", 23723, "ExportToPDF", "Export To PDF", "", "PDF", 2026, 18172, "idle"),
            row("host2/revit-win", 23723, "CloseWorksets", "Close Worksets", "View, Link", "", 2026, 18172, "idle")
        ];
    }
    Component { id: modelComp; RevitRemoteModel {} }
    function make(query) {
        const m = createTemporaryObject(modelComp, tc, { entries: sample(), query: query });
        verify(m !== null);
        return m;
    }
    function ids(m) { return m.results.map(r => r.target.replace("host2/", "") + ":" + r.command); }

    // ---- defaults
    function test_empty_query_shows_every_row_in_order_with_the_default_columns() {
        const m = make("");
        compare(m.results.length, 7);
        compare(m.results[0].command, "DeselectRandomly");
        compare(m.results[6].command, "CloseWorksets");
        compare(m.activeColumns, ["input", "instance"]);
    }

    // ---- free text (the picker's haystack: display name, class, target, year)
    function test_bare_word_matches_display_and_class_names() {
        compare(ids(make("pdf")), ["cid20:ExportToPDF", "cid21:ExportToPDF", "revit-win:ExportToPDF", "revit-win:ExportToPDF"]);
        compare(ids(make("deselectrandomly")).length, 2);
        compare(ids(make("deselect random")).length, 2);
    }
    function test_bare_word_matches_the_target_and_the_year() {
        compare(ids(make("cid21")).length, 2);
        compare(ids(make("2023")), ["revit-win:ExportToPDF"]);
    }
    function test_the_input_text_does_not_leak_into_free_text() {
        compare(ids(make("any")).length, 0);          // "Any" is the input of DeselectRandomly; only `//input any` should find it
    }

    // ---- scoped filters and via
    function test_scoped_filter_by_field() {
        compare(ids(make("//input any")).length, 2);
        compare(ids(make("/fv input:any")).length, 2);
        compare(ids(make("/fv/input any")).length, 2);
        compare(ids(make("//target cid20")), ["cid20:DeselectRandomly", "cid20:ExportToPDF"]);
        compare(ids(make("//year 2023")), ["revit-win:ExportToPDF"]);
        compare(ids(make("//class closew")), ["revit-win:CloseWorksets"]);
    }
    function test_instance_field_carries_target_year_and_pid() {
        compare(ids(make("//instance 17864")), ["revit-win:ExportToPDF"]);
        compare(ids(make("//instance \"cid20 · 2026\"")).length, 2);
    }
    function test_state_shows_a_blocking_dialog() {
        compare(ids(make("//state dialog")), ["revit-win:ExportToPDF"]);
        compare(ids(make("!//state dialog")).length, 6);
    }
    function test_and_of_terms_and_negation() {
        compare(ids(make("//target cid2 //input any")).length, 2);
        compare(ids(make("pdf !//target revit-win")), ["cid20:ExportToPDF", "cid21:ExportToPDF"]);
        compare(ids(make("!//target host2")).length, 0);
        compare(ids(make("!pdf")).length, 3);
    }
    function test_unresolved_field_narrows_to_nothing_and_half_typed_is_inert() {
        compare(ids(make("//zzz foo")).length, 0);
        compare(ids(make("//")).length, 7);
        compare(ids(make("/")).length, 7);
        compare(ids(make("//target")).length, 7);        // flat field, no value yet
    }

    // ---- columns
    function test_column_verbs() {
        compare(make("/at command").activeColumns, ["input", "instance", "command"]);
        compare(make("/rt input").activeColumns, ["instance"]);
        compare(make("/ft instance").activeColumns, ["instance"]);
        compare(make("/ft instance /at state").activeColumns, ["instance", "state"]);
        compare(make("/ft year /at state").activeColumns, ["state"]);          // /ft intersects with what is shown: year is not shown by default
        compare(make("/at output /rt instance").activeColumns, ["input", "output"]);
    }
    function test_filtered_fields_are_auto_shown() {
        compare(make("//year 2026").activeColumns, ["input", "instance", "year"]);
        compare(make("/ft instance //state idle").activeColumns, ["instance", "state"]);
    }

    // ---- order
    function test_sort_by_a_field_and_direction() {
        compare(make("/s command").results.map(r => r.fields.command).slice(0, 2), ["Close Worksets", "Deselect Randomly"]);
        const desc = make("/s command desc").results.map(r => r.fields.command);
        compare(desc[0], "Export To PDF");
        compare(desc[desc.length - 1], "Close Worksets");
    }
    function test_numeric_sort_on_pid_is_numeric_not_lexicographic() {
        compare(make("/s pid").results.map(r => r.fields.pid).filter((v, i, a) => a.indexOf(v) === i), ["4700", "5728", "17864", "18172"]);
        compare(make("/s pid desc").results[0].fields.pid, "18172");
    }
    function test_multi_key_sort() {
        const r = make("/s/target/command").results.map(r => r.target.replace("host2/", "") + ":" + r.command);
        compare(r[0], "cid20:DeselectRandomly");
        compare(r[1], "cid20:ExportToPDF");
    }
    function test_reverse_flips_the_default_order() {
        compare(make("/rv").results[0].command, "CloseWorksets");
        compare(make("/rv /rv").results[0].command, "CloseWorksets");      // idempotent, not a toggle
    }
    function test_sort_and_filter_split_the_trailing_word() {
        compare(ids(make("/s command pdf")).length, 4);          // `pdf` is not a direction, so it filters
    }

    // ---- rows from the backend
    function test_parseRows_skips_noise_and_malformed_lines() {
        const m = make("");
        const good = JSON.stringify(sample()[0]);
        const rows = m.parseRows("Warning: noise\n" + good + "\n{not json\n\n" + JSON.stringify({ id: "x" }) + "\n" + good + "\n");
        compare(rows.length, 2);
        compare(rows[0].command, "DeselectRandomly");
        compare(m.parseRows("").length, 0);
        compare(m.parseRows(null).length, 0);
    }
    function test_column_widths() {
        const m = make("");
        compare(m.colWidth("instance"), 230);
        compare(m.colWidth("unknown"), 90);
        compare(m.columnsWidth, 80 + 230);
    }
}
