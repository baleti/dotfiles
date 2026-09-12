import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import "../theme"
import "../services"

// Application launcher -- replaces `rofi -show drun` (mod + Super_l). Just
// launches apps: icon + name, nothing else (no descriptions, no
// run-a-command / calc / window modes). Search box speaks the shared
// picker DSL (QueryDsl.qml / ~/.config/docs/query-dsl.md): bare text + /fv
// match name + generic name only (short, controlled strings - matching
// prose Comment= / Keywords= in the free haystack made `ala` hit
// "scALAble" and "bALAnce"); comment/keywords/exec/categories are
// searchable but only when named (`/fv comment:vector`). /s and /rv for
// order. The column verbs (/ft /at /rt) are inert here -- no columns.
// One instance per monitor; only the focused one is ever shown.
PanelWindow {
    id: root

    // `screen` is PanelWindow's own property, set from shell.qml's Variants
    // (do NOT redeclare it -- that shadows the real one, see NotifLayer).
    // `open` is set imperatively (not a binding) so nothing downstream of it
    // -- visible, keyboardFocus, the autocomplete -- can feed a binding loop
    // back into it.
    property bool open: false

    // Type names filterable / sortable via the DSL. `name` and `generic`
    // are also the free-text (bare / `/fv text`) haystack; the rest are
    // scoped-only, because substring-matching prose Comment= or a
    // Keywords= list produces mid-word noise (`ala` in "scalable").
    readonly property var typeNames: ["name", "generic", "comment", "exec", "categories", "keywords"]
    readonly property var typeDescs: ({
        "name": "the application name",
        "generic": "the generic name (\"Web Browser\")",
        "comment": "the freedesktop Comment= description",
        "exec": "the launch command",
        "categories": "freedesktop Categories= entries",
        "keywords": "freedesktop Keywords= entries"
    })

    function _recompute() {
        root.open = LauncherState.active && LauncherState.monitor === root.screen.name;
    }
    Component.onCompleted: root._recompute()
    Connections {
        target: LauncherState
        function onActiveChanged() { root._recompute(); }
        function onMonitorChanged() { root._recompute(); }
    }

    onOpenChanged: {
        if (root.open) {
            query.text = "";
            root.selected = 0;
            ac.visible = false;
            root.acVerbMulti = false;
            focusGrab.active = true;
            Qt.callLater(() => query.forceActiveFocus());
        } else {
            focusGrab.active = false;
        }
    }
    function hide() { LauncherState.close(); }

    // ---- app records -- recomputed when the desktop-entry set changes ---
    readonly property var apps: {
        const out = [];
        const list = DesktopEntries.applications.values;
        for (let i = 0; i < list.length; i++) {
            const e = list[i];
            if (e.noDisplay)
                continue;
            const cats = (e.categories || []).map(c => String(c));
            const kws = (e.keywords || []).map(c => String(c));
            out.push({
                entry: e,
                id: e.id || "",
                name: e.name || "",
                comment: e.comment || "",
                generic: e.genericName || "",
                exec: e.execString || "",
                categories: cats,
                keywords: kws,
                haystack: [e.name, e.genericName]
                    .filter(s => !!s).join(" ").toLowerCase(),
            });
        }
        return out;
    }

    // ---- query -> results ------------------------------------------
    property var parsed: QueryDsl.parse(query.text)
    property int selected: 0

    function _fieldVals(app, field) {
        switch (field) {
        case "name": return [app.name];
        case "generic": return [app.generic];
        case "comment": return [app.comment];
        case "exec": return [app.exec];
        case "categories": return app.categories;
        case "keywords": return app.keywords;
        }
        return [];
    }

    function _matches(app, term) {
        if (term.text !== undefined)
            return app.haystack.indexOf(term.text) >= 0;
        // scoped path:value
        const fields = QueryDsl.resolvePath(term.field, root.typeNames);
        if (fields.length === 0)
            return false; // unresolvable complete path -> narrows to nothing
        for (const f of fields) {
            for (const v of root._fieldVals(app, f)) {
                if (String(v).toLowerCase().indexOf(term.value) >= 0)
                    return true;
            }
        }
        return false;
    }

    // Rank: exact name, name-prefix, name-substring, other -- then alpha.
    function _rank(app) {
        let firstText = "";
        for (const t of root.parsed.terms)
            if (t.text !== undefined) { firstText = t.text; break; }
        if (firstText.length === 0)
            return 3;
        const n = app.name.toLowerCase();
        if (n === firstText) return 0;
        if (n.startsWith(firstText)) return 1;
        if (n.indexOf(firstText) >= 0) return 2;
        return 3;
    }

    readonly property var results: {
        let rows = root.apps.filter(app => root.parsed.terms.every(t => root._matches(app, t)));

        const s = root.parsed.sort;
        // Each chain segment must resolve to exactly one field (query-dsl.md
        // "/sort"); any segment that doesn't makes the *whole* /sort inert,
        // not just that key -- falls through to the default order below.
        const sortFields = s ? s.fields.map(p => QueryDsl.resolvePath(p, root.typeNames)) : null;
        if (s && sortFields.every(fl => fl.length === 1)) {
            const keys = sortFields.map(fl => fl[0]);
            rows = rows.slice().sort((a, b) => {
                for (const f of keys) {
                    const av = root._fieldVals(a, f)[0] || "";
                    const bv = root._fieldVals(b, f)[0] || "";
                    const c = QueryDsl.compareFieldValues(av, bv, s.dir);
                    if (c !== 0) return c;
                }
                return 0;
            });
        } else {
            // rank first (only meaningful when text was typed), then launch
            // frecency, then alphabetical.
            rows = rows.slice().sort((a, b) => {
                const r = root._rank(a) - root._rank(b);
                if (r !== 0) return r;
                const f = LauncherHistory.score(b.id) - LauncherHistory.score(a.id);
                if (f !== 0) return f;
                return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1;
            });
        }
        if (root.parsed.reverse)
            rows = rows.slice().reverse();
        return rows;
    }

    onResultsChanged: {
        if (root.selected >= results.length)
            root.selected = Math.max(0, results.length - 1);
        root._measure();
    }

    function launch(i) {
        const app = root.results[i];
        if (!app) return;
        LauncherHistory.bump(app.id);
        app.entry.execute();
        root.hide();
    }

    // Resolve every app's icon name to a real file path once the entry set
    // is known (quickshell's own provider misses the hicolor fallback here).
    onAppsChanged: LauncherIcons.resolve(root.apps.map(a => a.entry.icon))

    // Every field currently `/fv field:value`-scoped by the query, deduped
    // - shown as an extra line under the app name (see the results
    // delegate) even though this launcher has no general column system,
    // so a hidden field (comment/keywords/...) that matched is visible
    // rather than left a mystery. query-dsl.md's "Auto-shown filter fields"
    // - includes `openPaths` (a via path named but not yet valued, e.g.
    // `/fv/comment` with nothing after it yet) so the field shows the
    // moment the command names it, not just once a value narrows anything;
    // an unresolvable path (typo, still mid-typing) resolves to nothing
    // here exactly like it already does for a complete term.
    readonly property var referencedFields: {
        const out = [];
        for (const t of root.parsed.terms) {
            if (t.field === undefined) continue;
            for (const f of QueryDsl.resolvePath(t.field, root.typeNames))
                if (out.indexOf(f) < 0) out.push(f);
        }
        for (const p of root.parsed.openPaths) {
            for (const f of QueryDsl.resolvePath(p, root.typeNames))
                if (out.indexOf(f) < 0) out.push(f);
        }
        return out;
    }

    // ---- autocomplete (marginalia-style) --------------------------
    // Rows carry: what accepting inserts (`text`), the short label, the
    // long-form alias, and a one-line description -- alias + desc rendered
    // grey, like emacs marginalia / zsh completion hints. Stages: verb
    // (`/frag`, only the verbs that do something here) and `/fv path`
    // (before the `:`), including the bare `/fv ` / `/s ` case (empty
    // fragment -> all candidates).
    readonly property var _acVerbs: ["/fv", "/s", "/rv"] // /ft /at /rt are inert here

    // ---- inline command-validity coloring (query-dsl.md) -----------
    // True if `v` (leading "/" included) is still a genuine prefix of some
    // real verb form - not wrong yet, just incomplete, so `_commandSpans`
    // leaves it in the default text color rather than either accent.
    function _isVerbPrefix(v) {
        if (v.length <= 1) return false; // just "/" - too early to call wrong
        const forms = QueryDsl.shortVerbs.concat(Object.keys(QueryDsl.verbAliases));
        return forms.some(f => f.startsWith(v));
    }

    // Every `/`-led token in `text` that's unambiguously a command attempt
    // - {start, end, valid} for each (byte/char offsets into `text`,
    // since JS strings are UTF-16 code units the same way QML text
    // positions are). Ported from winswitch's query.rs::command_spans.
    function _commandSpans(text) {
        const spans = [];
        let i = 0;
        while (i < text.length) {
            while (i < text.length && text[i] === " ") i++;
            if (i >= text.length) break;
            const start = i;
            if (text[i] === '"') {
                const end = text.indexOf('"', i + 1);
                i = end < 0 ? text.length : end + 1;
                continue; // quoted literal - never a command
            }
            let j = i;
            while (j < text.length && text[j] !== " ") j++;
            const tok = text.slice(i, j);
            i = j;
            if (tok.length > 1 && tok[0] === "/") {
                if (QueryDsl.canonVerb({ q: false, v: tok })) {
                    spans.push({ start, end: start + tok.length, valid: true });
                } else if (!root._isVerbPrefix(tok)) {
                    spans.push({ start, end: start + tok.length, valid: false });
                }
                // else: still forming - neutral, no span at all
            }
        }
        return spans;
    }

    // The full Verb-stage vocabulary: the three verbs that do anything here
    // (`_acVerbs`) plus `/fv` and `/s` - the two that take a real path -
    // crossed with every type name ("fv/comment", "s/name", ...), so a
    // fragment of the *type*, not just the verb, reaches a whole working
    // command. `/rv` isn't crossed (takes no path). See query-dsl.md's
    // "Verb-stage depth".
    function _verbStageUniverse() {
        const bare = root._acVerbs.map(v => v.slice(1));
        const deep = [];
        for (const v of ["fv", "s"])
            for (const n of root.typeNames)
                deep.push(v + "/" + n);
        return bare.concat(deep);
    }

    // Turns one universe entry ("fv", or the deep "fv/comment") into an
    // autocomplete row, given the query prefix before the completion's
    // opening "/". A deep `/fv` candidate lands the colon form
    // ("/fv comment:"), matching how the plain type-path stage below
    // already lands here (query-dsl.md: "the GTK pickers and app launcher
    // still land the : form"); `/s` lands its ordinary space form.
    function _verbStageItem(prefix, v) {
        const slash = v.indexOf("/");
        if (slash < 0) {
            return { text: prefix + "/" + v + " ", label: "/" + v,
                     alias: QueryDsl.verbInfo["/" + v].long, desc: QueryDsl.verbInfo["/" + v].desc };
        }
        const verb = v.slice(0, slash), name = v.slice(slash + 1);
        const text = verb === "fv" ? `${prefix}/${verb} ${name}:` : `${prefix}/${verb} ${name} `;
        return { text, label: "/" + v, alias: QueryDsl.verbInfo["/" + verb].long, desc: root.typeDescs[name] || "" };
    }

    // Ctrl+Space AND-narrowing (query-dsl.md): true while a Verb-stage
    // popup is being narrowed by more than one space-separated fragment;
    // `acVerbMultiStart` freezes the char offset of that completion's
    // opening "/". See the Ctrl+Space key handler below.
    property bool acVerbMulti: false
    property int acVerbMultiStart: 0

    function _acCandidates() {
        const t = query.text;

        if (root.acVerbMulti) {
            if (root.acVerbMultiStart < t.length && t[root.acVerbMultiStart] === "/") {
                const frags = t.slice(root.acVerbMultiStart + 1).split(/\s+/).filter(f => f.length > 0);
                const prefix = t.slice(0, root.acVerbMultiStart);
                return root._verbStageUniverse()
                    .filter(v => frags.every(f => v.indexOf(f) >= 0))
                    .map(v => root._verbStageItem(prefix, v));
            }
            root.acVerbMulti = false;
        }

        const vm = t.match(/(?:^|\s)(\/[a-z-]*)$/);
        if (vm) {
            const frag = vm[1].slice(1);
            const prefix = t.slice(0, t.length - vm[1].length);
            return root._verbStageUniverse().filter(v => v.indexOf(frag) >= 0).map(v => root._verbStageItem(prefix, v));
        }

        const pm = t.match(/(?:\/fv|\/filter-value|\/s|\/sort)\s+([a-z.]*)$/);
        if (pm && t.indexOf(":", t.length - pm[1].length) < 0) {
            const frag = pm[1];
            const isFv = /\/fv|\/filter-value/.test(t.slice(0, t.length - frag.length));
            return root.typeNames.filter(n => n.indexOf(frag) >= 0).map(n => ({
                text: t.slice(0, t.length - frag.length) + n + (isFv ? ":" : " "),
                label: n, alias: "", desc: root.typeDescs[n] || ""
            }));
        }
        return [];
    }
    // Tab-triggered to *open* (see _triggerCompletion) - typing alone
    // never opens it from nothing, only narrows it once it's already open
    // (query's onTextChanged) - a popup that popped open on every
    // keystroke was obtrusive and could steal focus at the wrong moment.
    // A plain property rather than a binding on query.text since it needs
    // to stay whatever it last was (open or closed) across keystrokes,
    // not recompute unconditionally on every one.
    property var acItems: []
    property int acSel: 0
    onAcItemsChanged: {
        ac.visible = acItems.length > 0;
        acSel = 0;
        if (!ac.visible) root.acVerbMulti = false;
    }

    function _applyAcItem(it) {
        if (!it) return;
        query.text = it.text;
        query.cursorPosition = query.text.length;
    }

    function acAccept() {
        root._applyAcItem(root.acItems[root.acSel]);
    }

    // Tab's entire job when the popup isn't already open: a single
    // candidate completes immediately with no popup ever shown, same as
    // ordinary shell tab-completion; 2+ reveals the popup (via
    // onAcItemsChanged) so Up/Down can choose one. Returns whether it
    // found anything to do.
    function _triggerCompletion() {
        const items = root._acCandidates();
        if (items.length === 0) return false;
        if (items.length === 1) {
            root._applyAcItem(items[0]);
            return true;
        }
        root.acSel = 0;
        root.acItems = items;
        return true;
    }

    // ---- dynamic card width: fit the widest visible name -----------
    // Measured imperatively (from onResultsChanged) into a plain property --
    // reading TextMetrics.width inside the width *binding* while also
    // setting its text there is a binding loop.
    TextMetrics {
        id: nameMetrics
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize - 1
    }
    property real _widestName: 0
    function _measure() {
        let w = 0;
        const n = Math.min(root.results.length, 13);
        for (let i = 0; i < n; i++) {
            nameMetrics.text = root.results[i].name;
            if (nameMetrics.width > w) w = nameMetrics.width;
        }
        root._widestName = w;
    }
    // icon gutter (40) + name + right padding (28); floored so the search
    // box always fits, capped so it never sprawls.
    readonly property real cardWidth: Math.max(360, Math.min(560, root._widestName + 68))

    // ---- window -------------------------------------------------
    // Sized box with partial anchors, not a 4-edge full-screen anchor -- the
    // latter is an Overlay surface that doesn't reliably map on every output
    // here (the volume OSD's unresolved bug); NotifLayer proved this shape
    // maps everywhere.
    anchors { top: true; left: true }
    implicitWidth: root.screen ? root.screen.width : 1920
    implicitHeight: root.screen ? root.screen.height : 1080
    color: "transparent"
    visible: root.open
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    WlrLayershell.namespace: "quickshell-launcher"
    exclusionMode: ExclusionMode.Ignore

    HyprlandFocusGrab {
        id: focusGrab
        windows: [root]
        onCleared: root.hide()
    }

    // Transparent backdrop -- no dim. Click outside the card closes.
    MouseArea {
        anchors.fill: parent
        onClicked: root.hide()
    }

    Rectangle {
        id: card
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        width: root.cardWidth
        // Fixed at 60% of the screen height, centred -- the results list
        // fills whatever's left under the search box (and the autocomplete
        // popup when it's up).
        height: Math.round((root.screen ? root.screen.height : 1080) * 0.6)
        radius: Theme.rounding
        color: Theme.bgAlpha
        // Thin border in the wallpaper-derived accent (scheme.primary).
        border.color: Theme.cyan
        border.width: 1

        Behavior on width { NumberAnimation { duration: 90; easing.type: Easing.OutQuad } }
        // Swallow clicks so they don't reach the backdrop.
        MouseArea { anchors.fill: parent }

        Item {
            id: header
            width: parent.width
            height: 44

            Text {
                id: prompt
                anchors.verticalCenter: parent.verticalCenter
                x: 16
                text: "" // magnifier
                font.family: Theme.iconFontFamily
                font.pixelSize: Theme.fontSize
                color: Theme.textDim
            }

            TextInput {
                id: query
                anchors.verticalCenter: parent.verticalCenter
                x: 40
                width: parent.width - 56
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize + 1
                color: Theme.text
                selectionColor: Theme.cyan
                selectByMouse: true
                clip: true
                // Once the popup is already open, keep recomputing
                // candidates from the new text instead of clearing --
                // narrows the list as you type (e.g. `/` + Tab shows every
                // verb, typing `f` narrows to /fv) rather than closing and
                // forcing another Tab press. Typing while nothing's open
                // still doesn't spontaneously show anything (`ac.visible`
                // check below), matching "Tab-triggered, never live".
                // Also fires (harmlessly) when accepting a completion sets
                // this text itself, on an already-open (fine, recomputes
                // to the same thing) or already-closed (no-op) popup.
                onTextChanged: root.acItems = ac.visible ? root._acCandidates() : []

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("search apps   ·   / ")
                    color: Theme.muted
                    font: query.font
                    visible: query.text.length === 0
                }

                // Inline command-validity coloring (query-dsl.md): an
                // underline under each `/command` token, not a recolored
                // glyph - TextInput has no per-range text styling to hook
                // (unlike GTK's Pango-backed Entry, see winswitch's
                // apply_command_colors), and coloring the *whole* input
                // would falsely tint bare filter words alongside it, so an
                // underline positioned via positionToRectangle (already
                // scroll-adjusted, unlike a manual TextMetrics measurement)
                // is the safe middle ground: real color signal, zero risk
                // to the TextInput's own text/cursor/selection rendering.
                Repeater {
                    model: query.text.length ? root._commandSpans(query.text) : []
                    Rectangle {
                        required property var modelData
                        x: query.positionToRectangle(modelData.start).x
                        y: query.positionToRectangle(modelData.start).y
                           + query.positionToRectangle(modelData.start).height - 2
                        width: Math.max(1, query.positionToRectangle(modelData.end).x - x)
                        height: 2
                        radius: 1
                        color: modelData.valid ? Theme.cyan : Theme.red
                    }
                }

                // Standard completion-menu convention (reported 2026-09-09
                // against winswitch's identical pattern -- accepting on
                // every Tab press without ever letting you cycle through
                // options was confusing): the first Tab opens the popup;
                // every Tab after that just moves the highlight, the same
                // as Down/Ctrl+j; Enter is the one key that actually
                // accepts the highlighted suggestion.
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Escape) {
                        if (ac.visible) { ac.visible = false; root.acVerbMulti = false; }
                        else root.hide();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        if (ac.visible) root.acAccept();
                        else root.launch(root.selected);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Tab) {
                        if (ac.visible)
                            root.acSel = (root.acSel + (event.modifiers & Qt.ShiftModifier ? -1 : 1) + root.acItems.length) % root.acItems.length;
                        else
                            root._triggerCompletion();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Space && ac.visible && (event.modifiers & Qt.ControlModifier)) {
                        // AND-narrows instead of accepting (query-dsl.md):
                        // only meaningful once the popup's on a Verb-stage
                        // fragment - `_acCandidates`'s multi branch is a
                        // no-op otherwise (empty universe cross), so this
                        // just always tries it rather than re-deriving the
                        // current stage here too.
                        const vm = query.text.match(/(?:^|\s)(\/[a-z-]*)$/);
                        if (vm || root.acVerbMulti) {
                            if (!root.acVerbMulti) {
                                root.acVerbMulti = true;
                                root.acVerbMultiStart = query.text.length - vm[1].length;
                            }
                            query.insert(query.cursorPosition, " ");
                        }
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Space && ac.visible) {
                        root.acAccept();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Down
                               || (event.key === Qt.Key_J && (event.modifiers & Qt.ControlModifier))) {
                        if (ac.visible) root.acSel = Math.min(root.acItems.length - 1, root.acSel + 1);
                        else root.selected = Math.min(root.results.length - 1, root.selected + 1);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Up
                               || (event.key === Qt.Key_K && (event.modifiers & Qt.ControlModifier))) {
                        if (ac.visible) root.acSel = Math.max(0, root.acSel - 1);
                        else root.selected = Math.max(0, root.selected - 1);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_PageDown) {
                        if (ac.visible) root.acSel = Math.min(root.acItems.length - 1, root.acSel + 7);
                        else root.selected = Math.min(root.results.length - 1,
                                                       root.selected + Math.max(1, Math.floor(list.height / 30)));
                        event.accepted = true;
                    } else if (event.key === Qt.Key_PageUp) {
                        if (ac.visible) root.acSel = Math.max(0, root.acSel - 7);
                        else root.selected = Math.max(0, root.selected - Math.max(1, Math.floor(list.height / 30)));
                        event.accepted = true;
                    }
                }
            }

            Rectangle { // divider
                anchors.bottom: parent.bottom
                width: parent.width
                height: 1
                color: Theme.border
            }
        }

        // Autocomplete popup, in-layout under the header (like the GTK
        // pickers). Each row: label, then the long-form alias and a
        // one-line description, both dim (marginalia).
        Column {
            id: ac
            visible: false
            anchors.top: header.bottom
            width: parent.width
            height: visible ? Math.min(root.acItems.length, 7) * 24 + 8 : 0
            clip: true
            padding: 4

            Repeater {
                model: root.acItems
                Rectangle {
                    id: acRow
                    required property var modelData
                    required property int index
                    readonly property bool cur: index === root.acSel
                    width: ac.width - 8
                    height: 24
                    radius: Theme.rounding - 5
                    color: cur ? Qt.rgba(Theme.cyan.r, Theme.cyan.g, Theme.cyan.b, 0.18) : "transparent"

                    Row {
                        id: acFields
                        anchors.verticalCenter: parent.verticalCenter
                        x: 10
                        spacing: 8

                        Text {
                            id: acLabel
                            text: acRow.modelData.label
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 1
                            color: acRow.cur ? Theme.cyan : Theme.text
                        }
                        Text {
                            visible: !!acRow.modelData.alias
                            anchors.baseline: acLabel.baseline
                            text: "(" + acRow.modelData.alias + ")"
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                            color: Theme.muted
                        }
                        Text {
                            anchors.baseline: acLabel.baseline
                            text: acRow.modelData.desc
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                            color: Theme.textDim
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: { root.acSel = acRow.index; root.acAccept(); }
                    }
                }
            }
        }

        ListView {
            id: list
            anchors.top: ac.visible ? ac.bottom : header.bottom
            anchors.bottom: parent.bottom
            width: parent.width
            clip: true
            model: root.results
            currentIndex: root.selected
            boundsBehavior: Flickable.StopAtBounds
            topMargin: 4
            bottomMargin: 4

            // One compact line per entry: icon + name -- plus, once a
            // `/fv field:value` term is actively scoping the query, a second
            // dim line showing that field's own value (query-dsl.md's
            // "Auto-shown filter fields") - this launcher has no general
            // column system, but a hidden field (comment/keywords/...) that
            // matched shouldn't stay invisible once there's more than one
            // candidate left to choose between.
            delegate: Rectangle {
                id: row
                required property var modelData
                required property int index
                readonly property string extraText: {
                    if (root.referencedFields.length === 0) return "";
                    const parts = [];
                    for (const f of root.referencedFields)
                        for (const v of root._fieldVals(modelData, f)) {
                            const s = String(v);
                            if (s) parts.push(s);
                        }
                    return parts.join("  ·  ");
                }
                width: list.width
                height: row.extraText ? 44 : 30
                color: index === root.selected ? Qt.rgba(Theme.cyan.r, Theme.cyan.g, Theme.cyan.b, 0.16)
                                               : "transparent"

                Image {
                    id: appIcon
                    x: 10
                    anchors.verticalCenter: parent.verticalCenter
                    width: 20
                    height: 20
                    sourceSize.width: 40
                    sourceSize.height: 40
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    // Our own XDG resolution first, quickshell's provider as
                    // a fallback for anything it misses.
                    source: LauncherIcons.pathFor(modelData.entry.icon)
                            || Quickshell.iconPath(modelData.entry.icon, "application-x-executable")
                }
                // Generic glyph when no icon resolves at all.
                Text {
                    anchors.centerIn: appIcon
                    visible: appIcon.status !== Image.Ready
                    text: ""
                    font.family: Theme.iconFontFamily
                    font.pixelSize: 14
                    color: Theme.textDim
                }

                Column {
                    x: 40
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 52
                    spacing: 1

                    Text {
                        width: parent.width
                        text: row.modelData.name
                        elide: Text.ElideRight
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 1
                        color: Theme.text
                    }
                    Text {
                        visible: !!row.extraText
                        width: parent.width
                        text: row.extraText
                        elide: Text.ElideRight
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 2
                        color: Theme.textDim
                        opacity: 0.7
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: root.selected = index
                    onClicked: root.launch(index)
                }
            }
        }
    }
}
