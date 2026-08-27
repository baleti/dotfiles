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
//    `seriesList` to [{data, color, dashed}, ...] -- dashed lines skip the
//    fill so overlapping series don't muddy each other.
Canvas {
    id: root

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

    // Bucket raw samples into canvas-pixel-wide columns, anchored to a
    // FIXED width/historyLen scale (not width/rawData.length), and average
    // each bucket. Two bugs the previous stride-based nearest-neighbor pick
    // had: (1) stride = data.length/target changed every single tick while
    // the buffer was still filling, reshuffling which raw sample landed on
    // which pixel from one repaint to the next; (2) even at a fixed steady
    // 600-length buffer, a non-integer stride (600/~432 ≈ 1.39) picks one
    // *arbitrary* sample per pixel rather than averaging the ~1.39 samples
    // that actually belong there, so a single noisy tick (CPU/disk are the
    // spikiest signals here) could dominate or vanish from frame to frame
    // -- the "rounding errors" flicker. Anchoring to historyLen means a
    // given raw sample's x position only ever moves by one fixed increment
    // per tick (pure left-scroll), and averaging instead of picking removes
    // the aliasing.
    function downsample(data) {
        const n = data.length;
        if (n === 0)
            return [];
        const pxPerSample = width / root.historyLen;
        const buckets = new Map();
        for (let i = 0; i < n; i++) {
            const slotFromRight = n - 1 - i;
            const x = width - slotFromRight * pxPerSample;
            const col = Math.floor(x);
            let b = buckets.get(col);
            if (!b) {
                b = { sum: 0, count: 0, x };
                buckets.set(col, b);
            }
            b.sum += data[i];
            b.count += 1;
        }
        const cols = [...buckets.keys()].sort((a, b) => a - b);
        return cols.map(col => {
            const b = buckets.get(col);
            return { x: b.x, v: b.sum / b.count };
        });
    }

    function drawSeries(ctx, rawData, rgb, fill, dashed) {
        if (rawData.length < 2)
            return;
        const points = root.downsample(rawData);
        if (points.length < 2)
            return;
        const h = height;
        const yOf = v => h - Math.max(0, Math.min(1, v / root.maxValue)) * h;

        if (fill) {
            ctx.beginPath();
            ctx.moveTo(points[0].x, h);
            for (const p of points)
                ctx.lineTo(p.x, yOf(p.v));
            ctx.lineTo(points[points.length - 1].x, h);
            ctx.closePath();
            ctx.fillStyle = Qt.rgba(rgb.r, rgb.g, rgb.b, 0.18);
            ctx.fill();
        }

        ctx.beginPath();
        ctx.setLineDash(dashed ? [6, 4] : []);
        ctx.moveTo(points[0].x, yOf(points[0].v));
        for (let i = 1; i < points.length; i++)
            ctx.lineTo(points[i].x, yOf(points[i].v));
        ctx.strokeStyle = Qt.rgba(rgb.r, rgb.g, rgb.b, 0.95);
        ctx.lineWidth = 2;
        ctx.stroke();
        ctx.setLineDash([]);
    }

    onPaint: {
        const ctx = getContext("2d");
        ctx.reset();
        if (seriesList.length > 0) {
            // Many overlapping filled areas (e.g. 12 CPU cores) just muddy
            // each other and cost more to draw -- stroke-only once there
            // are more than a couple of series; bucket-averaging above
            // already caps point count to ~canvas width regardless of
            // series count, so no separate hard cap is needed any more.
            const many = seriesList.length > 2;
            for (const s of seriesList)
                drawSeries(ctx, s.data, s.color, many ? false : !s.dashed, !!s.dashed);
        } else {
            drawSeries(ctx, series, color1, true, false);
        }
    }
}
