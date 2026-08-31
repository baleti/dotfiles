import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import "../theme"
import "../services"
import "../launcher" // QueryDsl -- shared picker DSL, see query-dsl.md

// Graphical RSS reader (mod + R). Master-detail: article list on the left,
// reading pane on the right. All feed fetching / XML + HTML parsing /
// sanitising / image validation happens in rssd (Python + feedparser); this
// panel only renders the JSON rssd writes to ~/.cache/rssd/ and shells out
// to `rssd` for a manual refresh. The reading pane renders rssd's
// already-sanitised content_html with Qt's QTextDocument (Text.RichText) --
// no web engine, no scripting, and remote <img> were stripped upstream.
//
// Window / focus-grab boilerplate mirrors launcher/AppLauncher.qml (sized
// box + partial anchors, HyprlandFocusGrab, per-monitor instance shown only
// on the focused output).
PanelWindow {
    id: root

    property bool open: false

    function _recompute() {
        root.open = RssReaderState.active && RssReaderState.monitor === root.screen.name;
    }
    Component.onCompleted: root._recompute()
    Connections {
        target: RssReaderState
        function onActiveChanged() { root._recompute(); }
        function onMonitorChanged() { root._recompute(); }
    }

    onOpenChanged: {
        if (root.open) {
            search.text = "";
            search.focus = false; // don't let a stale focus-scope memory re-trap into search on reopen
            focusGrab.active = true;
            Qt.callLater(() => keyScope.forceActiveFocus());
            if (RssSvc.items.length === 0)
                RssSvc.refresh();
        } else {
            focusGrab.active = false;
        }
    }
    function hide() { RssReaderState.close(); }

    // ---- filtering ------------------------------------------------
    property bool unreadOnly: false
    property string tagFilter: ""
    property int selected: 0

    // Search box speaks the shared picker DSL (QueryDsl.qml /
    // ~/.config/docs/query-dsl.md): bare text + /fv over title/feed/tag/
    // author, /s + /rv for order. /ft /at /rt are inert -- this is a list,
    // not a column view.
    readonly property var typeNames: ["title", "feed", "author", "tag", "date"]
    readonly property var typeDescs: ({
        "title": "article title",
        "feed": "source feed name",
        "author": "article author",
        "tag": "assigned tag",
        "date": "published/fetched date"
    })

    function _fieldVals(item, field) {
        switch (field) {
        case "title": return [item.title || ""];
        case "feed": return [item.feed_title || ""];
        case "author": return [item.author || ""];
        case "tag": return item.tags || [];
        case "date": return [item.sortKey || ""];
        }
        return [];
    }

    property var parsed: QueryDsl.parse(search.text)

    function _matches(item, term) {
        if (term.text !== undefined) {
            const hay = (item.title + " " + item.feed_title + " "
                         + (item.author || "") + " " + (item.tags || []).join(" ")).toLowerCase();
            return hay.indexOf(term.text) >= 0;
        }
        // scoped path:value
        const fields = QueryDsl.resolvePath(term.field, root.typeNames);
        if (fields.length === 0)
            return false; // unresolvable complete path -> narrows to nothing
        for (const f of fields) {
            for (const v of root._fieldVals(item, f)) {
                if (String(v).toLowerCase().indexOf(term.value) >= 0)
                    return true;
            }
        }
        return false;
    }

    readonly property var view: {
        RssSvc.readRevision; // dependency
        root.parsed; // dependency
        let rows = [];
        for (let i = 0; i < RssSvc.items.length; i++) {
            const it = RssSvc.items[i];
            if (root.unreadOnly && RssSvc.isRead(it.key))
                continue;
            if (root.tagFilter && (it.tags || []).indexOf(root.tagFilter) < 0)
                continue;
            if (!root.parsed.terms.every(t => root._matches(it, t)))
                continue;
            rows.push(it);
        }

        const s = root.parsed.sort;
        if (s) {
            const fields = QueryDsl.resolvePath(s.field, root.typeNames);
            const f = fields.length === 1 ? fields[0] : (fields[0] || "title");
            rows = rows.slice().sort((a, b) => {
                const av = String(root._fieldVals(a, f)[0] || "").toLowerCase();
                const bv = String(root._fieldVals(b, f)[0] || "").toLowerCase();
                const c = av < bv ? -1 : (av > bv ? 1 : 0);
                return s.dir === "desc" ? -c : c;
            });
        } // else: RssSvc.items' own newest-first order stands

        if (root.parsed.reverse)
            rows = rows.slice().reverse();
        return rows;
    }
    onViewChanged: {
        if (root.selected >= view.length)
            root.selected = Math.max(0, view.length - 1);
    }
    readonly property var current: view[root.selected] || null

    // Mark the selected article read a moment after you land on it with the
    // keyboard -- armed only by move()/g, never self-re-arming, so an
    // unread-only view doesn't silently drain itself while you're idle.
    Timer {
        id: dwell
        interval: 1100
        onTriggered: if (root.current) RssSvc.markRead(root.current.key)
    }

    // FocusScope remembers the last-focused child within it, so a bare
    // keyScope.forceActiveFocus() while `search` still holds focus just gets
    // redirected straight back into `search` -- clearing its focus first is
    // what actually lets the scope (and its own Keys.onPressed) take over.
    function _returnFocusToList() {
        search.focus = false;
        keyScope.forceActiveFocus();
    }

    // ---- autocomplete (marginalia-style, mirrors launcher/AppLauncher.qml)
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
    // - {start, end, valid} for each. Ported from winswitch's
    // query.rs::command_spans (see AppLauncher.qml for the identical copy).
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

    function _acCandidates() {
        const t = search.text;

        const vm = t.match(/(?:^|\s)(\/[a-z-]*)$/);
        if (vm) {
            const frag = vm[1].slice(1);
            return root._acVerbs.filter(v => v.indexOf(frag) >= 0).map(v => ({
                text: v + " ", label: v,
                alias: QueryDsl.verbInfo[v].long, desc: QueryDsl.verbInfo[v].desc
            }));
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
    // Tab-triggered only (see _triggerCompletion) - never recomputed just
    // from typing, so this stays a plain property rather than a binding
    // on search.text; a popup that popped open on every keystroke was
    // obtrusive and could steal focus at the wrong moment.
    property var acItems: []
    property int acSel: 0
    // Escape sets this instead of writing to `ac.visible` directly -- an
    // imperative write there would permanently sever the declarative
    // visibility binding below (same trap as forceActiveFocus() vs. `focus:`
    // bindings, see _returnFocusToList). New matches clear the dismissal.
    property bool acDismissed: false
    onAcItemsChanged: { acSel = 0; acDismissed = false; }

    function _applyAcItem(it) {
        if (!it) return;
        search.text = it.text;
        search.cursorPosition = search.text.length;
    }

    function acAccept() {
        root._applyAcItem(root.acItems[root.acSel]);
    }

    // Tab's entire job when the popup isn't already open: a single
    // candidate completes immediately with no popup ever shown, same as
    // ordinary shell tab-completion; 2+ reveals the popup so Up/Down can
    // choose one. Returns whether it found anything to do, so the caller
    // (which also gives Tab the search<->list focus-toggle meaning) knows
    // when to fall through to that instead.
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

    function openCurrent() {
        if (!root.current)
            return;
        Qt.openUrlExternally(root.current.link);
        RssSvc.markRead(root.current.key);
    }
    function move(d) {
        root.selected = Math.max(0, Math.min(root.view.length - 1, root.selected + d));
        listView.positionViewAtIndex(root.selected, ListView.Contain);
        dwell.restart();
    }

    // ---- window ---------------------------------------------------
    anchors { top: true; left: true }
    implicitWidth: root.screen ? root.screen.width : 1920
    implicitHeight: root.screen ? root.screen.height : 1080
    color: "transparent"
    visible: root.open
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    WlrLayershell.namespace: "quickshell-rssreader"
    exclusionMode: ExclusionMode.Ignore

    HyprlandFocusGrab {
        id: focusGrab
        windows: [root]
        onCleared: root.hide()
    }

    // dim backdrop; click outside closes
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.35)
        MouseArea { anchors.fill: parent; onClicked: root.hide() }
    }

    FocusScope {
        id: keyScope
        anchors.fill: parent
        focus: root.open

        Keys.onPressed: event => {
            const k = event.key;
            if (k === Qt.Key_Escape) {
                root.hide();
            } else if (k === Qt.Key_J || k === Qt.Key_Down) {
                root.move(1);
            } else if (k === Qt.Key_K || k === Qt.Key_Up) {
                root.move(-1);
            } else if (k === Qt.Key_G) {
                root.selected = (event.modifiers & Qt.ShiftModifier)
                    ? root.view.length - 1 : 0;
                listView.positionViewAtIndex(root.selected, ListView.Contain);
                dwell.restart();
            } else if (k === Qt.Key_PageDown) {
                root.move(10);
            } else if (k === Qt.Key_PageUp) {
                root.move(-10);
            } else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_O) {
                root.openCurrent();
            } else if (k === Qt.Key_M) {
                if (root.current) RssSvc.toggleRead(root.current.key);
            } else if (k === Qt.Key_A) {
                RssSvc.markReadKeys(root.view.map(i => i.key));
            } else if (k === Qt.Key_U) {
                root.unreadOnly = !root.unreadOnly;
            } else if (k === Qt.Key_R) {
                RssSvc.refresh();
            } else if (k === Qt.Key_Slash) {
                search.forceActiveFocus();
                search.selectAll();
            } else if (k === Qt.Key_Tab) {
                if (search.activeFocus) root._returnFocusToList();
                else search.forceActiveFocus();
            } else {
                return; // don't accept -- let it fall through
            }
            event.accepted = true;
        }

        Rectangle {
            id: card
            anchors.centerIn: parent
            width: Math.min(1180, parent.width - 100)
            height: Math.min(840, parent.height - 100)
            radius: Theme.rounding
            color: Theme.bgAlpha
            border.color: Theme.cyan
            border.width: 1
            clip: true

            MouseArea { anchors.fill: parent } // swallow backdrop clicks

            // ---- header ------------------------------------------
            Item {
                id: header
                // above tagRow/body (declared later, same default z) so the
                // autocomplete popup -- taller than the header itself --
                // isn't painted underneath the article list.
                z: 10
                width: parent.width
                height: 48

                Text {
                    id: brand
                    x: 18
                    anchors.verticalCenter: parent.verticalCenter
                    text: Icons.rss + "  RSS"
                    font.family: Theme.iconFontFamily
                    font.pixelSize: Theme.fontSize + 1
                    color: Theme.orange
                }
                Text {
                    anchors.left: brand.right
                    anchors.leftMargin: 10
                    anchors.baseline: brand.baseline
                    text: RssSvc.unreadCount + " unread · " + root.view.length + " shown"
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                    color: Theme.muted
                }

                Row {
                    anchors.right: parent.right
                    anchors.rightMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 8

                    // search
                    Item {
                        id: searchWrap
                        width: 240
                        height: 28

                        Rectangle {
                            id: searchBox
                            anchors.fill: parent
                            radius: Theme.rounding - 4
                            color: Qt.rgba(1, 1, 1, 0.06)
                            border.width: search.activeFocus ? 1 : 0
                            border.color: Theme.cyan

                            Text {
                                x: 8
                                anchors.verticalCenter: parent.verticalCenter
                                text: ""
                                font.family: Theme.iconFontFamily
                                font.pixelSize: Theme.fontSize - 2
                                color: Theme.muted
                            }
                            TextInput {
                                id: search
                                x: 26
                                width: parent.width - 34
                                anchors.verticalCenter: parent.verticalCenter
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 1
                                color: Theme.text
                                selectionColor: Theme.cyan
                                selectByMouse: true
                                clip: true
                                // Any further typing past a shown popup
                                // closes it, same as a shell or IDE - Tab
                                // recomputes it fresh for wherever the
                                // cursor is now (see _triggerCompletion).
                                // Also fires (harmlessly, on an
                                // already-empty acItems) when accepting a
                                // completion sets this text itself.
                                onTextChanged: root.acItems = []
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "filter… (/ for DSL)"
                                    color: Theme.muted
                                    font: search.font
                                    visible: search.text.length === 0 && !search.activeFocus
                                }

                                // Inline command-validity coloring
                                // (query-dsl.md): an underline under each
                                // `/command` token, not a recolored glyph -
                                // see AppLauncher.qml's identical copy for
                                // why (no per-range text styling on
                                // TextInput, and positionToRectangle stays
                                // correct under scrolling where a manual
                                // TextMetrics measurement wouldn't).
                                Repeater {
                                    model: search.text.length ? root._commandSpans(search.text) : []
                                    Rectangle {
                                        required property var modelData
                                        x: search.positionToRectangle(modelData.start).x
                                        y: search.positionToRectangle(modelData.start).y
                                           + search.positionToRectangle(modelData.start).height - 2
                                        width: Math.max(1, search.positionToRectangle(modelData.end).x - x)
                                        height: 2
                                        radius: 1
                                        color: modelData.valid ? Theme.cyan : Theme.red
                                    }
                                }

                                Keys.onPressed: e => {
                                    if (e.key === Qt.Key_Escape) {
                                        if (ac.visible) root.acDismissed = true;
                                        else if (search.text.length) search.text = "";
                                        else root._returnFocusToList();
                                        e.accepted = true;
                                    } else if (e.key === Qt.Key_Tab) {
                                        if (ac.visible) { root.acAccept(); e.accepted = true; }
                                        else if (root._triggerCompletion()) { e.accepted = true; }
                                        // else: fall through to keyScope's
                                        // search<->list Tab toggle.
                                    } else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                                        root._returnFocusToList();
                                        e.accepted = true;
                                    } else if (e.key === Qt.Key_Down) {
                                        if (ac.visible) root.acSel = Math.min(root.acItems.length - 1, root.acSel + 1);
                                        else root._returnFocusToList();
                                        e.accepted = true;
                                    } else if (e.key === Qt.Key_Up) {
                                        if (ac.visible) root.acSel = Math.max(0, root.acSel - 1);
                                        else root._returnFocusToList();
                                        e.accepted = true;
                                    }
                                }
                            }
                        }

                        // Autocomplete popup (marginalia-style, see
                        // launcher/AppLauncher.qml): label, long-form alias,
                        // one-line description.
                        Rectangle {
                            id: ac
                            visible: root.acItems.length > 0 && !root.acDismissed
                            z: 50
                            anchors.top: searchBox.bottom
                            anchors.right: searchBox.right
                            anchors.topMargin: 4
                            width: 360
                            height: visible ? Math.min(root.acItems.length, 7) * 24 + 8 : 0
                            radius: Theme.rounding - 4
                            color: Theme.bgAlpha
                            border.color: Theme.cyan
                            border.width: 1
                            clip: true

                            Column {
                                anchors.fill: parent
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
                                            anchors.verticalCenter: parent.verticalCenter
                                            x: 10
                                            spacing: 8

                                            Text {
                                                id: acLabel
                                                text: acRow.modelData.label
                                                font.family: Theme.fontFamily
                                                font.pixelSize: Theme.fontSize - 2
                                                color: acRow.cur ? Theme.cyan : Theme.text
                                            }
                                            Text {
                                                visible: !!acRow.modelData.alias
                                                anchors.baseline: acLabel.baseline
                                                text: "(" + acRow.modelData.alias + ")"
                                                font.family: Theme.fontFamily
                                                font.pixelSize: Theme.fontSize - 3
                                                color: Theme.muted
                                            }
                                            Text {
                                                anchors.baseline: acLabel.baseline
                                                text: acRow.modelData.desc
                                                font.family: Theme.fontFamily
                                                font.pixelSize: Theme.fontSize - 3
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
                        }
                    }

                    HeaderButton {
                        text: root.unreadOnly ? "unread" : "all"
                        active: root.unreadOnly
                        onClicked: root.unreadOnly = !root.unreadOnly
                    }
                    HeaderButton {
                        text: RssSvc.refreshing ? "…" : "refresh"
                        active: RssSvc.refreshing
                        onClicked: RssSvc.refresh()
                    }
                }

                Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: 1
                    color: Theme.border
                }
            }

            // ---- tag row ---------------------------------------
            Flickable {
                id: tagRow
                anchors.top: header.bottom
                width: parent.width
                height: RssSvc.tags.length ? 34 : 0
                contentWidth: tagFlow.width
                clip: true
                flickableDirection: Flickable.HorizontalFlick

                Row {
                    id: tagFlow
                    height: parent.height
                    spacing: 6
                    leftPadding: 14
                    rightPadding: 14

                    TagChip {
                        label: "all"
                        active: root.tagFilter === ""
                        onClicked: root.tagFilter = ""
                    }
                    Repeater {
                        model: RssSvc.tags
                        TagChip {
                            required property var modelData
                            label: modelData
                            active: root.tagFilter === modelData
                            onClicked: root.tagFilter =
                                (root.tagFilter === modelData ? "" : modelData)
                        }
                    }
                }

                Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: 1
                    color: Theme.border
                    visible: tagRow.height > 0
                }
            }

            // ---- body: list | reading pane --------------------
            Item {
                anchors.top: tagRow.bottom
                anchors.bottom: parent.bottom
                width: parent.width

                // list
                ListView {
                    id: listView
                    width: Math.round(parent.width * 0.38)
                    height: parent.height
                    clip: true
                    model: root.view
                    currentIndex: root.selected
                    boundsBehavior: Flickable.StopAtBounds

                    delegate: Rectangle {
                        required property var modelData
                        required property int index
                        readonly property bool isRead: {
                            RssSvc.readRevision;
                            RssSvc.isRead(modelData.key);
                        }
                        width: listView.width
                        height: 58
                        color: index === root.selected
                            ? Qt.rgba(Theme.cyan.r, Theme.cyan.g, Theme.cyan.b, 0.16)
                            : "transparent"

                        Rectangle { // unread dot
                            x: 8
                            anchors.verticalCenter: parent.verticalCenter
                            width: 6; height: 6; radius: 3
                            color: Theme.orange
                            visible: !parent.isRead
                        }

                        Image {
                            id: favi
                            x: 20
                            y: 10
                            width: 18; height: 18
                            sourceSize.width: 36
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                            source: modelData.iconUrl
                            visible: status === Image.Ready
                        }

                        Column {
                            x: 46
                            width: parent.width - 56
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2

                            Text {
                                width: parent.width
                                text: modelData.feed_title + "  ·  " + fmtDate(modelData.sortKey)
                                elide: Text.ElideRight
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 3
                                color: Theme.muted
                            }
                            Text {
                                width: parent.width
                                text: modelData.title
                                elide: Text.ElideRight
                                maximumLineCount: 2
                                wrapMode: Text.WordWrap
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 1
                                font.bold: !parent.parent.isRead
                                color: parent.parent.isRead ? Theme.textDim : Theme.text
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                root.selected = index;
                                RssSvc.markRead(modelData.key);
                            }
                            onDoubleClicked: root.openCurrent();
                        }
                    }
                }

                Rectangle { // divider
                    x: listView.width
                    width: 1
                    height: parent.height
                    color: Theme.border
                }

                // reading pane
                Flickable {
                    id: reader
                    x: listView.width + 1
                    width: parent.width - listView.width - 1
                    height: parent.height
                    clip: true
                    contentWidth: width
                    contentHeight: readCol.height + 40
                    boundsBehavior: Flickable.StopAtBounds

                    Column {
                        id: readCol
                        x: 26
                        y: 22
                        width: parent.width - 52
                        spacing: 12
                        visible: root.current !== null

                        Row {
                            spacing: 8
                            Image {
                                width: 18; height: 18
                                sourceSize.width: 36
                                fillMode: Image.PreserveAspectFit
                                source: root.current ? root.current.iconUrl : ""
                                visible: status === Image.Ready
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: {
                                    if (!root.current) return "";
                                    let s = root.current.feed_title + "  ·  "
                                            + fmtDate(root.current.sortKey);
                                    if (root.current.author) s += "  ·  " + root.current.author;
                                    return s;
                                }
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 2
                                color: Theme.muted
                            }
                        }

                        Text {
                            width: parent.width
                            text: root.current ? root.current.title : ""
                            wrapMode: Text.WordWrap
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize + 5
                            font.bold: true
                            color: Theme.text
                        }

                        Image {
                            width: parent.width
                            fillMode: Image.PreserveAspectFit
                            horizontalAlignment: Image.AlignLeft
                            asynchronous: true
                            source: root.current ? root.current.imageUrl : ""
                            visible: source != "" && status === Image.Ready
                            sourceSize.width: 900
                        }

                        // sanitised content from rssd -> Qt rich text.
                        Text {
                            width: parent.width
                            visible: text.length > 0
                            text: root.current
                                ? (root.current.content_html || "") : ""
                            textFormat: Text.RichText
                            wrapMode: Text.WordWrap
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize
                            color: Theme.textDim
                            lineHeight: 1.25
                            onLinkActivated: link => Qt.openUrlExternally(link)
                        }
                        // fallback for older items with no content_html
                        Text {
                            width: parent.width
                            visible: root.current
                                && !(root.current.content_html)
                                && !!root.current.summary
                            text: root.current ? (root.current.summary || "") : ""
                            textFormat: Text.PlainText
                            wrapMode: Text.WordWrap
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize
                            color: Theme.textDim
                            lineHeight: 1.25
                        }

                        Item { width: 1; height: 4 }

                        Rectangle {
                            width: openBtn.width + 28
                            height: 32
                            radius: Theme.rounding - 4
                            color: openArea.containsMouse ? Theme.cyan : "transparent"
                            border.color: Theme.cyan
                            border.width: 1
                            Text {
                                id: openBtn
                                anchors.centerIn: parent
                                text: "open in browser  ↗"
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 1
                                color: openArea.containsMouse ? Theme.bg : Theme.cyan
                            }
                            MouseArea {
                                id: openArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.openCurrent()
                            }
                        }

                        Row {
                            spacing: 6
                            visible: root.current && (root.current.tags || []).length > 0
                            Repeater {
                                model: root.current ? root.current.tags : []
                                Rectangle {
                                    required property var modelData
                                    height: 18
                                    width: tg.width + 14
                                    radius: 9
                                    color: Qt.rgba(1, 1, 1, 0.06)
                                    Text {
                                        id: tg
                                        anchors.centerIn: parent
                                        text: "#" + modelData
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontSize - 3
                                        color: Theme.muted
                                    }
                                }
                            }
                        }

                        Item { width: 1; height: 20 }
                    }

                    Text {
                        anchors.centerIn: parent
                        visible: root.current === null
                        text: RssSvc.refreshing ? "fetching…"
                            : (RssSvc.items.length === 0
                               ? "no articles yet — press r to fetch"
                               : "nothing matches this filter")
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize
                        color: Theme.muted
                    }
                }
            }

            // ---- footer hint ----------------------------------
            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: 22
                color: Qt.rgba(0, 0, 0, 0.25)
                Text {
                    anchors.centerIn: parent
                    text: "j/k move · Enter/o open · m read · a mark-all · u unread · / find · r refresh · Esc close"
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                    color: Theme.muted
                }
            }
        }
    }

    // dd MMM  |  HH:mm today  |  "3d"
    function fmtDate(iso) {
        if (!iso)
            return "";
        const d = new Date(iso);
        if (isNaN(d.getTime()))
            return iso.slice(0, 10);
        const now = new Date();
        const diff = (now - d) / 1000;
        if (diff < 3600)
            return Math.max(1, Math.floor(diff / 60)) + "m";
        if (diff < 86400)
            return Math.floor(diff / 3600) + "h";
        if (diff < 7 * 86400)
            return Math.floor(diff / 86400) + "d";
        return Qt.formatDate(d, "d MMM");
    }

    component HeaderButton: Rectangle {
        property alias text: btnLabel.text
        property bool active: false
        signal clicked
        width: btnLabel.width + 20
        height: 28
        radius: Theme.rounding - 4
        color: active ? Qt.rgba(Theme.cyan.r, Theme.cyan.g, Theme.cyan.b, 0.22)
                      : Qt.rgba(1, 1, 1, 0.06)
        Text {
            id: btnLabel
            anchors.centerIn: parent
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 2
            color: parent.active ? Theme.cyan : Theme.textDim
        }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: parent.clicked()
        }
    }

    component TagChip: Rectangle {
        property string label: ""
        property bool active: false
        signal clicked
        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
        height: 22
        width: chipText.width + 18
        radius: 11
        color: active ? Theme.cyan : Qt.rgba(1, 1, 1, 0.06)
        Text {
            id: chipText
            anchors.centerIn: parent
            text: parent.label
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 3
            color: parent.active ? Theme.bg : Theme.textDim
        }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: parent.clicked()
        }
    }
}
