#!/usr/bin/env bash
# Daily regression/health check for wa (systemd: wa-health.timer). Silent when
# healthy or not yet paired; emails and notifies when something is wrong.
set -uo pipefail
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:$PATH"
MAIL="$HOME/.config/claude-email/mail"
TO=baleti3266@gmail.com
problems=()

out=$(wa selftest 2>&1) || problems+=("selftest failed: $out")

if [ -s "$HOME/.local/share/wa/session.db" ] && [ -n "$(sqlite3 "$HOME/.local/share/wa/session.db" 'select jid from whatsmeow_device limit 1' 2>/dev/null)" ]; then
  st=$(wa status --json 2>/dev/null | tr -d ' \n')
  systemctl --user is-active --quiet wa || problems+=("wa.service is not running")
  case "$st" in *'"daemon":true'*) ;; *) problems+=("daemon not answering on its socket") ;; esac
  case "$st" in
    *'"link":"connected"'*) ;;
    *'"link":"logged_out"'*) problems+=("LOGGED OUT: the phone unlinked this device; re-pair with 'wa pair'") ;;
    *'"link":"client_outdated"'*) problems+=("WhatsApp rejected the client version; run ~/bin/wa/update.sh or check whatsmeow upstream") ;;
    *) problems+=("link state is not 'connected': $st") ;;
  esac
  case "$st" in *'"temp_ban":""'*) ;; *) problems+=("TEMPORARY BAN recorded: $st") ;; esac
fi

if [ ${#problems[@]} -gt 0 ]; then
  body=$(printf '%s\n' "${problems[@]}")
  echo "$body" >&2
  "$MAIL" send --to "$TO" --subject "wa health check: problems ($(date +%F))" --body "$body" >/dev/null 2>&1 || true
  notify-send -a wa -u critical "wa health check failed" "$body" >/dev/null 2>&1 || true
  exit 1
fi
echo "wa healthy"
