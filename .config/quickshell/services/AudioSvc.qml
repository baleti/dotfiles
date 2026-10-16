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

    property var playbackApps: []
    property var captureApps: []
    property var btCards: []

    property string pipewireVersion: ""
    property string wireplumberVersion: ""

    readonly property bool hasSink: sinkName !== ""
    readonly property int percent: Math.round(volume * 100)

    function refresh(): void {
        if (!_snapshot.running)
            _snapshot.running = true;
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

    function toggleSourceMute(): void {
        root.sourceMuted = !root.sourceMuted;
        Quickshell.execDetached(["wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", "toggle"]);
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

    readonly property Process _versions: Process {
        command: ["sh", "-c", "pipewire --version | tail -1; wireplumber --version | tail -1"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                const lines = text.trim().split("\n");
                const pw = (lines[0] || "").match(/libpipewire\s+([\d.]+)/);
                const wp = (lines[1] || "").match(/libwireplumber\s+([\d.]+)/);
                root.pipewireVersion = pw ? pw[1] : "";
                root.wireplumberVersion = wp ? wp[1] : "";
            }
        }
    }

    Component.onCompleted: root.refresh()
}
