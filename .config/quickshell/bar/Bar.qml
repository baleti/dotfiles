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

    // Exposed so shell.qml can drive the PanelWindow's WlrLayershell
    // keyboard-focus mode from each panel's own open/closed state.
    readonly property alias mediaPanel: mediaExpanded
    readonly property alias calendarPanel: calendarExpanded
    readonly property bool anyGraphExpanded: netPill.expanded || cpuPill.expanded || memPill.expanded || diskPill.expanded || tempPill.expanded || gpuPill.expanded

    // shell.qml watches this to tell "a panel just opened" (reclaim window
    // keyboard focus) apart from "a panel closed but others are still open"
    // (do nothing -- see holdsFocus there). A plain increase-vs-decrease
    // read on the count, not per-panel signals, since any of 7 panels could
    // be the one that changed.
    readonly property int openPanelCount: (mediaExpanded.expanded ? 1 : 0) + (calendarExpanded.expanded ? 1 : 0)
        + (netPill.expanded ? 1 : 0) + (cpuPill.expanded ? 1 : 0) + (memPill.expanded ? 1 : 0)
        + (diskPill.expanded ? 1 : 0) + (tempPill.expanded ? 1 : 0) + (gpuPill.expanded ? 1 : 0)
        + (claudeUsageExpanded.expanded ? 1 : 0)

    // Always focus-eligible -- actual keyboard delivery is already gated at
    // the window level by shell.qml's WlrLayershell.keyboardFocus/
    // HyprlandFocusGrab (both None/inactive when nothing is expanded), so
    // this being unconditionally true is harmless. It used to track
    // mediaExpanded/calendarExpanded.expanded directly, but that meant it
    // dropped to false whenever only a *graph* pill was focused (this
    // property didn't know about those), which yanks QML's activeFocus
    // away from that pill's Keys.onPressed the moment this binding
    // re-evaluates -- unconditional true removes that failure mode instead
    // of chasing every panel that can hold focus through this expression.
    focus: true

    // Points QML keyboard focus at whichever panel should be driving the
    // keys right now: a still-open graph pill if there is one (its own
    // Keys.onPressed), otherwise the bar itself (root.Keys.onPressed, which
    // routes to the media / calendar panels). Called after any panel closes.
    //
    // Without this, a graph pill that gets closed with Escape while the
    // calendar stayed open keeps QML activeFocus on its now-collapsed self,
    // and its Keys.onPressed goes on swallowing Left/Right (tier stepping) so
    // those keys never reach the calendar -- while h/l, which the pill
    // doesn't handle, still bubble through and work. Reported 2026-08-30.
    function refocusActivePanel(): void {
        for (const p of [gpuPill, tempPill, diskPill, memPill, cpuPill, netPill]) {
            if (p.expanded) {
                p.forceActiveFocus();
                return;
            }
        }
        root.forceActiveFocus();
    }
    // Back-compat shim for GraphPill's onExpandedChanged wiring.
    function reclaimGraphFocus(closedPill): void {
        if (closedPill.activeFocus)
            root.refocusActivePanel();
    }

    // Only live while a panel that wants real keyboard control is open (see
    // shell.qml's OnDemand/None keyboardFocus binding). Media: arrow keys
    // seek, space toggles play/pause, escape closes; mod+CTRL+m (the same
    // combo that opened it) also closes it, handled in hyprland/keybinds.lua
    // as a toggle. Calendar: delegated to CalendarExpanded.handleKey() -
    // arrows / h j k l move the day cursor, Ctrl+arrows page the month /
    // zoom into the year-picker, enter/escape drive it.
    Keys.onPressed: event => {
        if (mediaExpanded.expanded && Players.active) {
            const player = Players.active;
            if (event.key === Qt.Key_Left && player.canSeek) {
                player.seek(-5);
                event.accepted = true;
            } else if (event.key === Qt.Key_Right && player.canSeek) {
                player.seek(5);
                event.accepted = true;
            } else if (event.key === Qt.Key_Space && player.canTogglePlaying) {
                player.togglePlaying();
                event.accepted = true;
            } else if (event.key === Qt.Key_Escape) {
                mediaExpanded.expanded = false;
                event.accepted = true;
            } else if (event.key >= Qt.Key_0 && event.key <= Qt.Key_9 && player.canSeek && player.length > 0) {
                // Jump to that decile of the track (2 -> 20%, 9 -> 90%, 0 ->
                // start, ...) -- used to be a separate "media_seek" Hyprland
                // submap (mod+CTRL+m entered it, bare 0-9 while active) that
                // ran alongside this same real-QML-focus handling for
                // arrows/space/escape above, which left the bar's Submap{}
                // indicator visibly showing "media_seek" whenever it was
                // live (reported 2026-08-30). Same seek() workaround
                // MediaExpanded's own draggable seek bar uses -- .position
                // (MprisPlayer's SetPosition) isn't implemented by the phone
                // bridge, only relative Seek, which every player supports.
                const digit = event.key - Qt.Key_0;
                const target = player.length * digit / 10;
                player.seek(target - player.position);
                event.accepted = true;
            }
        } else if (calendarExpanded.expanded) {
            calendarExpanded.handleKey(event);
        } else if (claudeUsageExpanded.expanded && event.key === Qt.Key_Escape) {
            claudeUsageExpanded.expanded = false;
            event.accepted = true;
        } else if (claudeUsageExpanded.expanded && event.key === Qt.Key_Slash) {
            // Real keyboard focus moves into the search box itself here
            // (ClaudeUsageExpanded.focusSearch()) -- subsequent keystrokes
            // (including its own Escape-clears-query handling) go straight
            // to that TextInput, not back through this handler, the same
            // way "/" hands off focus in the RSS reader/app launcher.
            claudeUsageExpanded.focusSearch();
            event.accepted = true;
        }
    }

    // Theme-derived series palette (Theme.qml, generated by gen-theme.py).
    // sysmon-graph.rs's own IFACE_PALETTE is a separate static array baked
    // into that binary at compile time, so the two won't perfectly match
    // once the theme is regenerated from different seeds -- not wired
    // together, as that'd mean the Rust popup re-reading this JSON file.
    readonly property var palette: Theme.seriesPalette

    function colorFor(name: string): color {
        let hash = 0;
        for (let i = 0; i < name.length; i++)
            hash = (hash * 31 + name.charCodeAt(i)) >>> 0;
        return palette[hash % palette.length];
    }

    // Bar itself stays a fixed height (exclusiveZone in shell.qml is pinned
    // to Theme.barHeight); popup panels grow the *window* downward without
    // reserving that extra space from tiling. panelGridHeight (below) is
    // the single source of truth for every open panel's row -- media/
    // calendar are full members of that same grid, not maxed in
    // separately (see its own comment for why that used to cause an
    // overlap). totalHeight/overflow (a combined bar+panel-grid height
    // figure) used to live here for shell.qml's input mask, but that mask
    // is now two separate rectangles (bar strip + panel area, see its own
    // comment on openPanelsLeftEdge below) rather than one sized off a
    // single combined height, so nothing reads these two any more --
    // removed rather than left as dead code.

    // Any of these 7 can be open at once (e.g. mod+CTRL+m then mod+t then
    // mod+CTRL+c) and all share one row-wrapping layout (see the "Popup
    // panels" block below, once `panelY`/`naturalRightFor` are defined) --
    // this is that system's bar-visual left-to-right ordering (matching
    // rightRow's child order, with calendar's clock trigger last since
    // it's the rightmost).
    readonly property var panelOrder: ["media", "net", "cpu", "mem", "disk", "temp", "gpu", "claudeUsage", "calendar"]

    // Which of SysmonSvc's 6 fixed tiers (10m/30m/6h/7d/7w/7mo) each panel is
    // currently viewing -- kept here (not just read off SysmonSvc directly)
    // so each GraphPill's active-tier button highlight has somewhere to
    // bind to; setting one also tells SysmonSvc to reconnect that metric's
    // socket at the new tier (process-wide, see SysmonSvc.qml).
    property string netTier: "10m"
    property string cpuTier: "10m"
    property string memTier: "10m"
    property string diskTier: "10m"
    property string tempTier: "10m"
    property string gpuTier: "10m"

    function panelExpandedFor(name: string): bool {
        switch (name) {
        case "calendar": return calendarExpanded.expanded;
        case "claudeUsage": return claudeUsageExpanded.expanded;
        case "gpu": return gpuPill.expanded;
        case "temp": return tempPill.expanded;
        case "disk": return diskPill.expanded;
        case "mem": return memPill.expanded;
        case "cpu": return cpuPill.expanded;
        case "net": return netPill.expanded;
        case "media": return mediaExpanded.expanded;
        default: return false;
        }
    }

    // This panel's right edge with nothing else open -- directly below its
    // own trigger pill, right-aligned to it.
    function naturalRightFor(name: string): real {
        switch (name) {
        case "calendar": return rightRow.x + clockLoader.x + clockLoader.width;
        case "claudeUsage": return rightRow.x + claudeUsagePill.x + claudeUsagePill.width;
        case "gpu": return rightRow.x + gpuPill.x + gpuPill.width;
        case "temp": return rightRow.x + tempPill.x + tempPill.width;
        case "disk": return rightRow.x + diskPill.x + diskPill.width;
        case "mem": return rightRow.x + memPill.x + memPill.width;
        case "cpu": return rightRow.x + cpuPill.x + cpuPill.width;
        case "net": return rightRow.x + netPill.x + netPill.width;
        case "media": return rightRow.x + mediaLoader.x + mediaLoader.width;
        default: return rightRow.x + rightRow.width;
        }
    }

    // Shared Y for every panel -- all their trigger pills sit in the same
    // row at the same height, and every popup panel now stays on that one
    // row too (see below), so there's only ever this one Y.
    readonly property real panelY: rightRow.y + (Theme.barHeight - 10) + 6

    // Hard ceiling on how tall a popup panel may render: shell.qml sizes the
    // layer-shell surface to the full monitor height, so a panel can grow
    // down to the bottom of the screen (the calendar's agenda list does,
    // when a long selection has more entries than fit) and scroll past that.
    readonly property real maxPanelHeight: root.screen.height - root.panelY - 24

    // --- Popup panels (media, net/cpu/mem/disk/temp, calendar): shared
    // dynamic width, always one row -----------------------------------
    // One shared layout system for every panel that pops out of the bar.
    // Media/calendar used to run through a separate single-row `stackRight`
    // sweep while the 5 sysmon graph panels had their own row-*wrapping*
    // system; the two disagreeing about a panel's real width/position once
    // panels from both groups were open together is what let a panel run
    // off the left edge of the screen, or let calendar render directly on
    // top of an open graph panel instead of shifting clear of it (both
    // reported 2026-08-30). `panelOrder` above (bar-visual left-to-right
    // order, matching rightRow's child order, with calendar's clock
    // trigger last since it's the rightmost) is the single ordering this
    // whole system is built on now.
    //
    // Deliberately no row-wrapping: a second row was tried and rejected
    // (reported 2026-08-30, unusable) -- instead every open panel always
    // shares the one row, and width just keeps dividing evenly among
    // however many are open, with only a tiny sanity floor. All 7 open at
    // once on a ~1920px monitor lands around 260px each, which is
    // considered an acceptable, rare edge case rather than something worth
    // solving with e.g. spilling onto a neighboring monitor's own bar
    // (floated and deliberately skipped -- that would need real IPC
    // between separate per-monitor Bar.qml instances, since each one's
    // layer-shell surface is tied to a single output and can't render onto
    // another monitor's screen). screen.width is THIS monitor's own
    // (Bar.qml runs once per screen, via shell.qml's Variants), so this
    // still scales with whatever resolution/monitor it's actually running
    // on, not a hardcoded pixel target.
    readonly property var openPanels: root.panelOrder.filter(n => root.panelExpandedFor(n))
    readonly property int openCount: root.openPanels.length

    // Flush to the rightmost-open panel's own natural pill position, NOT
    // the screen's right edge -- that pill usually isn't at the true edge
    // (temp's own natural spot still has battery+clock to its right, and
    // calendar's is the clock itself), so sizing off the full screen width
    // overstated how much room the row actually has and ran the leftmost
    // panel(s) off the left edge once several were open (reported
    // 2026-08-29). This is the real, single source of truth for it.
    readonly property real rowRightAnchor: root.openCount > 0
        ? root.naturalRightFor(root.openPanels[root.openCount - 1])
        : root.screen.width - 20
    readonly property real panelAreaWidth: root.rowRightAnchor - 10
    // Sanity floor -- keeps the shrink-to-fit below from ever reaching
    // 0/negative if something pathological happens, not a legibility target.
    readonly property real minPanelWidth: 40
    readonly property real panelGap: 6

    // Per-panel PREFERRED width. The graph pills / media want a normal 560
    // (or less if the row is genuinely that narrow); the calendar wants half
    // the monitor -- its month grid + grouped agenda list need the room.
    // This is what each panel gets whenever the row has space for everyone's
    // preferred width; only when the sum overflows does widthScale below pull
    // them all in together (so panels don't shrink from the calendar merely
    // being open, only from actually running out of screen).
    readonly property real stdPanelWidth: Math.min(560, root.panelAreaWidth)
    readonly property real calPanelWidth: Math.min(root.screen.width / 2, root.panelAreaWidth)
    // The process table's columns (status/title/tokens/last/tmux session-
    // window-pane/hyprland #-monitor/pid/path) don't fit the standard 560
    // without squeezing title down to near-nothing -- wider by default
    // (760 -> 920 request 2026-09-01, then 920 -> 1196 the same day
    // alongside adding the hyprland column group), though still well
    // short of the calendar's half-monitor. 1196 is a ceiling now, not a
    // flat width -- shrinks to whatever the table actually needs
    // (claudeUsageExpanded.naturalContentWidth, sum of every column's own
    // width) down to claudeUsageMinWidth, so a near-empty panel (few/no
    // live processes) doesn't sit mostly blank at max width, and a
    // genuinely wide table (many long paths) can still claim more room up
    // to the ceiling instead of always being clipped at a flat constant
    // (request 2026-09-02: "current width... was meant to be only a
    // maximum, add a reasonable minimum").
    readonly property real claudeUsageMinWidth: 320
    readonly property real claudeUsagePanelWidth: Math.min(
        Math.max(claudeUsageExpanded.naturalContentWidth, root.claudeUsageMinWidth),
        1196, root.panelAreaWidth)

    function preferredWidthFor(name: string): real {
        if (name === "calendar")
            return root.calPanelWidth;
        if (name === "claudeUsage")
            return root.claudeUsagePanelWidth;
        return root.stdPanelWidth;
    }

    // 1 while every open panel's preferred width still fits the row (with
    // gaps); below 1 once they don't, shrinking everyone by the same factor.
    readonly property real widthScale: {
        if (root.openCount === 0)
            return 1;
        let sum = 0;
        for (const n of root.openPanels)
            sum += root.preferredWidthFor(n);
        const avail = root.panelAreaWidth - (root.openCount - 1) * root.panelGap;
        return sum > avail ? avail / sum : 1;
    }

    function widthFor(name: string): real {
        return Math.max(root.minPanelWidth, root.preferredWidthFor(name) * root.widthScale);
    }

    // This panel's right edge -- columns fill right-to-left within the one
    // row (matching the pills' own left-to-right order in the bar), each
    // panel offset past the actual widths of the ones to its right.
    function layoutFor(name: string): var {
        const idx = root.openPanels.indexOf(name);
        if (idx < 0)
            return { right: 0, width: 0 };
        let offset = 0;
        for (let i = idx + 1; i < root.openPanels.length; i++)
            offset += root.widthFor(root.openPanels[i]) + root.panelGap;
        return { right: root.rowRightAnchor - offset, width: root.widthFor(name) };
    }

    // How tall this panel's own expand area currently is (0 while
    // collapsed) -- GraphPill exposes this as `overflowHeight`;
    // MediaExpanded/CalendarExpanded's own `height` already means the same
    // thing, since their implicitHeight collapses to 0 when not expanded.
    function overflowHeightFor(name: string): real {
        switch (name) {
        case "net": return netPill.overflowHeight;
        case "cpu": return cpuPill.overflowHeight;
        case "mem": return memPill.overflowHeight;
        case "disk": return diskPill.overflowHeight;
        case "temp": return tempPill.overflowHeight;
        case "gpu": return gpuPill.overflowHeight;
        case "media": return mediaExpanded.height;
        case "calendar": return calendarExpanded.height;
        case "claudeUsage": return claudeUsageExpanded.height;
        default: return 0;
        }
    }

    // Every open panel is in the same one row now, so its Y is always the
    // shared baseline -- kept as a named function (rather than inlining
    // `root.panelY` at each binding site below) so a future panel kind
    // that genuinely needs to differ only has one place to change.
    function panelYFor(name: string): real {
        return root.panelY;
    }

    // The one row's height: the tallest currently-open panel's own expand
    // area. This is `overflow` (and so `totalHeight`) directly.
    readonly property real panelGridHeight: {
        let h = 0;
        for (const n of root.openPanels)
            h = Math.max(h, root.overflowHeightFor(n));
        return h;
    }

    // Leftmost edge of any currently-open panel's own rendered rectangle
    // -- screen.width (i.e. a zero-width region) when nothing's open.
    // shell.qml's input mask uses this to keep the *expanded-panel* click
    // region only as wide as where panels actually render, separate from
    // the always-full-width bar-pill strip above it. A single full-width
    // rectangle sized off panelGridHeight alone (the original version)
    // meant any panel tall enough -- ClaudeUsageExpanded routinely
    // reaches close to the full monitor height now -- turned nearly the
    // *entire screen* into a click-blocking overlay, since that one
    // rectangle's width was always the full monitor regardless of which
    // panel was actually open. Reported "block[s] everything" 2026-08-31.
    readonly property real openPanelsLeftEdge: {
        if (root.openCount === 0)
            return root.screen.width;
        let minX = Infinity;
        for (const n of root.openPanels)
            minX = Math.min(minX, root.layoutFor(n).right - root.widthFor(n));
        return minX;
    }

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

    // Every one of these re-derives its data from scratch (new arrays,
    // color lookups, spread over up to 600 samples) on every SysmonSvc tick
    // -- i.e. every second, forever, whether or not the panel is even
    // visible. Gating each on its own pill's `expanded` turns that into a
    // one-line early return when collapsed instead of doing the real work,
    // which is what was making `qs` itself the top CPU consumer (43% of a
    // core) and measurably contributing to the temperature widget's own
    // readings, 2026-08-27.
    readonly property var netLegend: netPill.expanded ? SysmonSvc.netInterfaces.map(i => ({ name: i.name, color: root.colorFor(i.name) })) : []
    readonly property var netSeriesList: {
        if (!netPill.expanded)
            return [];
        const out = [];
        for (const iface of SysmonSvc.netInterfaces) {
            const c = root.colorFor(iface.name);
            out.push({ data: iface.rx_bps, color: c, dashed: false });
            out.push({ data: iface.tx_bps, color: c, dashed: true });
        }
        return out;
    }
    readonly property real netMax: {
        if (!netPill.expanded)
            return 1024;
        let m = 1024;
        for (const iface of SysmonSvc.netInterfaces) {
            m = Math.max(m, ...iface.rx_bps, ...iface.tx_bps);
        }
        return m;
    }
    readonly property real netTotalNow: {
        // Cheap regardless (only reads each array's last element) and
        // needed for the always-visible compact pill text, so this one
        // stays ungated.
        let rx = 0, tx = 0;
        for (const iface of SysmonSvc.netInterfaces) {
            rx += root.last(iface.rx_bps);
            tx += root.last(iface.tx_bps);
        }
        return rx + tx;
    }

    // Overlay (one line per core), not stacked -- stacking summed
    // percentages across cores into an arbitrary "200%"-tall shape read as
    // confusing; separate overlaid lines show each core's own load clearly.
    readonly property var cpuOverlayList: cpuPill.expanded ? SysmonSvc.cpuCores.map((c, i) => ({ data: c, color: root.palette[i % root.palette.length], dashed: false })) : []

    readonly property var memLegend: [
        { name: qsTr("Used"), color: Theme.green },
        { name: qsTr("Cached"), color: Theme.cyan },
        { name: qsTr("Swap"), color: Theme.orange }
    ]
    readonly property var memSeriesList: memPill.expanded ? [
        { data: SysmonSvc.memUsedPct, color: Theme.green, dashed: false },
        { data: SysmonSvc.memCachedPct, color: Theme.cyan, dashed: true },
        { data: SysmonSvc.swapUsedPct, color: Theme.orange, dashed: false }
    ] : []

    readonly property var diskLegend: diskPill.expanded ? SysmonSvc.diskDevices.map(d => ({ name: d.name, color: root.colorFor(d.name) })) : []
    readonly property var diskSeriesList: {
        if (!diskPill.expanded)
            return [];
        const out = [];
        for (const dev of SysmonSvc.diskDevices) {
            const c = root.colorFor(dev.name);
            out.push({ data: dev.read_bps, color: c, dashed: false });
            out.push({ data: dev.write_bps, color: c, dashed: true });
        }
        return out;
    }
    readonly property real diskMax: {
        if (!diskPill.expanded)
            return 1024;
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

    // GPU: every GPU's lines overlaid on one 0..100 axis -- each GPU's
    // utilisation, plus the dGPU's VRAM-occupancy (dashed) and power
    // (% of TGP) lines. The iGPU has no VRAM/power line (shared system RAM,
    // no board-power telemetry). Colours are taken from seriesPalette at a
    // stride of 2 so they stay far apart in hue no matter how the theme is
    // regenerated (adjacent indices had collided). Legend labels are short
    // -- "iGPU"/"dGPU" are the util lines, "VRAM"/"power" the dGPU extras.
    // gpuSections is one titled block per GPU (its detail rows + its own
    // process table); gated on the pill being open so it's not rebuilt
    // every tick while collapsed (see the comment on netLegend above).
    function gpuTag(g) { return g.vendor === "intel" ? qsTr("iGPU") : qsTr("dGPU"); }
    // Stride 3 over the 8-hue palette is a full permutation (gcd(3,8)=1), so
    // up to 8 lines stay maximally far apart in hue no matter how the theme
    // regenerates.
    function gpuLineColor(i) {
        const p = Theme.seriesPalette;
        return p[(i * 3) % p.length];
    }
    // [{ data?, color, dashed, name }] in draw order -- the single source
    // both the graph series and the legend derive from, so their colours
    // can't drift apart. Every line is labelled "<tag> <metric>" in full.
    // The iGPU's "memory" is shared system RAM (no dedicated VRAM), and it
    // has no board-power line -- CometLake exposes no RAPL GPU domain.
    readonly property var gpuLines: {
        const out = [];
        for (const g of SysmonSvc.gpuList) {
            const tag = gpuTag(g);
            const memLabel = g.vendor === "intel" ? qsTr("memory") : qsTr("VRAM");
            if ((g.util_pct?.length ?? 0) > 0)
                out.push({ data: g.util_pct, dashed: false, name: tag + " " + qsTr("utilization") });
            if ((g.vram_pct?.length ?? 0) > 0)
                out.push({ data: g.vram_pct, dashed: true, name: tag + " " + memLabel });
            if ((g.power_pct?.length ?? 0) > 0)
                out.push({ data: g.power_pct, dashed: false, name: tag + " " + qsTr("power") });
        }
        return out.map((l, i) => Object.assign(l, { color: gpuLineColor(i) }));
    }
    readonly property var gpuLegend: root.gpuLines.map(l => ({ name: l.name, color: l.color }))
    readonly property var gpuSeriesList: gpuPill.expanded
        ? root.gpuLines.map(l => ({ data: l.data, color: l.color, dashed: l.dashed }))
        : []
    // One section per GPU -- its detail rows and its own "Top processes"
    // table, under a single heading so the GPU name isn't repeated.
    readonly property var gpuSections: {
        if (!gpuPill.expanded)
            return [];
        return SysmonSvc.gpuList.map(g => {
            const rows = [];
            const memName = g.vendor === "intel" ? qsTr("Memory (shared)") : qsTr("VRAM");
            if ((g.vram_total_mb ?? 0) > 0)
                rows.push({ name: memName, value: Math.round(g.vram_used_mb ?? 0) + " / " + Math.round(g.vram_total_mb) + " MB" });
            else if ((g.vram_used_mb ?? 0) > 0)
                rows.push({ name: memName, value: Math.round(g.vram_used_mb) + " MB" });
            if ((g.temp_c ?? 0) > 0)
                rows.push({ name: qsTr("Temperature"), value: Math.round(g.temp_c) + "°C" });
            if ((g.power_w ?? 0) > 0) {
                let p = g.power_w.toFixed(1) + " W";
                if ((g.power_limit_w ?? 0) > 0)
                    p += " / " + Math.round(g.power_limit_w) + " W";
                rows.push({ name: qsTr("Power draw"), value: p });
            }
            if ((g.sm_clock_mhz ?? 0) > 0)
                rows.push({ name: g.vendor === "intel" ? qsTr("Frequency") : qsTr("Core clock"), value: Math.round(g.sm_clock_mhz) + " MHz" });
            if ((g.mem_clock_mhz ?? 0) > 0)
                rows.push({ name: qsTr("Memory clock"), value: Math.round(g.mem_clock_mhz) + " MHz" });
            if ((g.enc_pct ?? 0) > 0 || (g.dec_pct ?? 0) > 0)
                rows.push({ name: g.vendor === "intel" ? qsTr("Video") : qsTr("Encode / decode"),
                            value: g.vendor === "intel"
                                ? Math.round(g.dec_pct) + "%"
                                : Math.round(g.enc_pct ?? 0) + "% / " + Math.round(g.dec_pct ?? 0) + "%" });
            if ((g.fan_pct ?? 0) > 0)
                rows.push({ name: qsTr("Fan"), value: Math.round(g.fan_pct) + "%" });
            return { label: g.name, rows: rows, procs: g.procs ?? [], procUnit: " MB" };
        });
    }

    // Compact pill: each GPU's utilisation side by side (iGPU then dGPU),
    // with the dGPU's VRAM occupancy as the divider-less secondary reading.
    readonly property var gpuNvidia: {
        for (const g of SysmonSvc.gpuList)
            if (g.vendor === "nvidia")
                return g;
        return null;
    }
    // "i 15 % · d 32 %" -- i/d prefix so the two GPUs' utilisations are
    // distinguishable in the compact pill without spelling out iGPU/dGPU.
    // Single-digit values get a leading space so each "<x> NN %" segment is
    // a fixed width in the monospace bar font -- the second GPU's letter
    // then never shifts as the first GPU's number crosses 10. A 100% is
    // three digits and does push things (an intentional "maxed" cue).
    readonly property string gpuCompactText: SysmonSvc.gpuList
        .map(g => {
            const n = Math.round(root.last(g.util_pct ?? []));
            return (g.vendor === "intel" ? "i " : "d ") + (n < 10 ? " " + n : n) + " %";
        })
        .join(" · ")
    // Fixed width sized for two-digit values so the pill doesn't jitter as
    // the numbers change; a rare 100% is allowed to push past it (and the
    // resize then reads as "something's maxed"). See gpuCompactMetrics.
    readonly property real gpuMaxUtil: {
        let m = 0;
        for (const g of SysmonSvc.gpuList)
            m = Math.max(m, root.last(g.util_pct ?? []));
        return m;
    }
    readonly property real gpuNvVram: root.gpuNvidia ? root.last(root.gpuNvidia.vram_pct ?? []) : NaN

    TextMetrics {
        id: gpuCompactMetrics
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize
        text: SysmonSvc.gpuList.map(g => (g.vendor === "intel" ? "i " : "d ") + "88 %").join(" · ")
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
            valueFraction: Theme.norm(root.netTotalNow, 0, 6 * 1024 * 1024)
            legendItems: root.netLegend
            topProcs: SysmonSvc.topNet
            topUnit: " KB/s"
            yAxisFormatter: v => root.fmtRate(v)
            tierCodes: SysmonSvc.tierCodes
            tierLabels: SysmonSvc.tierLabels
            tier: root.netTier
            onTierRequested: code => { root.netTier = code; SysmonSvc.setNetTier(code); }
            onExpandedChanged: if (!expanded) root.reclaimGraphFocus(netPill)
            groupX: rightRow.x
            groupY: rightRow.y
            targetRight: root.layoutFor("net").right
            targetY: root.panelYFor("net")
            expandWidth: root.widthFor("net")
        }

        GraphPill {
            id: cpuPill
            icon: Icons.cpu
            title: qsTr("CPU")
            compactText: Math.round(root.last(SysmonSvc.cpuTotal)) + "%"
            valueLabel: compactText
            mode: "overlay"
            seriesList: root.cpuOverlayList
            maxValue: 100
            valueFraction: root.last(SysmonSvc.cpuTotal) / 100
            topProcs: SysmonSvc.topCpu
            topUnit: "%"
            yAxisFormatter: v => Math.round(v) + "%"
            tierCodes: SysmonSvc.tierCodes
            tierLabels: SysmonSvc.tierLabels
            tier: root.cpuTier
            onTierRequested: code => { root.cpuTier = code; SysmonSvc.setCpuTier(code); }
            onExpandedChanged: if (!expanded) root.reclaimGraphFocus(cpuPill)
            groupX: rightRow.x
            groupY: rightRow.y
            targetRight: root.layoutFor("cpu").right
            targetY: root.panelYFor("cpu")
            expandWidth: root.widthFor("cpu")
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
            valueFraction: root.last(SysmonSvc.memUsedPct) / 100
            // Always-visible second reading in the same box, not just inside
            // the hover graph -- swap can be under pressure while memory
            // itself looks fine, and that's worth seeing at a glance.
            secondaryIcon: Icons.swap
            secondaryText: Math.round(root.last(SysmonSvc.swapUsedPct)) + "%"
            secondaryDivider: false
            secondaryValueFraction: root.last(SysmonSvc.swapUsedPct) / 100
            legendItems: root.memLegend
            topProcs: SysmonSvc.topMem
            topUnit: " MB"
            yAxisFormatter: v => Math.round(v) + "%"
            tierCodes: SysmonSvc.tierCodes
            tierLabels: SysmonSvc.tierLabels
            tier: root.memTier
            onTierRequested: code => { root.memTier = code; SysmonSvc.setMemTier(code); }
            onExpandedChanged: if (!expanded) root.reclaimGraphFocus(memPill)
            groupX: rightRow.x
            groupY: rightRow.y
            targetRight: root.layoutFor("mem").right
            targetY: root.panelYFor("mem")
            expandWidth: root.widthFor("mem")
        }

        GraphPill {
            id: diskPill
            // No primary icon here -- the pill shows one disk glyph total,
            // moved to the secondary (rightmost) slot below instead of
            // having one on each side of the divider.
            title: qsTr("Disk")
            compactText: root.fmtRate(root.diskTotalNow)
            compactTextWidth: 72
            valueLabel: root.fmtRate(root.diskTotalNow) + " total"
            mode: "overlay"
            seriesList: root.diskSeriesList
            maxValue: root.diskMax
            valueFraction: Theme.norm(root.diskTotalNow, 0, 300 * 1024 * 1024)
            // Always-visible second reading, same pattern as memPill's
            // swap readout above -- how full the root filesystem is, next
            // to the pill's own I/O-throughput value, without needing to
            // open the panel.
            secondaryIcon: Icons.disk
            secondaryText: (isNaN(SysmonSvc.rootUsagePct) ? "--" : Math.round(SysmonSvc.rootUsagePct)) + "% "
            secondaryDivider: false
            secondaryValueFraction: SysmonSvc.rootUsagePct / 100
            legendItems: root.diskLegend
            usageItems: SysmonSvc.diskUsage
            topProcs: SysmonSvc.topDisk
            topUnit: " KB/s"
            yAxisFormatter: v => root.fmtRate(v)
            tierCodes: SysmonSvc.tierCodes
            tierLabels: SysmonSvc.tierLabels
            tier: root.diskTier
            onTierRequested: code => { root.diskTier = code; SysmonSvc.setDiskTier(code); }
            onExpandedChanged: if (!expanded) root.reclaimGraphFocus(diskPill)
            groupX: rightRow.x
            groupY: rightRow.y
            targetRight: root.layoutFor("disk").right
            targetY: root.panelYFor("disk")
            expandWidth: root.widthFor("disk")
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
            valueFraction: Theme.norm(root.last(SysmonSvc.tempC), 45, 90)
            topProcs: SysmonSvc.topCpu
            topUnit: "%"
            topLabel: qsTr("Top CPU (heat proxy)")
            yAxisFormatter: v => Math.round(v) + "°C"
            tierCodes: SysmonSvc.tierCodes
            tierLabels: SysmonSvc.tierLabels
            tier: root.tempTier
            onTierRequested: code => { root.tempTier = code; SysmonSvc.setTempTier(code); }
            onExpandedChanged: if (!expanded) root.reclaimGraphFocus(tempPill)
            groupX: rightRow.x
            groupY: rightRow.y
            targetRight: root.layoutFor("temp").right
            targetY: root.panelYFor("temp")
            expandWidth: root.widthFor("temp")
        }

        // NVIDIA GPU -- hidden entirely on a machine with no NVIDIA GPU
        // (SysmonSvc.gpuPresent stays false, a Row skips invisible
        // children). Primary reading is engine load; VRAM occupancy rides
        // along as the always-visible secondary value, same divider-less
        // layout as diskPill's root-fs fill. mod+g toggles the panel
        // (keybinds.lua -> bar-toggle.sh toggleGpu).
        GraphPill {
            id: gpuPill
            visible: SysmonSvc.gpuPresent
            icon: Icons.gpu
            // The MDI expansion-card glyph draws small in its em box --
            // bump it to sit at the same visual height as the FA icons on
            // the other pills.
            iconPixelSize: Theme.fontSize + 7
            title: qsTr("GPU")
            compactText: root.gpuCompactText
            compactTextWidth: Math.ceil(gpuCompactMetrics.width) + 2
            valueLabel: SysmonSvc.gpuList.map(g => root.gpuTag(g) + " " + Math.round(root.last(g.util_pct ?? [])) + "%").join("   ")
            mode: "overlay"
            seriesList: root.gpuSeriesList
            maxValue: 100
            valueFraction: root.gpuMaxUtil / 100
            secondaryIcon: isNaN(root.gpuNvVram) ? "" : Icons.memory
            secondaryText: isNaN(root.gpuNvVram) ? "" : Math.round(root.gpuNvVram) + "%"
            secondaryDivider: false
            secondaryValueFraction: root.gpuNvVram / 100
            legendItems: root.gpuLegend
            sections: root.gpuSections
            yAxisFormatter: v => Math.round(v) + "%"
            tierCodes: SysmonSvc.tierCodes
            tierLabels: SysmonSvc.tierLabels
            tier: root.gpuTier
            onTierRequested: code => { root.gpuTier = code; SysmonSvc.setGpuTier(code); }
            onExpandedChanged: if (!expanded) root.reclaimGraphFocus(gpuPill)
            groupX: rightRow.x
            groupY: rightRow.y
            targetRight: root.layoutFor("gpu").right
            targetY: root.panelYFor("gpu")
            expandWidth: root.widthFor("gpu")
        }

        BatteryPill {}

        ClaudeUsagePill {
            id: claudeUsagePill
            onToggled: claudeUsageExpanded.expanded = !claudeUsageExpanded.expanded
        }

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
        interval: 0
        onTriggered: mediaExpanded.expanded = false
    }

    MediaExpanded {
        id: mediaExpanded

        panelWidth: root.widthFor("media")
        x: root.layoutFor("media").right - width
        y: root.panelYFor("media")
        // Take keyboard control on open (so a previously-focused graph pill
        // stops eating the arrow keys), hand it on when closing.
        onExpandedChanged: expanded ? root.forceActiveFocus() : root.refocusActivePanel()
    }

    // Same pattern for the clock's calendar hover-panel. Click-to-pin
    // mirrors GraphPill.togglePin() (net/cpu/mem/disk/temp): stays open
    // past hover-out until clicked again.
    property bool clockAreaHovered: clockHoverArea.containsMouse || calendarExpanded.hovered
    property bool clockPinned: false

    onClockAreaHoveredChanged: {
        if (clockAreaHovered) {
            clockHoverOutTimer.stop();
            calendarExpanded.expanded = true;
        } else if (!clockPinned) {
            clockHoverOutTimer.restart();
        }
    }

    Timer {
        id: clockHoverOutTimer
        interval: 0
        onTriggered: calendarExpanded.expanded = false
    }

    // Authoritative over the visible state -- see GraphPill.togglePin(). The
    // old `else if (!clockAreaHovered)` guard let a toggle-off keypress do
    // nothing while the pointer was on the clock or calendar (2026-08-29).
    function toggleClockPin(): void {
        clockHoverOutTimer.stop();
        if (calendarExpanded.expanded) {
            clockPinned = false;
            calendarExpanded.expanded = false;
        } else {
            clockPinned = true;
            calendarExpanded.expanded = true;
        }
    }

    MouseArea {
        id: clockHoverArea
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        x: rightRow.x + clockLoader.x
        y: rightRow.y + clockLoader.y
        width: clockLoader.width
        height: clockLoader.height
        onClicked: root.toggleClockPin()
    }

    CalendarExpanded {
        id: calendarExpanded

        panelWidth: root.widthFor("calendar")
        maxPanelHeight: root.maxPanelHeight
        // Pinned open (mod+CTRL+c or a clock click) -> the month-view layout
        // with event titles under each day; a passing hover stays compact.
        bigMode: root.clockPinned
        x: root.layoutFor("calendar").right - width
        y: root.panelYFor("calendar")
        // Take keyboard control on open (so a previously-focused graph pill
        // stops eating the arrow keys), hand it on when closing.
        onExpandedChanged: expanded ? root.forceActiveFocus() : root.refocusActivePanel()
    }

    // CTRL+ALT+c (keybinds.lua) or a click on claudeUsagePill toggles this.
    // Takes real keyboard control on open the same way media/calendar do
    // (root.Keys.onPressed above handles Escape while this is the open
    // panel) -- originally left out of this machinery since nothing here
    // needed arrow-key nav, but Escape-to-close was explicitly requested
    // and that needs real focus the same way the other panels get it.
    ClaudeUsageExpanded {
        id: claudeUsageExpanded

        screen: root.screen
        panelWidth: root.widthFor("claudeUsage")
        maxPanelHeight: root.maxPanelHeight
        x: root.layoutFor("claudeUsage").right - width
        y: root.panelYFor("claudeUsage")
        onExpandedChanged: expanded ? root.forceActiveFocus() : root.refocusActivePanel()
    }

    // Keyboard shortcuts (hyprland/keybinds.lua: mod+n/p/m/t/d, via
    // ~/.config/hypr/scripts/bar-toggle.sh) call these -- same open/close
    // toggle feel as the old standalone sysmon-graph popups, just for the
    // bar's own panels. Target is per-screen: this file runs once per
    // monitor (shell.qml's Variants over Quickshell.screens), and a shared
    // "bar" target name would collide across those instances -- the script
    // resolves whichever monitor is currently focused to "bar-<name>".
    //
    // No setXxxTier()/closeAllGraphs() functions here anymore -- those
    // existed only to shuttle 1-6/left/right tier keys and reload-time
    // resync through a Hyprland submap that tracked "which panel is open"
    // on the Lua side, in parallel with (and prone to desyncing from) each
    // GraphPill's own real pinned/expanded state. Tier keys now go straight
    // to whichever GraphPill holds real keyboard focus (forceActiveFocus()
    // in GraphPill.togglePin(), shell.qml's HyprlandFocusGrab) the same way
    // the calendar/media panels already worked -- nothing left to desync.
    // Reported 2026-08-29/30.
    IpcHandler {
        target: "bar-" + root.screen.name

        function toggleNet(): void { netPill.togglePin(); }
        function toggleCpu(): void { cpuPill.togglePin(); }
        function toggleMem(): void { memPill.togglePin(); }
        function toggleTemp(): void { tempPill.togglePin(); }
        function toggleDisk(): void { diskPill.togglePin(); }
        function toggleGpu(): void { gpuPill.togglePin(); }
        function toggleMedia(): void { mediaExpanded.expanded = !mediaExpanded.expanded; }
        function toggleCalendar(): void { root.toggleClockPin(); }
        function toggleClaudeUsage(): void { claudeUsageExpanded.expanded = !claudeUsageExpanded.expanded; }
    }
}
