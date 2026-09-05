import QtQuick
import QtQuick.Layouts
import "../theme"
import "../components"

// Compact "value + icon" pill that expands down into a Graph on hover,
// backed by sysmond's rolling history (see services/SysmonSvc.qml) --
// same idea as the KDE Plasma network/cpu graph widgets this replaces,
// and visually matching the existing alt+mod+n/p/t/m sysmon-graph popups.
Rectangle {
    id: root

    property string icon: ""
    // Per-pill override for the compact icon's pixel size -- some glyph sets
    // (Material Design's expansion-card, say) draw much smaller than Font
    // Awesome's inside the same em box, so a pill can bump this to match the
    // others visually. Only the primary icon; the secondary stays at
    // Theme.fontSize.
    property real iconPixelSize: Theme.fontSize
    property string compactText: ""
    // > 0 fixes the compact value's width (right-aligned) so widgets whose
    // text length varies with magnitude (byte rates: "8 KB/s" vs "1.2
    // MB/s") don't constantly resize the whole pill as the value changes.
    property real compactTextWidth: -1
    property string title: ""
    property string valueLabel: ""

    // "single" (series/color1) or "overlay" (seriesList)
    property string mode: "single"
    property list<real> series: []
    property var seriesList: []
    property real maxValue: 100

    // 0..1 (or NaN to opt out): how "high" this metric currently is. Drives
    // the compact value/icon colour along Theme's calm->hot intensity ramp,
    // and -- in single mode -- the graph line/fill colour too.
    property real valueFraction: NaN
    readonly property bool graded: !isNaN(valueFraction)
    readonly property color gradedColor: graded ? Theme.rampColor(valueFraction) : Theme.text

    property color color1: graded ? gradedColor : Theme.cyan

    // Optional second always-visible icon+value in the SAME box, e.g. the
    // memory pill's swap readout -- a separate ramped color from the
    // primary metric since e.g. memory can be comfortable while swap is
    // under pressure (or vice versa). Empty icon (the default) omits this
    // whole group, so every other GraphPill is unaffected.
    property string secondaryIcon: ""
    property string secondaryText: ""
    // When true (default) the secondary group is set off from the primary
    // value by a thin vertical divider; when false they're just separated
    // by blank space (disk pill -- the I/O rate and "/ NN%" read fine
    // without a rule between them).
    property bool secondaryDivider: true
    property real secondaryValueFraction: NaN
    readonly property color secondaryColor: !isNaN(secondaryValueFraction) ? Theme.rampColor(secondaryValueFraction) : Theme.text

    // Formats a raw value (0..maxValue) for the y-axis label column --
    // Bar.qml overrides per-widget (percent for cpu/mem, a byte-rate
    // string for net/disk, "N°C" for temperature).
    property var yAxisFormatter: v => Math.round(v)
    readonly property var gridFractions: [0, 0.25, 0.5, 0.75, 1.0]

    // [{name, color}] -- shown under the graph when non-empty.
    property var legendItems: []
    // [{name, pcent}] -- shown as a labelled bar per entry, under the graph
    // (above legendItems/topProcs) when non-empty. Percent-of-capacity
    // readings (e.g. disk space used) rather than the graph's own
    // time-series metric, so they get their own subsection instead of
    // being folded into legendItems (which is just a color key).
    property var usageItems: []
    // [{ label, rows: [{name, value}], procs: [{name, detail, value}],
    //    procUnit }] -- one titled block per subject (the GPU pill: one per
    // GPU) that carries BOTH its detail rows and its own process table, so
    // the subject's name isn't repeated. Used instead of topProcs when set.
    property var sections: []
    // [{name, value}] -- top-10 list shown when non-empty.
    property var topProcs: []
    property string topUnit: ""
    // Overrides the "Top processes" heading -- used by temperature, where
    // this is really "top CPU users" as a heat proxy, not a real per-
    // process temperature attribution (the kernel has no such thing).
    property string topLabel: qsTr("Top processes")

    // Shared column widths for every "Top processes" table (both the
    // `sections`/GPU-per-section shape and the plain `topProcs` shape) --
    // titled column headers instead of a single generic heading + purely
    // positional text (request 2026-09-06). "executable" (name + sysmond's
    // cmdline-tail/cwd detail, merged into one string) is Layout.fillWidth
    // instead of a fixed width -- a separate detail column used to go
    // `visible: false` when empty, which RowLayout excludes from the row
    // entirely, shifting pid/value left (reported in the memory panel,
    // 2026-09-05). Merging avoids that failure mode in every panel instead
    // of just patching it. "util%" is only ever populated for GPU rows
    // (ProcEntry::util_pct is 0 for cpu/mem/net/disk, which have no
    // equivalent per-process metric), so only the `sections` table includes
    // that column.
    readonly property real procPidW: 42
    readonly property real procUtilW: 34
    readonly property real procValueW: 56

    // Time-range toggle row, shown only when tierCodes is non-empty --
    // Bar.qml wires this up for the 5 sysmond-backed metrics (net/cpu/mem/
    // disk/temp); media/calendar leave it empty and get no row.
    property var tierCodes: []
    property var tierLabels: ({})
    property string tier: "10m"
    signal tierRequested(string code)

    // x-axis (time) ticks for the current tier -- span/step mirror
    // ~/.config/hypr/sysmon/src/lib.rs's Tier::span_secs exactly (the graph's
    // fixed width represents exactly one tier's span, oldest sample at the
    // left edge and "now" at the right -- see Graph.qml's downsample()), so
    // these have to be kept in sync with that table the same way
    // SysmonSvc.qml's tierCodes/tierLabels already duplicate it rather than
    // importing it. step divides span evenly for every tier below.
    readonly property var xAxisTickInfo: ({
        "10m": { span: 600,       step: 120,     div: 60,      unit: "m" },
        "30m": { span: 1800,      step: 300,     div: 60,      unit: "m" },
        "6h":  { span: 21600,     step: 3600,    div: 3600,    unit: "h" },
        "7d":  { span: 604800,    step: 86400,   div: 86400,   unit: "d" },
        "7w":  { span: 4233600,   step: 604800,  div: 604800,  unit: "w" },
        "7mo": { span: 18144000,  step: 2592000, div: 2592000, unit: "mo" },
    })
    readonly property var xAxisTicks: {
        const info = root.xAxisTickInfo[root.tier];
        if (!info)
            return [];
        const ticks = [];
        for (let ago = 0; ago <= info.span; ago += info.step) {
            ticks.push({
                fraction: 1 - ago / info.span,
                label: ago === 0 ? qsTr("now") : ((ago / info.div) + info.unit),
            });
        }
        return ticks;
    }

    property bool expanded: false
    // Set by a click on the pill (or Bar.qml's IpcHandler, for the mod+t
    // style keybind toggles) -- while pinned, hovering off no longer closes
    // the panel; only clicking again (or the keybind again) does.
    property bool pinned: false

    // "Top processes" no longer streams continuously in the background
    // (2026-09-05 on-demand panel data) -- sysmond only starts collecting
    // it once this panel actually opens, so there's a real gap (nethogs/
    // nvidia-smi pmon spawning, or a couple of sample_loop ticks to build
    // a delta baseline) before the first real batch arrives. Rather than
    // the whole table popping into existence once that arrives (a layout
    // jump, reported 2026-09-06: "may get confusing"), it shows up
    // immediately as 10 placeholder rows (top_n(...) never returns more
    // than that server-side, so 10 is always a safe reserved size) that
    // melt into the real, correctly-sized list the instant data lands.
    // Reset on every fresh open so a reopen shows placeholders again
    // rather than briefly reusing whatever the panel showed last time.
    // `sectionsEverArrived` is keyed by section label since the GPU pill's
    // two sections (iGPU/dGPU) can arrive at very different times --
    // Intel's is nearly instant (just gates an already-running loop's
    // ranking step), NVIDIA's waits on nvidia-smi pmon to spawn.
    property bool topProcsEverArrived: false
    property var sectionsEverArrived: ({})
    onExpandedChanged: {
        if (expanded) {
            topProcsEverArrived = false;
            sectionsEverArrived = {};
        }
    }
    onTopProcsChanged: {
        if (root.topProcs.length > 0)
            root.topProcsEverArrived = true;
    }
    onSectionsChanged: {
        for (const s of root.sections) {
            if ((s.procs ?? []).length > 0 && !root.sectionsEverArrived[s.label]) {
                const updated = Object.assign({}, root.sectionsEverArrived);
                updated[s.label] = true;
                root.sectionsEverArrived = updated;
            }
        }
    }
    readonly property bool hovered: hoverArea.containsMouse || expandPanel.hovered
    // Bar.qml reads this to size the window; 0 when collapsed.
    readonly property real overflowHeight: expandPanel.height
    // Bar.qml reads this to lay out multiple simultaneously-open panels
    // side by side instead of each self-positioning under its own pill
    // (which overlaps once more than one is expanded at once).
    readonly property real panelWidth: expandPanel.width
    // Set by Bar.qml when coordinating a multi-panel layout, so several
    // open panels stack side by side instead of overlapping. Both in
    // Bar.qml's own root coordinate space, since this pill lives inside
    // rightRow and doesn't know its own absolute position otherwise.
    // targetRight NaN falls back to this pill's own default (directly
    // below itself, right-aligned to its own right edge).
    property real groupX: 0
    property real targetRight: NaN
    // Same idea, vertically -- Bar.qml's graph widgets use this to stack
    // into multiple rows once too many are open to fit one row's width.
    // targetY NaN falls back to this pill's own default (directly below
    // itself).
    property real groupY: 0
    property real targetY: NaN
    // Bar.qml's graph widgets shrink this as more of them are open (and
    // widen it when only one/few are) instead of a fixed width, so the
    // panel(s) actually fit the screen they're on.
    property real expandWidth: 480

    onHoveredChanged: {
        if (hovered) {
            hideTimer.stop();
            expanded = true;
        } else if (!pinned) {
            hideTimer.restart();
        }
    }

    // 0, not a real debounce delay -- a bare `expanded = false` on hover-out
    // still works, but going through requestAnimationFrame-ish next-tick
    // timing here avoids a same-frame close+reopen flicker if the pointer
    // is exactly on the pill/panel boundary for an instant. Closes on the
    // very next event loop tick either way, i.e. instantly from a human
    // perspective -- the previous 250ms was what let sweeping the mouse
    // across several pills leave multiple panels open at once.
    Timer {
        id: hideTimer
        interval: 0
        onTriggered: root.expanded = false
    }

    // Click / keybind toggle (Bar.qml's IpcHandler calls this too). Branches
    // on `pinned`, not `expanded` -- hovering the pill already sets
    // `expanded = true` on its own, so a click while hovering would
    // otherwise always land on the "close" branch and the panel could never
    // be pinned open (reported 2026-08-29). It's still authoritative over
    // the current visible state: toggling a panel closed closes it NOW even
    // if the pointer is sitting on the pill or the panel (the old
    // `else if (!hovered)` guard made the keypress do nothing until the
    // mouse moved away -- reported 2026-08-29). Moving the pointer off and
    // back on can still reopen it via hover; that's a separate path.
    //
    // Claims real keyboard focus on open via forceActiveFocus() -- see
    // Keys.onPressed below and shell.qml's HyprlandFocusGrab (the same
    // mechanism the calendar/media panels use). QML only lets one item
    // hold focus within a scope at a time, so this doubles as "whichever
    // panel was opened/clicked last" tracking -- no separate bookkeeping
    // needed, unlike the old Hyprland-submap version of this (2026-08-29).
    function togglePin(): void {
        hideTimer.stop();
        if (pinned) {
            pinned = false;
            expanded = false;
        } else {
            pinned = true;
            expanded = true;
            forceActiveFocus();
        }
    }

    // 1-6 jumps straight to a tier, left/right steps by one -- left towards
    // *bigger* periods (10m -> ... -> 7mo), right towards smaller, matching
    // GraphPill's tierCodes ordering. Escape closes, same as the calendar/
    // media panels. Only live while this pill actually holds keyboard focus
    // (forceActiveFocus() above, and shell.qml only grants the *window*
    // real keyboard input while at least one panel is expanded) -- replaces
    // the old graph_nav Hyprland submap, which could only ever act on one
    // widget at a time and regularly desynced from which panels were
    // actually open (reported 2026-08-29).
    Keys.onPressed: event => {
        if (root.tierCodes.length === 0)
            return;
        const idx = root.tierCodes.indexOf(root.tier);
        if (event.key >= Qt.Key_1 && event.key <= Qt.Key_6) {
            const i = event.key - Qt.Key_1;
            if (i < root.tierCodes.length) {
                root.tierRequested(root.tierCodes[i]);
                event.accepted = true;
            }
        } else if (event.key === Qt.Key_Left) {
            if (idx >= 0 && idx < root.tierCodes.length - 1)
                root.tierRequested(root.tierCodes[idx + 1]);
            event.accepted = true;
        } else if (event.key === Qt.Key_Right) {
            if (idx > 0)
                root.tierRequested(root.tierCodes[idx - 1]);
            event.accepted = true;
        } else if (event.key === Qt.Key_Escape) {
            root.togglePin();
            event.accepted = true;
        }
    }

    implicitWidth: compactRow.implicitWidth + Theme.pillPadH * 2
    implicitHeight: Theme.barHeight - 10
    width: implicitWidth
    height: implicitHeight

    color: Theme.bgAlpha
    border.color: Theme.border
    border.width: 1
    radius: Theme.rounding

    Row {
        id: compactRow
        anchors.centerIn: parent
        spacing: 4

        Text {
            text: root.icon
            font.family: Theme.iconFontFamily
            font.pixelSize: root.iconPixelSize
            color: root.gradedColor
            anchors.verticalCenter: parent.verticalCenter
        }

        Text {
            text: root.compactText
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
            color: root.gradedColor
            // compactTextWidth pins a minimum so the pill doesn't jitter on
            // routine value changes, but content wider than it (a byte rate
            // that grew a unit, a GPU hitting 100%) still expands the pill
            // rather than clipping. Right-aligned so the value sits flush
            // against the pill's trailing edge -- icon leads on the left
            // (see above), value trails on the right, any padding slack
            // falls in between instead of next to either one.
            width: root.compactTextWidth > 0 ? Math.max(root.compactTextWidth, implicitWidth) : implicitWidth
            horizontalAlignment: Text.AlignRight
            anchors.verticalCenter: parent.verticalCenter
        }

        Rectangle {
            visible: root.secondaryText.length > 0 && root.secondaryDivider
            width: 1
            height: parent.height * 0.6
            anchors.verticalCenter: parent.verticalCenter
            color: Theme.border
        }

        // Divider suppressed (secondaryDivider: false): keep an equivalent
        // gap so the primary and secondary readings stay visually separated.
        Item {
            visible: root.secondaryText.length > 0 && !root.secondaryDivider
            width: 2
            height: 1
        }

        // Secondary icon is optional: a reading that's genuinely a
        // different metric (e.g. swap next to memory) gets its own glyph;
        // one that's just another view of the primary metric (e.g. disk
        // usage % next to disk I/O) leans on the pill's primary icon
        // instead and only shows its text here.
        Text {
            visible: root.secondaryIcon.length > 0
            text: root.secondaryIcon
            font.family: Theme.iconFontFamily
            font.pixelSize: Theme.fontSize
            color: root.secondaryColor
            anchors.verticalCenter: parent.verticalCenter
        }

        Text {
            visible: root.secondaryText.length > 0
            text: root.secondaryText
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
            color: root.secondaryColor
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    MouseArea {
        id: hoverArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.togglePin()
    }

    // Overlay child, not in-flow: extends below root's own bounds without
    // affecting the row layout it sits in. No height animation -- animating
    // this resizes the actual layer-shell window every frame (via Bar.qml's
    // totalHeight), which was visibly choppy.
    Rectangle {
        id: expandPanel

        readonly property bool hovered: expandMouseArea.containsMouse

        y: isNaN(root.targetY) ? (root.height + 6) : (root.targetY - root.groupY - root.y)
        x: isNaN(root.targetRight) ? (root.width - width) : (root.targetRight - width - root.groupX - root.x)
        width: root.expandWidth
        height: root.expanded ? content.implicitHeight + 24 : 0
        visible: height > 0
        clip: true

        color: Theme.bgAlpha
        border.color: Theme.border
        border.width: 1
        radius: Theme.rounding

        MouseArea {
            id: expandMouseArea
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.AllButtons
            onWheel: wheel => wheel.accepted = true
        }

        Column {
            id: content
            x: 12
            y: 12
            width: parent.width - 24
            spacing: 8

            Item {
                width: parent.width
                height: titleText.implicitHeight

                Text {
                    id: titleText
                    anchors.left: parent.left
                    text: root.title
                    color: Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize
                    font.bold: true
                }

                Text {
                    anchors.right: parent.right
                    text: root.valueLabel
                    color: Theme.textDim
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize
                }
            }

            Row {
                id: graphRow
                width: parent.width
                height: 300
                spacing: 6

                // Y-axis: labels at the same fractions of maxValue Graph's
                // height maps 0..1 to, so "what height corresponds to what
                // value" is readable directly off the graph instead of only
                // knowing the single top-of-scale number. Width sized off
                // the widest label (maxValue's, formatted) rather than a
                // fixed guess -- disk/net's byte-rate strings ("12.3 MB/s")
                // ran past a fixed 38px and got clipped by expandPanel's
                // clip:true (reported 2026-08-29).
                Item {
                    id: yAxis
                    width: Math.max(30, yAxisMetrics.width + 6)
                    height: parent.height

                    TextMetrics {
                        id: yAxisMetrics
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 4
                        text: root.yAxisFormatter(root.maxValue)
                    }

                    Repeater {
                        model: root.gridFractions

                        Text {
                            required property real modelData
                            y: (1 - modelData) * (yAxis.height - implicitHeight)
                            anchors.right: yAxis.right
                            text: root.yAxisFormatter(modelData * root.maxValue)
                            color: Theme.textDim
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 4
                        }
                    }
                }

                Graph {
                    id: graph
                    width: parent.width - yAxis.width - parent.spacing
                    height: parent.height
                    series: root.mode === "single" ? root.series : []
                    seriesList: root.mode === "overlay" ? root.seriesList : []
                    maxValue: root.maxValue
                    color1: root.color1
                }
            }

            // X-axis: time-ago labels under the graph area only (offset past
            // yAxis, same width as Graph itself). x interpolates each label
            // from left-aligned at fraction 0 (oldest sample) to
            // right-aligned at fraction 1 ("now") so nothing overhangs
            // either edge of the panel.
            Item {
                width: parent.width
                height: Theme.fontSize

                Item {
                    x: yAxis.width + graphRow.spacing
                    width: graph.width
                    height: parent.height

                    Repeater {
                        model: root.xAxisTicks

                        Text {
                            required property var modelData
                            x: modelData.fraction * (parent.width - implicitWidth)
                            text: modelData.label
                            color: Theme.textDim
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 4
                        }
                    }
                }
            }

            // Legend, wrapping across as many lines as it needs -- directly
            // under the graph's x-axis.
            Flow {
                width: parent.width
                spacing: 10
                visible: root.legendItems.length > 0

                Repeater {
                    model: root.legendItems

                    Row {
                        id: legendRow
                        spacing: 5
                        required property var modelData

                        Rectangle {
                            width: 9
                            height: 9
                            radius: 2
                            anchors.verticalCenter: parent.verticalCenter
                            color: legendRow.modelData.color
                        }

                        Text {
                            text: legendRow.modelData.name
                            color: Theme.textDim
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                        }
                    }
                }
            }

            // Time-range toggle on its own line below the legend, hard
            // right, so a long legend never squeezes it.
            Row {
                anchors.right: parent.right
                spacing: 6
                layoutDirection: Qt.RightToLeft
                visible: root.tierCodes.length > 0

                Repeater {
                    model: root.tierCodes

                    Rectangle {
                        id: tierBtn
                        required property string modelData
                        readonly property bool active: modelData === root.tier

                        width: tierLabel.implicitWidth + 10
                        height: tierLabel.implicitHeight + 4
                        radius: Theme.rounding - 4
                        color: active ? Theme.cyan : "transparent"
                        border.color: Theme.border
                        border.width: active ? 0 : 1

                        Text {
                            id: tierLabel
                            anchors.centerIn: parent
                            text: tierBtn.modelData
                            color: tierBtn.active ? Theme.bg : Theme.textDim
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 3
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.tierRequested(tierBtn.modelData)
                        }
                    }
                }
            }

            // One titled block per section (GPU pill: one per GPU) -- its
            // detail rows, then its own process table under a dim
            // sub-heading, all under a single bold label.
            Repeater {
                model: root.sections

                Column {
                    id: section
                    required property var modelData
                    width: parent.width
                    spacing: 3
                    visible: (modelData.rows ?? []).length > 0 || (modelData.procs ?? []).length > 0

                    Rectangle {
                        width: parent.width
                        height: 1
                        color: Theme.border
                    }

                    Text {
                        text: section.modelData.label ?? ""
                        visible: text.length > 0
                        color: Theme.text
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 1
                        font.bold: true
                        topPadding: 3
                    }

                    Repeater {
                        model: section.modelData.rows ?? []

                        Item {
                            required property var modelData
                            width: parent.width
                            height: detailName.implicitHeight

                            // Detail keys (Memory / Frequency / VRAM / ...)
                            // read at full text colour and the value's size
                            // so they stand out from the dim "Top processes"
                            // sub-heading below.
                            Text {
                                id: detailName
                                anchors.left: parent.left
                                anchors.baseline: detailValue.baseline
                                text: parent.modelData.name
                                color: Theme.text
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 1
                            }

                            Text {
                                id: detailValue
                                anchors.right: parent.right
                                text: parent.modelData.value
                                color: Theme.text
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 1
                            }
                        }
                    }

                    // A faint, stubby, left-aligned rule between this
                    // section's detail keys and its process table -- lighter
                    // and much shorter than the full-width divider that
                    // separates whole sections, so it reads as a minor
                    // in-section break rather than a new section.
                    Rectangle {
                        width: 90
                        height: 1
                        color: Theme.border
                        opacity: 0.4
                        // No longer gated on procs.length > 0 -- the table
                        // below now always reserves its placeholder rows
                        // once this section is showing at all (see
                        // topProcsEverArrived's own comment).
                        visible: (section.modelData.rows ?? []).length > 0
                    }

                    // Column headers -- the "Top processes" sub-heading now
                    // lives in this row's first cell instead of its own
                    // line above (request 2026-09-05: the process column
                    // doesn't need its own "exe" label, so the freed cell
                    // takes the sub-heading text and the whole table shifts
                    // up by that line). It stays visually distinct from the
                    // plain column labels beside it by size alone (-2 vs
                    // -4). "util%" only appears here (not on the plain
                    // topProcs table below) since it's only ever populated
                    // for GPU rows.
                    RowLayout {
                        width: parent.width
                        spacing: 6

                        Text {
                            text: qsTr("Top processes")
                            color: Theme.textDim
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                            font.italic: true
                            Layout.fillWidth: true
                        }
                        Text {
                            text: qsTr("util")
                            color: Theme.textDim
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 4
                            font.italic: true
                            horizontalAlignment: Text.AlignRight
                            Layout.preferredWidth: root.procUtilW
                        }
                        Text {
                            text: qsTr("pid")
                            color: Theme.textDim
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 4
                            font.italic: true
                            horizontalAlignment: Text.AlignRight
                            Layout.preferredWidth: root.procPidW
                        }
                        Text {
                            text: (section.modelData.procUnit ?? "").trim()
                            color: Theme.textDim
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 4
                            font.italic: true
                            horizontalAlignment: Text.AlignRight
                            Layout.preferredWidth: root.procValueW
                        }
                    }

                    Repeater {
                        id: sectionProcRepeater
                        readonly property bool everArrived: !!root.sectionsEverArrived[section.modelData.label]
                        readonly property var procs: section.modelData.procs ?? []
                        // Placeholder rows (blank) until this section's own
                        // data has arrived at least once since the panel
                        // opened, then sized to the real (possibly under
                        // 10) list from then on.
                        model: everArrived ? procs.length : 10

                        RowLayout {
                            required property int index
                            readonly property var entry: sectionProcRepeater.procs[index]
                            width: parent.width
                            spacing: 6

                            Text {
                                text: entry ? (entry.detail ? entry.name + " " + entry.detail : entry.name) : ""
                                color: Theme.text
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 3
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }
                            Text {
                                text: entry ? (entry.util_pct > 0 ? Math.round(entry.util_pct) + "%" : "--") : ""
                                color: Theme.textDim
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 3
                                horizontalAlignment: Text.AlignRight
                                Layout.preferredWidth: root.procUtilW
                            }
                            Text {
                                text: entry ? String(entry.pid) : ""
                                color: Theme.muted
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 4
                                horizontalAlignment: Text.AlignRight
                                Layout.preferredWidth: root.procPidW
                            }
                            Text {
                                text: entry ? entry.value.toFixed(1) : ""
                                color: Theme.textDim
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 3
                                horizontalAlignment: Text.AlignRight
                                Layout.preferredWidth: root.procValueW
                            }
                        }
                    }
                }
            }

            Column {
                width: parent.width
                spacing: 4
                visible: root.usageItems.length > 0

                Rectangle {
                    width: parent.width
                    height: 1
                    color: Theme.border
                }

                Repeater {
                    model: root.usageItems

                    // Name on its own full-width line above the bar, not
                    // sharing a row with it -- a fixed-width elided name
                    // column cut off longer mount paths (e.g. an rclone
                    // remote's real target dir), reported 2026-08-31.
                    Column {
                        id: usageItem
                        required property var modelData
                        width: parent.width
                        spacing: 2

                        Text {
                            width: parent.width
                            text: usageItem.modelData.name
                            color: Theme.textDim
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                            // Wraps instead of eliding -- a fixed-width
                            // column cutting off longer mount paths was the
                            // complaint (2026-08-31); WrapAnywhere (not
                            // Wrap) since a path has no spaces to break on.
                            wrapMode: Text.WrapAnywhere
                        }

                        Row {
                            width: parent.width
                            spacing: 6

                            Rectangle {
                                id: usageBarBg
                                width: parent.width - usageValue.width - parent.spacing
                                height: 8
                                anchors.verticalCenter: parent.verticalCenter
                                radius: 3
                                color: Theme.bgAlpha
                                border.color: Theme.border
                                border.width: 1

                                Rectangle {
                                    height: parent.height
                                    width: Math.max(0, Math.min(1, usageItem.modelData.pcent / 100)) * parent.width
                                    radius: parent.radius
                                    color: Theme.rampColor(usageItem.modelData.pcent / 100)
                                }
                            }

                            Text {
                                id: usageValue
                                width: 32
                                anchors.verticalCenter: parent.verticalCenter
                                horizontalAlignment: Text.AlignRight
                                text: Math.round(usageItem.modelData.pcent) + "%"
                                color: Theme.textDim
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 2
                            }
                        }
                    }
                }
            }

            // Single process table (net/cpu/mem/disk/temp). The GPU pill
            // uses `sections` above instead (root.sections.length === 0
            // excludes it here, rather than gating on topProcs.length like
            // before, so this table shows its placeholder rows immediately
            // on open instead of waiting for topProcs' first real batch --
            // see topProcsEverArrived's own comment).
            Column {
                width: parent.width
                spacing: 3
                visible: root.expanded && root.sections.length === 0

                Rectangle {
                    width: parent.width
                    height: 1
                    color: Theme.border
                }

                // Column headers -- topLabel ("Top processes" / "top CPU
                // users") now lives in this row's first cell instead of its
                // own line above (request 2026-09-05: the process column
                // doesn't need its own "exe" label, so the freed cell takes
                // the heading text and the whole table shifts up by that
                // line). It stays visually distinct from the plain pid/
                // value labels beside it by size alone (-2 vs -3).
                RowLayout {
                    width: parent.width
                    spacing: 6

                    Text {
                        text: root.topLabel
                        color: Theme.textDim
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 2
                        font.italic: true
                        Layout.fillWidth: true
                    }
                    Text {
                        text: qsTr("pid")
                        color: Theme.textDim
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 3
                        font.italic: true
                        horizontalAlignment: Text.AlignRight
                        Layout.preferredWidth: root.procPidW
                    }
                    Text {
                        text: root.topUnit.trim()
                        color: Theme.textDim
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 3
                        font.italic: true
                        horizontalAlignment: Text.AlignRight
                        Layout.preferredWidth: root.procValueW
                    }
                }

                Repeater {
                    // Placeholder rows (blank) until topProcs' first real
                    // batch has arrived since the panel opened, then sized
                    // to the real (possibly under 10) list from then on --
                    // see topProcsEverArrived's own comment.
                    model: root.topProcsEverArrived ? root.topProcs.length : 10

                    RowLayout {
                        required property int index
                        readonly property var entry: root.topProcs[index]
                        width: parent.width
                        spacing: 6

                        // Name plus sysmond's per-process hint (cmdline
                        // tail + cwd) in one column -- "claude" alone is
                        // useless when 8 of the top 10 are claude. Merged
                        // into a single fillWidth Text (rather than a
                        // separate detail column) so an empty detail can't
                        // make Layout exclude a column and shift pid/value
                        // left (reported in the memory panel, 2026-09-05).
                        Text {
                            text: entry ? (entry.detail ? entry.name + " " + entry.detail : entry.name) : ""
                            color: Theme.text
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 1
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }

                        Text {
                            text: entry ? String(entry.pid) : ""
                            color: Theme.muted
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                            horizontalAlignment: Text.AlignRight
                            Layout.preferredWidth: root.procPidW
                        }

                        Text {
                            text: entry ? entry.value.toFixed(1) : ""
                            color: Theme.textDim
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 1
                            horizontalAlignment: Text.AlignRight
                            Layout.preferredWidth: root.procValueW
                        }
                    }
                }
            }
        }
    }
}
