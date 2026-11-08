# Sourced by the other scripts. Finds the Windows profile on the PC (seen from WSL) without any user name in the repo.
# Cached in ~/.config/search-win/pc.env (local file, not part of the repo); delete it to detect again,
# or write PC_USER=<windows user name> there yourself.
ENVF="$HOME/.config/search-win/pc.env"
[ -f "$ENVF" ] && . "$ENVF"
if [ -z "$PC_USER" ]; then
  # several profiles may exist: take the one whose NTUSER.DAT changed most recently (the user who is logged in)
  CANDS=$(ssh wsl 'ls -t /mnt/c/Users/*/NTUSER.DAT 2>/dev/null' | awk -F/ '{print $5}' | grep -viE '^(default|default user|public|all users|defaultuser0)$')
  PC_USER=""
  for u in $CANDS; do [ -z "$PC_USER" ] && PC_USER=$u; ssh wsl "test -d /mnt/c/Users/$u/SearchApp" && { PC_USER=$u; break; }; done
  [ -n "$PC_USER" ] || { echo "cannot tell the Windows user, set PC_USER in $ENVF" >&2; exit 1; }
  echo "using Windows user '$PC_USER' (saved in $ENVF, edit it if wrong)" >&2
  mkdir -p "$(dirname "$ENVF")"; echo "PC_USER=$PC_USER" > "$ENVF"
fi
PCHOME=/mnt/c/Users/$PC_USER          # WSL view
PCWIN="C:\\Users\\$PC_USER"           # Windows view
PCDIR=$PCHOME/SearchApp
