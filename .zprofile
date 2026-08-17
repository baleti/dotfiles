#!/usr/bin/env zsh

# https://github.com/maximbaz/dotfiles/blob/master/.zprofile
# if [[ -z $DISPLAY && "$TTY" == "/dev/tty3" ]]; then
if [[ "$TTY" == "/dev/tty3" ]]; then
    # export $(systemctl --user show-environment)
	# systemd-cat -t hyprland Hyprland
    pgrep Hyprland || Hyprland
    # systemctl --user stop graphical-session.target
    # systemctl --user unset-environment DISPLAY WAYLAND_DISPLAY
fi

# [[ "$TTY" == /dev/tty3 ]] && exec Hyprland
# [[ $(tty) = /dev/tty4 ]] && exec startx /home/user1/.config/X11/xinitrc

# Created by `pipx` on 2025-07-26 21:40:55
export PATH="$PATH:/home/user1/.local/bin"
