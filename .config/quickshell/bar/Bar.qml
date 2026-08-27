import QtQuick
import Quickshell
import Quickshell.Io
import "../components"
import "../theme"
import "../services"

// Layout mirrors the old ~/.config/waybar/config.jsonc: modules-left
// (workspaces, submap), modules-right (tray, media, controls, network,
// hardware, clock), each its own rounded island. No window-title module
// (removed 2026-08-27).
Item {
    id: root

    required property ShellScreen screen

    // Same 8-color rotation as sysmon-graph.rs's IFACE_PALETTE, so a given
    // interface reads the same color in the bar and in the alt+mod+n popup.
    readonly property var palette: [
        Theme.cyan, Theme.green, Theme.orange, "#c87aff",
        "#ff73a6", "#f2d94e", "#ff6b6b", "#8ca6ff"
    ]

    function colorFor(name: string): color {
        let hash = 0;
        for (let i = 0; i < name.length; i++)
            hash = (hash * 31 + name.charCodeAt(i)) >>> 0;
        return palette[hash % palette.length];
    }

    // Bar itself stays a fixed height (exclusiveZone in shell.qml is pinned
    // to Theme.barHeight); this is the *window's* total height, letting the
    // media/graph hover-panels grow the window downward without reserving
    // that extra space from tiling. Only one panel is ever open at a time
    // in practice, but this takes the max defensively.
    readonly property real overflow: Math.max(mediaExpanded.height, netPill.overflowHeight, cpuPill.overflowHeight, memPill.overflowHeight, tempPill.overflowHeight, diskPill.overflowHeight, calendarExpanded.height)
    readonly property real totalHeight: Theme.barHeight + (overflow > 0 ? 6 + overflow : 0)

    function last(arr: var): real {
        return arr.length > 0 ? arr[arr.length - 1] : 0;
    }

    function fmtRate(bps: real): string {
        if (bps >= 1024 * 1024)
            return (bps / (1024 * 1024)).toFixed(1) + " MB/s";
        if (bps >= 1024)
            return Math.round(bps / 1024) + " KB/s";
        return Math.round(bps) + " B/s";
    }

    readonly property var netLegend: SysmonSvc.netInterfaces.map(i => ({ name: i.name, color: root.colorFor(i.name) }))
    readonly property var netSeriesList: {
        const out = [];
        for (const iface of SysmonSvc.netInterfaces) {
            const c = root.colorFor(iface.name);
            out.push({ data: iface.rx_bps, color: c, dashed: false });
            out.push({ data: iface.tx_bps, color: c, dashed: true });
        }
        return out;
    }
    readonly property real netMax: {
        let m = 1024;
        for (const iface of SysmonSvc.netInterfaces) {
            m = Math.max(m, ...iface.rx_bps, ...iface.tx_bps);
        }
        return m;
    }
    readonly property real netTotalNow: {
        let rx = 0, tx = 0;
        for (const iface of SysmonSvc.netInterfaces) {
            rx += root.last(iface.rx_bps);
            tx += root.last(iface.tx_bps);
        }
        return rx + tx;
    }

    readonly property var cpuLegend: SysmonSvc.cpuCores.map((c, i) => ({ name: qsTr("Core %1").arg(i), color: root.palette[i % root.palette.length] }))
    readonly property var cpuStackedList: SysmonSvc.cpuCores.map((c, i) => ({ data: c, color: root.palette[i % root.palette.length] }))

    readonly property var memLegend: [
        { name: qsTr("Used"), color: Theme.green },
        { name: qsTr("Cached"), color: Theme.cyan }
    ]
    readonly property var memSeriesList: [
        { data: SysmonSvc.memUsedPct, color: Theme.green, dashed: false },
        { data: SysmonSvc.memCachedPct, color: Theme.cyan, dashed: true }
    ]

    readonly property var diskLegend: SysmonSvc.diskDevices.map(d => ({ name: d.name, color: root.colorFor(d.name) }))
    readonly property var diskSeriesList: {
        const out = [];
        for (const dev of SysmonSvc.diskDevices) {
            const c = root.colorFor(dev.name);
            out.push({ data: dev.read_bps, color: c, dashed: false });
            out.push({ data: dev.write_bps, color: c, dashed: true });
        }
        return out;
    }
    readonly property real diskMax: {
        let m = 1024;
        for (const dev of SysmonSvc.diskDevices)
            m = Math.max(m, ...dev.read_bps, ...dev.write_bps);
        return m;
    }
    readonly property real diskTotalNow: {
        let rd = 0, wr = 0;
        for (const dev of SysmonSvc.diskDevices) {
            rd += root.last(dev.read_bps);
            wr += root.last(dev.write_bps);
        }
        return rd + wr;
    }

    anchors.fill: parent

    // Pinned to the top edge with a fixed offset, NOT vertically centered in
    // the whole window -- the window grows taller to fit the media hover
    // panel below, and centering-in-parent would drag the visible bar strip
    // down along with it as that height changes.
    readonly property real pillTopMargin: 5

    Row {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.leftMargin: 3
        anchors.topMargin: root.pillTopMargin
        spacing: 6

        Pill {
            Workspaces { screen: root.screen }
        }
        Submap {}
    }

    Row {
        id: rightRow
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.rightMargin: 3
        anchors.topMargin: root.pillTopMargin
        spacing: 6

        Tray {}
        Loader {
            id: mediaLoader
            active: !!Players.active
            sourceComponent: Media {}
        }

        GraphPill {
            id: netPill
            icon: Icons.network
            title: qsTr("Network")
            compactText: root.fmtRate(root.netTotalNow)
            compactTextWidth: 72
            valueLabel: root.fmtRate(root.netTotalNow) + " total"
            mode: "overlay"
            seriesList: root.netSeriesList
            maxValue: root.netMax
            legendItems: root.netLegend
        }

        GraphPill {
            id: cpuPill
            icon: Icons.cpu
            title: qsTr("CPU")
            compactText: Math.round(root.last(SysmonSvc.cpuTotal)) + "%"
            valueLabel: compactText
            mode: "stacked"
            stackedList: root.cpuStackedList
            maxValue: Math.max(100, SysmonSvc.cpuCores.length * 100)
            legendItems: root.cpuLegend
            topProcs: SysmonSvc.topCpu
            topUnit: "%"
        }

        GraphPill {
            id: memPill
            icon: Icons.memory
            title: qsTr("Memory")
            compactText: Math.round(root.last(SysmonSvc.memUsedPct)) + "%"
            valueLabel: compactText
            mode: "overlay"
            seriesList: root.memSeriesList
            maxValue: 100
            legendItems: root.memLegend
            topProcs: SysmonSvc.topMem
            topUnit: " MB"
        }

        GraphPill {
            id: diskPill
            icon: Icons.disk
            title: qsTr("Disk")
            compactText: root.fmtRate(root.diskTotalNow)
            compactTextWidth: 72
            valueLabel: root.fmtRate(root.diskTotalNow) + " total"
            mode: "overlay"
            seriesList: root.diskSeriesList
            maxValue: root.diskMax
            legendItems: root.diskLegend
        }

        GraphPill {
            id: tempPill
            icon: Icons.temp
            title: qsTr("Temperature")
            compactText: Math.round(root.last(SysmonSvc.tempC)) + "°C"
            valueLabel: compactText
            mode: "single"
            series: SysmonSvc.tempC
            maxValue: Math.max(60, ...SysmonSvc.tempC) + 10
            color1: Theme.orange
        }

        BatteryPill {}

        Loader {
            id: clockLoader
            active: true
            sourceComponent: Pill {
                Clock { id: clockText }
            }
        }
    }

    // Hover-down expansion for the media pill. A sibling overlay rather than
    // in-flow content, so growing it never pushes the other pills around --
    // it just floats over whatever's beneath (same layer-shell "top" layer
    // that lets the bar itself sit above tiled windows). mediaLoader lives
    // inside rightRow, not directly under root, so it isn't a QML anchor
    // sibling of mediaExpanded -- position is composed by hand instead
    // (rightRow's offset + mediaLoader's offset within it), using plain
    // property reads rather than mapToItem, which isn't reliably reactive
    // to layout changes and was landing this in the wrong place.
    property bool mediaAreaHovered: (mediaLoader.item?.hovered ?? false) || mediaExpanded.hovered

    onMediaAreaHoveredChanged: {
        if (mediaAreaHovered) {
            hoverOutTimer.stop();
            mediaExpanded.expanded = true;
        } else {
            hoverOutTimer.restart();
        }
    }

    Timer {
        id: hoverOutTimer
        interval: 250
        onTriggered: mediaExpanded.expanded = false
    }

    MediaExpanded {
        id: mediaExpanded

        x: rightRow.x + mediaLoader.x + mediaLoader.width - width
        y: rightRow.y + mediaLoader.y + mediaLoader.height + 6
    }

    // Same pattern for the clock's calendar hover-panel.
    property bool clockAreaHovered: clockHoverArea.containsMouse || calendarExpanded.hovered

    onClockAreaHoveredChanged: {
        if (clockAreaHovered) {
            clockHoverOutTimer.stop();
            calendarExpanded.expanded = true;
        } else {
            clockHoverOutTimer.restart();
        }
    }

    Timer {
        id: clockHoverOutTimer
        interval: 250
        onTriggered: calendarExpanded.expanded = false
    }

    MouseArea {
        id: clockHoverArea
        hoverEnabled: true
        x: rightRow.x + clockLoader.x
        y: rightRow.y + clockLoader.y
        width: clockLoader.width
        height: clockLoader.height
    }

    CalendarExpanded {
        id: calendarExpanded

        x: rightRow.x + clockLoader.x + clockLoader.width - width
        y: rightRow.y + clockLoader.y + clockLoader.height + 6
    }

    // Keyboard shortcuts (hyprland/keybinds.lua: alt+n/p/m/t/d, via
    // ~/.config/hypr/scripts/bar-toggle.sh) call these -- same open/close
    // toggle feel as the old standalone sysmon-graph popups, just for the
    // bar's own panels. Target is per-screen: this file runs once per
    // monitor (shell.qml's Variants over Quickshell.screens), and a shared
    // "bar" target name would collide across those instances -- the script
    // resolves whichever monitor is currently focused to "bar-<name>".
    IpcHandler {
        target: "bar-" + root.screen.name

        function toggleNet(): void { netPill.expanded = !netPill.expanded; }
        function toggleCpu(): void { cpuPill.expanded = !cpuPill.expanded; }
        function toggleMem(): void { memPill.expanded = !memPill.expanded; }
        function toggleTemp(): void { tempPill.expanded = !tempPill.expanded; }
        function toggleDisk(): void { diskPill.expanded = !diskPill.expanded; }
        function toggleMedia(): void { mediaExpanded.expanded = !mediaExpanded.expanded; }
        function toggleCalendar(): void { calendarExpanded.expanded = !calendarExpanded.expanded; }
    }
}
