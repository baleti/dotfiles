#!/usr/bin/env bash
# Weekly updater for wa's whatsmeow dependency (systemd: wa-update.timer).
#
# It never chases "latest". It adopts exactly the commit that the AUR security
# checker's review marked CLEAN (~/.local/share/aur-security-check/whatsmeow/
# reviewed-ok, which is itself age-gated). Then: rebuild, vet, test, selftest,
# swap the binary, restart the daemon and wait for it to reconnect. Any failure
# rolls back go.mod/go.sum and the previous binary, and emails.
set -uo pipefail
cd "$(dirname "$0")"
WM="$HOME/.local/share/aur-security-check/whatsmeow"
BIN="$HOME/.local/bin/wa"
MAIL="$HOME/.config/claude-email/mail"
TO=baleti3266@gmail.com
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:$PATH"

alert() { # subject, body
  echo "ALERT: $1 - $2" >&2
  "$MAIL" send --to "$TO" --subject "$1" --body "$2" >/dev/null 2>&1 || true
  notify-send -a wa -u critical "$1" "$2" >/dev/null 2>&1 || true
}

pinned() { go list -m -f '{{.Version}}' go.mau.fi/whatsmeow | sed 's/.*-//' | cut -c1-12; }

linked() { [ -s "$HOME/.local/share/wa/session.db" ] && "$BIN" status --json 2>/dev/null | grep -q '"link": "' ; }

wait_healthy() { # up to 120 s for the daemon to be connected again
  for _ in $(seq 1 24); do
    sleep 5
    if "$BIN" status --json 2>/dev/null | tr -d ' \n' | grep -q '"daemon":true' \
       && "$BIN" status --json 2>/dev/null | tr -d ' \n' | grep -q '"link":"connected"'; then
      return 0
    fi
  done
  return 1
}

reviewed=$(cat "$WM/reviewed-ok" 2>/dev/null || true)
if [ -z "$reviewed" ]; then
  echo "no reviewed-ok marker yet (the security check has not cleared a new commit); nothing to do"
  exit 0
fi
cur=$(pinned)
if [ "$reviewed" = "$cur" ]; then
  echo "whatsmeow already at reviewed commit $cur"
  exit 0
fi
if ! git -C "$WM/whatsmeow.git" merge-base --is-ancestor "$cur" "$reviewed" 2>/dev/null; then
  echo "reviewed commit $reviewed is not ahead of pinned $cur; leaving as is"
  exit 0
fi

echo "updating whatsmeow $cur -> $reviewed"
cp go.mod /tmp/wa-go.mod.bak && cp go.sum /tmp/wa-go.sum.bak
rollback_mod() { cp /tmp/wa-go.mod.bak go.mod; cp /tmp/wa-go.sum.bak go.sum; }

if ! GOFLAGS=-mod=mod go get "go.mau.fi/whatsmeow@$reviewed" 2>&1 | tail -3; then :; fi
go mod tidy >/dev/null 2>&1
if [ "$(pinned)" != "$reviewed" ]; then
  rollback_mod; alert "wa update failed" "go get did not land on reviewed commit $reviewed (got $(pinned))"; exit 1
fi
if ! out=$( { go vet ./... && go test ./... && go build -trimpath -o "$BIN.new" . ; } 2>&1 ); then
  rollback_mod; alert "wa update failed to build/test" "whatsmeow $reviewed: $(echo "$out" | tail -25)"; exit 1
fi
if ! out=$("$BIN.new" selftest 2>&1); then
  rollback_mod; rm -f "$BIN.new"; alert "wa selftest failed after update" "whatsmeow $reviewed: $out"; exit 1
fi

cp -f "$BIN" "$BIN.prev" 2>/dev/null || true
mv -f "$BIN.new" "$BIN"
if systemctl --user is-active --quiet wa; then
  systemctl --user restart wa
  if ! wait_healthy; then
    rollback_mod; mv -f "$BIN.prev" "$BIN"; systemctl --user restart wa
    alert "wa update rolled back" "whatsmeow $reviewed built and tested fine but the daemon did not reconnect within 2 minutes (possible protocol change). Rolled back to $cur."
    exit 1
  fi
fi

[ -n "${WA_UPDATE_NOGIT:-}" ] || { cd "$HOME" && git add bin/wa/go.mod bin/wa/go.sum \
  && git commit -q -m "wa: bump whatsmeow $cur -> $reviewed (security-reviewed commit)" \
  && git push -q 2>/dev/null || true; }
echo "updated and healthy on whatsmeow $reviewed"
