#!/bin/sh
# usage: tools/pcrun.sh <outfile-name> args...   runs SearchApp.exe on the PC (no window), writes the --out file, prints it
# (WinExe has no console: the app writes the result file given as --out)
. "$(dirname "$0")/pc.sh"
n="$1"; shift
args=""; for a in "$@"; do args="$args '$a'"; done
ssh wsl "rm -f $PCDIR/out/$n; cd $PCDIR && timeout 120 ./SearchApp.exe $args --out '${PCWIN}\\SearchApp\\out\\$n'; cat $PCDIR/out/$n"
