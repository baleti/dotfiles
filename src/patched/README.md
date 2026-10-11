# patched: locally patched distro programs

Programs we patch live here as git checkouts, built into pacman packages (`<name>-local`, which
`provides`/`conflicts` the distro package), kept up to date by two scripts. Zathura is the first.

## Using it
- Weekly, after paru (needs the sudo lease):
  `paru; ~/src/patched/bin/patched-update; pipx upgrade-all; flatpak update --noninteractive; doom sync -u; doom upgrade --force`
- `bin/patched-update` installs builds staged by the monthly sync, and rebuilds when a `DEPS` package changed version.
- `bin/patched-sync` runs monthly from `systemd --user` (`patched-sync.timer`): fetch upstream, rebase our patches
  onto the newest release tag, let `claude -p` resolve conflicts, build into `staging/`. It never installs.
- Status/logs: `~/.local/state/patched/<name>.{status,build.log,agent.log}`.
  Status is one of `installed | ready:<pkg> | uptodate | conflict | build-failed | dirty-checkout | fetch-failed`.

## Adding another program
1. `git clone <upstream> ~/src/patched/<name>` and `git checkout -b local <release tag>`; commit patches there
   (rebase on new tags, never merge).
2. `build/<name>/PKGBUILD` (copy zathura's): package `<name>-local`, `provides`/`conflicts` the distro name,
   source `git+file://$HOME/src/patched/<name>#branch=local`, `pkgver()` from `git describe`.
3. `registry/<name>.sh` (copy zathura's): upstream URL, tag glob, DEPS, and PATCH_NOTES (the intent of every patch,
   which the conflict-resolving agent reads).
4. Build once with `makepkg` in `build/<name>`, then install with `sudo pacman -U`.
No other wiring: the scripts iterate over `registry/*.sh`.

## Rules
- Prefer config over patches (e.g. zathura `map` lines in zathurarc). Patch only what config cannot express.
- Zathura: `map` applies to normal mode only; every map needs a `map [fullscreen]` twin (block at the bottom of zathurarc).
- Zathura reads zathurarc only at startup.
- Checkouts and builds are gitignored. Tracked here: scripts, registry, PKGBUILDs, and `patches/<name>/*.patch` (format-patch export of the `local` branch, refreshed by patched-sync; re-export by hand with `export_patches` after committing a new patch). This directory is part of the $HOME dotfiles repo (public) - no secrets here.
