#!/bin/sh
# (Re)start the background watcher on the PC with the newest exe, and make it start at every logon (HKCU Run, no admin).
# Also (re)writes the "watch" folders in the PC's config.json from the catalog's extra_roots that live on the PC.
set -e
cd "$(dirname "$0")/.."
. tools/pc.sh
CFG=$PCHOME/AppData/Roaming/SearchApp/config.json
ssh wsl "cat $CFG" | python3 tools/pc-watch-config.py | ssh wsl "cat > $CFG.new && mv $CFG.new $CFG"
ssh wsl "cd $PCDIR && ./SearchApp.exe --watch-stop; sleep 2; ./SearchApp.exe --install-watcher"
ssh wsl "cd $PCDIR && (setsid nohup ./SearchApp.exe --watch >/dev/null 2>&1 < /dev/null &) ; sleep 3; tail -5 $PCHOME/AppData/Local/SearchApp/watcher.log"
