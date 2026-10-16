import QtQuick
import "../theme"
import "../services"

// Pan/zoom/click viewer for the PipeWire graph laid out by pw-graph.py.
//   wheel: zoom at cursor   drag: pan   click: select node   double-click: fit
Item {
    id: gv

    property int selectedId: -1
    signal nodeClicked(int id)

    property real zoom: 1
    property bool fitted: false
    readonly property real minZoom: 0.2
    readonly property real maxZoom: 3

    implicitHeight: 300
    height: implicitHeight
    clip: true

    function kindColor(kind) {
        switch (kind) {
        case "source": return Theme.green;
        case "sink": return Theme.cyan;
        case "playback": return Theme.orange;
        case "capture": return "#c792ea";
        default: return Theme.muted;
        }
    }
    function stateColor(state) {
        switch (state) {
        case "running": return Theme.green;
        case "idle": return Theme.orange;
        case "error": return Theme.red;
        default: return Theme.muted;
        }
    }

    function fit() {
        const gw = AudioSvc.graph.width || 0;
        const gh = AudioSvc.graph.height || 0;
        if (gw <= 0 || gh <= 0 || width <= 0)
            return;
        const z = Math.max(minZoom, Math.min(maxZoom, 1.2, width / gw, height / gh));
        gv.zoom = z;
        world.x = (width - gw * z) / 2;
        world.y = (height - gh * z) / 2;
        gv.fitted = true;
    }

    function zoomAt(mx, my, factor) {
        const z = Math.max(minZoom, Math.min(maxZoom, gv.zoom * factor));
        const k = z / gv.zoom;
        world.x = mx - (mx - world.x) * k;
        world.y = my - (my - world.y) * k;
        gv.zoom = z;
    }

    // First data after the panel opens: frame the whole graph once; after
    // that the user's own pan/zoom is left alone across refreshes.
    Connections {
        target: AudioSvc
        function onGraphChanged() { if (!gv.fitted) gv.fit(); }
    }
    onWidthChanged: if (!fitted) fit()

    Rectangle {
        anchors.fill: parent
        radius: Theme.rounding - 3
        color: Qt.rgba(0, 0, 0, 0.28)
        border.color: Theme.border
        border.width: 1
    }

    // Links are painted in viewport coordinates (crisp at any zoom).
    Canvas {
        id: linkCanvas
        anchors.fill: parent
        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            const z = gv.zoom, ox = world.x, oy = world.y;
            for (const id of AudioSvc.linkIds) {
                const l = AudioSvc.graphLinks[id];
                if (!l) continue;
                const touches = gv.selectedId >= 0 && (l.from === gv.selectedId || l.to === gv.selectedId);
                const x1 = ox + l.x1 * z, y1 = oy + l.y1 * z, x2 = ox + l.x2 * z, y2 = oy + l.y2 * z;
                const dx = Math.max(30 * z, Math.abs(x2 - x1) * 0.5);
                ctx.beginPath();
                ctx.moveTo(x1, y1);
                ctx.bezierCurveTo(x1 + dx, y1, x2 - dx, y2, x2, y2);
                const base = l.state === "active" ? Theme.cyan : (l.state === "error" ? Theme.red : Theme.muted);
                ctx.strokeStyle = Qt.rgba(base.r, base.g, base.b, touches ? 1 : 0.65);
                ctx.lineWidth = (touches ? 2.6 : 1.6) * Math.max(0.7, Math.min(1.5, z));
                ctx.stroke();
            }
        }
        Connections {
            target: AudioSvc
            function onGraphLinksChanged() { linkCanvas.requestPaint(); }
        }
        Connections {
            target: gv
            function onZoomChanged() { linkCanvas.requestPaint(); }
            function onSelectedIdChanged() { linkCanvas.requestPaint(); }
        }
        Connections {
            target: world
            function onXChanged() { linkCanvas.requestPaint(); }
            function onYChanged() { linkCanvas.requestPaint(); }
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
    }

    Item {
        id: world
        transformOrigin: Item.TopLeft
        scale: gv.zoom

        Repeater {
            model: AudioSvc.nodeIds

            delegate: Rectangle {
                id: nd
                required property int modelData
                readonly property var n: AudioSvc.graphNodes[modelData] || ({ ports: [], x: 0, y: 0, w: 0, h: 0, headH: 26 })
                readonly property bool selected: gv.selectedId === modelData
                readonly property color kc: gv.kindColor(n.kind)

                x: n.x
                y: n.y
                width: n.w
                height: n.h
                radius: 6
                color: Qt.rgba(0.11, 0.11, 0.12, 0.96)
                border.color: selected ? Theme.text : Qt.rgba(nd.kc.r, nd.kc.g, nd.kc.b, 0.7)
                border.width: selected ? 2 : 1
                opacity: n.state === "suspended" ? 0.6 : 1

                Rectangle {
                    width: parent.width
                    height: n.headH
                    radius: 6
                    color: Qt.rgba(nd.kc.r, nd.kc.g, nd.kc.b, 0.22)
                    Rectangle {  // squares off the bottom corners
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: 6
                        color: parent.color
                    }
                    Rectangle {  // state dot
                        x: 7
                        anchors.verticalCenter: parent.verticalCenter
                        width: 8
                        height: 8
                        radius: 4
                        color: gv.stateColor(n.state)
                    }
                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 22
                        anchors.right: parent.right
                        anchors.rightMargin: 6
                        anchors.verticalCenter: parent.verticalCenter
                        text: n.title || ""
                        elide: Text.ElideRight
                        color: Theme.text
                        font.family: Theme.fontFamily
                        font.pixelSize: 11
                        font.bold: true
                    }
                }

                Repeater {
                    model: n.ports
                    delegate: Item {
                        required property var modelData
                        readonly property bool isIn: modelData.dir === "in"
                        x: modelData.x
                        y: modelData.y
                        Rectangle {
                            x: -4
                            y: -4
                            width: 8
                            height: 8
                            radius: 4
                            color: nd.kc
                            border.color: Qt.rgba(0, 0, 0, 0.6)
                            border.width: 1
                        }
                        Text {
                            x: isIn ? 8 : -width - 8
                            y: -height / 2
                            text: modelData.label
                            color: Theme.textDim
                            font.family: Theme.fontFamily
                            font.pixelSize: 9
                        }
                    }
                }
            }
        }
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: false
        acceptedButtons: Qt.LeftButton
        property real lastX: 0
        property real lastY: 0
        property real pressX: 0
        property real pressY: 0
        property bool dragged: false

        onPressed: mouse => {
            lastX = pressX = mouse.x;
            lastY = pressY = mouse.y;
            dragged = false;
        }
        onPositionChanged: mouse => {
            if (!pressed)
                return;
            if (!dragged && Math.abs(mouse.x - pressX) + Math.abs(mouse.y - pressY) > 4)
                dragged = true;
            if (dragged) {
                world.x += mouse.x - lastX;
                world.y += mouse.y - lastY;
            }
            lastX = mouse.x;
            lastY = mouse.y;
        }
        onReleased: mouse => {
            if (dragged)
                return;
            const wx = (mouse.x - world.x) / gv.zoom;
            const wy = (mouse.y - world.y) / gv.zoom;
            let hit = -1;
            for (const id of AudioSvc.nodeIds) {
                const n = AudioSvc.graphNodes[id];
                if (n && wx >= n.x && wx <= n.x + n.w && wy >= n.y && wy <= n.y + n.h) {
                    hit = id;
                    break;
                }
            }
            gv.nodeClicked(hit);
        }
        onDoubleClicked: gv.fit()
        onWheel: wheel => {
            gv.zoomAt(wheel.x, wheel.y, wheel.angleDelta.y > 0 ? 1.15 : 1 / 1.15);
            wheel.accepted = true;
        }
    }

    // Small zoom controls, top-right.
    Row {
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: 6
        spacing: 4
        Repeater {
            model: [
                { t: "+", f: 1.25 },
                { t: "−", f: 0.8 },
                { t: "fit", f: 0 }
            ]
            delegate: Rectangle {
                required property var modelData
                width: modelData.t === "fit" ? 30 : 22
                height: 20
                radius: 4
                color: bma.containsMouse ? Qt.rgba(1, 1, 1, 0.16) : Qt.rgba(1, 1, 1, 0.08)
                border.color: Theme.border
                border.width: 1
                Text {
                    anchors.centerIn: parent
                    text: modelData.t
                    color: Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: 11
                }
                MouseArea {
                    id: bma
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: modelData.f === 0 ? gv.fit() : gv.zoomAt(gv.width / 2, gv.height / 2, modelData.f)
                }
            }
        }
    }

    Text {
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.margins: 6
        text: qsTr("scroll zoom · drag pan · click node")
        color: Theme.muted
        font.family: Theme.fontFamily
        font.pixelSize: 9
    }
}
