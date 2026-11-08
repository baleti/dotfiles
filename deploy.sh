#!/bin/sh
# Build and copy SearchApp.exe to the PC (via the WSL box). Seeds %APPDATA%\SearchApp\config.json only if it does not exist yet.
set -e
cd "$(dirname "$0")"
dotnet build -c Release -o out 2>&1 | grep -E " error|Elapsed" | sort -u
ssh wsl 'mkdir -p /mnt/c/Users/USER/SearchApp/out'
# A running exe cannot be overwritten but it can be renamed: move it aside, then put the new one in place.
# The running copy keeps working; the next start uses the new file (the app also offers Ctrl+Shift+R to restart into it).
D=/mnt/c/Users/USER/SearchApp
scp -q out/SearchApp.exe wsl:$D/SearchApp.new.exe
ssh wsl "cd $D && rm -f SearchApp-update.exe; [ -f SearchApp.exe ] && mv SearchApp.exe SearchApp.old-\$(date +%s).exe; mv SearchApp.new.exe SearchApp.exe; rm -f SearchApp.old-*.exe 2>/dev/null; ls"
CFG=/mnt/c/Users/USER/AppData/Roaming/SearchApp/config.json
if ! ssh wsl "test -f $CFG"; then
  T=$(mktemp)
  printf '%s\n' '{"server":"http://127.0.0.1:8795","pathMap":[["/mnt/share/m/","M:\\"],["/mnt/share/q/","Q:\\"],["/mnt/share/c/","C:\\"]],"thumb":16}' > "$T"
  ssh wsl 'mkdir -p /mnt/c/Users/USER/AppData/Roaming/SearchApp'
  scp -q "$T" wsl:$CFG; rm -f "$T"; echo "seeded config"
fi
echo deployed
