#!/bin/sh
# Build and copy SearchApp.exe to the PC (via the WSL box). Seeds the config only if it does not exist yet.
set -e
cd "$(dirname "$0")"
dotnet build -c Release -o out 2>&1 | grep -E "error|Warn|Elapsed" | sort -u
ssh wsl 'mkdir -p /mnt/c/Users/USER/SearchApp/out'
scp -q out/SearchApp.exe wsl:/mnt/c/Users/USER/SearchApp/SearchApp.exe
echo deployed
