#!/usr/bin/env python3
"""
pixel6-mpris-bridge - registers org.mpris.MediaPlayer2.pixel6 on host3's
session bus and proxies MPRIS calls to the phone's PeerAgent Companion app,
via peer-agent's media-* actions over WireGuard.

This is what makes playerctl (and the existing mod+ctrl+x/z keybinds, and the
ALT+CTRL+SHIFT+m zenity player picker, which already read/write
~/.config/playerctl-current) able to control playback on the phone: it just
needed a real MPRIS name on the bus to select. See
~/.config/peer-agent/peer-agent.md on the phone for the other half.

No new dependency: dbus-python + PyGObject/GLib are both already installed.
"""
import json
import time
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

PEER_AGENT_BASE = "http://10.10.0.5:8787/run"
POLL_INTERVAL_S = 4
HTTP_TIMEOUT_S = 3


def call_action(name):
    """POST to a peer-agent action, return its parsed JSON body or None."""
    req = urllib.request.Request(
        f"{PEER_AGENT_BASE}/{name}",
        method="POST",
        headers={"X-Peer-Agent": "1"},
    )
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_S) as resp:
            return json.loads(resp.read())
    except (URLError, TimeoutError, OSError, ValueError):
        return None


def fetch_status():
    """media-status wraps the sidecar app's /status JSON in payload["stdout"]."""
    payload = call_action("media-status")
    if not payload or payload.get("status") != "ok":
        return None
    try:
        return json.loads(payload["stdout"])
    except (KeyError, ValueError):
        return None


class Pixel6Player(dbus.service.Object):
    def __init__(self, bus):
        super().__init__(bus, OBJECT_PATH)
        self._status = None  # last-fetched status dict, or None if unreachable

    # ------------------------------------------------------------------
    # org.freedesktop.DBus.Properties
    # ------------------------------------------------------------------

    @dbus.service.method(dbus.PROPERTIES_IFACE, in_signature="ss", out_signature="v")
    def Get(self, interface, prop):
        return self.GetAll(interface)[prop]

    @dbus.service.method(dbus.PROPERTIES_IFACE, in_signature="ssv")
    def Set(self, interface, prop, value):
        # Only Volume is technically settable per the spec, and we don't
        # proxy volume - nothing here actually needs to accept a Set.
        pass

    @dbus.service.method(dbus.PROPERTIES_IFACE, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface):
        if interface == ROOT_IFACE:
            return {
                "CanQuit": False,
                "CanRaise": False,
                "HasTrackList": False,
                "Identity": "pixel6",
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

        return {
            "PlaybackStatus": playback_status,
            "Metadata": dbus.Dictionary(metadata, signature="sv"),
            "Volume": 1.0,
            "Position": dbus.Int64(max(0, int(s.get("position", 0))) * 1000 if active else 0),
            "CanGoNext": reachable,
            "CanGoPrevious": reachable,
            "CanPlay": reachable,
            "CanPause": reachable,
            "CanSeek": False,
            "CanControl": reachable,
        }

    @dbus.service.method(PLAYER_IFACE)
    def Next(self):
        call_action("media-next")
        self.refresh(force=True)

    @dbus.service.method(PLAYER_IFACE)
    def Previous(self):
        call_action("media-prev")
        self.refresh(force=True)

    @dbus.service.method(PLAYER_IFACE)
    def Pause(self):
        call_action("media-pause")
        self.refresh(force=True)

    @dbus.service.method(PLAYER_IFACE)
    def Play(self):
        call_action("media-play")
        self.refresh(force=True)

    @dbus.service.method(PLAYER_IFACE)
    def PlayPause(self):
        if self._status and self._status.get("state") == "playing":
            self.Pause()
        else:
            self.Play()

    @dbus.service.method(PLAYER_IFACE)
    def Stop(self):
        call_action("media-pause")
        self.refresh(force=True)

    @dbus.service.method(PLAYER_IFACE, in_signature="x")
    def Seek(self, offset):
        pass

    @dbus.service.method(PLAYER_IFACE, in_signature="ox")
    def SetPosition(self, track_id, position):
        pass

    @dbus.service.method(PLAYER_IFACE, in_signature="s")
    def OpenUri(self, uri):
        pass

    # ------------------------------------------------------------------
    # polling
    # ------------------------------------------------------------------

    def refresh(self, force=False):
        new_status = fetch_status()
        if new_status == self._status and not force:
            return
        self._status = new_status
        self.PropertiesChanged(PLAYER_IFACE, self._player_props(), [])
        return True

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
