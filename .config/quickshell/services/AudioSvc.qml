pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Live PipeWire/WirePlumber audio state for the bar's volume pill and its
// expanded panel: default sink/source volume + mute, per-app streams, and
// every Bluetooth card with its selectable profiles (A2DP / HFP / HSP).
//
// State comes from services/audio-state.py (one `pactl --format=json`
// snapshot); `pactl subscribe` events trigger a debounced re-snapshot, so
// changes made anywhere else (keyboard volume keys, the headset's own
// buttons, WirePlumber auto-switching to the headset profile when a call
// starts) show up without polling. Writes go through wpctl/pactl.
Singleton {
    id: root

    property string server: ""
    property string sinkName: ""
    property string sinkDescription: ""
    property real volume: 0          // 0..1+ (1 == 100%)
    property bool muted: false
    property bool sinkBluetooth: false
    property string sinkCard: ""

    property string sourceDescription: ""
    property real sourceVolume: 0
    property bool sourceMuted: false

    // Every real output / input device (monitors excluded), each
    // {name, description, volume, muted, bluetooth, card, cardDescription,
    // default}. VolumeExpanded pairs them up by card.
    property var sinks: []
    property var sources: []

    property var playbackApps: []
    property var captureApps: []
    property var btCards: []

    // Full PipeWire graph (services/pw-graph.py), refreshed only while the
    // volume panel is open (graphWanted). graphNodes/graphLinks are id-keyed
    // maps; nodeIds/linkIds only change when the SET of ids changes, so the
    // viewer's Repeaters don't rebuild every delegate on each 2s refresh.
    property bool graphWanted: false
    property var graph: ({})
    property var graphNodes: ({})
    property var graphLinks: ({})
    property var nodeIds: []
    property var linkIds: []

    readonly property bool hasSink: sinkName !== ""
    readonly property int percent: Math.round(volume * 100)

    function refresh(): void {
        if (!_snapshot.running)
            _snapshot.running = true;
        if (root.graphWanted && !_graphProc.running)
            _graphProc.running = true;
    }

    function _applyGraph(g): void {
        root.graph = g;
        root.graphNodes = g.nodes || {};
        const links = {};
        for (const l of (g.links || []))
            links[l.id] = l;
        root.graphLinks = links;
        const nids = Object.keys(root.graphNodes).map(Number).sort((a, b) => a - b);
        const lids = Object.keys(links).map(Number).sort((a, b) => a - b);
        if (nids.join(",") !== root.nodeIds.join(","))
            root.nodeIds = nids;
        if (lids.join(",") !== root.linkIds.join(","))
            root.linkIds = lids;
    }

    onGraphWantedChanged: {
        if (graphWanted)
            refresh();
    }

    Timer {
        interval: 2000
        repeat: true
        running: root.graphWanted
        onTriggered: root.refresh()
    }

    readonly property Process _graphProc: Process {
        command: ["python3", "-I", Quickshell.shellPath("services/pw-graph.py")]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root._applyGraph(JSON.parse(text));
                } catch (e) {
                    // pw-dump unavailable / mid-restart -- keep last graph.
                }
            }
        }
    }

    function _apply(s): void {
        root.server = s.server || "";
        root.sinkName = s.sink.name;
        root.sinkDescription = s.sink.description;
        if (!_volumeThrottle.running)
            root.volume = s.sink.volume;
        root.muted = s.sink.muted;
        root.sinkBluetooth = s.sink.bluetooth;
        root.sinkCard = s.sink.card;
        root.sourceDescription = s.source.description;
        root.sourceVolume = s.source.volume;
        root.sourceMuted = s.source.muted;
        root.sinks = s.sinks || [];
        root.sources = s.sources || [];
        root.playbackApps = s.playbackApps;
        root.captureApps = s.captureApps;
        root.btCards = s.btCards;
    }

    // ---- writes --------------------------------------------------------
    property real _pendingVolume: -1

    // Throttled: a slider drag calls this on every pixel; wpctl only needs
    // the latest value every ~60ms.
    function setVolume(fraction: real): void {
        root.volume = Math.max(0, Math.min(1.5, fraction));
        root._pendingVolume = root.volume;
        if (!_volumeThrottle.running)
            _volumeThrottle.start();
        _flushVolume();
    }

    function _flushVolume(): void {
        if (root._pendingVolume < 0)
            return;
        Quickshell.execDetached(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@",
                                 Math.round(root._pendingVolume * 100) + "%"]);
        root._pendingVolume = -1;
    }

    Timer {
        id: _volumeThrottle
        interval: 60
        onTriggered: {
            root._flushVolume();
            root.refresh();
        }
    }

    function toggleMute(): void {
        root.muted = !root.muted;
        Quickshell.execDetached(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"]);
    }

    function setSourceVolume(fraction: real): void {
        root.sourceVolume = Math.max(0, Math.min(1, fraction));
        Quickshell.execDetached(["wpctl", "set-volume", "@DEFAULT_AUDIO_SOURCE@",
                                 Math.round(root.sourceVolume * 100) + "%"]);
    }

    function toggleSourceMute(): void {
        root.sourceMuted = !root.sourceMuted;
        Quickshell.execDetached(["wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", "toggle"]);
    }

    // ---- per-device writes (any sink/source, not just the default) -------
    function _patch(list, name, fields) {
        return list.map(d => d.name === name ? Object.assign({}, d, fields) : d);
    }

    function setDeviceVolume(kind: string, name: string, fraction: real): void {
        const v = Math.max(0, Math.min(kind === "sink" ? 1.5 : 1, fraction));
        Quickshell.execDetached(["pactl", "set-" + kind + "-volume", name, Math.round(v * 100) + "%"]);
        if (kind === "sink") root.sinks = _patch(root.sinks, name, { volume: v });
        else root.sources = _patch(root.sources, name, { volume: v });
        const d = (kind === "sink" ? root.sinks : root.sources).find(x => x.name === name);
        if (d && d.default) {
            if (kind === "sink") root.volume = v;
            else root.sourceVolume = v;
        }
    }

    function toggleDeviceMute(kind: string, name: string): void {
        Quickshell.execDetached(["pactl", "set-" + kind + "-mute", name, "toggle"]);
        const list = kind === "sink" ? root.sinks : root.sources;
        const d = list.find(x => x.name === name);
        if (!d) return;
        if (kind === "sink") root.sinks = _patch(list, name, { muted: !d.muted });
        else root.sources = _patch(list, name, { muted: !d.muted });
        if (d.default) {
            if (kind === "sink") root.muted = !d.muted;
            else root.sourceMuted = !d.muted;
        }
    }

    // Make a speaker/mic pair the default; either half may be "" (skipped).
    function setDefaults(sink: string, source: string): void {
        if (sink) Quickshell.execDetached(["pactl", "set-default-sink", sink]);
        if (source) Quickshell.execDetached(["pactl", "set-default-source", source]);
        root.sinks = root.sinks.map(d => sink ? Object.assign({}, d, { default: d.name === sink }) : d);
        root.sources = root.sources.map(d => source ? Object.assign({}, d, { default: d.name === source }) : d);
    }

    function setProfile(card: string, profile: string): void {
        Quickshell.execDetached(["pactl", "set-card-profile", card, profile]);
        // Profile switches take a moment to settle; the subscribe events
        // refresh again, this just makes the radio button respond at once.
        const cards = root.btCards.map(c => c.name === card ? Object.assign({}, c, { activeProfile: profile }) : c);
        root.btCards = cards;
    }

    // ---- plumbing ------------------------------------------------------
    readonly property Process _snapshot: Process {
        command: ["python3", "-I", Quickshell.shellPath("services/audio-state.py")]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root._apply(JSON.parse(text));
                } catch (e) {
                    // pactl unavailable / mid-restart -- keep last state.
                }
            }
        }
    }

    // Event-driven refresh; relaunched if pipewire-pulse restarts.
    readonly property Process _subscribe: Process {
        command: ["pactl", "subscribe"]
        running: true
        stdout: SplitParser {
            onRead: line => {
                if (/sink|source|card|server/.test(line))
                    _debounce.restart();
            }
        }
        onRunningChanged: if (!running) _resubscribe.start()
    }

    Timer {
        id: _debounce
        interval: 150
        onTriggered: root.refresh()
    }

    Timer {
        id: _resubscribe
        interval: 3000
        onTriggered: {
            root._subscribe.running = true;
            root.refresh();
        }
    }

    Component.onCompleted: root.refresh()
}
