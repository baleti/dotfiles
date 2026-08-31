import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import "../theme"
import "../services"

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

    readonly property var view: {
        RssSvc.readRevision; // dependency
        const q = search.text.trim().toLowerCase();
        const out = [];
        for (let i = 0; i < RssSvc.items.length; i++) {
            const it = RssSvc.items[i];
            if (root.unreadOnly && RssSvc.isRead(it.key))
                continue;
            if (root.tagFilter && (it.tags || []).indexOf(root.tagFilter) < 0)
                continue;
            if (q && (it.title + " " + it.feed_title).toLowerCase().indexOf(q) < 0)
                continue;
            out.push(it);
        }
        return out;
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
                if (search.activeFocus) keyScope.forceActiveFocus();
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
                    Rectangle {
                        width: 240
                        height: 28
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
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "filter…"
                                color: Theme.muted
                                font: search.font
                                visible: search.text.length === 0 && !search.activeFocus
                            }
                            Keys.onPressed: e => {
                                if (e.key === Qt.Key_Escape) {
                                    if (search.text.length) search.text = "";
                                    else keyScope.forceActiveFocus();
                                    e.accepted = true;
                                } else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter
                                           || e.key === Qt.Key_Down || e.key === Qt.Key_Up) {
                                    keyScope.forceActiveFocus();
                                    e.accepted = true;
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
