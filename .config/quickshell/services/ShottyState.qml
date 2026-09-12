pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Screenshot-annotation tool ("shotty") -- see the approved plan at
// ~/.claude2/plans/rippling-wiggling-wilkinson.md. Panels are dumb views
// (Shotty.qml); everything about the session lives here.
//
// Coordinates for selection/shapes are always desktop-GLOBAL logical
// coordinates (screen.x + local mouse pos), not per-panel local -- that's
// what lets a drag or a shape cross a monitor boundary: each panel only
// ever converts its own local mouse position to global on the way in, and
// converts back to local on the way out to draw. See Shotty.qml.
//
// phase: idle -> selecting -> toolbar -> drawing -> toolbar (repeat) ->
//        compositing -> idle. Escape from any non-idle phase cancels
//        straight to idle (no partial-undo, matching the "no undo" ask).
QtObject {
    id: root

    property string phase: "idle" // idle | selecting | toolbar | drawing | compositing
    property bool active: false // true whenever phase != "idle" -- Shotty.qml panels key visibility off this
    property real openedAt: 0

    // ---- selection rect (global logical coords) ----
    property real selX1: 0
    property real selY1: 0
    property real selX2: 0
    property real selY2: 0
    readonly property real selLeft: Math.min(selX1, selX2)
    readonly property real selTop: Math.min(selY1, selY2)
    readonly property real selWidth: Math.abs(selX2 - selX1)
    readonly property real selHeight: Math.abs(selY2 - selY1)

    // ---- annotation tools ----
    readonly property var palette: ["#ff5555", "#50fa7b", "#8be9fd", "#f1fa8c", "#ffffff"]
    property string currentTool: "arrow" // arrow | line | rect
    property string currentColor: root.palette[0]
    // Committed shapes: [{tool, color, x1,y1,x2,y2}], global coords.
    property var shapes: []

    // In-progress shape drag (phase "drawing"), global coords.
    property real drawX1: 0
    property real drawY1: 0
    property real drawX2: 0
    property real drawY2: 0

    // ---- commit/compositing ----
    property var _expectedNames: []
    property var _pieces: ({}) // screen.name -> {path, gx, gy, w, h, dpr}

    function open(): void {
        root.openedAt = Date.now();
        root.phase = "selecting";
        root.active = true;
        root.shapes = [];
        console.log(`shotty: open() at ${root.openedAt}`);
    }

    function close(): void {
        root.phase = "idle";
        root.active = false;
        console.log(`shotty: close() at ${Date.now()}`);
    }

    function toggle(): void {
        if (root.active) root.close(); else root.open();
    }

    // ---- selection drag ----
    function beginSelect(gx: real, gy: real): void {
        root.selX1 = root.selX2 = gx;
        root.selY1 = root.selY2 = gy;
    }
    function updateSelect(gx: real, gy: real): void {
        root.selX2 = gx;
        root.selY2 = gy;
    }
    function endSelect(): void {
        if (root.selWidth < 4 || root.selHeight < 4) {
            root.close(); // trivial drag (or a bare click) -- cancel the session
            return;
        }
        root.phase = "toolbar";
    }

    function pickTool(tool: string): void {
        root.currentTool = tool;
        root.phase = "drawing";
    }
    function pickColor(color: string): void {
        root.currentColor = color;
    }
    function backToToolbar(): void {
        root.phase = "toolbar";
    }

    // ---- shape drag ----
    function beginDraw(gx: real, gy: real): void {
        root.drawX1 = root.drawX2 = gx;
        root.drawY1 = root.drawY2 = gy;
    }
    function updateDraw(gx: real, gy: real): void {
        root.drawX2 = gx;
        root.drawY2 = gy;
    }
    function endDraw(): void {
        if (Math.abs(root.drawX2 - root.drawX1) >= 2 || Math.abs(root.drawY2 - root.drawY1) >= 2) {
            const next = root.shapes.slice();
            next.push({ tool: root.currentTool, color: root.currentColor, x1: root.drawX1, y1: root.drawY1, x2: root.drawX2, y2: root.drawY2 });
            root.shapes = next;
        }
        root.phase = "toolbar";
    }

    // ---- commit ----
    function commit(): void {
        root._pieces = {};
        root._expectedNames = Quickshell.screens
            .filter(s => s.x < root.selLeft + root.selWidth && s.x + s.width > root.selLeft &&
                         s.y < root.selTop + root.selHeight && s.y + s.height > root.selTop)
            .map(s => s.name);
        if (root._expectedNames.length === 0) {
            root.close();
            return;
        }
        root.phase = "compositing";
    }

    // Called by each intersecting Shotty.qml panel once its own full-panel
    // grab is saved to disk.
    function reportPiece(name: string, path: string, gx: real, gy: real, w: real, h: real, dpr: real): void {
        const next = Object.assign({}, root._pieces);
        next[name] = { path, gx, gy, w, h, dpr };
        root._pieces = next;
        if (Object.keys(root._pieces).length >= root._expectedNames.length) {
            root._runComposite();
        }
    }

    function _runComposite(): void {
        const dir = `${Quickshell.env("XDG_RUNTIME_DIR")}/shotty`;
        const outPath = `${dir}/shot-${Date.now()}.png`;
        const w = Math.round(root.selWidth);
        const h = Math.round(root.selHeight);

        let cmd = `mkdir -p '${dir}' && magick -size ${w}x${h} xc:none `;
        for (const name of root._expectedNames) {
            const p = root._pieces[name];
            if (!p) continue;
            // p.path is a full-screen grab at p.dpr device pixels per logical
            // pixel; crop it to the piece of the selection that overlaps this
            // screen, in that image's own pixel space, then place it in the
            // output canvas at the selection-relative offset.
            const cropX = Math.round(Math.max(0, root.selLeft - p.gx) * p.dpr);
            const cropY = Math.round(Math.max(0, root.selTop - p.gy) * p.dpr);
            const cropW = Math.round(Math.min(p.w, root.selLeft + root.selWidth - p.gx) * p.dpr) - cropX;
            const cropH = Math.round(Math.min(p.h, root.selTop + root.selHeight - p.gy) * p.dpr) - cropY;
            const pageX = Math.round(Math.max(p.gx, root.selLeft) - root.selLeft);
            const pageY = Math.round(Math.max(p.gy, root.selTop) - root.selTop);
            cmd += `\\( '${p.path}' -crop ${cropW}x${cropH}+${cropX}+${cropY} +repage -page +${pageX}+${pageY} \\) `;
        }
        cmd += `-layers merge +repage '${outPath}' && wl-copy --type image/png < '${outPath}'`;

        root._compositeProc.command = ["bash", "-c", cmd];
        root._compositeProc.running = true;
    }

    property Process _compositeProc: Process {
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) {
                console.log(`shotty: composite/copy failed, exit ${exitCode}`);
            } else {
                console.log("shotty: committed to clipboard");
                root._notifyProc.command = ["notify-send", "-a", "shotty", "Screenshot copied", "Copied to clipboard."];
                root._notifyProc.running = true;
            }
            root.close();
        }
    }
    property Process _notifyProc: Process {}
}
