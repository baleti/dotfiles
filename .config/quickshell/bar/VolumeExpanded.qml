import QtQuick
import "../theme"
import "../services"

// Detail panel under VolumePill: output volume slider + mute, input (mic)
// state, running PipeWire/WirePlumber info, active app streams, and - for
// Bluetooth headphones - a radio list of the card's selectable profiles
// (A2DP high-fidelity playback vs HSP/HFP headset with microphone).
Rectangle {
    id: root

    property bool expanded: false
    readonly property bool hovered: mouseArea.containsMouse

    // Set from outside by Bar.qml (shared popup-row layout).
    property real panelWidth: 320
    width: panelWidth
    implicitHeight: expanded ? content.implicitHeight + 24 : 0
    height: implicitHeight
    visible: height > 0
    radius: Theme.rounding
    color: Theme.bgAlpha
    border.color: Theme.border
    border.width: 1
    clip: true

    onExpandedChanged: if (expanded) AudioSvc.refresh()

    // Same routing as VolumePill: with the phone bridge as MPRIS target the
    // output row shows/controls the phone's volume (stepped, 0..100%, no mute).
    readonly property var phone: {
        const p = Players.active;
        return (p && p.dbusName === "org.mpris.MediaPlayer2.pixel6" && p.volumeSupported) ? p : null;
    }
    readonly property real vol: phone ? phone.volume : AudioSvc.volume
    readonly property bool isMuted: phone ? false : AudioSvc.muted

    // {cardKey: {title, sink, source}} grouped by card, plus _order (sorted by title). Devices without a card get their own entry.
    readonly property var pairsByKey: {
        const byCard = {};
        const order = [];
        const add = (kind, d) => {
            const k = d.card || d.name;
            if (!byCard[k]) {
                byCard[k] = { title: d.cardDescription || d.description, sink: null, source: null };
                order.push(k);
            }
            if (!byCard[k][kind]) byCard[k][kind] = d;
        };
        AudioSvc.sinks.forEach(d => add("sink", d));
        AudioSvc.sources.forEach(d => add("source", d));
        // Stable order (never default-first) so selecting a pair doesn't move it.
        order.sort((a, b) => byCard[a].title.localeCompare(byCard[b].title) || a.localeCompare(b));
        byCard._order = order;
        return byCard;
    }

    // The Repeater's model: only reassigned when the set/order of pairs
    // changes, NOT on every volume tick -- otherwise the delegates (and the
    // slider being dragged) are destroyed mid-drag.
    property var pairKeys: []
    function _syncPairKeys() {
        const k = pairsByKey._order || [];
        if (k.join("\n") !== pairKeys.join("\n"))
            pairKeys = k;
    }
    onPairsByKeyChanged: _syncPairKeys()
    Component.onCompleted: _syncPairKeys()

    // The graph only polls while the panel is open.
    Binding { target: AudioSvc; property: "graphWanted"; value: root.expanded }

    property int selectedNode: -1
    readonly property var sel: selectedNode >= 0 ? (AudioSvc.graphNodes[selectedNode] || null) : null
    // "key value" rows for the selected node, important keys first.
    readonly property var selProps: {
        if (!sel) return [];
        const first = ["node.name", "node.description", "node.nick", "media.class", "media.role", "application.name",
                       "application.process.binary", "device.id", "node.driver-id", "node.group", "audio.rate",
                       "audio.channels", "audio.format", "node.latency", "node.rate", "priority.session", "priority.driver",
                       "api.bluez5.address", "api.bluez5.profile", "api.bluez5.codec"];
        const keys = Object.keys(sel.props);
        const rest = keys.filter(k => !first.includes(k)).sort();
        return first.filter(k => keys.includes(k)).concat(rest).map(k => [k, sel.props[k]]);
    }
    // "→ Brave input (active)" / "← Soundcore Q20 (active)" for every link of the selected node.
    readonly property var selLinks: {
        if (!sel) return [];
        const out = [];
        for (const id of AudioSvc.linkIds) {
            const l = AudioSvc.graphLinks[id];
            if (l.from === selectedNode || l.to === selectedNode) {
                const other = AudioSvc.graphNodes[l.from === selectedNode ? l.to : l.from];
                out.push((l.from === selectedNode ? "\u2192 " : "\u2190 ") + (other ? other.title : "?") + " (" + l.state + ")");
            }
        }
        return out;
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.AllButtons
        onWheel: wheel => wheel.accepted = true
    }

    component Label: Text {
        color: Theme.textDim
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize - 2
        elide: Text.ElideRight
    }

    component Heading: Text {
        color: Theme.text
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize - 1
        font.bold: true
    }

    // Icon-only toggle button (mute).
    component IconButton: Rectangle {
        id: btn
        property string glyph
        property bool active: false
        signal clicked
        width: 30
        height: 26
        radius: Theme.rounding - 3
        color: active ? Qt.rgba(1, 1, 1, 0.14) : (ma.containsMouse ? Qt.rgba(1, 1, 1, 0.08) : Qt.rgba(1, 1, 1, 0.04))
        border.color: Theme.border
        border.width: 1
        Text {
            anchors.centerIn: parent
            text: btn.glyph
            font.family: Theme.iconFontFamily
            font.pixelSize: Theme.fontSize
            color: btn.active ? Theme.muted : Theme.text
        }
        MouseArea {
            id: ma
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: btn.clicked()
        }
    }

    // Horizontal 0..150% slider.
    component VolumeSlider: Item {
        id: sl
        property real value: 0
        property bool dimmed: false
        property real maxValue: 1.5
        signal moved(real v)
        height: 22

        Rectangle {
            id: track
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: 6
            radius: 3
            color: Qt.rgba(1, 1, 1, 0.1)
            Rectangle {
                width: Math.min(1, sl.value / sl.maxValue) * parent.width
                height: parent.height
                radius: 3
                color: sl.dimmed ? Theme.muted : (sl.value > 1 ? Theme.orange : Theme.cyan)
            }
            // 100% tick
            Rectangle {
                x: parent.width / sl.maxValue - 1
                y: -3
                width: 1
                height: parent.height + 6
                color: Theme.muted
            }
        }
        Rectangle {
            x: Math.min(1, sl.value / sl.maxValue) * (track.width - width)
            anchors.verticalCenter: parent.verticalCenter
            width: 12
            height: 12
            radius: 6
            color: Theme.text
        }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            function setFrom(mx) {
                const v = Math.max(0, Math.min(1, mx / width)) * sl.maxValue;
                sl.moved(Math.round(v * 100) / 100);
            }
            onPressed: mouse => setFrom(mouse.x)
            onPositionChanged: mouse => { if (pressed) setFrom(mouse.x); }
        }
    }

    Column {
        id: content
        x: 12
        y: 12
        width: parent.width - 24
        spacing: 10

        // ---- Phone (MPRIS target) ---------------------------------------
        Row {
            visible: !!root.phone
            width: parent.width
            spacing: 8
            Heading { text: qsTr("Output"); anchors.verticalCenter: parent.verticalCenter }
            Label {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - x - 0
                text: root.phone ? qsTr("Phone (%1)").arg(root.phone.identity) : ""
            }
        }
        Row {
            visible: !!root.phone
            width: parent.width
            spacing: 10
            IconButton {
                glyph: (!root.phone && AudioSvc.sinkBluetooth) ? (root.isMuted ? Icons.volHeadphoneMuted : Icons.volHeadphone) : (root.isMuted ? Icons.volMuted : Icons.levelIcon(Icons.volLevels, Math.min(1, root.vol)))
                active: root.isMuted
                onClicked: { if (!root.phone) AudioSvc.toggleMute(); }
            }
            VolumeSlider {
                width: parent.width - 30 - 52 - 20
                anchors.verticalCenter: parent.verticalCenter
                value: root.vol
                maxValue: root.phone ? 1 : 1.5
                dimmed: root.isMuted
                onMoved: v => { if (root.phone) root.phone.volume = Math.min(1, v); else AudioSvc.setVolume(v); }
            }
            Text {
                width: 52
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                text: root.isMuted ? qsTr("muted") : Math.round(root.vol * 100) + "%"
                color: root.isMuted ? Theme.muted : Theme.text
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 1
            }
        }

        // ---- Bluetooth profiles ----------------------------------------
        Repeater {
            model: AudioSvc.btCards

            delegate: Column {
                id: card
                required property var modelData
                width: content.width
                spacing: 4

                Row {
                    width: parent.width
                    spacing: 8
                    Heading { text: qsTr("Bluetooth profile"); anchors.verticalCenter: parent.verticalCenter }
                    Label {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - x
                        text: card.modelData.description
                    }
                }

                Repeater {
                    model: card.modelData.profiles

                    delegate: Rectangle {
                        id: prof
                        required property var modelData
                        readonly property bool selected: modelData.name === card.modelData.activeProfile
                        width: card.width
                        height: 26
                        radius: Theme.rounding - 3
                        opacity: modelData.available ? 1 : 0.4
                        color: profMa.containsMouse ? Qt.rgba(1, 1, 1, 0.08) : (selected ? Qt.rgba(1, 1, 1, 0.05) : "transparent")

                        // Radio dot
                        Rectangle {
                            id: radio
                            x: 6
                            anchors.verticalCenter: parent.verticalCenter
                            width: 14
                            height: 14
                            radius: 7
                            color: "transparent"
                            border.color: prof.selected ? Theme.cyan : Theme.muted
                            border.width: 1.5
                            Rectangle {
                                anchors.centerIn: parent
                                width: 8
                                height: 8
                                radius: 4
                                color: Theme.cyan
                                visible: prof.selected
                            }
                        }
                        Text {
                            anchors.left: radio.right
                            anchors.leftMargin: 8
                            anchors.right: parent.right
                            anchors.rightMargin: 6
                            anchors.verticalCenter: parent.verticalCenter
                            text: prof.modelData.description
                            elide: Text.ElideRight
                            color: prof.selected ? Theme.text : Theme.textDim
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                            font.bold: prof.selected
                        }
                        MouseArea {
                            id: profMa
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: prof.modelData.available
                            cursorShape: Qt.PointingHandCursor
                            onClicked: AudioSvc.setProfile(card.modelData.name, prof.modelData.name)
                        }
                    }
                }
            }
        }

        // ---- Speaker / mic pairs ----------------------------------------
        // Sinks and sources grouped by their card (a laptop's built-in
        // audio, a headset's A2DP/HFP sink+mic, ...). Clicking a pair's
        // header makes its speaker and mic the defaults.
        Repeater {
            model: root.pairKeys

            delegate: Column {
                id: pair
                required property var modelData
                readonly property var pairData: root.pairsByKey[modelData] || ({ title: "", sink: null, source: null })
                readonly property var sink: pairData.sink
                readonly property var source: pairData.source
                readonly property bool isDefault: (sink && sink.default) || (source && source.default)
                width: content.width
                spacing: 6

                Rectangle {
                    width: parent.width
                    height: 24
                    radius: Theme.rounding - 3
                    color: hdrMa.containsMouse ? Qt.rgba(1, 1, 1, 0.08) : "transparent"
                    Rectangle {
                        id: pairRadio
                        x: 4
                        anchors.verticalCenter: parent.verticalCenter
                        width: 14; height: 14; radius: 7
                        color: "transparent"
                        border.color: pair.isDefault ? Theme.cyan : Theme.muted
                        border.width: 1.5
                        Rectangle {
                            anchors.centerIn: parent
                            width: 8; height: 8; radius: 4
                            color: Theme.cyan
                            visible: pair.isDefault
                        }
                    }
                    Heading {
                        anchors.left: pairRadio.right
                        anchors.leftMargin: 8
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideRight
                        text: pair.pairData.title
                    }
                    MouseArea {
                        id: hdrMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: AudioSvc.setDefaults(pair.sink ? pair.sink.name : "", pair.source ? pair.source.name : "")
                    }
                }

                Row {
                    visible: !!pair.sink
                    width: parent.width
                    spacing: 10
                    IconButton {
                        glyph: !pair.sink ? "" : pair.sink.bluetooth ? (pair.sink.muted ? Icons.volHeadphoneMuted : Icons.volHeadphone) : (pair.sink.muted ? Icons.volMuted : Icons.levelIcon(Icons.volLevels, Math.min(1, pair.sink.volume)))
                        active: !!pair.sink && pair.sink.muted
                        onClicked: AudioSvc.toggleDeviceMute("sink", pair.sink.name)
                    }
                    VolumeSlider {
                        width: parent.width - 30 - 52 - 20
                        anchors.verticalCenter: parent.verticalCenter
                        value: pair.sink ? pair.sink.volume : 0
                        dimmed: !!pair.sink && pair.sink.muted
                        onMoved: v => AudioSvc.setDeviceVolume("sink", pair.sink.name, v)
                    }
                    Text {
                        width: 52
                        anchors.verticalCenter: parent.verticalCenter
                        horizontalAlignment: Text.AlignRight
                        text: !pair.sink ? "" : pair.sink.muted ? qsTr("muted") : Math.round(pair.sink.volume * 100) + "%"
                        color: pair.sink && pair.sink.muted ? Theme.muted : Theme.text
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 1
                    }
                }

                Row {
                    visible: !!pair.source
                    width: parent.width
                    spacing: 10
                    IconButton {
                        glyph: pair.source && pair.source.muted ? "\uf131" : "\uf130"
                        active: !!pair.source && pair.source.muted
                        onClicked: AudioSvc.toggleDeviceMute("source", pair.source.name)
                    }
                    VolumeSlider {
                        width: parent.width - 30 - 52 - 20
                        anchors.verticalCenter: parent.verticalCenter
                        maxValue: 1
                        value: pair.source ? pair.source.volume : 0
                        dimmed: !!pair.source && pair.source.muted
                        onMoved: v => AudioSvc.setDeviceVolume("source", pair.source.name, v)
                    }
                    Text {
                        width: 52
                        anchors.verticalCenter: parent.verticalCenter
                        horizontalAlignment: Text.AlignRight
                        text: !pair.source ? "" : pair.source.muted ? qsTr("muted") : Math.round(pair.source.volume * 100) + "%"
                        color: pair.source && pair.source.muted ? Theme.muted : Theme.text
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 1
                    }
                }
            }
        }

        // ---- Live PipeWire state summary ---------------------------------
        Column {
            width: parent.width
            spacing: 3
            readonly property var g: AudioSvc.graph
            readonly property var clock: g.clock || ({})
            readonly property var counts: g.counts || ({})
            readonly property var wp: g.wireplumber || ({})
            Label {
                width: parent.width
                visible: !!parent.clock.rate
                text: qsTr("Clock  ") + parent.clock.rate + " Hz · quantum " + parent.clock.quantum
                    + " (" + (parent.clock.quantum / parent.clock.rate * 1000).toFixed(1) + " ms) · range "
                    + parent.clock.minQuantum + "-" + parent.clock.maxQuantum
                    + (parent.clock.forceQuantum ? " · forced " + parent.clock.forceQuantum : "")
            }
            Label {
                width: parent.width
                visible: parent.counts.nodes !== undefined
                text: qsTr("Graph  ") + parent.counts.nodes + " nodes (" + parent.counts.running + " running · "
                    + parent.counts.idle + " idle · " + parent.counts.suspended + " suspended"
                    + (parent.counts.error ? " · " + parent.counts.error + " error" : "") + ") · "
                    + parent.counts.links + " links"
            }
            Label {
                width: parent.width
                visible: parent.counts.clients !== undefined
                text: qsTr("Clients  ") + parent.counts.clients + " · devices " + parent.counts.devices
                    + " · xruns " + parent.counts.xruns
            }
            Label {
                width: parent.width
                visible: parent.wp.autoswitch !== undefined
                text: qsTr("WirePlumber  BT headset auto-switch ") + (parent.wp.autoswitch ? qsTr("on") : qsTr("off"))
                    + " · prefers " + parent.wp.profilePreference
                    + " · follow default " + (parent.wp.followDefault ? qsTr("on") : qsTr("off"))
            }
            Label {
                width: parent.width
                text: qsTr("Playing  ") + (AudioSvc.playbackApps.length ? AudioSvc.playbackApps.join(", ") : qsTr("nothing"))
                    + qsTr("  ·  Recording  ") + (AudioSvc.captureApps.length ? AudioSvc.captureApps.join(", ") : qsTr("nothing"))
            }
        }

        // ---- Interactive graph --------------------------------------------
        Heading { text: qsTr("PipeWire graph") }
        PwGraphView {
            id: graphView
            width: parent.width
            selectedId: root.selectedNode
            onNodeClicked: id => root.selectedNode = (id === root.selectedNode ? -1 : id)
        }

        // ---- Selected node details -----------------------------------------
        Column {
            id: details
            width: parent.width
            spacing: 4
            visible: !!root.sel

            Row {
                width: parent.width
                spacing: 8
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 8; height: 8; radius: 4
                    color: root.sel ? graphView.stateColor(root.sel.state) : "transparent"
                }
                Heading {
                    width: parent.width - 16
                    elide: Text.ElideRight
                    text: root.sel ? root.sel.title : ""
                }
            }
            Label {
                width: parent.width
                text: root.sel ? (root.sel.class || "node") + " · " + root.sel.state + " · id " + root.sel.id
                    + (root.sel.error ? " · " + root.sel.error : "") : ""
            }
            Label {
                width: parent.width
                visible: !!(root.sel && root.sel.stats && root.sel.stats.quantum)
                text: {
                    const st = root.sel ? root.sel.stats : null;
                    if (!st) return "";
                    const us = v => v === null || v === undefined ? "-" : (v >= 1000 ? (v / 1000).toFixed(1) + " ms" : v.toFixed(0) + " µs");
                    return "quantum " + st.quantum + " @ " + st.rate + " Hz · wait " + us(st.waitUs) + " · busy " + us(st.busyUs)
                        + (st.bq !== null ? " · load " + (st.bq * 100).toFixed(1) + "%" : "") + " · errors " + st.errors
                        + (st.format ? " · " + st.format : "");
                }
            }
            Label {
                width: parent.width
                visible: root.selLinks.length > 0
                color: Theme.text
                text: root.selLinks.join("\n")
                wrapMode: Text.NoWrap
                elide: Text.ElideRight
                maximumLineCount: 6
            }
            Rectangle {
                width: parent.width
                height: Math.min(150, propsList.contentHeight + 8)
                radius: Theme.rounding - 3
                color: Qt.rgba(0, 0, 0, 0.25)
                clip: true
                ListView {
                    id: propsList
                    anchors.fill: parent
                    anchors.margins: 4
                    model: root.selProps
                    boundsBehavior: Flickable.StopAtBounds
                    delegate: Row {
                        required property var modelData
                        width: propsList.width
                        spacing: 8
                        Text {
                            width: Math.min(150, parent.width * 0.4)
                            text: modelData[0]
                            elide: Text.ElideRight
                            color: Theme.textDim
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 3
                        }
                        Text {
                            width: parent.width - Math.min(150, parent.width * 0.4) - 8
                            text: modelData[1]
                            elide: Text.ElideRight
                            color: Theme.text
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 3
                        }
                    }
                }
            }
        }
    }
}
