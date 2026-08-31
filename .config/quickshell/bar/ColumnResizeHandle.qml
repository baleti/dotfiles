import QtQuick

// Drag-to-resize handle for one column boundary in ClaudeUsageExpanded's
// process table. Sits in the RowLayout gap between two header cells (the
// same handleW-wide gap every other row -- group-header and data rows --
// fills with a plain non-interactive Item, so columns stay aligned
// regardless of which row it is). Owns no state of its own: the caller
// passes the current width in `targetWidth` and reads the drag result
// back out of the `widthChangeRequested` signal, rather than this
// component writing directly to a bound property (QML property bindings
// and direct writes to the same property fight each other -- this way
// the caller's own `property real colXxxW: ...` stays a single normal
// property, no binding-vs-imperative-write conflict).
MouseArea {
    id: handle

    property real targetWidth: 0
    property real minWidth: 24
    signal widthChangeRequested(real newWidth)

    hoverEnabled: true
    cursorShape: Qt.SizeHorCursor

    property real pressX: 0
    property real startWidth: 0

    onPressed: mouse => {
        pressX = mouse.x;
        startWidth = handle.targetWidth;
    }
    onPositionChanged: mouse => {
        if (pressed)
            handle.widthChangeRequested(Math.max(handle.minWidth, handle.startWidth + (mouse.x - handle.pressX)));
    }
}
