# dotfiles documentation

Official documentation of the currently active projects tracked in this
`$HOME` dotfiles git repository. Covers only what `git ls-files` actually
tracks today — configs and code that were removed via an "archive" commit
(e.g. spotifyd, spotify-tui, the old doom `+magit` layer, htop's `htoprc`)
are gone from the working tree and gone from these docs too. Where a file is
still tracked but functionally superseded (waybar), that's called out
explicitly rather than omitted, since it hasn't been archived.

Scope: this only documents what lives in the `$HOME` git repo. A large
amount of *other* local infrastructure exists on this machine (rclone/restic
mount units, the flight-price tracker, the AUR security checker, the
password-store backup, peer-agent, mail sync) that is deliberately **not**
version-controlled here and is out of scope for this doc set.

## Map

| Doc | Covers |
|---|---|
| [hyprland.md](hyprland.md) | Window manager: `hl.*` Lua config, autostart, keybinds, window/layer rules, monitors, input, the RDP focus guard, and the small scripts it shells out to |
| [rust-tools.md](rust-tools.md) | The four standalone Rust/Cargo projects under `~/.config/hypr/`: `clipboard-picker`, `notifyd`, `sysmon`, `winswitch` |
| [quickshell-bar.md](quickshell-bar.md) | The custom QML status bar (`~/.config/quickshell/`) that replaced waybar |
| [theming.md](theming.md) | `gen-theme.py`'s wallpaper→Material You pipeline and every consumer it writes to |
| [tmux.md](tmux.md) | `.tmux.conf` and the Python/shell scripts behind its session/window/pane navigation |
| [zsh-and-terminal.md](zsh-and-terminal.md) | zsh (`motions.zsh`, `.zshrc`/`.zshenv`), Doom Emacs, Alacritty |
| [desktop-apps.md](desktop-apps.md) | rofi, mpv, GTK, nsxiv, fsearch, GnuPG, `.desktop` overrides, and waybar's legacy status |
| [claude-history.md](claude-history.md) | `bin/claude-history`, the standalone CLI search over Claude Code conversation history |
| [query-dsl.md](query-dsl.md) | The shared (copy-pasted, not imported) query language behind `window-search.py`, `focus-picker.py`, `claude-history`, and winswitch's grid search — grammar, fuzzy-matching rules, and the design principles behind them |

## Architecture at a glance

- **Compositor**: Hyprland, configured in Lua (`~/.config/hypr/*.lua`), not
  the stock `hyprland.conf` syntax — see [hyprland.md](hyprland.md).
- **Bar**: a from-scratch quickshell bar (replaced caelestia-shell, then
  waybar, 2026-08-27) — see [quickshell-bar.md](quickshell-bar.md).
- **System monitoring**: `sysmond` (Rust daemon, Unix socket) feeds both the
  quickshell bar's hover graphs and the standalone `sysmon-graph` popups.
- **Notifications**: `notifyd` replaced dunst so notification actions
  survive after the popup closes.
- **Theming**: wallpaper changes → `gen-theme.py` (Material You/HCT) →
  GTK/Qt/KDE/Hyprland/Alacritty/rofi/tmux/nsxiv, live-reloaded where the
  toolkit supports it.
- **Shell**: zsh with custom Emacs-style motions; tmux with a custom MRU
  session/window/pane navigation layer and resurrect/continuum wired in.

## Regenerating/updating this doc set

These are hand-written, not generated. When a project's active/inactive
status changes (e.g. waybar gets formally archived, or a script gets
replaced), update the relevant doc in the same commit as the code change
where practical, or as a prompt follow-up otherwise.

## Website

This doc set is published at <https://baleti.github.io/dotfiles/>. The repo
keeps one long-lived branch per machine, and the site is built from **all**
of them:

| URL | Source |
|---|---|
| `/` | shared docs (`SHARED_PAGES` in `build.py`) + a machine index |
| `/host3/` | `host3` branch's machine-specific pages |
| `/host6/` | `host6` branch |
| `/wsl/` | `main` branch |
| `/qemu/` | `qemu-claude` branch |

- `./build.py` — reads each branch's `.config/docs/*.md` from a throwaway
  `git worktree` (**never** a checkout in the live `$HOME` tree), renders
  with `pandoc` into `./site/`. Pages in `SHARED_PAGES` publish once at the
  root; every other page a branch ships becomes that machine's own.
  Rewrites inter-doc links across the tree, builds the sidebar + contents
  rail + a client-side search index. `./build.py --serve` previews on
  `localhost:8000`. Branch→slug map and the shared/host split are the
  `BRANCHES` / `SHARED_PAGES` / `CANONICAL_BRANCH` constants at the top.
- `./deploy.sh [--setup]` — `git fetch`, `build.py`, then force-pushes
  `./site/` to the repo's orphan `gh-pages` branch via a throwaway git repo
  inside `site/` (never checks `gh-pages` out in `$HOME`). `--setup` also
  points the Pages config at the branch via `gh`.
- `assets/` (`style.css`, `site.js`) is the hand-written theme, taken from
  whichever branch you run `build.py` on. `site/` is generated output —
  git-ignored via `.git/info/exclude`, never committed.

Requires `pandoc` + `git`. Run `./deploy.sh` after editing any doc (on any
branch) to republish.
