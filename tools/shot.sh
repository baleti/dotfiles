#!/bin/sh
# usage: tools/shot.sh name [shot args...]  -> shots/name.png (rendered offscreen on the PC, no window)
. "$(dirname "$0")/pc.sh"
n="$1"; shift
args=""; for a in "$@"; do args="$args '$a'"; done
D=$PCDIR/out; W="${PCWIN}\\SearchApp\\out"
ssh wsl "rm -f $D/$n.png $D/$n.txt; cd $PCDIR && timeout 90 ./SearchApp.exe --shot '$W\\$n.png' --out '$W\\$n.txt' $args; cat $D/$n.txt" && scp -q wsl:$D/$n.png "$(dirname "$0")/../shots/$n.png"
