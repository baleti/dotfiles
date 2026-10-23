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
        // positionToRectangle() itself doesn't notify, so also depend on
        // cursorRectangle/contentHeight to re-evaluate once layout settles
        // (otherwise y stuck at 0 in a vertically centred input = too high).
        x: (root.input.cursorRectangle, root.input.contentWidth, root.input.positionToRectangle(0).x)
        y: (root.input.cursorRectangle, root.input.contentHeight, root.input.height, root.input.positionToRectangle(0).y)
        textFormat: Text.RichText
        text: root.html
        color: Theme.text
        font: root.input.font
        wrapMode: Text.NoWrap
    }
}
