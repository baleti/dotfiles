import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import "../services"
import "../theme"

// Screenshot annotation tool ("shotty", Print key) -- see
// ~/.claude2/plans/rippling-wiggling-wilkinson.md. One instance per
// monitor; unlike launcher/clipboardPicker/etc every instance opens
// together (no focused-monitor latch), since a selection or a shape can
// span monitor boundaries.
//
// Coordinate model: this panel only ever converts ITS OWN local mouse
// position to desktop-global coordinates on the way into ShottyState, and
// converts back to local on the way out to draw -- see toLocal() below.
// Wayland gives the panel that received a button press an implicit pointer
// grab for the drag's duration, so local mouseX/mouseY keep updating
// (out-of-range) even once the cursor visually crosses onto another
// monitor -- that's the whole mechanism, no explicit multi-panel handoff
// needed. (This is the same mechanism `slurp` already relies on.)
PanelWindow {
    id: root

    property bool open: false
    property bool colorPickerOpen: false
    property bool widthPickerOpen: false

    function _recompute() {
        root.open = ShottyState.active;
    }
    Component.onCompleted: root._recompute()
    Connections {
        target: ShottyState
        function onActiveChanged() { root._recompute(); }
    }

    function toLocalX(gx: real): real { return gx - root.screen.x; }
    function toLocalY(gy: real): real { return gy - root.screen.y; }

    // captureSource is assigned imperatively here, on open, NOT as a static
    // QML binding on the ScreencopyView below. A static binding evaluates
    // the instant the item is constructed -- i.e. at qs startup, regardless
    // of `open` -- and Quickshell's own createContext() auto-fires a real
    // capture the moment captureSource is set (confirmed via
    // ~/.cache/paru/clone/quickshell-git .../screencopy/view.cpp). That
    // means simply launching qs would open a screencopy session per
    // monitor before the tool is ever used, which is both wasteful and (on
    // a machine that hasn't yet answered Hyprland's screencopy permission
    // prompt) blocks compositor rendering while that prompt sits
    // unanswered -- this is what caused a real ~1-2min freeze 2026-09-12
    // during initial development. setCaptureSource() no-ops if the value
    // is unchanged, so reassigning on every open is safe/cheap.
    onOpenChanged: {
        if (root.open) {
            view.captureSource = root.screen;
            view.captureFrame();
            root.colorPickerOpen = false;
            root.widthPickerOpen = false;
            Qt.callLater(() => escCatcher.forceActiveFocus());
        }
    }

    // Re-grab and re-composite whenever we enter "compositing", if this
    // panel's screen overlaps the final selection.
    Connections {
        target: ShottyState
        function onPhaseChanged() {
            if (ShottyState.phase === "compositing" && root._intersectsSelection()) {
                root._grabAndReport();
            }
        }
    }

    function _intersectsSelection(): bool {
        const s = root.screen;
        return s.x < ShottyState.selLeft + ShottyState.selWidth && s.x + s.width > ShottyState.selLeft &&
               s.y < ShottyState.selTop + ShottyState.selHeight && s.y + s.height > ShottyState.selTop;
    }

    function _grabAndReport(): void {
        // NOT screen.devicePixelRatio: Qt rounds fractional Hyprland scales
        // (eDP-2 is really 1.5x, Qt reports 2) but grabToImage's actual
        // output resolution follows Hyprland's real scale. Using Qt's
        // rounded dpr made crop math request more pixels than the grabbed
        // image actually has, silently clipped by ImageMagick to the real
        // (narrower) width -- the visible cause of a 2026-09-12 stitching
        // gap at eDP-2's boundary. view.sourceSize is the actual captured
        // frame's pixel size, so this ratio is always correct regardless of
        // Qt's own scale-rounding.
        const dpr = (view.sourceSize.width > 0 && root.screen.width > 0)
            ? view.sourceSize.width / root.screen.width
            : (root.screen.devicePixelRatio || 1);
        grabTarget.grabToImage(result => {
            const dir = `${Quickshell.env("XDG_RUNTIME_DIR")}/shotty`;
            const path = `${dir}/piece-${root.screen.name}-${Date.now()}.png`;
            result.saveToFile(path);
            ShottyState.reportPiece(root.screen.name, path, root.screen.x, root.screen.y, root.screen.width, root.screen.height, dpr);
        });
    }

    // Same shape as AppLauncher/NotifLayer -- a 4-edge full-screen anchor is
    // an Overlay surface that doesn't reliably map on every output here.
    anchors { top: true; left: true }
    implicitWidth: root.screen ? root.screen.width : 1920
    implicitHeight: root.screen ? root.screen.height : 1080
    color: "transparent"
    visible: root.open
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    WlrLayershell.namespace: "quickshell-shotty"
    exclusionMode: ExclusionMode.Ignore

    // Everything below gets grabbed together (screencopy frame + dim +
    // shapes), which is exactly what we want committed to the clipboard.
    Item {
        id: grabTarget
        anchors.fill: parent

        ScreencopyView {
            id: view
            anchors.fill: parent
            // Not bound declaratively -- see onOpenChanged above.
            captureSource: null
            paintCursor: false
            live: false
        }

        // Dim everywhere except the selection rect (a "spotlight" cutout),
        // plus committed shapes and the in-progress one being drawn.
        Canvas {
            id: canvas
            anchors.fill: parent

            // One derived property so a single onXxxChanged handles every
            // dependency -- QML tracks each singleton property read inside
            // this binding and re-evaluates it (and only it) when any of
            // them change.
            property var paintSnapshot: [
                ShottyState.phase, ShottyState.selX1, ShottyState.selY1, ShottyState.selX2, ShottyState.selY2,
                ShottyState.drawX1, ShottyState.drawY1, ShottyState.drawX2, ShottyState.drawY2,
                ShottyState.shapes.length, JSON.stringify(ShottyState.shapes),
                ShottyState.currentColor, ShottyState.currentWidth
            ]
            onPaintSnapshotChanged: requestPaint()
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()

            function drawShape(ctx, tool, color, lineWidth, x1, y1, x2, y2) {
                ctx.strokeStyle = color;
                ctx.fillStyle = color;
                ctx.lineWidth = lineWidth;
                if (tool === "rect") {
                    ctx.lineCap = "square";
                    ctx.strokeRect(Math.min(x1, x2), Math.min(y1, y2), Math.abs(x2 - x1), Math.abs(y2 - y1));
                } else if (tool === "line") {
                    ctx.lineCap = "round";
                    ctx.beginPath();
                    ctx.moveTo(x1, y1);
                    ctx.lineTo(x2, y2);
                    ctx.stroke();
                } else { // arrow -- filled solid triangle head, sharp (no
                         // rounded caps anywhere), scales with stroke width.
                    ctx.lineCap = "butt";
                    const angle = Math.atan2(y2 - y1, x2 - x1);
                    // Mostly proportional to stroke width (a fixed base
                    // offset made thin lines look disproportionately
                    // big-headed) -- small floor so a 1px line still gets a
                    // visible head instead of nearly vanishing.
                    const headLen = Math.max(8, lineWidth * 3.5);
                    const headAngle = Math.PI / 7;

                    // Pull the shaft back so it ends at the head's base
                    // instead of poking through the solid triangle.
                    const backX = x2 - headLen * 0.85 * Math.cos(angle);
                    const backY = y2 - headLen * 0.85 * Math.sin(angle);
                    ctx.beginPath();
                    ctx.moveTo(x1, y1);
                    ctx.lineTo(backX, backY);
                    ctx.stroke();

                    const hx1 = x2 - headLen * Math.cos(angle - headAngle);
                    const hy1 = y2 - headLen * Math.sin(angle - headAngle);
                    const hx2 = x2 - headLen * Math.cos(angle + headAngle);
                    const hy2 = y2 - headLen * Math.sin(angle + headAngle);
                    ctx.beginPath();
                    ctx.moveTo(x2, y2);
                    ctx.lineTo(hx1, hy1);
                    ctx.lineTo(hx2, hy2);
                    ctx.closePath();
                    ctx.fill();
                }
            }

            onPaint: {
                const ctx = getContext("2d");
                ctx.reset();
                if (ShottyState.phase === "idle") return;

                // Skip the dim/cutout/border once committing: they're
                // purely decorative (always cropped away, only the inner
                // selection rect ever makes it into the composited output)
                // and the actual grab/composite/wl-copy pipeline keeps
                // running in the background regardless of what's painted
                // here -- clearing them the instant Ctrl+C/Enter is pressed
                // makes the frozen frame snap back to looking like the live
                // desktop immediately instead of visibly lingering for
                // however long compositing takes.
                if (ShottyState.phase !== "compositing") {
                    ctx.fillStyle = "rgba(0, 0, 0, 0.45)";
                    ctx.fillRect(0, 0, width, height);

                    if (ShottyState.selWidth > 0 || ShottyState.selHeight > 0) {
                        const lx = root.toLocalX(ShottyState.selLeft);
                        const ly = root.toLocalY(ShottyState.selTop);
                        ctx.clearRect(lx, ly, ShottyState.selWidth, ShottyState.selHeight);
                        ctx.strokeStyle = Theme.cyan;
                        ctx.lineWidth = 1;
                        ctx.strokeRect(lx + 0.5, ly + 0.5, ShottyState.selWidth - 1, ShottyState.selHeight - 1);
                    }
                }

                for (const shape of ShottyState.shapes) {
                    drawShape(ctx,
                        shape.tool, shape.color, shape.width || 3,
                        root.toLocalX(shape.x1), root.toLocalY(shape.y1),
                        root.toLocalX(shape.x2), root.toLocalY(shape.y2));
                }

                if (ShottyState.phase === "drawing") {
                    drawShape(ctx,
                        ShottyState.currentTool, ShottyState.currentColor, ShottyState.currentWidth,
                        root.toLocalX(ShottyState.drawX1), root.toLocalY(ShottyState.drawY1),
                        root.toLocalX(ShottyState.drawX2), root.toLocalY(ShottyState.drawY2));
                }
            }
        }
    }

    MouseArea {
        id: mainArea
        anchors.fill: parent
        enabled: ShottyState.phase === "selecting" || ShottyState.phase === "toolbar" || ShottyState.phase === "drawing"
        hoverEnabled: true
        property bool panning: false

        // "toolbar" phase (a selection exists, no tool armed): hovering
        // inside the selection shows a move/pan cursor (same idea as
        // Hyprland's mod+drag window-move cursor) since dragging there
        // pans the whole selection; anywhere else (or in "selecting"/
        // "drawing") is a plain crosshair, since a drag there always
        // starts something fresh (a new selection, or a new shape).
        readonly property bool hoverInsideSel: ShottyState.phase === "toolbar" &&
            ShottyState.isInsideSelection(root.screen.x + mouseX, root.screen.y + mouseY)
        cursorShape: hoverInsideSel ? Qt.SizeAllCursor : Qt.CrossCursor

        onPressed: mouse => {
            const gx = root.screen.x + mouse.x, gy = root.screen.y + mouse.y;
            if (ShottyState.phase === "selecting") {
                ShottyState.beginSelect(gx, gy);
            } else if (ShottyState.phase === "toolbar") {
                if (ShottyState.isInsideSelection(gx, gy)) {
                    mainArea.panning = true;
                    ShottyState.beginPan(gx, gy);
                } else {
                    mainArea.panning = false;
                    ShottyState.phase = "selecting"; // hides the toolbar/handles for the new drag
                    ShottyState.beginSelect(gx, gy); // replaces the current selection
                }
            } else if (ShottyState.phase === "drawing") {
                ShottyState.beginDraw(gx, gy);
            }
        }
        onPositionChanged: mouse => {
            const gx = root.screen.x + mouse.x, gy = root.screen.y + mouse.y;
            if (ShottyState.phase === "selecting") {
                ShottyState.updateSelect(gx, gy);
            } else if (ShottyState.phase === "toolbar" && pressed) {
                if (mainArea.panning) ShottyState.updatePan(gx, gy);
                else ShottyState.updateSelect(gx, gy);
            } else if (ShottyState.phase === "drawing") {
                ShottyState.updateDraw(gx, gy);
            }
        }
        onReleased: mouse => {
            if (ShottyState.phase === "selecting") {
                ShottyState.endSelect();
            } else if (ShottyState.phase === "toolbar") {
                if (mainArea.panning) ShottyState.endPan();
                else ShottyState.endSelect();
                mainArea.panning = false;
            } else if (ShottyState.phase === "drawing") {
                ShottyState.endDraw();
            }
        }
    }

    // Resize handles: 8 small draggable squares around the selection
    // border, active only once a selection exists ("toolbar" phase, not
    // while actively drawing a shape). Each handle's global position is
    // computed from the current selection bounds; a handle whose position
    // falls outside THIS panel's own screen just renders off-window and is
    // naturally invisible/non-interactive there (a Wayland surface only
    // composites and accepts input within its own bounds) -- so every
    // panel can declare all 8 unconditionally and only the panel(s) that
    // actually contain a given handle ever show or receive it, exactly
    // like shapes/selection already work.
    Repeater {
        model: [
            { edge: "nw", cursor: Qt.SizeFDiagCursor },
            { edge: "n",  cursor: Qt.SizeVerCursor },
            { edge: "ne", cursor: Qt.SizeBDiagCursor },
            { edge: "w",  cursor: Qt.SizeHorCursor },
            { edge: "e",  cursor: Qt.SizeHorCursor },
            { edge: "sw", cursor: Qt.SizeBDiagCursor },
            { edge: "s",  cursor: Qt.SizeVerCursor },
            { edge: "se", cursor: Qt.SizeFDiagCursor }
        ]
        Rectangle {
            id: handle
            required property var modelData
            readonly property real gx: {
                switch (modelData.edge) {
                    case "nw": case "w": case "sw": return ShottyState.selLeft;
                    case "ne": case "e": case "se": return ShottyState.selLeft + ShottyState.selWidth;
                    default: return ShottyState.selLeft + ShottyState.selWidth / 2; // n, s
                }
            }
            readonly property real gy: {
                switch (modelData.edge) {
                    case "nw": case "n": case "ne": return ShottyState.selTop;
                    case "sw": case "s": case "se": return ShottyState.selTop + ShottyState.selHeight;
                    default: return ShottyState.selTop + ShottyState.selHeight / 2; // w, e
                }
            }
            visible: ShottyState.phase === "toolbar"
            width: 9; height: 9; radius: 2
            x: root.toLocalX(gx) - width / 2
            y: root.toLocalY(gy) - height / 2
            color: Theme.cyan
            border.width: 1
            border.color: Theme.bg
            z: 15

            MouseArea {
                id: handleMouse
                anchors.fill: parent
                anchors.margins: -4 // small squares are hard to grab exactly
                cursorShape: handle.modelData.cursor
                // mapToItem(root, ...), not handle.x + mouse.x: this
                // MouseArea is expanded 4px beyond `handle` by the negative
                // margin above, so mouse.x/y aren't directly relative to
                // handle's own origin.
                onPressed: mouse => {
                    const p = handleMouse.mapToItem(root, mouse.x, mouse.y);
                    ShottyState.beginResize(handle.modelData.edge, p.x + root.screen.x, p.y + root.screen.y);
                }
                onPositionChanged: mouse => {
                    if (!pressed) return;
                    const p = handleMouse.mapToItem(root, mouse.x, mouse.y);
                    ShottyState.updateResize(p.x + root.screen.x, p.y + root.screen.y);
                }
                onReleased: ShottyState.endResize()
            }
        }
    }

    // Toolbar tracks the selection's own bottom-right corner, shown only in
    // whichever panel that corner actually falls in (an arbitrary but
    // always well-defined anchor point).
    readonly property bool _isToolbarAnchor: {
        const s = root.screen;
        const px = ShottyState.selLeft + ShottyState.selWidth;
        const py = ShottyState.selTop + ShottyState.selHeight;
        return s && px >= s.x && px <= s.x + s.width && py >= s.y && py <= s.y + s.height;
    }

    Rectangle {
        id: toolbar
        visible: root._isToolbarAnchor && (ShottyState.phase === "toolbar" || ShottyState.phase === "drawing")
        width: Math.min(row.implicitWidth, root.width - 40) + 12
        height: row.implicitHeight + 10
        // Anchored to the selection's bottom-right corner, but clamped to
        // stay fully on this screen -- a selection ending near a screen
        // edge would otherwise push the toolbar half off-screen.
        x: Math.max(0, Math.min(root.toLocalX(ShottyState.selLeft + ShottyState.selWidth), root.width - width))
        y: Math.max(0, Math.min(root.toLocalY(ShottyState.selTop + ShottyState.selHeight) + 8, root.height - height))
        radius: 8
        color: Theme.bgAlpha
        border.width: 1
        border.color: Theme.border

        // Row, not Flow: Flow's own implicitWidth depends on whatever width
        // it's currently assigned (wrapping is width-dependent), so any
        // `width: f(implicitWidth)` binding on a Flow is self-referential
        // and QML resolves it unpredictably -- this is what wrapped the
        // toolbar into one long vertical column instead of reflowing sanely
        // (2026-09-12). Row's implicitWidth is always just "natural
        // single-line content width" regardless of its own assigned width,
        // so capping it here is safe; in the rare case content is wider
        // than the screen it clips at the toolbar's edge rather than
        // wrapping -- acceptable since none of this machine's real monitors
        // are anywhere near that narrow.
        Row {
            id: row
            x: 6
            y: 5
            spacing: 5

            ToolButton {
                iconType: "arrow"; tooltip: "Arrow (A)"; active: ShottyState.currentTool === "arrow"
                onActivated: ShottyState.pickTool("arrow")
            }
            ToolButton {
                iconType: "rect"; tooltip: "Rectangle (R)"; active: ShottyState.currentTool === "rect"
                onActivated: ShottyState.pickTool("rect")
            }
            ToolButton {
                iconType: "line"; tooltip: "Line (L)"; active: ShottyState.currentTool === "line"
                onActivated: ShottyState.pickTool("line")
            }

            Rectangle { width: 1; height: 28; color: Theme.border }

            // Single color-picker button (shows the current color) instead
            // of all swatches inline -- click opens a small flyout with the
            // full palette (below).
            Rectangle {
                id: colorPickerButton
                width: 28; height: 28; radius: 14
                color: ShottyState.currentColor
                border.width: 2
                border.color: Theme.text
                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        root.colorPickerOpen = !root.colorPickerOpen;
                        root.widthPickerOpen = false;
                    }
                }
            }

            Rectangle { width: 1; height: 28; color: Theme.border }

            // Line-thickness button: shows the current width as a bar
            // (thicker bar = thicker stroke), click opens a flyout with the
            // actual slider -- same collapse-to-flyout pattern as the color
            // picker, instead of an always-visible slider eating toolbar
            // width. Also adjustable directly via Ctrl+wheel, see the
            // WheelHandler below.
            Rectangle {
                id: widthPickerButton
                width: 28; height: 28; radius: 5
                color: Theme.bgAlpha
                border.width: 1
                border.color: Theme.border
                Rectangle {
                    anchors.centerIn: parent
                    width: 16
                    height: Math.max(2, Math.min(10, ShottyState.currentWidth))
                    radius: height / 2
                    color: Theme.text
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        root.widthPickerOpen = !root.widthPickerOpen;
                        root.colorPickerOpen = false;
                    }
                }
            }

            Rectangle { width: 1; height: 28; color: Theme.border }

            ToolButton { iconType: "copy"; tooltip: "Copy to clipboard (Ctrl+C / Enter)"; onActivated: ShottyState.commit() }
            ToolButton { iconType: "save"; tooltip: "Save to file (Ctrl+S)"; onActivated: ShottyState.requestSaveDialog() }
            ToolButton { iconType: "cancel"; tooltip: "Cancel (Esc)"; onActivated: ShottyState.close() }
        }
    }

    // Color palette flyout -- opened by the toolbar's single color-picker
    // button instead of showing every swatch inline. Sits just above the
    // toolbar, clamped the same way the toolbar itself is.
    Rectangle {
        id: colorPopup
        visible: root.colorPickerOpen && toolbar.visible
        width: swatchFlow.implicitWidth + 16
        height: swatchFlow.implicitHeight + 12
        x: Math.max(0, Math.min(toolbar.x, root.width - width))
        y: Math.max(0, toolbar.y - height - 8)
        radius: 8
        color: Theme.bgAlpha
        border.width: 1
        border.color: Theme.border
        z: 20

        Flow {
            id: swatchFlow
            x: 8
            y: 6
            spacing: 8

            Repeater {
                model: ShottyState.palette
                Item {
                    id: swatchWrap
                    required property string modelData
                    width: 30; height: 30
                    Rectangle {
                        anchors.centerIn: parent
                        width: 26; height: 26; radius: 13
                        color: swatchWrap.modelData
                        border.width: ShottyState.currentColor === swatchWrap.modelData ? 2 : 0
                        border.color: Theme.text
                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                ShottyState.pickColor(swatchWrap.modelData);
                                root.colorPickerOpen = false;
                            }
                        }
                    }
                }
            }
        }
    }

    // Line-thickness flyout -- opened by the toolbar's width-indicator
    // button. Same collapse-to-flyout pattern and positioning as the color
    // popup, just wider (a slider needs more room than swatches).
    Rectangle {
        id: widthPopup
        visible: root.widthPickerOpen && toolbar.visible
        width: 150
        height: 36
        x: Math.max(0, Math.min(toolbar.x, root.width - width))
        y: Math.max(0, toolbar.y - height - 8)
        radius: 8
        color: Theme.bgAlpha
        border.width: 1
        border.color: Theme.border
        z: 20

        Rectangle {
            id: widthTrack
            anchors.verticalCenter: parent.verticalCenter
            x: 12
            width: parent.width - 24
            height: 3
            radius: 1.5
            color: Theme.border
        }
        Rectangle {
            id: widthHandle
            readonly property real minW: 1
            readonly property real maxW: 12
            readonly property real frac: (ShottyState.currentWidth - minW) / (maxW - minW)
            x: widthTrack.x + frac * (widthTrack.width - width)
            anchors.verticalCenter: widthTrack.verticalCenter
            width: 14; height: 14; radius: 7
            color: Theme.cyan
        }
        MouseArea {
            anchors.fill: parent
            onPressed: mouse => {
                const f = Math.max(0, Math.min(1, (mouse.x - widthTrack.x) / widthTrack.width));
                ShottyState.currentWidth = Math.round(widthHandle.minW + f * (widthHandle.maxW - widthHandle.minW));
            }
            onPositionChanged: mouse => {
                if (!pressed) return;
                const f = Math.max(0, Math.min(1, (mouse.x - widthTrack.x) / widthTrack.width));
                ShottyState.currentWidth = Math.round(widthHandle.minW + f * (widthHandle.maxW - widthHandle.minW));
            }
        }
    }


    Item {
        id: escCatcher
        anchors.fill: parent
        focus: root.open

        // Ctrl+wheel adjusts stroke width directly (works globally for
        // whichever tool is selected, not tied to any button) -- must be a
        // child of a real Item, not the bare PanelWindow: pointer handlers
        // attach to their parent Item's geometry for hit-testing, and a
        // Window isn't one, which is why an earlier attempt (as a direct
        // PanelWindow child) silently never received events.
        WheelHandler {
            acceptedModifiers: Qt.ControlModifier
            enabled: ShottyState.phase !== "idle" && ShottyState.phase !== "compositing"
            onWheel: event => {
                console.log(`shotty: ctrl-wheel angleDelta.y=${event.angleDelta.y}`);
                const delta = event.angleDelta.y > 0 ? 1 : -1;
                ShottyState.currentWidth = Math.max(1, Math.min(12, ShottyState.currentWidth + delta));
            }
        }
        // TEMPORARY diagnostic: any wheel at all reaching this Item,
        // regardless of modifier -- narrows down whether Ctrl+wheel's
        // silence is a routing problem (this never logs either) or a
        // modifier-matching problem (this logs, the one above doesn't).
        WheelHandler {
            acceptedModifiers: Qt.NoModifier | Qt.ControlModifier | Qt.ShiftModifier | Qt.AltModifier | Qt.MetaModifier
            enabled: ShottyState.phase !== "idle" && ShottyState.phase !== "compositing"
            onWheel: event => {
                console.log(`shotty: ANY wheel reached escCatcher, modifiers=${event.modifiers}, angleDelta.y=${event.angleDelta.y}`);
            }
        }

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape) {
                ShottyState.escapeAction(); // exits tool-modal back to "toolbar", or closes if no tool is active
            } else if (event.key === Qt.Key_A && (event.modifiers & Qt.ControlModifier)) {
                ShottyState.selectAllToggle();
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                if (ShottyState.phase === "toolbar" || ShottyState.phase === "drawing") ShottyState.commit();
            } else if (event.key === Qt.Key_Z && (event.modifiers & Qt.ControlModifier)) {
                if (ShottyState.phase === "toolbar") ShottyState.undo();
            } else if (event.key === Qt.Key_Y && (event.modifiers & Qt.ControlModifier)) {
                if (ShottyState.phase === "toolbar") ShottyState.redo();
            } else if (event.key === Qt.Key_C && (event.modifiers & Qt.ControlModifier)) {
                if (ShottyState.phase === "toolbar" || ShottyState.phase === "drawing") ShottyState.commit();
            } else if (event.key === Qt.Key_S && (event.modifiers & Qt.ControlModifier)) {
                if (ShottyState.phase === "toolbar" || ShottyState.phase === "drawing") ShottyState.requestSaveDialog();
            } else if (ShottyState.phase === "toolbar" || ShottyState.phase === "drawing") {
                // Tool shortcuts (Flameshot convention): a=arrow, r=rectangle,
                // l=line. Digits 1-N pick a palette color (satty convention) --
                // there's no clickable swatch anymore, so this is the only way.
                if (event.key === Qt.Key_A) ShottyState.pickTool("arrow");
                else if (event.key === Qt.Key_R) ShottyState.pickTool("rect");
                else if (event.key === Qt.Key_L) ShottyState.pickTool("line");
                else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
                    const idx = event.key - Qt.Key_1;
                    if (idx < ShottyState.palette.length) ShottyState.pickColor(ShottyState.palette[idx]);
                }
            }
        }
    }
}
