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

    function drawSeries(ctx, rawData, rawColor, fill, dashed, lineWidth, alpha) {
        if (rawData.length < 2)
            return;
        const points = root.downsample(rawData);
        if (points.length < 2)
            return;
        // seriesList's per-entry `color` field comes from Theme.seriesPalette,
        // an untyped `property var` array of plain hex STRINGS (not QML
        // `color` objects -- only a top-level `property color` gets that
        // string->QColor auto-coercion, a nested object-literal field like
        // seriesList[i].color never does). rgb.r/.g/.b on a bare string is
        // undefined, so every overlay graph (net/cpu/mem/disk) has been
        // drawing Qt.rgba(undefined, undefined, undefined, alpha) -- i.e.
        // black -- since overlay mode was introduced; only the single-series
        // path (color1, a real `property color`) ever worked. Reported as
        // "CPU is all black" / "graphs don't use theme colors" 2026-08-28.
        const rgb = Qt.color(rawColor);
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
        ctx.strokeStyle = Qt.rgba(rgb.r, rgb.g, rgb.b, alpha);
        ctx.lineWidth = lineWidth;
        ctx.stroke();
        ctx.setLineDash([]);
    }

    // Fractions of maxValue (0=bottom, 1=top) to draw a faint horizontal
    // line at -- GraphPill's y-axis label column lines its own labels up
    // against these same fractions, so the two have to stay in sync.
    property var gridFractions: [0, 0.25, 0.5, 0.75, 1.0]

    function drawGrid(ctx) {
        ctx.beginPath();
        for (const f of gridFractions) {
            const y = height - f * height;
            ctx.moveTo(0, y);
            ctx.lineTo(width, y);
        }
        ctx.strokeStyle = Qt.rgba(Theme.textDim.r, Theme.textDim.g, Theme.textDim.b, 0.15);
        ctx.lineWidth = 1;
        ctx.stroke();
    }

    onPaint: {
        const ctx = getContext("2d");
        ctx.reset();
        drawGrid(ctx);
        if (seriesList.length > 0) {
            // Many overlapping filled areas (e.g. 12 CPU cores) just muddy
            // each other and cost more to draw -- stroke-only once there
            // are more than a couple of series. That same overlap is also
            // why "many" needs a bolder, more opaque line than a lone
            // series: a dozen thin (1.25px, alpha 0.9) semi-transparent
            // lines sharing the same few low-activity pixel rows optically
            // blend into a dark, undifferentiated mud (reported as "CPU is
            // all black", 2026-08-28) rather than reading as 12 distinct
            // colors -- near-opaque + slightly thicker keeps each core's
            // hue legible even where several overlap.
            const many = seriesList.length > 2;
            for (const s of seriesList)
                drawSeries(ctx, s.data, s.color, many ? false : !s.dashed, !!s.dashed, many ? 1.5 : 1.25, many ? 1.0 : 0.9);
        } else {
            drawSeries(ctx, series, color1, true, false, 1.25, 0.9);
        }
    }
}
