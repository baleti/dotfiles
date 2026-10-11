#!/usr/bin/env sh
file_dir=$(dirname "$1")
alacritty --working-directory "$file_dir" & disown
