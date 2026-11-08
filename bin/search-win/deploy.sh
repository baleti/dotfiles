#!/bin/sh
# Build and copy SearchApp.exe to the PC (via the WSL box) into <profile>\SearchApp.
# A running exe cannot be overwritten but it can be renamed: move it aside, then put the new one in place.
# The running copy keeps working; the next start uses the new file (the app also offers Ctrl+Shift+R to restart into it).
# Per-user settings (server address, drive map) live only on the PC in %APPDATA%\SearchApp\config.json, see README.
set -e
cd "$(dirname "$0")"
. tools/pc.sh
dotnet build -c Release -o out 2>&1 | grep -E " error|Elapsed" | sort -u
ssh wsl "mkdir -p $PCDIR/out"
scp -q out/SearchApp.exe wsl:$PCDIR/SearchApp.new.exe
ssh wsl "cd $PCDIR && rm -f SearchApp-update.exe; [ -f SearchApp.exe ] && mv SearchApp.exe SearchApp.old-\$(date +%s).exe; mv SearchApp.new.exe SearchApp.exe; rm -f SearchApp.old-*.exe 2>/dev/null; ls"
echo deployed
