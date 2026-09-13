pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "../theme"

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
    // palette[0] is a fixed toned/muted red (not neon #ff5555, and not
    // wallpaper-derived -- annotation red needs to stay visible regardless
    // of theme). The rest come from Theme.seriesPalette, the same
    // wallpaper-seeded Material You colors gen-theme.py already generates
    // for the bar's graphs -- so this palette re-themes itself whenever the
    // wallpaper does, same as everything else in this shell.
    readonly property var palette: ["#c0392b"].concat(Theme.seriesPalette.slice(0, 4))
    property string currentTool: "arrow" // arrow | line | rect
    property string currentColor: root.palette[0]
    property real currentWidth: 3 // stroke width in px, 1..24 (see the toolbar slider)
    // Committed shapes: [{tool, color, width, x1,y1,x2,y2}], global coords.
    property var shapes: []
    // Undo/redo stack (Ctrl+Z / Ctrl+Y), shapes only -- not the selection
    // itself. Drawing a new shape after an undo drops the redo stack, same
    // as any standard editor.
    property var _redoStack: []

    // ---- Ctrl+A "select all" (Lightshot precedent: Ctrl+A maximizes the
    // selection to fullscreen; extended here for multi-monitor -- first
    // press selects the screen the tool was opened on, a second
    // consecutive press expands to the full virtual desktop). Any manual
    // drag resets this so Ctrl+A always starts from "current screen" again.
    property string lastSelectAllScope: "" // "" | "screen" | "all"
    property real originX: 0
    property real originY: 0
    property real originW: 0
    property real originH: 0

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
        root._redoStack = [];
        // Reset the leftover selection rect from the previous session --
        // without this, a fresh Print showed the old spotlight cutout
        // still in place until the first new drag started.
        root.selX1 = root.selY1 = root.selX2 = root.selY2 = 0;
        root.lastSelectAllScope = "";

        const mon = Hyprland.focusedMonitor;
        const s = (mon && Quickshell.screens.find(sc => sc.name === mon.name)) || Quickshell.screens[0];
        root.originX = s.x; root.originY = s.y; root.originW = s.width; root.originH = s.height;

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

    function escapeAction(): void {
        if (root.phase === "drawing") root.phase = "toolbar"; // exit tool-modal, keep the selection
        else root.close();
    }

    // ---- selection drag ----
    function isInsideSelection(gx: real, gy: real): bool {
        return gx >= root.selLeft && gx <= root.selLeft + root.selWidth &&
               gy >= root.selTop && gy <= root.selTop + root.selHeight;
    }

    function beginSelect(gx: real, gy: real): void {
        root.lastSelectAllScope = "";
        root.selX1 = root.selX2 = gx;
        root.selY1 = root.selY2 = gy;
    }

    // ---- pan (move the whole selection without resizing it -- shapes are
    // stored in absolute screen coords and deliberately don't move with it,
    // same as Flameshot: panning/resizing only changes what gets cropped
    // into the final output, never the annotations themselves) ----
    property real _panOffsetX: 0
    property real _panOffsetY: 0
    function beginPan(gx: real, gy: real): void {
        root._panOffsetX = gx - root.selLeft;
        root._panOffsetY = gy - root.selTop;
    }
    function updatePan(gx: real, gy: real): void {
        const w = root.selWidth, h = root.selHeight;
        const left = gx - root._panOffsetX, top = gy - root._panOffsetY;
        root.selX1 = left; root.selY1 = top;
        root.selX2 = left + w; root.selY2 = top + h;
    }
    function endPan(): void {
        root.lastSelectAllScope = "";
    }

    // ---- per-shape hover/move (Stage 1 of "shapes stay editable, not
    // flattened like Lightshot" -- double-click endpoint/corner editing and
    // the text tool are later stages). Shapes are referenced by array
    // index; safe because nothing inserts/removes from `shapes` mid-drag
    // (you can't simultaneously be moving an existing shape and drawing a
    // new one). ----
    function distToSegment(px: real, py: real, x1: real, y1: real, x2: real, y2: real): real {
        const dx = x2 - x1, dy = y2 - y1;
        const lenSq = dx * dx + dy * dy;
        let t = lenSq > 0 ? ((px - x1) * dx + (py - y1) * dy) / lenSq : 0;
        t = Math.max(0, Math.min(1, t));
        return Math.hypot(px - (x1 + t * dx), py - (y1 + t * dy));
    }

    function distToShape(s: var, px: real, py: real): real {
        if (s.tool === "rect") {
            const left = Math.min(s.x1, s.x2), right = Math.max(s.x1, s.x2);
            const top = Math.min(s.y1, s.y2), bottom = Math.max(s.y1, s.y2);
            const dx = Math.max(left - px, 0, px - right);
            const dy = Math.max(top - py, 0, py - bottom);
            return Math.hypot(dx, dy);
        }
        return root.distToSegment(px, py, s.x1, s.y1, s.x2, s.y2);
    }

    // Returns the index of the topmost (last-drawn) shape within
    // `threshold` px of a point, or -1. Same generous-radius-independent-
    // of-visual-size idea as hitTestHandle.
    function hitTestShape(gx: real, gy: real, threshold: real): int {
        for (let i = root.shapes.length - 1; i >= 0; i--) {
            if (root.distToShape(root.shapes[i], gx, gy) <= threshold) return i;
        }
        return -1;
    }

    property int movingShapeIndex: -1
    property real _moveLastX: 0
    property real _moveLastY: 0

    function beginMoveShape(index: int, gx: real, gy: real): void {
        root.movingShapeIndex = index;
        root._moveLastX = gx;
        root._moveLastY = gy;
    }
    function updateMoveShape(gx: real, gy: real): void {
        if (root.movingShapeIndex < 0) return;
        const dx = gx - root._moveLastX, dy = gy - root._moveLastY;
        const next = root.shapes.slice();
        const s = Object.assign({}, next[root.movingShapeIndex]);
        s.x1 += dx; s.y1 += dy; s.x2 += dx; s.y2 += dy;
        next[root.movingShapeIndex] = s;
        root.shapes = next;
        root._moveLastX = gx;
        root._moveLastY = gy;
    }
    function endMoveShape(): void {
        root.movingShapeIndex = -1;
    }

    // Ctrl+A: first call selects the screen the tool opened on; a second
    // consecutive call (no manual drag in between) expands to every
    // monitor's combined bounding box. Works from "selecting" (no
    // selection yet) or "toolbar" (replacing the current selection).
    function selectAllToggle(): void {
        if (root.phase !== "selecting" && root.phase !== "toolbar") return;
        if (root.lastSelectAllScope !== "screen") {
            root.selX1 = root.originX;
            root.selY1 = root.originY;
            root.selX2 = root.originX + root.originW;
            root.selY2 = root.originY + root.originH;
            root.lastSelectAllScope = "screen";
        } else {
            let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
            for (const s of Quickshell.screens) {
                minX = Math.min(minX, s.x);
                minY = Math.min(minY, s.y);
                maxX = Math.max(maxX, s.x + s.width);
                maxY = Math.max(maxY, s.y + s.height);
            }
            root.selX1 = minX; root.selY1 = minY;
            root.selX2 = maxX; root.selY2 = maxY;
            root.lastSelectAllScope = "all";
        }
        root.phase = "toolbar";
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

    // ---- resize handles (8 handles around the selection border, active
    // only in "toolbar" phase). Reuses the exact same mechanism as the
    // initial drag: an "anchor" point (the opposite corner/edge, held
    // fixed) and a "free" point that follows the mouse, both funneled
    // through selX1/Y1/X2/Y2 -- so selLeft/selTop/selWidth/selHeight's
    // existing min()/abs() derivation handles a drag crossing past the
    // opposite edge for free, no extra flip-handling needed. Edge (not
    // corner) handles additionally pin the OTHER axis to both of its
    // current extents up front, then updateResize only ever touches the
    // one axis that's actually supposed to move.
    property string _resizeEdge: ""

    function beginResize(edge: string, gx: real, gy: real): void {
        root._resizeEdge = edge;
        const left = root.selLeft, right = root.selLeft + root.selWidth;
        const top = root.selTop, bottom = root.selTop + root.selHeight;
        switch (edge) {
            case "nw": root.selX1 = right; root.selY1 = bottom; break;
            case "ne": root.selX1 = left;  root.selY1 = bottom; break;
            case "sw": root.selX1 = right; root.selY1 = top;    break;
            case "se": root.selX1 = left;  root.selY1 = top;    break;
            case "n":  root.selX1 = left;  root.selY1 = bottom; root.selX2 = right; break;
            case "s":  root.selX1 = left;  root.selY1 = top;    root.selX2 = right; break;
            case "w":  root.selX1 = right; root.selY1 = top;    root.selY2 = bottom; break;
            case "e":  root.selX1 = left;  root.selY1 = top;    root.selY2 = bottom; break;
        }
        root.updateResize(gx, gy);
    }

    function updateResize(gx: real, gy: real): void {
        const edge = root._resizeEdge;
        if (edge === "n" || edge === "s") {
            root.selY2 = gy; // X1/X2 already pinned to left/right in beginResize
        } else if (edge === "w" || edge === "e") {
            root.selX2 = gx; // Y1/Y2 already pinned to top/bottom in beginResize
        } else {
            root.selX2 = gx;
            root.selY2 = gy;
        }
    }

    function endResize(): void {
        root._resizeEdge = "";
        root.lastSelectAllScope = ""; // this is a manual edit, same as any drag
    }

    // Returns which handle (if any) a point is within `threshold` px of, or
    // "" if none -- used by the single confirmed-working MouseArea to
    // detect "the press is meant to resize, not pan/reselect" itself,
    // rather than giving each of the 8 handles its own separate MouseArea
    // (which never received a single real press/drag on this compositor,
    // even correctly sized/positioned -- same class of thing as
    // WheelHandler never firing). A generous threshold also means the
    // clickable region can be much bigger than the little square drawn for
    // it, independent of how large that square actually is.
    function hitTestHandle(gx: real, gy: real, threshold: real): string {
        const left = root.selLeft, right = root.selLeft + root.selWidth;
        const top = root.selTop, bottom = root.selTop + root.selHeight;
        const midX = (left + right) / 2, midY = (top + bottom) / 2;
        const points = [
            ["nw", left, top], ["n", midX, top], ["ne", right, top],
            ["w", left, midY], ["e", right, midY],
            ["sw", left, bottom], ["s", midX, bottom], ["se", right, bottom]
        ];
        let best = "", bestDist = threshold;
        for (const p of points) {
            const d = Math.hypot(gx - p[1], gy - p[2]);
            if (d <= bestDist) { bestDist = d; best = p[0]; }
        }
        return best;
    }

    function pickTool(tool: string): void {
        root.currentTool = tool;
        // Zero out the leftover drag coords from the last shape -- without
        // this, flipping to "drawing" briefly repaints a ghost of whatever
        // was last drawn (onPaint renders drawX1..drawY2 the instant phase
        // becomes "drawing", before beginDraw() ever overwrites them).
        root.drawX1 = root.drawY1 = root.drawX2 = root.drawY2 = 0;
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
    // snapAngle: held Ctrl while dragging an arrow/line's second point --
    // rounds the angle from the start point to the nearest 45 deg (keeping
    // the actual dragged distance), same idea as Flameshot's Shift-snap.
    // Not applied to "rect" -- there's no meaningful "angle" for a
    // rectangle's opposite corner to snap to.
    function updateDraw(gx: real, gy: real, snapAngle: bool): void {
        if (snapAngle && (root.currentTool === "arrow" || root.currentTool === "line")) {
            const dx = gx - root.drawX1, dy = gy - root.drawY1;
            const dist = Math.hypot(dx, dy);
            const step = Math.PI / 4; // 45 degrees
            const angle = Math.round(Math.atan2(dy, dx) / step) * step;
            root.drawX2 = root.drawX1 + dist * Math.cos(angle);
            root.drawY2 = root.drawY1 + dist * Math.sin(angle);
        } else {
            root.drawX2 = gx;
            root.drawY2 = gy;
        }
    }
    function endDraw(): void {
        if (Math.abs(root.drawX2 - root.drawX1) >= 2 || Math.abs(root.drawY2 - root.drawY1) >= 2) {
            const next = root.shapes.slice();
            next.push({ tool: root.currentTool, color: root.currentColor, width: root.currentWidth, x1: root.drawX1, y1: root.drawY1, x2: root.drawX2, y2: root.drawY2 });
            root.shapes = next;
            root._redoStack = []; // a new shape invalidates any redo history
        }
        // Zero the in-progress drag coords -- otherwise the just-finished
        // shape's stale coordinates would render a second time as the
        // "live preview" (phase is still "drawing") until the next press
        // overwrites them, showing a visible duplicate.
        root.drawX1 = root.drawY1 = root.drawX2 = root.drawY2 = 0;
        // Deliberately NOT resetting phase to "toolbar" -- the tool stays
        // armed/modal so the next drag draws another shape immediately,
        // same tool, no need to press the shortcut again. Escape
        // (escapeAction()) is what exits back to "toolbar".
    }

    // ---- undo/redo (shapes only, not the selection itself) ----
    function undo(): void {
        if (root.shapes.length === 0) return;
        const shapes = root.shapes.slice();
        const popped = shapes.pop();
        root.shapes = shapes;
        const redo = root._redoStack.slice();
        redo.push(popped);
        root._redoStack = redo;
    }
    function redo(): void {
        if (root._redoStack.length === 0) return;
        const redo = root._redoStack.slice();
        const shape = redo.pop();
        root._redoStack = redo;
        const shapes = root.shapes.slice();
        shapes.push(shape);
        root.shapes = shapes;
    }

    // ---- commit (copy to clipboard) / save-as (write to a chosen file) ----
    property string _commitMode: "clipboard" // "clipboard" | "file"
    property string _commitPath: ""

    function commit(): void {
        root._commitMode = "clipboard";
        root._beginCommit();
    }

    // fileUrl: a QML file:// URL string, as produced by FileDialog's
    // selectedFile -- the actual dialog lives in shell.qml (it needs a
    // window/Item context this QtObject singleton doesn't have) and calls
    // this once the user picks a destination.
    function saveToFile(fileUrl: string): void {
        root._commitMode = "file";
        root._commitPath = fileUrl.replace(/^file:\/\//, "");
        root._beginCommit();
    }

    function _beginCommit(): void {
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

    // The actual FileDialog lives in shell.qml (needs a window context this
    // singleton doesn't have); Ctrl+S / the toolbar's save button just ask
    // for it to open, pre-filled with defaultSavePath().
    signal requestSaveDialog()

    // Default location/name for the save-as dialog -- same convention
    // hyprshot already used (XDG_PICTURES_DIR, falling back to $HOME).
    function defaultSavePath(): string {
        const dir = Quickshell.env("XDG_PICTURES_DIR") || Quickshell.env("HOME");
        const d = new Date();
        const pad = n => String(n).padStart(2, "0");
        const name = `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}_shotty.png`;
        return `${dir}/${name}`;
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
        // Clipboard mode composites to a throwaway tmpfs file, then wl-copy
        // reads it. Save-as mode composites directly to the user's chosen
        // path -- no intermediate file at all.
        const outPath = root._commitMode === "file" ? root._commitPath : `${dir}/shot-${Date.now()}.png`;
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
        cmd += `-layers merge +repage '${outPath}'`;
        if (root._commitMode === "clipboard") {
            cmd += ` && wl-copy --type image/png < '${outPath}'`;
        }

        root._compositeProc.command = ["bash", "-c", cmd];
        root._compositeProc.running = true;
    }

    property Process _compositeProc: Process {
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) {
                console.log(`shotty: composite/${root._commitMode === "file" ? "save" : "copy"} failed, exit ${exitCode}`);
            } else if (root._commitMode === "file") {
                console.log(`shotty: saved to ${root._commitPath}`);
                root._notifyProc.command = ["notify-send", "-a", "shotty", "Screenshot saved", root._commitPath];
                root._notifyProc.running = true;
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
