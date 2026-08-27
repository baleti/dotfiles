import QtQuick
import Quickshell
import "bar"

ShellRoot {
    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: panel

            required property var modelData
            screen: modelData

            anchors {
                top: true
                left: true
                right: true
            }

            // Fixed at the largest any hover panel can plausibly get, and
            // never resized reactively -- resizing the actual layer-shell
            // surface (previously bound to bar.totalHeight) caused a visible
            // flicker on every collapse. The mask below is what actually
            // keeps clicks passing through to windows underneath the empty
            // area when nothing's expanded; it's cheap to update since it
            // only changes the input region, not the rendered surface size.
            implicitHeight: 800
            exclusiveZone: 38
            color: "transparent"

            mask: Region {
                x: 0
                y: 0
                width: panel.width
                height: bar.totalHeight
            }

            Bar {
                id: bar
                screen: panel.screen
            }
        }
    }
}
