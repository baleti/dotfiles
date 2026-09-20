#!/bin/sh
cd "$(dirname "$0")" && gcc -O2 -shared -fPIC -o mlockself.so mlockself.c
