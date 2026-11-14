#!/usr/bin/env python3
"""Open the xdg-desktop-portal FileChooser (the system default picker) in
save mode; print the chosen path on stdout, nothing + exit 1 if cancelled.
usage: save-picker.py <default-path>"""
import os, sys, urllib.parse
import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

default = sys.argv[1]
bus = Gio.bus_get_sync(Gio.BusType.SESSION)
token = "shotty%d" % os.getpid()
sender = bus.get_unique_name()[1:].replace(".", "_")
handle = f"/org/freedesktop/portal/desktop/request/{sender}/{token}"
loop = GLib.MainLoop()
result = []

def on_response(conn, snd, path, iface, sig, params):
    code, res = params.unpack()
    if code == 0 and res.get("uris"):
        result.append(urllib.parse.unquote(urllib.parse.urlparse(res["uris"][0]).path))
    loop.quit()

bus.signal_subscribe("org.freedesktop.portal.Desktop", "org.freedesktop.portal.Request",
                     "Response", handle, None, Gio.DBusSignalFlags.NONE, on_response)
opts = {
    "handle_token": GLib.Variant("s", token),
    "current_name": GLib.Variant("s", os.path.basename(default)),
    "current_folder": GLib.Variant("ay", os.path.dirname(default).encode() + b"\0"),
    "filters": GLib.Variant("a(sa(us))", [("PNG image", [(0, "*.png")])]),
}
bus.call_sync("org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
              "org.freedesktop.portal.FileChooser", "SaveFile",
              GLib.Variant("(ssa{sv})", ("", "Save screenshot", opts)), None,
              Gio.DBusCallFlags.NONE, -1)
loop.run()
if not result:
    sys.exit(1)
print(result[0])
