# One file per patched program. Sourced by bin/patched-sync and bin/patched-update.
# checkout:  ~/src/patched/$NAME   (branch `local` = upstream tag + our patch commits)
# package:   ~/src/patched/build/$NAME/PKGBUILD  -> $PKG
NAME=zathura
PKG=zathura-local
UPSTREAM_URL=https://github.com/pwmt/zathura.git
TAG_GLOB='20*'                 # release tags to follow
BRANCH=local
# Installed packages the binary links against. If any changes version the package is
# rebuilt even when upstream did not move (soname bumps would otherwise break it).
DEPS="girara gtk4 glib2 poppler-glib json-glib sqlite libseccomp file libsynctex xxhash"
# What the agent should verify after resolving conflicts, in addition to a clean build.
PATCH_NOTES="(1) Ctrl + left button drag pans the view (config.c mouse events, shortcuts.c mouse.dragged, page-widget.c skips selection/click for that drag). (2) sc_adjust_window best-fit realigns the current page via position_set(-1,-1) in an idle callback after adjust_view."
