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
        ctx.lineJoin = "round";
        ctx.lineCap = "round";
        ctx.moveTo(points[0].x, yOf(points[0].v));
        for (let i = 1; i < points.length; i++)
            ctx.lineTo(points[i].x, yOf(points[i].v));
        ctx.strokeStyle = Qt.rgba(rgb.r, rgb.g, rgb.b, 0.9);
        ctx.lineWidth = 1.25;
        ctx.stroke();
        ctx.setLineDash([]);
    }

    onPaint: {
        const ctx = getContext("2d");
        ctx.reset();
        if (seriesList.length > 0) {
            // Many overlapping filled areas (e.g. 12 CPU cores) just muddy
            // each other and cost more to draw -- stroke-only once there
            // are more than a couple of series.
            const many = seriesList.length > 2;
            for (const s of seriesList)
                drawSeries(ctx, s.data, s.color, many ? false : !s.dashed, !!s.dashed);
        } else {
            drawSeries(ctx, series, color1, true, false);
        }
    }
}
