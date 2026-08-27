import QtQuick
import "../theme"

// Filled-area-under-line chart, same visual recipe as
// ~/.config/hypr/sysmon/src/bin/sysmon-graph.rs's draw_series (0.18-alpha
// fill, 0.95-alpha 2px stroke) so the bar's hover graphs read as the same
// family as the existing alt+mod+n/p/t popups.
//
// Three usage modes:
//  - single: set `series`/`color1`.
//  - overlay (e.g. network rx/tx per interface): set `seriesList` to
//    [{data, color, dashed}, ...] -- dashed lines skip the fill so
//    overlapping series don't muddy each other.
//  - stacked (e.g. per-core CPU): set `stackedList` to
//    [{data, color}, ...] -- each series is drawn cumulatively on top of
//    the ones before it, like a stacked area chart.
Canvas {
    id: root

    property list<real> series: []
    property color color1: Theme.cyan
    property var seriesList: []
    property var stackedList: []
    property real maxValue: 100

    onSeriesChanged: requestPaint()
    onSeriesListChanged: requestPaint()
    onStackedListChanged: requestPaint()
    onMaxValueChanged: requestPaint()

    function drawSeries(ctx, data, rgb, fill, dashed) {
        if (data.length < 2)
            return;
        const w = width, h = height;
        const n = data.length;
        const step = w / (n - 1);
        const yOf = v => h - Math.max(0, Math.min(1, v / root.maxValue)) * h;

        if (fill) {
            ctx.beginPath();
            ctx.moveTo(0, h);
            for (let i = 0; i < n; i++)
                ctx.lineTo(i * step, yOf(data[i]));
            ctx.lineTo((n - 1) * step, h);
            ctx.closePath();
            ctx.fillStyle = Qt.rgba(rgb.r, rgb.g, rgb.b, 0.18);
            ctx.fill();
        }

        ctx.beginPath();
        ctx.setLineDash(dashed ? [6, 4] : []);
        ctx.moveTo(0, yOf(data[0]));
        for (let i = 1; i < n; i++)
            ctx.lineTo(i * step, yOf(data[i]));
        ctx.strokeStyle = Qt.rgba(rgb.r, rgb.g, rgb.b, 0.95);
        ctx.lineWidth = 2;
        ctx.stroke();
        ctx.setLineDash([]);
    }

    function drawStacked(ctx) {
        const lists = root.stackedList.filter(s => s.data.length > 1);
        if (lists.length === 0)
            return;
        const w = width, h = height;
        const n = Math.min(...lists.map(s => s.data.length));
        const step = w / (n - 1);
        const yOf = v => h - Math.max(0, Math.min(1, v / root.maxValue)) * h;

        // Running cumulative sum, bottom series first.
        let cumBottom = new Array(n).fill(0);
        for (const s of lists) {
            const cumTop = cumBottom.map((v, i) => v + s.data[i]);

            ctx.beginPath();
            ctx.moveTo(0, yOf(cumBottom[0]));
            for (let i = 1; i < n; i++)
                ctx.lineTo(i * step, yOf(cumBottom[i]));
            for (let i = n - 1; i >= 0; i--)
                ctx.lineTo(i * step, yOf(cumTop[i]));
            ctx.closePath();
            ctx.fillStyle = Qt.rgba(s.color.r, s.color.g, s.color.b, 0.55);
            ctx.fill();
            ctx.strokeStyle = Qt.rgba(s.color.r, s.color.g, s.color.b, 0.9);
            ctx.lineWidth = 1;
            ctx.beginPath();
            ctx.moveTo(0, yOf(cumTop[0]));
            for (let i = 1; i < n; i++)
                ctx.lineTo(i * step, yOf(cumTop[i]));
            ctx.stroke();

            cumBottom = cumTop;
        }
    }

    onPaint: {
        const ctx = getContext("2d");
        ctx.reset();
        if (stackedList.length > 0) {
            drawStacked(ctx);
        } else if (seriesList.length > 0) {
            for (const s of seriesList)
                drawSeries(ctx, s.data, s.color, !s.dashed, !!s.dashed);
        } else {
            drawSeries(ctx, series, color1, true, false);
        }
    }
}
