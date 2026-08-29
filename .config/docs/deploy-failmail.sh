#!/usr/bin/env bash
# Invoked by systemd `OnFailure=` when dotfiles-docs-deploy.service fails
# (a real build/push error - offline runs exit 0 and never reach here).
# Emails the recent journal so a broken .md source gets noticed.
#
# Recipient: $DOCS_FAIL_EMAIL, else the repo's git author address.
# Sender:    the `baleti` account in ~/.config/claude-email/accounts/.
set -uo pipefail
cd "$(dirname "$0")"

to="${DOCS_FAIL_EMAIL:-$(git config user.email || true)}"
mail="$HOME/.config/claude-email/mail"
host="$(hostname)"

if [[ -z "$to" || ! -x "$mail" ]]; then
  echo "deploy-failmail: no recipient or mail tool - skipping" >&2
  exit 0
fi

log="$(journalctl --user -u dotfiles-docs-deploy.service -n 80 --no-pager -o cat 2>/dev/null \
       || echo '(journal unavailable)')"

body="dotfiles-docs-deploy.service failed on ${host} at $(date -u +%FT%TZ).

The published site at https://baleti.github.io/dotfiles/ was NOT updated.
Usually a malformed .md source or a build.py/pandoc error.

Last 80 log lines:
------------------------------------------------------------
${log}
------------------------------------------------------------

Retry after fixing:  systemctl --user start dotfiles-docs-deploy.service
"

exec "$mail" send --account baleti --to "$to" \
  --subject "[dotfiles-docs] deploy FAILED on ${host}" \
  --body "$body"
