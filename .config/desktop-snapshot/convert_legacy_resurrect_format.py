#!/usr/bin/env python3
"""Convert a tmux-resurrect layout file from one pane-line field order to
another between two DIFFERENT checkouts this system had at the time
(pane_title in one, window_name in the other - see field layouts below).

CORRECTION 2026-09-06 (after this script had already done its one-time
job): the "vanilla upstream restore.sh" this docstring originally meant
was actually ~/.tmux/plugins/tmux-resurrect/ - a stale, unreferenced 2021
checkout, since deleted. The checkout .tmux.conf actually loads
(~/.config/tmux/plugins/tmux-resurrect/) uses the OTHER format (pane_title,
not window_name) for both its save.sh and restore.sh - they were never
mismatched with each other, only restore_desktop_session.py's hardcoded
reference to the wrong checkout was. So "old/legacy" vs "vanilla/current"
above described which checkout THIS SCRIPT was targeting at the time, not
which one was actually live. Left as historical record; this script
already converted the one old backup file it was written for and isn't
part of the ongoing pipeline - the live save.sh/restore.sh pair has agreed
with each other the whole time.

Old pane line (11 tab fields):
  pane, session, window, window_active, window_flags, pane_index,
  pane_title, dir, pane_active, pane_command, pane_full_command
Vanilla pane line (11 tab fields):
  pane, session, window, window_name(":"-prefixed), window_active,
  window_flags, pane_index, dir, pane_active, pane_command, pane_full_command

Old window line (8 tab fields):
  window, session, window_index, window_name(":"-prefixed), window_active,
  window_flags(":"-prefixed), window_layout, extra_flag
Vanilla window line (6 tab fields):
  window, session, window_index, window_active, window_flags(":"-prefixed),
  window_layout

Usage:
  convert_legacy_resurrect_format.py INPUT.txt OUTPUT.txt
"""
import sys

def convert_pane(fields):
    if len(fields) != 11:
        return None
    _, session, window, window_active, window_flags, pane_index, pane_title, dir_, pane_active, pane_command, pane_full_command = fields
    window_name = ":" + pane_title if not pane_title.startswith(":") else pane_title
    return ["pane", session, window, window_name, window_active, window_flags,
            pane_index, dir_, pane_active, pane_command, pane_full_command]


def convert_window(fields):
    if len(fields) != 8:
        return None
    _, session, window_index, _window_name, window_active, window_flags, window_layout, _extra = fields
    return ["window", session, window_index, window_active, window_flags, window_layout]


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    src, dst = sys.argv[1], sys.argv[2]
    out_lines = []
    converted_panes = converted_windows = passthrough = 0
    with open(src) as f:
        for line in f:
            line = line.rstrip("\n")
            fields = line.split("\t")
            if fields[0] == "pane":
                converted = convert_pane(fields)
                if converted:
                    out_lines.append("\t".join(converted))
                    converted_panes += 1
                    continue
            elif fields[0] == "window":
                converted = convert_window(fields)
                if converted:
                    out_lines.append("\t".join(converted))
                    converted_windows += 1
                    continue
            out_lines.append(line)
            passthrough += 1

    with open(dst, "w") as f:
        f.write("\n".join(out_lines) + "\n")

    print(f"converted {converted_panes} pane line(s), {converted_windows} window line(s), "
          f"{passthrough} line(s) passed through unchanged -> {dst}")


if __name__ == "__main__":
    main()
