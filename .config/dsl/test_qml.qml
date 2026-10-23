import QtQuick
import "../quickshell/lib/dsl.js" as Dsl

// run: QML_XHR_ALLOW_FILE_READ=1 QT_FORCE_STDERR_LOGGING=1 QT_QPA_PLATFORM=offscreen qml6 test_qml.qml
QtObject {
    Component.onCompleted: {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("tests.json"), false);
        xhr.send();
        const T = JSON.parse(xhr.responseText);
        let fails = 0;
        const check = (name, got, want) => {
            if (JSON.stringify(got) !== JSON.stringify(want)) { fails++; print("FAIL " + name + ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want)); }
        };
        for (const c of T.resolve) check("resolve " + c.keys, Dsl.resolveNames(c.keys, c.names), c.expect);
        for (const c of T.sortkeys) check("sortkeys " + c.keys, Dsl.resolveSortKeys(c.keys, c.names), c.expect);
        for (const c of T.direction) check("direction " + c.word, Dsl.parseDirection(c.word), c.expect);
        for (const c of T.splitcmd.cases) {
            const g = Dsl.splitCmd(c.text, T.splitcmd.verbs, T.splitcmd.maxParts);
            check("splitcmd " + c.text, g ? [g.verb, g.keys, g.dir, g.bad] : null, c.expect);
        }
        for (const c of T.substr) check("substr " + c.needle + "/" + c.hay, Dsl.substr(c.needle, c.hay, c.exact), c.expect);
        for (const c of T.compare) check("compare " + c.a + "/" + c.b + "/" + c.dir, Math.sign(Dsl.compareFieldValues(c.a, c.b, c.dir)), c.sign);
        for (const c of T.tokenize) check("tokenize " + c.query, Dsl.tokenize(c.query).map(t => [t.text, t.leadQuote, t.quoted, t.neg, t.start]), c.expect);
        const G = T.group, get = (r, n) => r[n];
        for (const c of G.parse) check("group parse " + c.text, Dsl.parseGroup(c.text, G.known, G.aliases), c.expect);
        for (const c of G.value) check("group value " + c.bucket + " " + c.raw, Dsl.groupValue({ bucket: c.bucket, level: c.level }, c.raw, G.today), c.expect);
        for (const c of G.layout) check("group layout " + c.text, Dsl.groupLayout(G.rows, Dsl.parseGroup(c.text, G.known, G.aliases), get, G.today), c.expect);
        const lay = Dsl.groupLayout(G.rows, Dsl.parseGroup(G.visible.text, G.known, G.aliases), get, G.today);
        G.visible.collapsed.forEach((col, i) => { const m = {}; col.forEach(id => { m[id] = true; }); check("group visible " + JSON.stringify(col), Dsl.groupVisible(lay, m), G.visible.expect[i]); });
        for (const c of G.extract) { const r = Dsl.extractGroup(c.tokens, G.known, G.aliases); check("group extract " + c.tokens.join(" "), [r.rest, r.parsed], c.expect); }
        print("qml dsl.js: " + (fails === 0 ? "ok" : fails + " failures"));
        Qt.quit();
    }
}
