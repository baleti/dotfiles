import QtQuick
import "../theme"

// Filled-area-under-line chart, same visual recipe as
// ~/.config/hypr/sysmon/src/bin/sysmon-graph.rs's draw_series (0.18-alpha
// fill, 0.95-alpha 2px stroke) so the bar's hover graphs read as the same
// family as the existing alt+mod+n/p/t popups.
//
// Two usage modes:
//  - single: set `series`/`color1`.
//  - overlay (network rx/tx per interface, or one line per CPU core): set
//    `seriesList` to [{data, color, dashed, noFill, dash}, ...]. `dashed`
//    no longer means a dash pattern (that read as "the line broke up" on
//    steep spikes, 2026-08-29) -- it now marks a secondary/de-emphasised
//    series (tx, disk-write, mem-cached): same hue, drawn at a lower alpha
//    with no fill, so it still reads as "the quieter twin" of its solid
//    partner. `noFill` (2026-09-27) independently drops a PRIMARY series
//    out of the fill pass only (envelope or individual) while keeping its
//    full-alpha, on-top stroke -- the CPU pill's power/platform lines use
//    this so they don't add to the grey wash under the per-core envelope.
//    `dash` (2026-09-27) is a `[onLen, offLen]` pair, opt-in per series --
//    safe for smooth lines like those same two power lines, still avoided
//    for the spiky per-sample metrics that prompted `dashed` to stop
//    meaning a visual dash pattern in the first place. Hand-rolled in
//    `strokeSeries`/`_dashRun` below rather than `ctx.setLineDash` -- see
//    `_arcPositions`' comment; the canvas-native version couldn't be made
//    to travel with the data.
Canvas {
    id: root

    antialiasing: true

    property list<real> series: []
    property color color1: Theme.cyan
    property var seriesList: []
    property real maxValue: 100
    // Overlay mode only -- single mode (series/color1) always fills.
    // Off for the GPU pill (request 2026-09-06: "stop filling the area
    // under igpu utilization"/"this maybe making colors harder to
    // distinguish") -- with several overlaid lines already hard enough to
    // tell apart by stroke colour alone, a translucent wash underneath
    // (individual per-line fills, or with >2 primary lines one shared
    // envelope wash in a single unrelated colour, see "many" below)
    // muddies exactly the contrast this needs. Every other overlay pill
    // (net/cpu/mem/disk) keeps its fill -- unaffected by this, defaults
    // true.
    property bool fillOverlay: true
    // Secondary (dashed=de-emphasised) lines normally draw UNDER primary
    // ones, so a primary line never gets buried under its own "quieter
    // twin" -- fine when the two series usually differ (net rx/tx, disk
    // read/write). The GPU pill's VRAM-vs-power pair, though, can sit at
    // nearly the same value for long stretches (both roughly flat
    // percentages), and default draw order then means power (primary)
    // paints straight over VRAM (secondary) for that entire stretch --
    // no colour choice fixes a line that's literally occluded (confirmed
    // 2026-09-06: searched the actual rendered pixels for VRAM's
    // supposedly-distinct colour and found almost none of it -- power's
    // colour was sitting on top the whole time). Off (default) preserves
    // today's order for every other overlay pill; on for the GPU pill
    // only.
    property bool secondaryOnTop: false
    // Overlay mode only -- single mode keeps its own hardcoded 1.25.
    // Used to be a flat 1.0 for every overlay pill regardless of series
    // count (deliberately unified, see git history: "a 2-series net
    // graph at 1.25px next to a 12-series cpu graph at 1px read as one's
    // thinner") -- request 2026-09-06 asks to pull them back apart again
    // in the other direction: the GPU pill's several overlaid, already
    // hard-to-tell-apart lines read as thin/faint next to disk's, and
    // CPU's dozen-ish per-core lines are the one case this file's own
    // history explicitly called out as needing *thinner* lines to avoid
    // clutter. Per-pill now instead of a shared constant; default keeps
    // net/mem/disk exactly as they render today.
    property real lineWidth: 1.0
    // Full ring-buffer capacity the raw data represents (sysmond's
    // HISTORY_LEN), NOT rawData.length -- see downsample() below for why
    // that distinction is the whole fix.
    property int historyLen: 600

    // Mirrors sysmon::NO_DATA (lib.rs) -- sysmond writes this into a tier's
    // buffer for the wall-clock span it wasn't running (machine off/
    // suspended, service restarted), instead of splicing pre-shutdown
    // history directly against post-restart samples as if no time had
    // passed. Every metric this draws (percentages, temps, bytes/sec) is
    // non-negative, so -1 can never be a real sample -- see that constant's
    // own comment for why it's a plain sentinel and not NaN/Infinity.
    readonly property real _noData: -1

    function _isGap(v) {
        return v <= root._noData;
    }

    // Which series is under the cursor right now, by its `name` field
    // (request 2026-09-10: "hovers mouse over a graph line it gets bolder
    // and its corresponding label gets bolder too") -- "" means nothing.
    // Named rather than indexed so a pill whose legend groups two series
    // under one row (net/disk's rx+tx sharing one interface/device name
    // and one legend swatch) bolds *both* lines together when either is
    // hovered, matching what the legend row itself represents. Single
    // mode (series/color1, no seriesList) has no real name to key off, so
    // its one line uses the sentinel below instead of "" -- "" has to
    // stay reserved for "nothing hovered" or a single-mode graph would
    // read as permanently hovered.
    readonly property string _singleSentinel: "__single__"
    // Whether hovering a line bolds it (and its legend row). Only useful on
    // graphs that have labels to match a line back to -- the CPU panel has
    // a dozen unlabelled per-core lines, where bolding one on hover is just
    // noise. Off there; the cursor-slice tracking below (hoveredIndex, for
    // GraphPill's top-process tooltip) is unaffected.
    property bool lineHoverHighlight: true
    property string hoveredName: ""
    // Index into `seriesList` of the nearest line (-1 = none/single-mode)
    // -- see `_updateHover`'s own comment on why this exists alongside
    // `hoveredName` rather than being redundant with it.
    property int hoveredSeriesIndex: -1
    // Read by GraphPill.qml's legend Repeater to bold the matching row --
    // exposed as the sentinel-free single-mode-aware form (never leaks
    // _singleSentinel to a consumer that doesn't know about it).
    readonly property string hoveredLegendName: hoveredName === _singleSentinel ? "" : hoveredName

    // Data index (0-based, oldest..newest) of the graph point under the
    // cursor, or -1 when the cursor is off the graph -- for GraphPill's
    // top-process hover tooltip. Set from the cursor x alone (unlike
    // hoveredName, which needs the cursor near an actual line): the tooltip
    // answers "what was running at this *time*", so anywhere over the graph
    // counts. hoveredPixelX/Y are the raw cursor position for placing it.
    property int hoveredIndex: -1
    property real hoveredPixelX: 0
    property real hoveredPixelY: 0

    // Samples-appended counter from TieredSocket.qml -- gives every point
    // an absolute index (`downsample`'s `k`) that stays with it as it
    // scrolls, which is what anchors dashes to the data (`_arcPositions`).
    property real sampleSeq: 0

    // Arc-length dashing (2026-09-27, take 5). Take 4 decided on/off from
    // each point's x alone, so a steep rise/fall -- a lot of line over very
    // little x -- came out as one long unbroken "dash", and state could only
    // flip at sample vertices. Now the pattern runs along the line's true
    // length and every dash edge is cut at its exact interpolated point.
    //
    // To keep dashes travelling WITH the data, each sample's arc position is
    // cached by its absolute index (`sampleSeq` - slot from the right) the
    // first time it's seen, and reused while it scrolls: segment lengths
    // are translation-invariant, so a cached chain stays valid. Each reuse
    // is checked against the actual segment length, and a mismatch (tier
    // switch, mis-inferred resync shift) rebuilds the chain from that point
    // on -- self-healing rather than trusting the counter blindly. The
    // newest `_uncommitted` points aren't cached: the moving-average in
    // `smooth()` still changes them as the next samples arrive.
    property var _arcCache: ({})
    readonly property int _uncommitted: 3
    function _resetArcCache() { root._arcCache = ({}); }
    onWidthChanged: _resetArcCache()
    onHeightChanged: _resetArcCache()

    // Arc positions for one run of screen points ({x, y, k}), via/into the
    // cache map `m` (absolute index -> arc px).
    function _arcPositions(run, m, commitBelow) {
        const out = new Array(run.length);
        const k0 = run[0].k;
        out[0] = m[k0] ?? 0;
        if (run[0].k < commitBelow)
            m[k0] = out[0];
        for (let i = 1; i < run.length; i++) {
            const seg = Math.hypot(run[i].x - run[i - 1].x, run[i].y - run[i - 1].y);
            const want = out[i - 1] + seg;
            const have = m[run[i].k];
            out[i] = (have !== undefined && Math.abs(have - want) < 0.25) ? have : want;
            if (run[i].k < commitBelow)
                m[run[i].k] = out[i];
        }
        return out;
    }

    // Adds the "on" pieces of one run to the current path as subpaths
    // (single stroke() for the whole series by the caller).
    function _dashRun(ctx, run, arc, dash) {
        const on = dash[0], cycle = dash[0] + dash[1];
        const phase = s => ((s % cycle) + cycle) % cycle;
        let penDown = phase(arc[0]) < on;
        if (penDown)
            ctx.moveTo(run[0].x, run[0].y);
        for (let i = 1; i < run.length; i++) {
            const p0 = run[i - 1], p1 = run[i];
            const s0 = arc[i - 1], s1 = arc[i];
            const len = s1 - s0;
            if (len <= 0)
                continue;
            // Walk every dash boundary inside (s0, s1).
            let s = s0;
            while (true) {
                const ph = phase(s);
                const next = s + (ph < on ? on - ph : cycle - ph);
                if (next >= s1)
                    break;
                const t = (next - s0) / len;
                const x = p0.x + (p1.x - p0.x) * t, y = p0.y + (p1.y - p0.y) * t;
                if (penDown)
                    ctx.lineTo(x, y);
                else
                    ctx.moveTo(x, y);
                penDown = !penDown;
                // Nudge past the boundary so phase() lands in the next state.
                s = next + 1e-6;
            }
            if (penDown)
                ctx.lineTo(p1.x, p1.y);
        }
    }

    function _pointCount() {
        if (root.seriesList.length > 0)
            return root.seriesList[0] && root.seriesList[0].data ? root.seriesList[0].data.length : 0;
        return root.series.length;
    }

    onSeriesChanged: requestPaint()
    onSeriesListChanged: requestPaint()
    onMaxValueChanged: { _resetArcCache(); requestPaint(); }
    onFillOverlayChanged: requestPaint()
    onSecondaryOnTopChanged: requestPaint()
    onLineWidthChanged: requestPaint()
    onHoveredNameChanged: requestPaint()

    // Plots every raw sample at its exact (sub-pixel, unrounded) x position,
    // anchored to a FIXED width/historyLen scale (not width/rawData.length)
    // -- a given raw sample's x position only ever moves by one fixed
    // increment per tick (pure smooth left-scroll), never jumps. Two
    // earlier approaches both introduced aliasing/shimmer this replaces:
    // (1) stride-based nearest-neighbor picking (stride = data.length/
    // target) changed every tick while the buffer was still filling, AND
    // at steady state picked one arbitrary sample per pixel instead of
    // representing all of them; (2) a follow-up pixel-bucket-averaging
    // pass fixed that but rounded each point to an integer pixel column
    // (Math.floor), so points near a column boundary would flip which
    // column they landed in as their exact position drifted by fractional
    // pxPerSample amounts tick to tick -- a one-pixel shimmer along the
    // whole curve, reported as "jagged, even flickering when moving"
    // 2026-08-28. At <=600 raw points into a few-hundred-px-wide canvas,
    // plotting every point directly (no merging at all) is trivially
    // cheap, so there's no accuracy/performance reason to bucket any more.
    // Small moving-average low-pass, radius in samples either side --
    // spiky raw metrics (network/disk bursts, per-core CPU) plotted
    // point-to-point with no smoothing at all read as a harsh, jagged
    // "picket fence" rather than a legible trend (reported 2026-08-28).
    // This softens that into rounded humps without reducing the actual
    // point count/time resolution -- it's a filter, not a downsample.
    // Gap (NO_DATA) points pass through untouched -- never averaged into
    // a neighbor. A real point's own average also excludes any gap
    // neighbors within `radius`, so a valid sample right next to a gap
    // isn't pulled toward -1.
    function smooth(data, radius) {
        const n = data.length;
        const out = new Array(n);
        for (let i = 0; i < n; i++) {
            if (root._isGap(data[i])) {
                out[i] = root._noData;
                continue;
            }
            let sum = 0, count = 0;
            for (let k = -radius; k <= radius; k++) {
                const j = i + k;
                if (j >= 0 && j < n && !root._isGap(data[j])) {
                    sum += data[j];
                    count++;
                }
            }
            out[i] = count > 0 ? sum / count : root._noData;
        }
        return out;
    }

    // Splits a downsample()d points array into contiguous runs with no gap
    // (NO_DATA) point in them -- every draw routine below strokes/fills
    // each run separately instead of one path across the whole series, so
    // a gap becomes a visible break rather than a line through -1 (or,
    // pre-smoothing-fix, a value dragged toward it).
    function _splitRuns(points) {
        const runs = [];
        let cur = [];
        for (const p of points) {
            if (root._isGap(p.v)) {
                if (cur.length > 0)
                    runs.push(cur);
                cur = [];
            } else {
                cur.push(p);
            }
        }
        if (cur.length > 0)
            runs.push(cur);
        return runs;
    }

    function downsample(data) {
        const n = data.length;
        if (n === 0)
            return [];
        const smoothed = root.smooth(data, 2);
        const pxPerSample = width / root.historyLen;
        const points = new Array(n);
        for (let i = 0; i < n; i++) {
            const slotFromRight = n - 1 - i;
            // `k`: absolute sample index -- see `_arcPositions`.
            points[i] = { x: width - slotFromRight * pxPerSample, v: smoothed[i], k: Math.round(root.sampleSeq) - slotFromRight };
        }
        return points;
    }

    // The list hit-testing/the bold-redraw pass both iterate -- single
    // mode's one implicit line wrapped up the same shape as an overlay
    // entry (with the sentinel name, see hoveredName's own comment) so
    // both code paths share one implementation instead of a duplicate for
    // "is it single or overlay mode".
    function _hitTestSeries() {
        if (root.seriesList.length > 0)
            return root.seriesList;
        if (root.series.length > 0)
            return [{ data: root.series, color: root.color1, name: root._singleSentinel }];
        return [];
    }

    // y (canvas px) of series `data`'s line at x (canvas px), by linear
    // interpolation between the two downsampled points bracketing it --
    // null if x falls outside the plotted range (fewer than 2 points, or
    // past either end, which happens for a still-filling ring buffer's
    // right edge).
    function _lineYAt(data, x) {
        const pts = root.downsample(data);
        for (const run of root._splitRuns(pts)) {
            if (run.length < 2)
                continue;
            if (x < run[0].x || x > run[run.length - 1].x)
                continue;
            for (let i = 1; i < run.length; i++) {
                if (x <= run[i].x) {
                    const span = run[i].x - run[i - 1].x;
                    const t = span > 0 ? (x - run[i - 1].x) / span : 0;
                    const v = run[i - 1].v + (run[i].v - run[i - 1].v) * t;
                    return height - Math.max(0, Math.min(1, v / root.maxValue)) * height;
                }
            }
        }
        return null;
    }

    // Nearest line to (mx, my) within a comfortable click/hover radius
    // (10px -- a bare 1-1.5px stroke is a much smaller target than that,
    // same "give hover targets real breathing room" reasoning as any
    // other thin-control hit area in this UI) sets hoveredName; nothing
    // within radius clears it. Ties (two lines equally close, e.g. rx/tx
    // crossing) keep whichever was checked first -- seriesList's own
    // draw order, stable and not worth breaking on.
    function _updateHover(mx, my) {
        if (root.lineHoverHighlight) {
            const list = root._hitTestSeries();
            let bestName = "";
            let bestIdx = -1;
            let bestDist = 10;
            for (let i = 0; i < list.length; i++) {
                const y = root._lineYAt(list[i].data, mx);
                if (y === null)
                    continue;
                const d = Math.abs(my - y);
                if (d < bestDist) {
                    bestDist = d;
                    bestName = list[i].name ?? "";
                    bestIdx = i;
                }
            }
            root.hoveredName = bestName;
            // Index into `seriesList` (== `list` in overlay mode -- single
            // mode's one implicit line has no real seriesList entry, so
            // this stays -1 there) of the nearest line, not just its name --
            // two lines can share one `name` on purpose (rx/tx under one
            // legend row bold together), so GraphPill needs to know which
            // one was actually nearest to attribute a hover tooltip to just
            // that line, not whichever shares the name.
            root.hoveredSeriesIndex = root.seriesList.length > 0 ? bestIdx : -1;
        }

        const n = root._pointCount();
        if (n >= 1 && mx >= 0 && mx <= width) {
            const pxPerSample = width / root.historyLen;
            const slotFromRight = Math.round((width - mx) / pxPerSample);
            root.hoveredIndex = Math.max(0, Math.min(n - 1, n - 1 - slotFromRight));
            root.hoveredPixelX = mx;
            root.hoveredPixelY = my;
        } else {
            root.hoveredIndex = -1;
        }
    }

    MouseArea {
        id: hoverArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        onPositionChanged: mouse => root._updateHover(mouse.x, mouse.y)
        onExited: {
            root.hoveredName = "";
            root.hoveredSeriesIndex = -1;
            root.hoveredIndex = -1;
        }
    }

    // seriesList's per-entry `color` field comes from Theme.seriesPalette,
    // an untyped `property var` array of plain hex STRINGS (not QML `color`
    // objects -- only a top-level `property color` gets that string->QColor
    // auto-coercion, a nested object-literal field like seriesList[i].color
    // never does). rgb.r/.g/.b on a bare string is undefined, so every
    // overlay graph (net/cpu/mem/disk) drew Qt.rgba(undefined... ) -- i.e.
    // black -- until overlay mode was fixed to Qt.color() it first (reported
    // "CPU is all black" / "graphs don't use theme colors", 2026-08-28).

    function fillSeries(ctx, rawData, rawColor, fillAlpha) {
        if (rawData.length < 2)
            return;
        const points = root.downsample(rawData);
        const runs = root._splitRuns(points);
        if (runs.length === 0)
            return;
        const rgb = Qt.color(rawColor);
        const h = height;
        const yOf = v => h - Math.max(0, Math.min(1, v / root.maxValue)) * h;
        ctx.fillStyle = Qt.rgba(rgb.r, rgb.g, rgb.b, fillAlpha);
        for (const run of runs) {
            if (run.length < 2)
                continue;
            ctx.beginPath();
            ctx.moveTo(run[0].x, h);
            for (const p of run)
                ctx.lineTo(p.x, yOf(p.v));
            ctx.lineTo(run[run.length - 1].x, h);
            ctx.closePath();
            ctx.fill();
        }
    }

    // One translucent fill under the UPPER ENVELOPE (max at each x) of a
    // group of series -- used for the CPU overlay: 12 per-core fills stacked
    // into mud however their alpha was tuned, so instead there's a single
    // faint wash under the bundle and the individual per-core lines carry
    // all the detail on top.
    function fillEnvelope(ctx, seriesArr, envColor, fillAlpha) {
        const cols = seriesArr.map(s => root.downsample(s.data)).filter(p => p.length >= 2);
        if (cols.length === 0)
            return;
        const n = Math.min(...cols.map(c => c.length));
        if (n < 2)
            return;
        // Per-x max across every column, skipping columns that are gapped
        // at that x -- if every column is gapped there, the envelope
        // itself is gapped too (_splitRuns below breaks the fill there).
        const envPoints = new Array(n);
        for (let i = 0; i < n; i++) {
            // root._noData (-1) as the running max's start is safe here
            // (not just "no worse than 0"): every real value in these
            // series is non-negative, so it's immediately overtaken by the
            // first real column and never surfaces unless `any` stays
            // false, at which point the whole point is reported as a gap.
            let v = root._noData, any = false;
            for (const c of cols) {
                if (root._isGap(c[i].v))
                    continue;
                any = true;
                v = Math.max(v, c[i].v);
            }
            envPoints[i] = { x: cols[0][i].x, v: any ? v : root._noData };
        }
        const rgb = Qt.color(envColor);
        const h = height;
        const yOf = v => h - Math.max(0, Math.min(1, v / root.maxValue)) * h;
        ctx.fillStyle = Qt.rgba(rgb.r, rgb.g, rgb.b, fillAlpha);
        for (const run of root._splitRuns(envPoints)) {
            if (run.length < 2)
                continue;
            ctx.beginPath();
            ctx.moveTo(run[0].x, h);
            for (const p of run)
                ctx.lineTo(p.x, yOf(p.v));
            ctx.lineTo(run[run.length - 1].x, h);
            ctx.closePath();
            ctx.fill();
        }
    }

    function strokeSeries(ctx, rawData, rawColor, lineWidth, strokeAlpha, dash = [], cacheKey = "") {
        if (rawData.length < 2)
            return;
        const points = root.downsample(rawData);
        const runs = root._splitRuns(points);
        if (runs.length === 0)
            return;
        const rgb = Qt.color(rawColor);
        const h = height;
        const yOf = v => h - Math.max(0, Math.min(1, v / root.maxValue)) * h;
        ctx.strokeStyle = Qt.rgba(rgb.r, rgb.g, rgb.b, strokeAlpha);
        ctx.lineWidth = lineWidth;
        ctx.lineJoin = "round";

        if (dash.length === 0) {
            ctx.lineCap = "round";
            for (const run of runs) {
                if (run.length < 2)
                    continue;
                ctx.beginPath();
                ctx.moveTo(run[0].x, yOf(run[0].v));
                for (let i = 1; i < run.length; i++)
                    ctx.lineTo(run[i].x, yOf(run[i].v));
                ctx.stroke();
            }
            return;
        }

        // "butt", not "round" -- a round cap adds a soft semicircular bump
        // to both ends of every short dash segment, disproportionate at
        // these dash lengths. Flat, perpendicular-cut ends instead.
        ctx.lineCap = "butt";

        // Dashed: arc-length pattern (see `_arcPositions`). Butt caps --
        // round caps on short dashes bulge each one into a blob -- and one
        // stroke() over every dash as subpaths so they antialias alike.
        ctx.lineCap = "butt";
        const m = root._arcCache[cacheKey] ?? (root._arcCache[cacheKey] = ({}));
        const newest = points[points.length - 1].k;
        const commitBelow = newest - root._uncommitted + 1;
        ctx.beginPath();
        for (const run of runs) {
            if (run.length < 2)
                continue;
            const pts = run.map(p => ({ x: p.x, y: yOf(p.v), k: p.k }));
            root._dashRun(ctx, pts, root._arcPositions(pts, m, commitBelow), dash);
        }
        ctx.stroke();
        // Drop cache entries that have scrolled off the left.
        const oldest = points[0].k;
        for (const key in m)
            if (key < oldest)
                delete m[key];
    }

    onPaint: {
        const ctx = getContext("2d");
        ctx.reset();

        if (seriesList.length > 0) {
            const primary = seriesList.filter(s => !s.dashed);
            const secondary = seriesList.filter(s => !!s.dashed);
            // Mud comes from stacking many overlapping FILLED areas (cpu
            // cores) -- a couple of filled primaries next to an unfilled,
            // de-emphasised secondary (mem used+swap next to cached) never
            // has that problem, so this counts primary only. Counting
            // seriesList.length instead (pre-2026-08-29) made mem's own
            // 3rd series (swap) flip it into a single shared envelope wash
            // in the pill's overall graded color -- losing both series'
            // individual fill colors, not just swap's.
            const many = primary.length > 2;

            // Lines on top of fills, always (two passes). Fill strategy
            // depends on how many series there are -- per-core translucent
            // fills stacked into mud at every alpha they were tried at
            // ("a mess" / "all mashed together", 2026-08-29), so with many
            // series there's instead ONE faint wash under their combined
            // envelope and the per-core lines carry the detail. With just
            // a couple (mem used/cached) the individual fills are fine.
            if (root.fillOverlay) {
                // `noFill` (2026-09-27, the CPU pill's power/platform/
                // battery lines): excluded from BOTH the shared envelope's
                // per-x max and individual per-line fills -- a line marked
                // this way never contributes any grey area underneath,
                // whether it's sharing the cores' envelope wash or would
                // otherwise get its own fill in the few-series branch.
                const fillable = primary.filter(s => !s.noFill);
                if (many)
                    fillEnvelope(ctx, fillable, color1, 0.14);
                else
                    for (const s of fillable)
                        fillSeries(ctx, s.data, s.color, 0.22);
            }

            // Both passes share one lineWidth (root.lineWidth, per-pill --
            // see its own comment above) rather than each pass picking
            // its own, so a pill's primary/secondary lines still read as
            // the same weight of line, just quieter. Secondary (tx/write/
            // cached/VRAM) at 0.62 alpha, not much below primary's 0.9:
            // lower still and it looked like a thinner line rather than a
            // quieter one.
            // Per-series `width` overrides root.lineWidth -- the CPU pill's
            // dashed power lines need more than the cores' 0.7px, where a
            // dash is too thin to read as anything but a smear.
            const strokeSecondary = () => { for (const s of secondary) strokeSeries(ctx, s.data, s.color, s.width ?? root.lineWidth, 0.62, s.dash ?? [], s.name ?? ""); };
            const strokePrimary = () => { for (const s of primary) strokeSeries(ctx, s.data, s.color, s.width ?? root.lineWidth, 0.9, s.dash ?? [], s.name ?? ""); };
            if (root.secondaryOnTop) {
                strokePrimary();
                strokeSecondary();
            } else {
                strokeSecondary();
                strokePrimary();
            }
        } else {
            fillSeries(ctx, series, color1, 0.24);
            strokeSeries(ctx, series, color1, 1.25, 0.9);
        }

        // Bold re-stroke of whichever line is hovered, on top of
        // everything else drawn above (including its own already-drawn
        // normal-weight pass) so it's never occluded by a sibling line --
        // request 2026-09-10. Every series sharing hoveredName redraws
        // together (net/disk's rx+tx pair under one legend row both bold
        // when either is hovered, matching what that one row represents).
        // Always full alpha regardless of primary/secondary, and always
        // double lineWidth -- deliberately not "1px more" so it reads as
        // obviously emphasised even on the thinnest per-pill lineWidth
        // (CPU's 0.7, see Bar.qml).
        if (root.hoveredName.length > 0) {
            for (const s of root._hitTestSeries())
                if ((s.name ?? "") === root.hoveredName)
                    strokeSeries(ctx, s.data, s.color, s.width ? s.width * 1.5 : root.lineWidth * 2.2, 1.0, s.dash ?? [], s.name ?? "");
        }
    }
}
