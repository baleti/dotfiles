import QtQuick
import "../quickshell/lib/dsl.js" as Dsl
import "../quickshell/launcher"
import "../quickshell/clipboard"

// The QML consumers' own parsers (launcher/rss/usage-panel QueryDsl, clipboard family, (winswitch needs the Quickshell module and cannot load here) against the
// shared engine in dsl.js on the "pipeline" vectors: /s, /g, /ft /at /rt and //keys value must agree.
// run: QML_XHR_ALLOW_FILE_READ=1 QT_FORCE_STDERR_LOGGING=1 QT_QPA_PLATFORM=offscreen qml6 test_qml_consumers.qml
QtObject {
    Component.onCompleted: {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("tests.json"), false);
        xhr.send();
        const T = JSON.parse(xhr.responseText), P = T.pipeline;
        let fails = 0;
        const check = (name, got, want) => {
            if (JSON.stringify(got) !== JSON.stringify(want)) { fails++; print("FAIL " + name + ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want)); }
        };
        const long = { fv: "fv", ft: "ft", at: "at", rt: "rt" };
        const queries = P.cases.map(c => c.query).concat(["//tmux-s 3", "/s/age/asc /fts x", "!//title idle", "/fv/title a b"]);
        const sch = Dsl.makeSchema(P.schema.types.concat(["x"]), P.schema.appVerbs, []);
        for (const q of queries) {
            const e = Dsl.parseQuery(sch, q);
            const wantSort = e.sortRaw ? [e.sortRaw.keys, e.sortRaw.dir] : null;
            const wantGroup = e.groupRaw || "";
            const wantOps = e.colOps.map(o => [o.op, o.keys]);
            const wantScoped = e.terms.filter(t => t.scoped && t.value !== "").map(t => [t.keys, t.value.toLowerCase(), t.neg]);

            // launcher / rss reader / usage panel
            const a = QueryDsl.parse(q);
            check("QueryDsl sort " + q, a.sort ? [a.sort.fields, a.sort.dir] : null, wantSort);
            check("QueryDsl group " + q, a.groupRaw, wantGroup);
            check("QueryDsl colops " + q, a.cols.map(c => [c.op === "filter" ? "ft" : (c.op === "add" ? "at" : "rt"), c.path]), wantOps);
            check("QueryDsl scoped " + q, a.terms.filter(t => t.field !== undefined && t.value !== "").map(t => [t.field, t.value, !!t.neg]), wantScoped);

            // clipboard family (notification / revit-remote / appmenu pickers share it)
            const c = ClipboardQueryDsl.parse(q, P.schema.types);
            check("Clipboard sort " + q, c.sort ? [c.sort.paths, c.sort.direction === "ascending" ? "asc" : "desc"] : null, wantSort);
            check("Clipboard group " + q, c.groupRaw, wantGroup);
            check("Clipboard colops " + q, c.columnOps.map(o => [o.verb, o.path]), wantOps);
        }
        print("qml consumers: " + (fails === 0 ? "ok" : fails + " failures"));
        Qt.quit();
    }
}
