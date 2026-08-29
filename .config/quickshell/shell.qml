import QtQuick
import Quickshell
import Quickshell.Wayland
import "bar"
import "background"
import "osd"

ShellRoot {
    Background {}

    Variants {
        model: Quickshell.screens

        VolumeOsd {
            required property var modelData
            screen: modelData
        }
    }

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

            // mod+m opens the media panel with real keyboard control (arrow
            // keys seek, space toggles play/pause -- see Bar.qml's Keys
            // handling). OnDemand, not Exclusive: the compositor hands this
            // surface focus while it's the newest focusable thing shown,
            // without permanently grabbing all keyboard input the way a
            // picker's Exclusive mode does (that risk is why pickers are
            // never self-launched for testing -- this reverts to None the
            // instant the panel closes, so there's no lingering grab).
            WlrLayershell.keyboardFocus: bar.mediaPanel.expanded ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

            Bar {
                id: bar
                screen: panel.screen
            }
        }
    }
}
