#!/bin/sh
# Desktop dictation: host3's own mic -> ai1's GPU whisper-medium (the same
# server + model dictate-android now defaults to on the phone). Toggle:
# SUPER+CTRL+t starts recording, SUPER+CTRL+t again stops it, transcribes,
# copies the result to the clipboard, and types it into whatever window
# currently has real focus. Asked for explicitly 2026-09-20, right after
# confirming the phone flow works reliably ("insert into the current chat
# window... works... let's add transcription also to the host3 desktop").
#
# Host/port hardcoded to host3's own local proxy (10.10.0.2:8792, see
# newsdigest-android/server/server.py's /stt/transcribe) rather than any
# app's own settings -- this is a separate client with nothing to read;
# that address is already confirmed reachable directly from host3 itself.
#
# Types the text directly (wtype "$text"), NOT wl-copy + wtype ctrl+v --
# confirmed live 2026-09-20 that the paste version actually triggered
# "CTRL + escape" (this config's own htop keybind, keybinds.lua:171)
# instead of pasting. Root cause: wtype has no way to send arbitrary
# Unicode through Wayland's virtual-keyboard protocol directly, so even
# a single named key (-k v) works by dynamically remapping a spare
# keycode to that keysym and pressing THAT physical keycode -- while
# holding ctrl as a real modifier, that physical keycode collided with
# whatever keycode Escape normally occupies, and Hyprland matches binds
# by keycode, not by the keysym wtype was actually trying to send. Typing
# plain text holds no modifier down at all, so there's no keybind for a
# remapped keycode to alias -- same mechanism, but only a problem when
# combined with a modifier. ydotool (real evdev keycodes via /dev/uinput,
# no remap trick, no risk of this class of bug at all) was tried first,
# but this system's uinput kernel module isn't loaded and modprobing it
# needs sudo -- switched to plain typing instead of chasing that.
# ydotool.service is disabled again (was enabled+started, then reverted).

STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/dictate"
PIDFILE="$STATE_DIR/record.pid"
RAWFILE="$STATE_DIR/record.raw"
HOST="10.10.0.2"
PORT="8792"
MODEL="whisper-medium-gpu"

mkdir -p "$STATE_DIR"

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    # ---- stop + transcribe ----
    pid=$(cat "$PIDFILE")
    rm -f "$PIDFILE"
    kill -INT "$pid" 2>/dev/null
    # parecord needs a moment to flush the file after SIGINT -- wait for
    # the process to actually exit rather than a fixed sleep.
    i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 50 ]; do
        sleep 0.1
        i=$((i + 1))
    done

    notify-send -t 4000 "Dictate" "Transcribing…"

    resp=$(curl -s -m 30 -X POST \
        -H "X-Peer-Agent: 1" -H "Content-Type: application/octet-stream" \
        --data-binary @"$RAWFILE" \
        "http://$HOST:$PORT/stt/transcribe?model=$MODEL")
    rm -f "$RAWFILE"

    text=$(printf '%s' "$resp" | jq -r '.text // empty' 2>/dev/null)

    if [ -z "$text" ]; then
        notify-send -u critical "Dictate" "Transcription failed or heard nothing: $resp"
        exit 0
    fi

    printf '%s' "$text" | wl-copy
    wtype -- "$text"

    preview=$(printf '%s' "$text" | cut -c1-80)
    notify-send -t 4000 "Dictate" "Inserted: $preview"
else
    # ---- start recording ----
    # --latency-msec=50: parecord's default buffering only flushes to disk
    # in full ~2s (64000-byte) fragments and silently drops any trailing
    # partial fragment when killed -- confirmed live 2026-09-20 that a
    # normal short (1-2s) dictation landed as a genuine 0-byte file this
    # way. Forcing a much smaller fragment size bounds that dropped tail
    # to under ~100ms instead.
    parecord --raw --rate=16000 --channels=1 --format=s16le --latency-msec=50 \
        --device=@DEFAULT_SOURCE@ "$RAWFILE" &
    echo $! > "$PIDFILE"
    notify-send -t 3000 "Dictate" "Recording… SUPER+CTRL+t to stop"
fi
