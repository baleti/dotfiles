import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import "../services"

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
                ShottyState.shapes.length, JSON.stringify(ShottyState.shapes), ShottyState.currentColor
            ]
            onPaintSnapshotChanged: requestPaint()
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()

            function drawShape(ctx, tool, color, x1, y1, x2, y2) {
                ctx.strokeStyle = color;
                ctx.lineWidth = 3;
                ctx.lineCap = "round";
                if (tool === "rect") {
                    ctx.strokeRect(Math.min(x1, x2), Math.min(y1, y2), Math.abs(x2 - x1), Math.abs(y2 - y1));
                } else if (tool === "line") {
                    ctx.beginPath();
                    ctx.moveTo(x1, y1);
                    ctx.lineTo(x2, y2);
                    ctx.stroke();
                } else { // arrow
                    ctx.beginPath();
                    ctx.moveTo(x1, y1);
                    ctx.lineTo(x2, y2);
                    ctx.stroke();
                    const angle = Math.atan2(y2 - y1, x2 - x1);
                    const headLen = 14;
                    ctx.beginPath();
                    ctx.moveTo(x2, y2);
                    ctx.lineTo(x2 - headLen * Math.cos(angle - Math.PI / 6), y2 - headLen * Math.sin(angle - Math.PI / 6));
                    ctx.moveTo(x2, y2);
                    ctx.lineTo(x2 - headLen * Math.cos(angle + Math.PI / 6), y2 - headLen * Math.sin(angle + Math.PI / 6));
                    ctx.stroke();
                }
            }

            onPaint: {
                const ctx = getContext("2d");
                ctx.reset();
                if (ShottyState.phase === "idle") return;

                ctx.fillStyle = "rgba(0, 0, 0, 0.45)";
                ctx.fillRect(0, 0, width, height);

                if (ShottyState.selWidth > 0 || ShottyState.selHeight > 0) {
                    const lx = root.toLocalX(ShottyState.selLeft);
                    const ly = root.toLocalY(ShottyState.selTop);
                    ctx.clearRect(lx, ly, ShottyState.selWidth, ShottyState.selHeight);
                    ctx.strokeStyle = "#8be9fd";
                    ctx.lineWidth = 1;
                    ctx.strokeRect(lx + 0.5, ly + 0.5, ShottyState.selWidth - 1, ShottyState.selHeight - 1);
                }

                for (const shape of ShottyState.shapes) {
                    drawShape(ctx,
                        shape.tool, shape.color,
                        root.toLocalX(shape.x1), root.toLocalY(shape.y1),
                        root.toLocalX(shape.x2), root.toLocalY(shape.y2));
                }

                if (ShottyState.phase === "drawing") {
                    drawShape(ctx,
                        ShottyState.currentTool, ShottyState.currentColor,
                        root.toLocalX(ShottyState.drawX1), root.toLocalY(ShottyState.drawY1),
                        root.toLocalX(ShottyState.drawX2), root.toLocalY(ShottyState.drawY2));
                }
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        enabled: ShottyState.phase === "selecting" || ShottyState.phase === "drawing"
        onPressed: mouse => {
            const gx = root.screen.x + mouse.x, gy = root.screen.y + mouse.y;
            if (ShottyState.phase === "selecting") ShottyState.beginSelect(gx, gy);
            else if (ShottyState.phase === "drawing") ShottyState.beginDraw(gx, gy);
        }
        onPositionChanged: mouse => {
            const gx = root.screen.x + mouse.x, gy = root.screen.y + mouse.y;
            if (ShottyState.phase === "selecting") ShottyState.updateSelect(gx, gy);
            else if (ShottyState.phase === "drawing") ShottyState.updateDraw(gx, gy);
        }
        onReleased: mouse => {
            if (ShottyState.phase === "selecting") ShottyState.endSelect();
            else if (ShottyState.phase === "drawing") ShottyState.endDraw();
        }
    }

    // Toolbar: shown once a selection exists, only in the panel that
    // contains the selection's bottom-right corner (an arbitrary but always
    // well-defined anchor point).
    readonly property bool _isToolbarAnchor: {
        const s = root.screen;
        const px = ShottyState.selLeft + ShottyState.selWidth;
        const py = ShottyState.selTop + ShottyState.selHeight;
        return s && px >= s.x && px <= s.x + s.width && py >= s.y && py <= s.y + s.height;
    }

    Row {
        id: toolbar
        visible: root._isToolbarAnchor && (ShottyState.phase === "toolbar" || ShottyState.phase === "drawing")
        x: Math.min(root.toLocalX(ShottyState.selLeft + ShottyState.selWidth), root.width - width)
        y: Math.min(root.toLocalY(ShottyState.selTop + ShottyState.selHeight) + 8, root.height - height)
        spacing: 6
        z: 10

        Rectangle {
            width: toolbarRow.implicitWidth + 16
            height: toolbarRow.implicitHeight + 12
            radius: 8
            color: "#282a36"
            border.color: "#44475a"

            Row {
                id: toolbarRow
                x: 8
                y: 6
                spacing: 6

                Repeater {
                    model: ["arrow", "line", "rect"]
                    Rectangle {
                        required property string modelData
                        width: 32
                        height: 28
                        radius: 4
                        color: ShottyState.currentTool === modelData ? "#6272a4" : "#44475a"
                        Text { anchors.centerIn: parent; text: modelData[0].toUpperCase(); color: "white" }
                        MouseArea { anchors.fill: parent; onClicked: ShottyState.pickTool(parent.modelData) }
                    }
                }

                Rectangle { width: 1; height: 24; color: "#44475a" }

                Repeater {
                    model: ShottyState.palette
                    Rectangle {
                        required property string modelData
                        width: 22
                        height: 22
                        radius: 11
                        color: modelData
                        border.width: ShottyState.currentColor === modelData ? 2 : 0
                        border.color: "white"
                        anchors.verticalCenter: parent.verticalCenter
                        MouseArea { anchors.fill: parent; onClicked: ShottyState.pickColor(parent.modelData) }
                    }
                }

                Rectangle { width: 1; height: 24; color: "#44475a" }

                Rectangle {
                    width: 32; height: 28; radius: 4; color: "#50fa7b"
                    Text { anchors.centerIn: parent; text: "✓"; color: "#282a36" }
                    MouseArea { anchors.fill: parent; onClicked: ShottyState.commit() }
                }
                Rectangle {
                    width: 32; height: 28; radius: 4; color: "#ff5555"
                    Text { anchors.centerIn: parent; text: "✕"; color: "#282a36" }
                    MouseArea { anchors.fill: parent; onClicked: ShottyState.close() }
                }
            }
        }
    }

    Item {
        id: escCatcher
        anchors.fill: parent
        focus: root.open
        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape) {
                ShottyState.close();
            } else if (event.key === Qt.Key_A && (event.modifiers & Qt.ControlModifier)) {
                ShottyState.selectAllToggle();
            } else if (ShottyState.phase === "toolbar" || ShottyState.phase === "drawing") {
                // Tool shortcuts (Flameshot convention): a=arrow, r=rectangle,
                // l=line.
                if (event.key === Qt.Key_A) ShottyState.pickTool("arrow");
                else if (event.key === Qt.Key_R) ShottyState.pickTool("rect");
                else if (event.key === Qt.Key_L) ShottyState.pickTool("line");
            }
        }
    }
}
