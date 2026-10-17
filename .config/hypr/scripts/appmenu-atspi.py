#!/usr/bin/env python3
# mod+a "global menu": flattens the focused window's AT-SPI accessible menu tree (or the menu the app serves on its own
# socket, see provider_request) into rows for the Quickshell picker (~/.config/quickshell/appmenu/, same query DSL as
# mod+v, ~/.config/docs/query-dsl.md), and activates whatever is chosen there.
#
#   appmenu-atspi.py pick              (mod+a) collect the focused window's menu, stash it, open/close the picker
#   appmenu-atspi.py rows [pid]        NDJSON rows on stdout (debugging)
#   appmenu-atspi.py activate PID ID   activate one item (the picker runs this after Enter)
#
# Why AT-SPI and not com.canonical.AppMenu.Registrar/dbusmenu: that scheme is
# keyed on X11 window IDs, and every client on this Hyprland session runs as
# native Wayland (xwayland=false), so it never gets a windowId to register
# with. AT-SPI works over its own a11y DBus bus regardless of X11/Wayland.

import json
import os
import socket
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
            out.append((breadcrumb + [name], obj, idx))
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


def provider_request(pid, req, timeout=1.5):
    """Apps that cannot expose an AT-SPI menu bar (AccessKit's Linux backend waits for the bus property
    ScreenReaderEnabled, which at-spi2-core 2.62 no longer has, so egui apps never register) can serve their menu on a
    unix socket named after their process id: $XDG_RUNTIME_DIR/appmenu/<pid>.sock, one JSON line per request:
    {"cmd":"menu"} -> {"title","items":[{"id","label","checked"}]} and {"cmd":"activate","id":..} -> {"ok":true}."""
    path = os.path.join(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"), "appmenu", f"{pid}.sock")
    if not os.path.exists(path):
        return None
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(path)
        s.sendall((json.dumps(req) + "\n").encode())
        line = s.makefile().readline()
        return json.loads(line) if line else None
    except (OSError, ValueError):
        return None
    finally:
        s.close()


def key_hint(obj, idx):
    """'F;<Control>o;<Control>o' (mnemonic;accelerator;shortcut) -> 'Ctrl+o'."""
    try:
        raw = Atspi.Action.get_key_binding(obj, idx) or ""
    except Exception:
        return ""
    parts = [p for p in raw.split(";") if p]
    if not parts:
        return ""
    hint = parts[-1] if len(parts) > 1 else ""
    for src, dst in (("<Control>", "Ctrl+"), ("<Primary>", "Ctrl+"), ("<Shift>", "Shift+"), ("<Alt>", "Alt+"), ("<Super>", "Super+")):
        hint = hint.replace(src, dst)
    return hint


def unique_ids(entries):
    """Label paths can repeat (two separators, two 'Recent' entries); the n-th repeat gets '#n', in tree order, so a
    later re-collect maps the id back to the same item."""
    seen = {}
    for e in entries:
        n = seen.get(e["path"], 0) + 1
        seen[e["path"]] = n
        e["id"] = e["path"] if n == 1 else f'{e["path"]}#{n}'


def collect_atspi(pid, title):
    """-> (entries, atspi_objs, note). entries are plain dicts; atspi_objs maps id -> (obj, action index)."""
    app = find_app(pid)
    if app is None:
        return [], {}, f"'{title}' has no accessible menu (not AT-SPI registered, and no menu socket)."
    frame = find_active_frame(app)
    if frame is None:
        return [], {}, f"'{title}': no window frame found via AT-SPI."
    menubar = find_menubar(frame)
    if menubar is None:
        return [], {}, f"'{title}': no menu bar exposed via AT-SPI."
    leaves = []
    state = {"opened_any": False}
    collect_leaves(menubar, [], leaves, state)
    if state["opened_any"]:
        # Close whatever lazy-populated submenu we forced open above (GTK/Gecko menu bars show one open menu at a time,
        # so this closes the last one regardless of how many we stepped through). Runs before the picker opens, while
        # the app still has the keyboard.
        subprocess.run(["wtype", "-k", "Escape"], check=False)
    if not leaves:
        return [], {}, f"'{title}': menu bar has no actionable items."
    try:
        app_name = app.get_name() or title
    except Exception:
        app_name = title
    entries, objs = [], []
    for parts, obj, idx in leaves:
        checked = ""
        try:
            ss = obj.get_state_set()
            if ss.contains(Atspi.StateType.CHECKED):
                checked = "checked"
            elif obj.get_role_name() in ("check menu item", "radio menu item"):
                checked = "unchecked"
        except Exception:
            pass
        entries.append({"parts": parts, "path": " › ".join(parts), "app": app_name, "shortcut": key_hint(obj, idx),
                        "state": checked, "src": "atspi"})
        objs.append((obj, idx))
    unique_ids(entries)
    return entries, {e["id"]: o for e, o in zip(entries, objs)}, ""


def collect_provider(pid):
    menu = provider_request(pid, {"cmd": "menu"})
    if not menu or not menu.get("items"):
        return None
    title = menu.get("title") or "Menu"
    entries = []
    for item in menu["items"]:
        c = item.get("checked")
        entries.append({"parts": [title, item["label"]], "path": f"{title} › {item['label']}", "app": title, "shortcut": "",
                        "state": "checked" if c else ("unchecked" if c is False else ""), "src": "provider",
                        "provider_id": item["id"]})
    unique_ids(entries)
    return entries


def collect(pid, title):
    """-> (entries, atspi_objs, note); the app's own menu socket wins over AT-SPI."""
    prov = collect_provider(pid)
    if prov is not None:
        return prov, {}, ""
    return collect_atspi(pid, title)


def row_of(e):
    parts = e["parts"]
    menu = " › ".join(parts[:-1])
    hay = " ".join([e["path"], e["app"], e["shortcut"], e["state"]]).lower()
    return {"id": e["id"], "preview": e["path"], "haystack": hay, "src": e["src"],
            "fields": {"item": parts[-1], "menu": menu, "path": e["path"], "app": e["app"],
                       "shortcut": e["shortcut"], "state": e["state"]}}


def stash_dir():
    d = os.path.join(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"), "appmenu-picker")
    os.makedirs(d, exist_ok=True)
    return d


def qs_call(*args):
    return subprocess.run(["qs", "ipc", "call", "appMenu", *args], capture_output=True, text=True, check=False)


def cmd_pick():
    if qs_call("isOpen").stdout.strip() == "true":
        qs_call("close")
        return
    pid, title = focused_pid()
    if pid is None:
        notify("No focused window.")
        return
    entries, _, note = collect(pid, title)
    if not entries:
        notify(note or f"'{title}': no menu.")
        return
    with open(os.path.join(stash_dir(), "rows.ndjson"), "w") as f:
        f.write(json.dumps({"pid": pid, "title": title}) + "\n")
        for e in entries:
            f.write(json.dumps(row_of(e)) + "\n")
    qs_call("open")


def cmd_rows(pid):
    title = ""
    if pid is None:
        pid, title = focused_pid()
    entries, _, note = collect(pid, title)
    for e in entries:
        print(json.dumps(row_of(e)))
    if note:
        print(note, file=sys.stderr)


def cmd_activate(pid, item_id):
    entries, objs, note = collect(pid, "")
    for e in entries:
        if e["id"] != item_id:
            continue
        if e["src"] == "provider":
            provider_request(pid, {"cmd": "activate", "id": e["provider_id"]})
        else:
            obj, idx = objs[item_id]
            Atspi.Action.do_action(obj, idx)
        return
    notify(f"Could not find the menu item any more: {item_id}")


def main():
    argv = sys.argv[1:]
    mode = argv[0] if argv else "pick"
    if mode == "pick":
        cmd_pick()
    elif mode == "rows":
        cmd_rows(int(argv[1]) if len(argv) > 1 else None)
    elif mode == "activate" and len(argv) >= 3:
        cmd_activate(int(argv[1]), argv[2])
    else:
        print(__doc__ or "usage: appmenu-atspi.py pick | rows [pid] | activate PID ID", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        notify(f"appmenu-atspi error: {e}")
        raise
