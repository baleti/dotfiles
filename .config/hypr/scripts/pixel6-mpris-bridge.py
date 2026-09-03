#!/usr/bin/env python3
"""
pixel6-mpris-bridge - registers org.mpris.MediaPlayer2.pixel6 on host3's
session bus and proxies MPRIS calls to the phone's PeerAgent Companion app
directly over WireGuard (http://10.10.0.5:8788, guarded by the X-Peer-Agent
header). peer-agent used to sit in front of this on the phone; it was retired
from the phone since it only held a perimeter the Companion app now carries
itself - see BridgeHttpServer.kt.

This is what makes playerctl (and the existing mod+ctrl+x/z keybinds, and the
ALT+CTRL+SHIFT+m zenity player picker, which already read/write
~/.config/playerctl-current) able to control playback on the phone: it just
needed a real MPRIS name on the bus to select.

No new dependency: dbus-python + PyGObject/GLib are both already installed.
"""
import json
import time
import urllib.parse
import urllib.request
from urllib.error import URLError

import dbus
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib

BUS_NAME = "org.mpris.MediaPlayer2.pixel6"
OBJECT_PATH = "/org/mpris/MediaPlayer2"
ROOT_IFACE = "org.mpris.MediaPlayer2"
PLAYER_IFACE = "org.mpris.MediaPlayer2.Player"

COMPANION_BASE = "http://10.10.0.5:8788"
POLL_INTERVAL_S = 4
HTTP_TIMEOUT_S = 3

# Android package -> friendly name, for the Identity property (shown by the
# waybar widget). BridgeForegroundService.kt already reports the source
# app's package name in media-status's "package" field; unmapped packages
# fall back to their last dot-segment.
KNOWN_APPS = {
    "InfinityLoop1309.NewPipeEnhanced": "NewPipe",
    "org.videolan.vlc": "VLC",
    "com.google.android.youtube": "YouTube",
    "com.google.android.apps.youtube.music": "YT Music",
    "com.spotify.music": "Spotify",
    "com.google.android.apps.podcasts": "Podcasts",
}


def friendly_app_name(pkg):
    if not pkg:
        return "pixel6"
    if pkg in KNOWN_APPS:
        return KNOWN_APPS[pkg]
    return pkg.rsplit(".", 1)[-1]


def _request(method, path, params=None):
    """Hit the Companion app, return the raw response body (bytes) or None."""
    url = COMPANION_BASE + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(
        url,
        method=method,
        headers={"X-Peer-Agent": "1"},
    )
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_S) as resp:
            return resp.read()
    except (URLError, TimeoutError, OSError, ValueError):
        return None


def command(name, params=None):
    """POST /command/<name> on the Companion app. Reply body is unused."""
    return _request("POST", f"/command/{name}", params)


def fetch_status():
    """GET /status on the Companion app - already the bare status JSON."""
    body = _request("GET", "/status")
    if body is None:
        return None
    try:
        return json.loads(body)
    except ValueError:
        return None


class Pixel6Player(dbus.service.Object):
    def __init__(self, bus):
        super().__init__(bus, OBJECT_PATH)
        self._status = None  # last-fetched status dict, or None if unreachable
        self._status_mono = None  # time.monotonic() at that fetch, for Position interpolation

    # ------------------------------------------------------------------
    # org.freedesktop.DBus.Properties
    # ------------------------------------------------------------------

    @dbus.service.method(dbus.PROPERTIES_IFACE, in_signature="ss", out_signature="v")
    def Get(self, interface, prop):
        return self.GetAll(interface)[prop]

    @dbus.service.method(dbus.PROPERTIES_IFACE, in_signature="ssv")
    def Set(self, interface, prop, value):
        if interface == PLAYER_IFACE and prop == "Volume":
            self._set_volume(float(value))

    @dbus.service.method(dbus.PROPERTIES_IFACE, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface):
        if interface == ROOT_IFACE:
            s = self._status
            identity = friendly_app_name(s.get("package")) if s and s.get("active") else "pixel6"
            return {
                "CanQuit": False,
                "CanRaise": False,
                "HasTrackList": False,
                "Identity": identity,
                "SupportedUriSchemes": dbus.Array([], signature="s"),
                "SupportedMimeTypes": dbus.Array([], signature="s"),
            }
        if interface == PLAYER_IFACE:
            return self._player_props()
        return {}

    @dbus.service.signal(dbus.PROPERTIES_IFACE, signature="sa{sv}as")
    def PropertiesChanged(self, interface, changed, invalidated):
        pass

    # ------------------------------------------------------------------
    # org.mpris.MediaPlayer2 (root)
    # ------------------------------------------------------------------

    @dbus.service.method(ROOT_IFACE)
    def Quit(self):
        pass

    @dbus.service.method(ROOT_IFACE)
    def Raise(self):
        pass

    # ------------------------------------------------------------------
    # org.mpris.MediaPlayer2.Player
    # ------------------------------------------------------------------

    def _player_props(self):
        s = self._status
        reachable = s is not None
        active = reachable and s.get("active")

        if not active:
            metadata = {"mpris:trackid": dbus.ObjectPath("/org/mpris/MediaPlayer2/TrackList/NoTrack")}
            playback_status = "Stopped"
        else:
            metadata = {
                "mpris:trackid": dbus.ObjectPath("/org/mpris/MediaPlayer2/pixel6/CurrentTrack"),
                "xesam:title": s.get("title") or "",
                "xesam:artist": dbus.Array([s.get("artist") or ""], signature="s"),
                "xesam:album": s.get("album") or "",
                "mpris:length": dbus.Int64(max(0, int(s.get("duration", 0))) * 1000),
            }
            playback_status = {
                "playing": "Playing",
                "paused": "Paused",
                "buffering": "Playing",
            }.get(s.get("state"), "Playing" if reachable else "Stopped")

        # Interpolate Position between polls (POLL_INTERVAL_S) instead of showing
        # the same stale number for up to 4s: local arithmetic, no extra phone
        # traffic/battery. Scaled by the on-device playback speed (statusJson's
        # "speed", e.g. NewPipe's speed control at 1.73x) - without this it
        # under-advances between polls then jumps to catch up at the next real
        # one, which is what "choppy" looked like in practice.
        rate = float(s.get("speed", 1.0)) if active else 1.0
        position_ms = max(0, int(s.get("position", 0))) if active else 0
        if active and playback_status == "Playing" and self._status_mono is not None:
            position_ms += (time.monotonic() - self._status_mono) * 1000 * rate
            length_ms = max(0, int(s.get("duration", 0)))
            if length_ms:
                position_ms = min(position_ms, length_ms)

        return {
            "PlaybackStatus": playback_status,
            "Metadata": dbus.Dictionary(metadata, signature="sv"),
            "Volume": dbus.Double(float(s.get("volume", 1.0)) if reachable else 1.0),
            "Rate": dbus.Double(rate),
            "Position": dbus.Int64(int(position_ms) * 1000),
            "CanGoNext": reachable,
            "CanGoPrevious": reachable,
            "CanPlay": reachable,
            "CanPause": reachable,
            "CanSeek": reachable,
            "CanControl": reachable,
        }

    @dbus.service.method(PLAYER_IFACE)
    def Next(self):
        command("next")
        # No refresh(force=True) here (or below): that was a second,
        # sequential WireGuard round trip after the action's own, blocking
        # this method that much longer for no real benefit - playerctl
        # doesn't wait on Next/Previous/Play/Pause/Stop's reply anyway (measured
        # live: these already return in ~50-130ms, under one single HTTP round
        # trip, so it's firing without waiting). Leave the cache as-is - the
        # next periodic poll_tick (<= POLL_INTERVAL_S) picks up the real new
        # track. Deliberately NOT clearing self._status here: that would make
        # _player_props() report "Stopped"/no-track in the meantime, a worse
        # flicker than just showing the stale track a little longer.
        pass

    @dbus.service.method(PLAYER_IFACE)
    def Previous(self):
        command("prev")

    @dbus.service.method(PLAYER_IFACE)
    def Pause(self):
        command("pause")
        self._optimistic_state("paused")

    @dbus.service.method(PLAYER_IFACE)
    def Play(self):
        command("play")
        self._optimistic_state("playing")

    @dbus.service.method(PLAYER_IFACE)
    def PlayPause(self):
        if self._status and self._status.get("state") == "playing":
            self.Pause()
        else:
            self.Play()

    @dbus.service.method(PLAYER_IFACE)
    def Stop(self):
        command("pause")
        self._optimistic_state("paused")

    def _optimistic_state(self, state):
        # Cheap, no extra network call: flip the cached playback state so a
        # rapid double-tap of play/pause (or the widget reading Position
        # right after) sees the right thing immediately, same spirit as
        # _seek_to_ms/_set_volume. poll_tick corrects it for real shortly.
        if self._status is not None:
            self._status = dict(self._status, state=state)
            self._status_mono = time.monotonic()
            self.PropertiesChanged(PLAYER_IFACE, self._player_props(), [])

    def _seek_to_ms(self, target_ms):
        props = self._player_props()
        length_us = props["Metadata"].get("mpris:length")
        length_ms = int(length_us) // 1000 if length_us else 0
        target_ms = max(0, int(target_ms))
        if length_ms:
            target_ms = min(target_ms, length_ms)
        command("seek-to", {"ms": target_ms})
        # Don't refresh(force=True) here: an immediate /status re-fetch
        # racingly reads the phone's PRE-seek position (confirmed live -
        # transportControls.seekTo() returns to the HTTP caller before the
        # underlying MediaSession's position actually catches up, worse over
        # a network-backed player like Spotify buffering to the new spot).
        # Broadcasting that stale value is what made the quickshell bar's
        # scrub-bar visibly snap back to the old position right after a
        # click. Patch the cached status optimistically instead - poll_tick
        # reconciles with the real device state on the next regular poll
        # (<= POLL_INTERVAL_S later), by which point it has settled.
        if self._status is not None:
            self._status = dict(self._status, position=target_ms)
            self._status_mono = time.monotonic()
            self.PropertiesChanged(PLAYER_IFACE, self._player_props(), [])

    def _set_volume(self, target):
        # Android's STREAM_MUSIC is stepped (getStreamMaxVolume(), commonly
        # ~15-25 steps depending on device/output), not a continuous 0.0-1.0
        # knob, so there's no meaningful "set to this exact float" action -
        # the Companion app only exposes the same up/down nudge the hardware
        # buttons send (/command/volume-up|-down, one adjustStreamVolume() step
        # each). Move one step towards whatever playerctl/the quickshell
        # widget asked for; if it wanted a bigger jump, the next scroll/press
        # will take another step from the corrected real level.
        target = max(0.0, min(1.0, target))
        current = float((self._status or {}).get("volume", 1.0))
        if target > current:
            command("volume-up")
        elif target < current:
            command("volume-down")
        else:
            return
        # Unlike _seek_to_ms, an immediate /status re-fetch here already
        # reflects the new level (confirmed live - adjustStreamVolume()
        # isn't buffered/async the way a network player's seekTo() is), but
        # patch the cache optimistically anyway rather than force-refetch:
        # one fewer HTTP round trip, and it can't reintroduce the seek-bar's
        # snap-back bug here if a slower link ever does race.
        if self._status is not None:
            self._status = dict(self._status, volume=target)
            self._status_mono = time.monotonic()
            self.PropertiesChanged(PLAYER_IFACE, self._player_props(), [])

    @dbus.service.method(PLAYER_IFACE, in_signature="x")
    def Seek(self, offset):
        # /command/seek-to (BridgeHttpServer -> BridgeForegroundService.seekTo)
        # carries an absolute ms position, validated digits-only in the app.
        # Compute the absolute target from the last-known interpolated Position
        # plus this relative offset (both microseconds) so an arbitrary-
        # magnitude Seek (e.g. the quickshell bar's scrub-bar drag) actually
        # lands where it was dropped, instead of a flat 5s nudge.
        current_us = int(self._player_props()["Position"])
        self._seek_to_ms((current_us + int(offset)) // 1000)

    @dbus.service.method(PLAYER_IFACE, in_signature="ox")
    def SetPosition(self, track_id, position):
        self._seek_to_ms(int(position) // 1000)

    @dbus.service.method(PLAYER_IFACE, in_signature="s")
    def OpenUri(self, uri):
        pass

    # ------------------------------------------------------------------
    # polling
    # ------------------------------------------------------------------

    def refresh(self, force=False):
        new_status = fetch_status()
        changed = new_status != self._status
        self._status = new_status
        self._status_mono = time.monotonic()
        if changed or force:
            self.PropertiesChanged(PLAYER_IFACE, self._player_props(), [])
        return changed

    def poll_tick(self):
        self.refresh()
        return True  # keep the GLib timeout running


def main():
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    name = dbus.service.BusName(BUS_NAME, bus)
    player = Pixel6Player(bus)
    player.refresh(force=True)
    GLib.timeout_add_seconds(POLL_INTERVAL_S, player.poll_tick)
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
