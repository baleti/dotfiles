import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import "../theme"
import "../services"

// Application launcher -- replaces `rofi -show drun` (mod + Super_l). Just
// launches apps: no run-a-command, no calc, no window mode. Search box
// speaks the shared picker DSL (QueryDsl.qml / ~/.config/docs/query-dsl.md):
// bare text + /fv over name/comment/generic/exec/categories/keywords, /s
// and /rv for order. One instance per monitor; only the focused one is
// ever shown (shell.qml's IpcHandler targets Hyprland.focusedMonitor).
PanelWindow {
    id: root

    // `screen` is PanelWindow's own property, set from shell.qml's Variants
    // (do NOT redeclare it -- that shadows the real one, see NotifLayer).
    // `open` is set imperatively (not a binding) so nothing downstream of it
    // -- visible, keyboardFocus, the autocomplete -- can feed a binding loop
    // back into it.
    property bool open: false

    // Type names filterable / sortable via the DSL.
    readonly property var typeNames: ["name", "comment", "generic", "exec", "categories", "keywords"]

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
                name: e.name || "",
                comment: e.comment || "",
                generic: e.genericName || "",
                exec: e.execString || "",
                categories: cats,
                keywords: kws,
                haystack: [e.name, e.genericName, e.comment, kws.join(" ")]
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
        case "comment": return [app.comment];
        case "generic": return [app.generic];
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
        if (s) {
            const fields = QueryDsl.resolvePath(s.field, root.typeNames);
            const f = fields.length === 1 ? fields[0] : (fields[0] || "name");
            rows = rows.slice().sort((a, b) => {
                const av = String(root._fieldVals(a, f)[0] || "").toLowerCase();
                const bv = String(root._fieldVals(b, f)[0] || "").toLowerCase();
                const c = av < bv ? -1 : (av > bv ? 1 : 0);
                return s.dir === "desc" ? -c : c;
            });
        } else {
            rows = rows.slice().sort((a, b) => {
                const r = root._rank(a) - root._rank(b);
                return r !== 0 ? r : (a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1);
            });
        }
        if (root.parsed.reverse)
            rows = rows.slice().reverse();
        return rows;
    }

    onResultsChanged: if (root.selected >= results.length) root.selected = Math.max(0, results.length - 1)

    function launch(i) {
        const app = root.results[i];
        if (!app) return;
        app.entry.execute();
        root.hide();
    }

    // ---- extra columns shown per row (name is always shown) ---------
    readonly property var extraCols: {
        let cols = ["comment"]; // launcher default: name + comment subtitle
        for (const c of root.parsed.cols) {
            const hit = QueryDsl.resolvePath(c.path, root.typeNames);
            if (c.op === "filter") cols = cols.filter(x => hit.indexOf(x) >= 0);
            else if (c.op === "add") for (const h of hit) if (cols.indexOf(h) < 0) cols.push(h);
            else if (c.op === "remove") cols = cols.filter(x => hit.indexOf(x) < 0);
        }
        return cols;
    }
    function _colText(app, col) {
        const v = root._fieldVals(app, col);
        return Array.isArray(v) ? v.join(", ") : String(v[0] || "");
    }

    // ---- autocomplete --------------------------------------------
    // Minimal: verb stage (/frag) and /fv path stage. Value/direction
    // completion (DSL stages 3-4) left for later.
    function _acCandidates() {
        const t = query.text;
        const m = t.match(/(^|\s)(\/[a-z-]*)$/);
        if (m) {
            const frag = m[2];
            return QueryDsl.shortVerbs.filter(v => v.indexOf(frag.slice(1)) >= 0)
                .map(v => ({ text: v + " ", label: v }));
        }
        const fv = t.match(/\/fv\s+([a-z]*)$/);
        if (fv) {
            const frag = fv[1];
            return root.typeNames.filter(n => n.indexOf(frag) >= 0)
                .map(n => ({ text: t.slice(0, t.length - frag.length) + n + ":", label: n }));
        }
        return [];
    }
    property var acItems: root.open ? _acCandidates() : []
    property int acSel: 0
    onAcItemsChanged: { ac.visible = acItems.length > 0; acSel = 0; }

    function acAccept() {
        const it = root.acItems[root.acSel];
        if (!it) return;
        query.text = it.text;
        query.cursorPosition = query.text.length;
    }

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

    // Dim backdrop; click outside the card closes.
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.35)
        MouseArea { anchors.fill: parent; onClicked: root.hide() }
    }

    Rectangle {
        id: card
        anchors.horizontalCenter: parent.horizontalCenter
        y: Math.round(parent.height * 0.18)
        width: 640
        height: header.height + list.height + (ac.visible ? ac.height : 0)
        radius: Theme.rounding
        color: Theme.bgAlpha
        border.color: Theme.border
        border.width: 1
        // Swallow clicks so they don't reach the backdrop.
        MouseArea { anchors.fill: parent }

        Item {
            id: header
            width: parent.width
            height: 52

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

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("search apps   ·   /  for filters")
                    color: Theme.muted
                    font: query.font
                    visible: query.text.length === 0
                }

                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Escape) {
                        if (ac.visible) ac.visible = false;
                        else root.hide();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        root.launch(root.selected);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Tab) {
                        if (ac.visible) root.acAccept();
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

        // Autocomplete popup, in-layout under the header (like the GTK pickers).
        Column {
            id: ac
            visible: false
            anchors.top: header.bottom
            width: parent.width
            height: visible ? Math.min(root.acItems.length, 6) * 26 + 8 : 0
            clip: true
            padding: 4

            Repeater {
                model: root.acItems
                Rectangle {
                    required property var modelData
                    required property int index
                    width: ac.width - 8
                    height: 26
                    radius: Theme.rounding - 5
                    color: index === root.acSel ? Theme.cyan : "transparent"
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        x: 10
                        text: modelData.label
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 1
                        color: index === root.acSel ? Theme.bg : Theme.text
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: { root.acSel = index; root.acAccept(); }
                    }
                }
            }
        }

        ListView {
            id: list
            anchors.top: ac.visible ? ac.bottom : header.bottom
            width: parent.width
            height: Math.min(root.results.length, 9) * 48 + 8
            clip: true
            model: root.results
            currentIndex: root.selected
            boundsBehavior: Flickable.StopAtBounds
            topMargin: 4
            bottomMargin: 4

            delegate: Rectangle {
                required property var modelData
                required property int index
                width: list.width
                height: 48
                color: index === root.selected ? Qt.rgba(Theme.cyan.r, Theme.cyan.g, Theme.cyan.b, 0.16)
                                               : "transparent"

                Image {
                    id: appIcon
                    x: 12
                    anchors.verticalCenter: parent.verticalCenter
                    width: 30
                    height: 30
                    sourceSize.width: 60
                    sourceSize.height: 60
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    source: Quickshell.iconPath(modelData.entry.icon, "application-x-executable")
                }

                Text {
                    id: appName
                    x: 54
                    width: parent.width - 66
                    anchors.top: parent.top
                    anchors.topMargin: subtitle.text.length > 0 ? 7 : 0
                    anchors.bottom: subtitle.text.length > 0 ? undefined : parent.bottom
                    verticalAlignment: subtitle.text.length > 0 ? Text.AlignTop : Text.AlignVCenter
                    text: modelData.name
                    elide: Text.ElideRight
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize
                    color: Theme.text
                }

                Text {
                    id: subtitle
                    x: 54
                    width: parent.width - 66
                    anchors.top: appName.bottom
                    anchors.topMargin: 1
                    text: root.extraCols.map(c => root._colText(modelData, c)).filter(s => !!s).join("  ·  ")
                    elide: Text.ElideRight
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                    color: Theme.textDim
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
