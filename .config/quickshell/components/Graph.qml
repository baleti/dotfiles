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
//    `seriesList` to [{data, color, dashed}, ...]. `dashed` no longer means
//    a dash pattern (that read as "the line broke up" on steep spikes,
//    2026-08-29) -- it now marks a secondary/de-emphasised series (tx,
//    disk-write, mem-cached): same hue, drawn at a lower alpha with no
//    fill, so it still reads as "the quieter twin" of its solid partner.
Canvas {
    id: root

    antialiasing: true

    property list<real> series: []
    property color color1: Theme.cyan
    property var seriesList: []
    property real maxValue: 100
    // Full ring-buffer capacity the raw data represents (sysmond's
    // HISTORY_LEN), NOT rawData.length -- see downsample() below for why
    // that distinction is the whole fix.
    property int historyLen: 600

    onSeriesChanged: requestPaint()
    onSeriesListChanged: requestPaint()
    onMaxValueChanged: requestPaint()

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
    function smooth(data, radius) {
        const n = data.length;
        const out = new Array(n);
        for (let i = 0; i < n; i++) {
            let sum = 0, count = 0;
            for (let k = -radius; k <= radius; k++) {
                const j = i + k;
                if (j >= 0 && j < n) {
                    sum += data[j];
                    count++;
                }
            }
            out[i] = sum / count;
        }
        return out;
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
            points[i] = { x: width - slotFromRight * pxPerSample, v: smoothed[i] };
        }
        return points;
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
        if (points.length < 2)
            return;
        const rgb = Qt.color(rawColor);
        const h = height;
        const yOf = v => h - Math.max(0, Math.min(1, v / root.maxValue)) * h;
        ctx.beginPath();
        ctx.moveTo(points[0].x, h);
        for (const p of points)
            ctx.lineTo(p.x, yOf(p.v));
        ctx.lineTo(points[points.length - 1].x, h);
        ctx.closePath();
        ctx.fillStyle = Qt.rgba(rgb.r, rgb.g, rgb.b, fillAlpha);
        ctx.fill();
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
        const rgb = Qt.color(envColor);
        const h = height;
        const yOf = v => h - Math.max(0, Math.min(1, v / root.maxValue)) * h;
        ctx.beginPath();
        ctx.moveTo(cols[0][0].x, h);
        for (let i = 0; i < n; i++) {
            let v = 0;
            for (const c of cols)
                v = Math.max(v, c[i].v);
            ctx.lineTo(cols[0][i].x, yOf(v));
        }
        ctx.lineTo(cols[0][n - 1].x, h);
        ctx.closePath();
        ctx.fillStyle = Qt.rgba(rgb.r, rgb.g, rgb.b, fillAlpha);
        ctx.fill();
    }

    function strokeSeries(ctx, rawData, rawColor, lineWidth, strokeAlpha) {
        if (rawData.length < 2)
            return;
        const points = root.downsample(rawData);
        if (points.length < 2)
            return;
        const rgb = Qt.color(rawColor);
        const h = height;
        const yOf = v => h - Math.max(0, Math.min(1, v / root.maxValue)) * h;
        ctx.beginPath();
        ctx.lineJoin = "round";
        ctx.lineCap = "round";
        ctx.moveTo(points[0].x, yOf(points[0].v));
        for (let i = 1; i < points.length; i++)
            ctx.lineTo(points[i].x, yOf(points[i].v));
        ctx.strokeStyle = Qt.rgba(rgb.r, rgb.g, rgb.b, strokeAlpha);
        ctx.lineWidth = lineWidth;
        ctx.stroke();
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
            if (many)
                fillEnvelope(ctx, primary, color1, 0.14);
            else
                for (const s of primary)
                    fillSeries(ctx, s.data, s.color, 0.22);

            // All overlay lines are 1px regardless of series count -- a
            // 2-series net graph at 1.25px next to a 12-series cpu graph at
            // 1px read as "one's thinner". Secondary (tx/write/cached) at
            // 0.62 alpha, not much below primary's 0.9: lower still and it
            // looked like a thinner line rather than a quieter one.
            for (const s of secondary)
                strokeSeries(ctx, s.data, s.color, 1.0, 0.62);
            for (const s of primary)
                strokeSeries(ctx, s.data, s.color, 1.0, 0.9);
        } else {
            fillSeries(ctx, series, color1, 0.24);
            strokeSeries(ctx, series, color1, 1.25, 0.9);
        }
    }
}
