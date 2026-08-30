import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import "bar"
import "background"
import "osd"
import "notifications"
import "services"

ShellRoot {
    Background {}

    // Single, top-level target -- the picker itself is instantiated once per
    // monitor inside each Bar PanelWindow (below), so a per-screen
    // IpcHandler would collide the same way bar-toggle.sh has to route
    // around. Latches the currently-focused monitor so the picker opens
    // there and stays put (follow_mouse=1). `toggle` (not `show`): a bare
    // `show` function name collides with `qs ipc show` -- see VolumeOsd.
    IpcHandler {
        target: "mprisPicker"
        function toggle(): void {
            MprisPickerState.toggle(Hyprland.focusedMonitor?.name ?? "");
        }
    }

    Variants {
        model: Quickshell.screens

        VolumeOsd {
            required property var modelData
            screen: modelData
        }
    }

    Variants {
        model: Quickshell.screens

        NotifLayer {
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

            // Full monitor height, fixed -- a panel can only render within
            // the layer-shell surface, and the calendar's agenda list is
            // allowed to grow to fill the screen. Not reactively resized
            // (binding it to bar.totalHeight caused a visible flicker on
            // every collapse); the surface just stays screen-sized and
            // transparent, and the mask below limits input to the bar +
            // whatever's currently expanded so clicks pass through the
            // empty area. Bar.qml reads screen.height for its own
            // maxPanelHeight the same way.
            implicitHeight: panel.screen.height
            exclusiveZone: 38
            color: "transparent"

            // While the MPRIS picker is up it's a full-screen modal (dim
            // backdrop + centered card), so the whole surface has to accept
            // input; otherwise input is limited to the bar strip + whatever
            // panel is expanded, and everything else clicks through.
            mask: Region {
                x: 0
                y: 0
                width: panel.width
                height: mprisPicker.showing ? panel.height : Math.min(bar.totalHeight, panel.height)
            }

            // mod+CTRL+m (media), mod+CTRL+c (calendar), and mod+n/p/m/t/d
            // (the graph pills) all open their panel with real keyboard
            // control (arrow keys/space/tab/enter/1-6 -- see Bar.qml's Keys
            // handling and each GraphPill's own Keys.onPressed). OnDemand,
            // not Exclusive: the compositor hands this surface focus while
            // it's the newest focusable thing shown, without permanently
            // grabbing all keyboard input the way a picker's Exclusive mode
            // does (that risk is why pickers are never self-launched for
            // testing).
            //
            // holdsFocus is deliberately its own state, NOT just "something
            // is expanded" -- panels are meant to stay open after you click
            // into another window (reported 2026-08-30), but Hyprland's
            // LayerSurface.cpp only ever hands keyboard focus back to
            // whatever you clicked on a commit where this surface's
            // interactivity actually *drops to None*. Leaving
            // WlrLayershell.keyboardFocus pinned at OnDemand for as long as
            // a panel is visually open -- as an earlier version of this did
            // -- means that handoff commit never happens: the click reaches
            // the other window for pointer purposes, but keyboard input
            // stays stuck here (reported 2026-08-30, right after the "don't
            // close on click-away" fix landed). holdsFocus drops to None on
            // its own grab clearing (see onCleared below) regardless of
            // whether any panel is still expanded, so that handoff commit
            // actually happens; reopening or opening another panel (see
            // Bar.qml's openPanelCount below) reclaims it.
            property bool holdsFocus: false

            WlrLayershell.keyboardFocus: panel.holdsFocus ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

            // HyprlandFocusGrab drives Hyprland's separate
            // hyprland-focus-grab-v1 protocol to request the keyboard
            // handoff directly -- no pointer hover needed, unlike plain
            // OnDemand on an already-mapped surface (verified against
            // LayerSurface.cpp: that only auto-grabs at initial map or on
            // an EXCLUSIVE transition, never a live None->OnDemand commit).
            // Same mechanism caelestia/DankMaterialShell/omarchy use for
            // their own popups. onCleared fires when Hyprland ends the grab
            // (e.g. a click outside `windows`) and just drops holdsFocus --
            // panels stay exactly as open/closed as they already were, only
            // keyboard delivery moves on.
            HyprlandFocusGrab {
                id: focusGrab
                windows: [panel]
                onCleared: panel.holdsFocus = false
            }

            // Releasing the grab in the very same tick keyboardFocus drops
            // to None raced Hyprland trying to hand focus back to the
            // surface it had just made non-interactive (DankMaterialShell's
            // DankFocusGrab.qml carries an identical delay for the same
            // upstream ordering issue). Grabbing can happen immediately;
            // releasing waits one tick past the keyboardFocus commit.
            Timer {
                id: releaseGrabTimer
                interval: 0
                onTriggered: focusGrab.active = false
            }

            onHoldsFocusChanged: {
                if (holdsFocus) {
                    releaseGrabTimer.stop();
                    focusGrab.active = true;
                } else {
                    releaseGrabTimer.restart();
                }
            }

            // Reclaims holdsFocus whenever a panel *newly opens* -- reacting
            // to openPanelCount rising, not just "is anything open" (that
            // boolean can already be true from an earlier panel that stayed
            // open after losing holdsFocus to a click-away, in which case
            // opening a second panel would otherwise never re-trigger
            // anything). Dropping to 0 releases; a plain decrease that
            // still leaves something open does nothing -- closing one panel
            // shouldn't yank focus back from wherever the user clicked.
            property int prevOpenPanelCount: 0

            Connections {
                target: bar
                function onOpenPanelCountChanged() {
                    if (bar.openPanelCount > panel.prevOpenPanelCount)
                        panel.holdsFocus = true;
                    else if (bar.openPanelCount === 0)
                        panel.holdsFocus = false;
                    panel.prevOpenPanelCount = bar.openPanelCount;
                }
            }

            Bar {
                id: bar
                screen: panel.screen
            }

            // Modal MPRIS player picker (ALT+CTRL+SHIFT+m). Overlays the bar
            // on the one monitor MprisPickerState latched. Takes real
            // keyboard control on open the same way the media/calendar
            // panels do -- holdsFocus true drives shell.qml's
            // HyprlandFocusGrab -- and hands it back on close (to a
            // still-open bar panel if there is one, else nothing).
            MprisPicker {
                id: mprisPicker
                anchors.fill: parent
                screenName: panel.screen.name
                onShowingChanged: {
                    if (showing) {
                        panel.holdsFocus = true;
                        forceActiveFocus();
                    } else {
                        panel.holdsFocus = bar.openPanelCount > 0;
                        bar.refocusActivePanel();
                    }
                }
            }
        }
    }
}
