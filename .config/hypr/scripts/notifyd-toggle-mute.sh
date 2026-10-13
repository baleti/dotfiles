#!/bin/sh
# Toggle notifyd mute (history still recorded, popups suppressed). The
# feedback card uses app "notifyd-mute", which always bypasses mute.
state=$(~/.config/hypr/notifyd/target/release/notifyctl toggle-mute) || exit 1
notify-send -a notifyd-mute -t 1500 "Notifications $state"
