#!/usr/bin/env python3
# mod+a "global menu" prototype: flattens the focused window's AT-SPI
# accessible menu tree into a wofi picker, then activates whatever is chosen.
#
# Why AT-SPI and not com.canonical.AppMenu.Registrar/dbusmenu: that scheme is
# keyed on X11 window IDs, and every client on this Hyprland session runs as
# native Wayland (xwayland=false), so it never gets a windowId to register
# with. AT-SPI works over its own a11y DBus bus regardless of X11/Wayland.

import json
import subprocess
import sys
import time

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi

MENU_CONTAINER_ROLES = {"menu", "menu bar", "popup menu"}
MENU_LEAF_ROLES = {"menu item", "check menu item", "radio menu item"}
MAX_DEPTH = 12
# Gecko (Firefox/LibreWolf) builds each submenu's accessible children lazily,
# only once that submenu is actually opened -- unlike LibreOffice/GTK, which
# expose the full tree upfront regardless of visibility. So an empty "menu"
# container gets force-opened via its own click action, then polled (rather
# than given one fixed sleep) until children appear, since most opens
# populate near-instantly and a flat sleep per node adds up fast across a
# whole menu tree. Whatever got opened this way is left on screen until a
# single trailing Escape closes it, right before the picker shows (see
# main()).
POPULATE_POLL_INTERVAL_SECS = 0.005
POPULATE_POLL_TIMEOUT_SECS = 0.15


def notify(msg):
    subprocess.run(["notify-send", "-a", "appmenu", "Global menu", msg], check=False)


def focused_pid():
    out = subprocess.run(
        ["hyprctl", "activewindow", "-j"], capture_output=True, text=True, check=True
    ).stdout
    data = json.loads(out)
    return data.get("pid"), data.get("title", "")


def find_app(pid):
    desktop = Atspi.get_desktop(0)
    for i in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(i)
        try:
            if app.get_process_id() == pid:
                return app
        except Exception:
            continue
    return None


def find_active_frame(app):
    # Prefer the frame AT-SPI marks active (apps can have >1 top-level
    # window, e.g. multiple LibreOffice documents); fall back to the first.
    frames = []
    for i in range(app.get_child_count()):
        child = app.get_child_at_index(i)
        if child.get_role_name() == "frame":
            frames.append(child)
    for frame in frames:
        try:
            if frame.get_state_set().contains(Atspi.StateType.ACTIVE):
                return frame
        except Exception:
            continue
    return frames[0] if frames else None


def find_menubar(obj, depth=0):
    if depth > MAX_DEPTH:
        return None
    if obj.get_role_name() == "menu bar":
        return obj
    for i in range(obj.get_child_count()):
        try:
            child = obj.get_child_at_index(i)
        except Exception:
            continue
        found = find_menubar(child, depth + 1)
        if found is not None:
            return found
    return None


def click_action_index(obj):
    n = Atspi.Action.get_n_actions(obj)
    for i in range(n):
        if Atspi.Action.get_action_name(obj, i) == "click":
            return i
    return 0 if n > 0 else None


def collect_leaves(obj, breadcrumb, out, state, depth=0):
    if depth > MAX_DEPTH:
        return
    try:
        role = obj.get_role_name()
    except Exception:
        return
    if role not in MENU_LEAF_ROLES and role not in MENU_CONTAINER_ROLES:
        return

    try:
        nc = obj.get_child_count()
    except Exception:
        nc = 0

    # Gecko-style lazy submenu: force it open and wait for real children.
    if role == "menu" and nc == 0:
        idx = click_action_index(obj)
        if idx is not None:
            Atspi.Action.do_action(obj, idx)
            state["opened_any"] = True
            deadline = time.monotonic() + POPULATE_POLL_TIMEOUT_SECS
            while obj.get_child_count() == 0 and time.monotonic() < deadline:
                time.sleep(POPULATE_POLL_INTERVAL_SECS)
            # Child count can flip to nonzero a beat before the child
            # proxies themselves are actually resolvable -- one more short
            # interval avoids racing that.
            time.sleep(POPULATE_POLL_INTERVAL_SECS)
            nc = obj.get_child_count()

    if nc == 0:
        if role in MENU_LEAF_ROLES:
            try:
                if not obj.get_state_set().contains(Atspi.StateType.ENABLED):
                    return
            except Exception:
                pass
            idx = click_action_index(obj)
            if idx is None:
                return
            name = obj.get_name() or "(unnamed)"
            out.append((" › ".join(breadcrumb + [name]), obj, idx))
        return

    # nc > 0: a container to recurse into. This covers classic "menu"/"menu
    # bar" roles, Qt's anonymous "popup menu" wrapper, AND the Qt quirk where
    # a submenu *header* (e.g. the top-level "File") is itself labeled
    # "menu item" despite having a real submenu underneath -- Dolphin/Okular/
    # VLC/Wireshark/Scribus/LibreCAD/DB Browser for SQLite all do this. Any
    # menu-ish node with children is a container; only childless ones are
    # truly actionable. "menu bar" and "popup menu" are anonymous levels
    # (Gecko's "Application" menu-bar name is also skipped -- it would
    # otherwise prefix every single item with a meaningless "Application ›").
    name = obj.get_name() if role in MENU_LEAF_ROLES or role == "menu" else None
    next_breadcrumb = breadcrumb + [name] if name else breadcrumb
    for i in range(nc):
        try:
            child = obj.get_child_at_index(i)
        except Exception:
            continue
        if child is None:
            continue
        collect_leaves(child, next_breadcrumb, out, state, depth + 1)


def main():
    pid, title = focused_pid()
    if pid is None:
        notify("No focused window.")
        return

    app = find_app(pid)
    if app is None:
        notify(f"'{title}' has no accessible menu (not AT-SPI registered).")
        return

    frame = find_active_frame(app)
    if frame is None:
        notify(f"'{title}': no window frame found via AT-SPI.")
        return

    menubar = find_menubar(frame)
    if menubar is None:
        notify(f"'{title}': no menu bar exposed via AT-SPI.")
        return

    items = []
    state = {"opened_any": False}
    collect_leaves(menubar, [], items, state)
    if state["opened_any"]:
        # Close whatever lazy-populated submenu we forced open above (GTK/Gecko
        # menu bars show one open menu at a time, so this closes the last one
        # regardless of how many we stepped through).
        subprocess.run(["wtype", "-k", "Escape"], check=False)
    if not items:
        notify(f"'{title}': menu bar has no actionable items.")
        return

    labels = "\n".join(label for label, _, _ in items)
    result = subprocess.run(
        ["rofi", "-dmenu", "-i", "-p", "menu"],
        input=labels,
        capture_output=True,
        text=True,
    )
    choice = result.stdout.strip()
    if not choice:
        return

    for label, obj, idx in items:
        if label == choice:
            Atspi.Action.do_action(obj, idx)
            return

    notify(f"Could not map selection back to a menu item: {choice!r}")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        notify(f"appmenu-atspi error: {e}")
        raise
