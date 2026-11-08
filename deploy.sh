#!/bin/sh
# Build and copy SearchApp.exe to the PC (via the WSL box). Seeds %APPDATA%\SearchApp\config.json only if it does not exist yet.
set -e
cd "$(dirname "$0")"
dotnet build -c Release -o out 2>&1 | grep -E " error|Elapsed" | sort -u
ssh wsl 'mkdir -p /mnt/c/Users/USER/SearchApp/out'
scp -q out/SearchApp.exe wsl:/mnt/c/Users/USER/SearchApp/SearchApp.exe || { scp -q out/SearchApp.exe wsl:/mnt/c/Users/USER/SearchApp/SearchApp-update.exe; echo 'SearchApp.exe is running: copied as SearchApp-update.exe, close the app and rename it'; }
CFG=/mnt/c/Users/USER/AppData/Roaming/SearchApp/config.json
if ! ssh wsl "test -f $CFG"; then
  T=$(mktemp)
  printf '%s\n' '{"server":"http://127.0.0.1:8795","pathMap":[["/mnt/share/m/","M:\\"],["/mnt/share/q/","Q:\\"],["/mnt/share/c/","C:\\"]],"thumb":16}' > "$T"
  ssh wsl 'mkdir -p /mnt/c/Users/USER/AppData/Roaming/SearchApp'
  scp -q "$T" wsl:$CFG; rm -f "$T"; echo "seeded config"
fi
echo deployed
