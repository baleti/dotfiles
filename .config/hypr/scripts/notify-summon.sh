#!/bin/sh
# Summon the window that sent a notification.
#
# Called by the quickshell notification card (NotifSvc.summonSource) on a
# left-click when the notification has no default action to invoke -- the
# "or at least focus the window that spawned it" fallback. Brings the app's
# window(s) to the current workspace and focuses it, pulling them out of a
# per-app scratch workspace (special:scratch_<slug>, see apps.lua) if that's
# where they're hiding -- so e.g. clicking a Signal message notification
# makes Signal appear on the monitor you're looking at.
#
#   notify-summon.sh <app_name> [dbus-sender]
#
# Matching (any hit counts, most-recently-focused window wins):
#   * <app_name> lowercased against apps.lua's slug / class
#   * <app_name> as a loose substring match either way against window class
#   * the pid behind <dbus-sender> (resolved via busctl) -- catches apps
#     that send notifications directly (not through xdg-desktop-portal,
#     whose pid would just be the portal and match no window).
#
# Dispatch goes through `hyprctl eval` because this Hyprland is the
# Lua-config build -- plain `hyprctl dispatch` doesn't work here (see the
# hyprland-lua-binding-dispatch-syntax note).

app=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
# escape for a Lua "..." literal
esc=$(printf '%s' "$app" | sed 's/\\/\\\\/g; s/"/\\"/g')

sender="${2:-}"
pid=0
if [ -n "$sender" ]; then
    pid=$(busctl --user call org.freedesktop.DBus /org/freedesktop/DBus \
              org.freedesktop.DBus GetConnectionUnixProcessID s "$sender" \
              2>/dev/null | awk '{ print $2 }')
    case "$pid" in
        ''|*[!0-9]*) pid=0 ;;
    esac
fi

exec hyprctl eval "(function()
  local target = \"$esc\"
  local pid = $pid
  local okapps, apps = pcall(require, 'apps')
  local want
  if okapps then
    for _, a in ipairs(apps) do
      if a.slug == target or string.lower(a.class) == target then want = a.class end
    end
  end

  local matches = {}
  for _, w in ipairs(hl.get_windows({})) do
    local cls = string.lower(w.class or '')
    local hit = false
    if pid > 0 and w.pid == pid then hit = true end
    if want and w.class == want then hit = true end
    if not want and target ~= '' and cls ~= ''
       and (string.find(cls, target, 1, true) or string.find(target, cls, 1, true)) then
      hit = true
    end
    if hit then matches[#matches + 1] = w end
  end
  if #matches == 0 then return 'none' end

  local primary = matches[1]
  for _, w in ipairs(matches) do
    if (w.focus_history_id or 1e9) < (primary.focus_history_id or 1e9) then primary = w end
  end

  if primary.workspace and primary.workspace.special then
    local cur = hl.get_active_workspace()
    for _, w in ipairs(matches) do
      if w.workspace and w.workspace.special then
        hl.dispatch(hl.dsp.window.move({ workspace = cur, window = w, follow = false }))
      end
    end
  end
  hl.dispatch(hl.dsp.focus({ window = primary }))
  return 'ok'
end)()"
