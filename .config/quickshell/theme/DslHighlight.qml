import QtQuick

// Query-DSL syntax highlighting (query-dsl.md "Syntax highlighting"). Child of
// the search TextInput: the input's own glyphs are made transparent and this
// overlay paints the same text, with each recognised /command in the theme's
// accent colour and bold. Everything else (barewords, "phrases", paths such as
// /mnt/x, unknown /tokens) stays the normal text colour. The input still places
// the caret (drawn in Theme.text) and the selection. Colours come from Theme, i.e. the wallpaper
// palette in scheme.json.
//   spans: [{start, end, valid}] char offsets of command tokens; only valid ones are painted
Item {
    id: root
    required property TextInput input
    property var spans: []

    Binding { target: root.input; property: "color"; value: "transparent" }
    Binding { target: root.input; property: "selectedTextColor"; value: "transparent" }

    // The default caret is painted in the input's text colour, which is
    // transparent here, so supply an explicit one (the input still places
    // and blinks it).
    Binding {
        target: root.input
        property: "cursorDelegate"
        value: Component {
            Rectangle {
                width: 2
                color: Theme.text
            }
        }
    }

    // Auto-pairing of quotes (query-dsl.md "Quoted terms"): typing one quote
    // completes it. After a word (`5"`, `title:abc"`) it wraps that word
    // (`"5"`); on an empty spot it inserts the pair with the caret between;
    // before a word it wraps the word; typing the closing quote over an
    // existing one just steps past it. `'` only pairs where it could open a
    // quote (apostrophes in words stay plain). Detected from the text change
    // itself, so no picker needs its own key handler.
    property string _prev: input.text
    property bool _busy: false
    function _pair(prev, t, p) {
        const q = t.charAt(p);
        const next = t.charAt(p + 1), before = p > 0 ? t.charAt(p - 1) : "";
        const isSpace = c => c === "" || /\s/.test(c);
        const isBoundary = c => isSpace(c) || c === ":" || c === "!";
        const word = c => !isSpace(c);
        if (next === q && (q === '"' ? (t.slice(0, p).split('"').length - 1) % 2 === 1 : word(before)))
            return { text: prev, cursor: p + 1 };           // step over the closing quote
        if (q === '"' && (t.slice(0, p).split('"').length - 1) % 2 === 1)
            return null;                                     // closing a quote that is open
        if (isBoundary(before) && isSpace(next))
            return { text: t.slice(0, p + 1) + q + t.slice(p + 1), cursor: p + 1 };  // empty pair
        if (isBoundary(before) && word(next)) {              // wrap the word ahead
            let e = p + 1;
            while (e < t.length && !isSpace(t.charAt(e))) e++;
            return { text: t.slice(0, e) + q + t.slice(e), cursor: e + 1 };
        }
        if (q === '"' && word(before) && before !== '"') {   // wrap the word behind
            let b = p;
            while (b > 0 && !isBoundary(t.charAt(b - 1))) b--;
            return { text: t.slice(0, b) + q + t.slice(b, p) + q + t.slice(p + 1), cursor: p + 2 };
        }
        return null;
    }
    Connections {
        target: root.input
        function onTextChanged() {
            if (root._busy) return;
            const t = root.input.text, prev = root._prev;
            root._prev = t;
            if (t.length !== prev.length + 1) return;
            // the caret sits right after the typed char (a diff alone is
            // ambiguous when it equals its neighbour, as in "5""); fall back
            // to the diff if the caret is somewhere unexpected
            let p = root.input.cursorPosition - 1;
            if (p < 0 || t.slice(0, p) + t.slice(p + 1) !== prev) {
                p = 0;
                while (p < prev.length && prev.charAt(p) === t.charAt(p)) p++;
            }
            const c = t.charAt(p);
            if ((c !== '"' && c !== "'") || t.slice(0, p) + t.slice(p + 1) !== prev) return;
            const r = root._pair(prev, t, p);
            if (!r) return;
            root._busy = true;
            root.input.text = r.text;
            root.input.cursorPosition = r.cursor;
            root._busy = false;
            root._prev = r.text;
        }
    }

    function _esc(s) {
        return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/ /g, "&nbsp;");
    }

    readonly property string html: {
        const t = input.text;
        const hi = (spans || []).filter(s => s.valid).sort((a, b) => a.start - b.start);
        let out = "", pos = 0;
        for (const s of hi) {
            if (s.start < pos) continue;
            out += _esc(t.slice(pos, s.start));
            out += "<b><font color=\"" + Theme.cyan + "\">" + _esc(t.slice(s.start, s.end)) + "</font></b>";
            pos = s.end;
        }
        return out + _esc(t.slice(pos));
    }

    Text {
        // positionToRectangle is scroll-adjusted, so a long query that has scrolled still lines up
        x: root.input.positionToRectangle(0).x
        y: root.input.positionToRectangle(0).y
        textFormat: Text.RichText
        text: root.html
        color: Theme.text
        font: root.input.font
        wrapMode: Text.NoWrap
    }
}
