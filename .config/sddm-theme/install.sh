#!/usr/bin/env bash
# One-time root setup for the custom SDDM login theme. The theme dir is made
# user-owned so gen-theme.py (theme_sddm) can rewrite theme.conf + wallpaper.png
# on every wallpaper change without sudo. Re-run after editing Main.qml.
set -euo pipefail
[ "$(id -u)" -ne 0 ] || { echo "run without sudo (it calls sudo itself)" >&2; exit 1; }
here="$(cd "$(dirname "$0")" && pwd)"
dest=/usr/share/sddm/themes/material-you
sudo install -d -o "$USER" -g "$(id -gn)" -m 755 "$dest"
install -m 644 "$here/material-you/Main.qml" "$here/material-you/metadata.desktop" "$dest/"
sudo install -d -m 755 /etc/sddm.conf.d
printf '[Theme]\nCurrent=material-you\n' | sudo tee /etc/sddm.conf.d/20-theme.conf >/dev/null
python3 "$here/../hypr/scripts/gen-theme.py" --image "$HOME/.local/state/quickshell/wallpaper.png" >/dev/null
echo "installed $dest; active at next login screen"
