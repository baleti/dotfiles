#!/bin/sh
# usage: tools/shot.sh name [shot args...]  -> ~/src/search-win/shots/name.png (rendered offscreen on the PC)
n="$1"; shift
D=/mnt/c/Users/USER/SearchApp/out
ssh wsl "rm -f $D/$n.png $D/$n.txt; cd /mnt/c/Users/USER/SearchApp && timeout 90 ./SearchApp.exe --shot 'C:\\Users\\USER\\SearchApp\\out\\$n.png' --out 'C:\\Users\\USER\\SearchApp\\out\\$n.txt' $*; cat $D/$n.txt" && scp -q wsl:$D/$n.png "$(dirname "$0")/../shots/$n.png"
