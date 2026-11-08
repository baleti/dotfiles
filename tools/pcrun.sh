#!/bin/sh
# usage: tools/pcrun.sh <outfile-name> args...   runs SearchApp.exe on the PC, writes the --out file, prints it
# (WinExe has no console: the app writes the result file given as --out)
n="$1"; shift
ssh wsl "rm -f /mnt/c/Users/USER/SearchApp/out/$n; cd /mnt/c/Users/USER/SearchApp && timeout 120 ./SearchApp.exe $* --out 'C:\\Users\\USER\\SearchApp\\out\\$n'; cat /mnt/c/Users/USER/SearchApp/out/$n"
