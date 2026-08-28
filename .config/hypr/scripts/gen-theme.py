#!/usr/bin/env python3
"""Generates a Material You dark scheme, either seeded from this desktop's
existing cyan/green accent (appearance.lua's col.active_border gradient,
the default) or extracted from a wallpaper image via --image PATH.

Uses python-materialyoucolor (the same real HCT/tonal-palette algorithm
caelestia-shell used) directly, without the shell around it.

Usage:
  gen-theme.py                    # seed from the cyan/green accent
  gen-theme.py --image PATH       # extract primary+secondary from an image

Writes/applies (2026-08-28, expanded past just GTK/KDE -- see conversation
2026-08-28 for the GTK3 root-cause writeup):
  - ~/.local/state/quickshell/scheme.json      -- read by Theme.qml (FileView)
  - ~/.config/gtk-3.0/colors.css, gtk-4.0/colors.css
    -- the *_breeze named colors Infinity-GTK's own CSS actually consumes
       (confirmed via grep: the theme never references the libadwaita-style
       names like window_bg_color at all). gtk.css just `@import`s this --
       overwriting gtk.css directly with unrelated variable names (the old
       approach) silently deleted KDE's own `colors.css` import line that
       kde-gtk-config had put there, which is what broke Infinity-GTK to a
       plain white/Adwaita fallback (reproduced: an EMPTY gtk.css also broke
       it, proving it was the missing import, not any variable collision).
  - ~/.config/gtk-3.0/gtk.css, gtk-4.0/gtk.css -- `@import "colors.css"` plus
    a small libadwaita-style override block, for any GTK4/libadwaita app
    that does read those names (Infinity-GTK doesn't, but this is harmless).
  - ~/.local/share/color-schemes/MaterialYou.colors, applied live via
    `plasma-apply-colorscheme` -- Dolphin/KDE apps resolve their palette
    from kdeglobals's [KDE] ColorScheme=<name>, NOT from kdeglobals's own
    inline [Colors:*] sections (those are only a fallback for apps with no
    named scheme configured) -- confirmed via kdeglobals having
    `[KDE] ColorScheme=Breeze`, which is why patching [Colors:*] alone
    never visibly changed Dolphin.
  - kdeglobals [Colors:*] sections directly too, as a fallback for anything
    that does read them inline.
  - Hyprland window border colors, live via `hyprctl keyword` (NOT written
    into appearance.lua -- reverts to that file's static default on the
    next full Hyprland restart until wallpaper-watch.sh's next theme regen
    reapplies it; editing the live Lua config file itself was judged too
    risky to do unattended).
  - ~/.config/alacritty/alacritty.toml's [colors.primary/normal/bright]
    tables, in place (regex-scoped to just those tables; alacritty.yml is
    untouched dead weight -- alacritty 0.17 only reads the .toml).
  - ~/.config/rofi/materialyou.rasi, auto-@import-ed from config.rasi.
"""
import argparse
import configparser
import json
import re
import subprocess
import sys
import types
from pathlib import Path

# python-materialyoucolor 3.0.2-1 (AUR) ships a theme_utils.py that imports
# `materialyoucolor.utils.string_utils.hex_from_argb`, but that module
# doesn't exist in this version -- the function lives in color_utils.py
# instead. Shimming it in sys.modules rather than patching the installed
# package.
if "materialyoucolor.utils.string_utils" not in sys.modules:
    from materialyoucolor.utils import color_utils as _color_utils

    _shim = types.ModuleType("materialyoucolor.utils.string_utils")
    _shim.hex_from_argb = _color_utils.hex_from_argb
    sys.modules["materialyoucolor.utils.string_utils"] = _shim

from materialyoucolor.hct.hct import Hct
from materialyoucolor.utils.theme_utils import CustomColor, theme_from_source_color
from materialyoucolor.score.score import Score, ScoreOptions
from materialyoucolor.quantize import QuantizeCelebi

PRIMARY_SEED = "#33ccff"   # appearance.lua active_border gradient start
SECONDARY_SEED = "#00ff99"  # appearance.lua active_border gradient end

STATE_DIR = Path.home() / ".local/state/quickshell"
GTK3_DIR = Path.home() / ".config/gtk-3.0"
GTK4_DIR = Path.home() / ".config/gtk-4.0"
KDEGLOBALS = Path.home() / ".config/kdeglobals"
COLOR_SCHEME_NAME = "MaterialYou"
COLOR_SCHEME_FILE = Path.home() / f".local/share/color-schemes/{COLOR_SCHEME_NAME}.colors"
ALACRITTY_TOML = Path.home() / ".config/alacritty/alacritty.toml"
ROFI_DIR = Path.home() / ".config/rofi"
ROFI_THEME = ROFI_DIR / "materialyou.rasi"
ROFI_CONFIG = ROFI_DIR / "config.rasi"
TMUX_THEME = Path.home() / ".config/tmux/theme.conf"


def hex_to_argb(hex_color: str) -> int:
    h = hex_color.lstrip("#")
    r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
    return 0xFF000000 | (r << 16) | (g << 8) | b


def argb_to_hex(argb: int) -> str:
    return f"#{argb & 0xFFFFFF:06x}"


def argb_to_rgb_tuple(argb: int) -> tuple[int, int, int]:
    return ((argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF)


def vivid_hex(hex_color: str, chroma: float = 90, tone: float = 78) -> str:
    """Same hue, forced to a high, fixed chroma/tone -- the extracted
    primary/secondary can be quite muted (a hazy/moody source photo yields
    a muted HCT primary by design, since that's what reads as harmonious
    for body text/backgrounds), which made the border read as "barely
    visible against desktop colors" (2026-08-28). Border accents want to
    stand out, not blend in, so they get their own vividness pass -- same
    fixed-chroma technique series_palette already uses for CPU/network/disk
    line colors, just a higher chroma."""
    hue = Hct.from_int(hex_to_argb(hex_color)).hue
    return argb_to_hex(Hct.from_hct(hue, chroma, tone).to_int())


def lerp_hex(a: str, b: str, t: float) -> str:
    ra, ga, ba = argb_to_rgb_tuple(hex_to_argb(a))
    rb, gb, bb = argb_to_rgb_tuple(hex_to_argb(b))
    r = round(ra + (rb - ra) * t)
    g = round(ga + (gb - ga) * t)
    b_ = round(ba + (bb - ba) * t)
    return f"#{r:02x}{g:02x}{b_:02x}"


def seeds_from_image(path: Path) -> tuple[int, int]:
    """Top two ranked dominant colors, primary + secondary seed."""
    from PIL import Image

    img = Image.open(path).convert("RGBA")
    img.thumbnail((128, 128))  # quantizing the full-res image is needless work
    pixels = list(img.getdata())  # [(r, g, b, a), ...] -- QuantizeCelebi wants per-pixel sequences, not flat ARGB ints
    quantized = QuantizeCelebi(pixels, 128)
    ranked = Score.score(quantized, ScoreOptions(desired=2))
    primary = ranked[0]
    secondary = ranked[1] if len(ranked) > 1 else primary
    return primary, secondary


def build_scheme(primary_argb: int, secondary_argb: int) -> dict:
    theme = theme_from_source_color(
        primary_argb,
        custom_colors=[CustomColor(secondary_argb, "accentSecondary", blend=True)],
    )
    scheme = theme.schemes["dark"]
    secondary_group = theme.custom_colors[0].dark  # harmonized green, dark-scheme tones

    # 8 evenly-spaced hues off the primary seed's own HCT hue, fixed
    # chroma/tone so they all read as "vivid, on a dark background" --
    # used to color distinguishable series (CPU cores, network interfaces,
    # disk devices), not for the base UI palette above.
    primary_hue = Hct.from_int(scheme.primary).hue
    series_palette = [
        argb_to_hex(Hct.from_hct((primary_hue + i * 45) % 360, 60, 72).to_int())
        for i in range(8)
    ]

    return {
        "background": argb_to_hex(scheme.background),
        "surface": argb_to_hex(scheme.surface),
        "surfaceContainer": argb_to_hex(scheme.surface_variant),
        "onBackground": argb_to_hex(scheme.on_background),
        "onSurface": argb_to_hex(scheme.on_surface),
        "onSurfaceVariant": argb_to_hex(scheme.on_surface_variant),
        "outline": argb_to_hex(scheme.outline),
        "outlineVariant": argb_to_hex(scheme.outline_variant),
        "primary": argb_to_hex(scheme.primary),
        "onPrimary": argb_to_hex(scheme.on_primary),
        "primaryContainer": argb_to_hex(scheme.primary_container),
        "secondary": argb_to_hex(secondary_group.color),
        "onSecondary": argb_to_hex(secondary_group.on_color),
        "error": argb_to_hex(scheme.error),
        "seriesPalette": series_palette,
    }


def write_scheme_json(out: dict) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    (STATE_DIR / "scheme.json").write_text(json.dumps(out, indent=2) + "\n")
    print(f"wrote {STATE_DIR / 'scheme.json'}")


# --- GTK -----------------------------------------------------------------

def classify_breeze_key(key: str) -> str | None:
    """Which part of our palette a `*_breeze`-suffixed GTK variable (as used
    throughout Infinity-GTK's own gtk.css, and normally kept in sync with
    Plasma's active color scheme by kde-gtk-config's colors.css) should draw
    from. None means "leave this one's existing value alone" -- semantic
    (error/warning/success) and disabled-state colors aren't part of an
    accent palette and shouldn't get recolored."""
    k = key.lower()
    if any(s in k for s in ("insensitive", "error_color", "warning_color", "success_color")):
        return None
    if "selected_fg" in k:
        return "accent_fg"
    if any(s in k for s in ("decoration", "selected_bg", "hovering_selected", "link_color")):
        return "accent"
    if "tooltip_background" in k or "button_background" in k:
        return "surface_container"
    if "tooltip_border" in k or "border" in k:
        return "outline"
    if any(s in k for s in ("bg_color", "base_color", "content_view_bg", "background")):
        return "bg"
    if any(s in k for s in ("fg_color", "text_color", "foreground")):
        return "fg"
    return None


def patch_breeze_colors_css(path: Path, out: dict) -> None:
    """In-place value substitution, keyed by variable name -- every other
    line (semantic/disabled-state colors this desktop's theme also defines
    here) passes through untouched. Starts from a minimal skeleton if the
    file doesn't exist yet (fresh machine, kde-gtk-config never ran)."""
    color_for = {
        "accent": out["primary"],
        "accent_fg": out["onPrimary"],
        "surface_container": out["surfaceContainer"],
        "outline": out["outline"],
        "bg": out["background"],
        "fg": out["onBackground"],
    }
    line_re = re.compile(r'^@define-color\s+(\S+)\s+([^;]+);\s*$')

    if path.exists():
        lines = path.read_text().splitlines()
    else:
        # Minimal skeleton covering what Infinity-GTK actually uses -- see
        # the _breeze names grepped out of ~/.themes/Infinity-GTK/gtk-3.0/gtk.css.
        base_keys = [
            "theme_bg_color_breeze", "theme_fg_color_breeze", "theme_base_color_breeze",
            "theme_text_color_breeze", "theme_selected_bg_color_breeze", "theme_selected_fg_color_breeze",
            "theme_button_background_normal_breeze", "theme_button_foreground_normal_breeze",
            "borders_breeze", "unfocused_borders_breeze",
            "theme_view_hover_decoration_color_breeze", "theme_view_active_decoration_color_breeze",
            "content_view_bg_breeze",
        ]
        lines = [f"@define-color {k} #000000;" for k in base_keys]

    out_lines = []
    for line in lines:
        m = line_re.match(line)
        if not m:
            out_lines.append(line)
            continue
        key, _old_value = m.group(1), m.group(2)
        category = classify_breeze_key(key)
        if category is None:
            out_lines.append(line)
        else:
            out_lines.append(f"@define-color {key} {color_for[category]};")

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(out_lines) + "\n")


def write_gtk_css(gtk_dir: Path, out: dict) -> None:
    gtk_css = f"""/* Generated by ~/.config/hypr/scripts/gen-theme.py. DO NOT remove the
 * @import line below -- that's what actually feeds colors.css's *_breeze
 * variables (the ones Infinity-GTK's own CSS consumes) into the cascade;
 * without it every GTK3 app on this system renders in a plain white
 * fallback instead of the theme (reproduced 2026-08-28). The block below
 * is a secondary libadwaita-style override for GTK4/other-theme apps that
 * *do* read these names -- delete this whole file to fully revert to
 * Infinity-GTK's own static colors. */
@import "colors.css";

@define-color accent_color {out['primary']};
@define-color accent_bg_color {out['primary']};
@define-color accent_fg_color {out['onPrimary']};
@define-color window_bg_color {out['background']};
@define-color window_fg_color {out['onBackground']};
@define-color view_bg_color {out['surface']};
@define-color view_fg_color {out['onSurface']};
"""
    gtk_dir.mkdir(parents=True, exist_ok=True)
    (gtk_dir / "gtk.css").write_text(gtk_css)


def theme_gtk(out: dict) -> None:
    patch_breeze_colors_css(GTK3_DIR / "colors.css", out)
    patch_breeze_colors_css(GTK4_DIR / "colors.css", out)
    write_gtk_css(GTK3_DIR, out)
    write_gtk_css(GTK4_DIR, out)
    print(f"wrote {GTK3_DIR}/{{colors.css,gtk.css}} and {GTK4_DIR}/{{colors.css,gtk.css}}")


# --- KDE / Dolphin ---------------------------------------------------------

def rgb(hexcolor: str) -> str:
    r, g, b = argb_to_rgb_tuple(hex_to_argb(hexcolor))
    return f"{r},{g},{b}"


def color_sections(out: dict) -> dict:
    return {
        "Colors:Window": {
            "BackgroundNormal": rgb(out["background"]),
            "ForegroundNormal": rgb(out["onBackground"]),
        },
        "Colors:View": {
            "BackgroundNormal": rgb(out["surface"]),
            "ForegroundNormal": rgb(out["onSurface"]),
        },
        "Colors:Button": {
            "BackgroundNormal": rgb(out["surfaceContainer"]),
            "BackgroundAlternate": rgb(out["surfaceContainer"]),
            "ForegroundNormal": rgb(out["onSurface"]),
        },
        "Colors:Selection": {
            "BackgroundNormal": rgb(out["primary"]),
            "BackgroundAlternate": rgb(out["primaryContainer"]),
            "ForegroundNormal": rgb(out["onPrimary"]),
        },
        "Colors:Tooltip": {
            "BackgroundNormal": rgb(out["surfaceContainer"]),
            "ForegroundNormal": rgb(out["onSurface"]),
        },
        "Colors:Complementary": {
            "DecorationFocus": rgb(out["primary"]),
            "DecorationHover": rgb(out["secondary"]),
        },
    }


def write_color_scheme_file(out: dict) -> None:
    """A proper named KDE color scheme -- Dolphin/other KDE apps resolve
    their actual palette from kdeglobals's `[KDE] ColorScheme=<name>`
    pointing at a file exactly like this one under
    ~/.local/share/color-schemes/, NOT from kdeglobals's own inline
    [Colors:*] sections (those are only a fallback used when no named
    scheme is configured at all -- confirmed this system has
    `ColorScheme=Breeze` set, which is why patching kdeglobals in place
    alone never visibly changed Dolphin)."""
    cp = configparser.ConfigParser(strict=False, interpolation=None)
    cp.optionxform = str
    cp.add_section("General")
    cp.set("General", "Name", COLOR_SCHEME_NAME)
    cp.set("General", "ColorScheme", COLOR_SCHEME_NAME)
    for section, keys in color_sections(out).items():
        cp.add_section(section)
        for k, v in keys.items():
            cp.set(section, k, v)
    COLOR_SCHEME_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(COLOR_SCHEME_FILE, "w") as f:
        cp.write(f, space_around_delimiters=False)


def patch_kdeglobals_inline(out: dict) -> None:
    """Fallback for anything that reads kdeglobals's own [Colors:*]
    sections directly instead of following [KDE] ColorScheme=. Every other
    section (fonts, icons, KDE internals, the ColorScheme pointer itself)
    is preserved untouched.

    Also sets [General] AccentColor -- Plasma 6's newer accent-color
    feature takes priority over a named scheme's own Colors:Selection for
    widget accents (confirmed: this system's /etc/xdg/kdeglobals ships a
    distro-default AccentColor=146,110,228, and since the user's own
    kdeglobals never had that key at all, `kreadconfig6` was falling
    through to that system default -- which is why Dolphin kept showing
    "old" purple-ish selection/accent colors no matter what
    MaterialYou.colors said, 2026-08-28)."""
    cp = configparser.ConfigParser(strict=False, interpolation=None)
    cp.optionxform = str
    if KDEGLOBALS.exists():
        cp.read(KDEGLOBALS)
    for section, keys in color_sections(out).items():
        if not cp.has_section(section):
            cp.add_section(section)
        for k, v in keys.items():
            cp.set(section, k, v)
    if not cp.has_section("General"):
        cp.add_section("General")
    cp.set("General", "AccentColor", rgb(out["primary"]))
    with open(KDEGLOBALS, "w") as f:
        cp.write(f, space_around_delimiters=False)


def theme_kde(out: dict) -> None:
    write_color_scheme_file(out)
    patch_kdeglobals_inline(out)
    # Best-effort: sets kdeglobals's [KDE] ColorScheme=MaterialYou and (when
    # a KDE session/DBus is actually reachable) notifies running apps to
    # reload live. Under plain Hyprland (no plasmashell/kded6) the DBus
    # notify step just silently has no one to notify -- the file changes
    # still land, apps pick them up on next launch.
    result = subprocess.run(
        ["plasma-apply-colorscheme", COLOR_SCHEME_NAME],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"plasma-apply-colorscheme failed (non-fatal): {result.stderr.strip()}", file=sys.stderr)
    print(f"wrote {COLOR_SCHEME_FILE}, patched {KDEGLOBALS}")


# --- Hyprland borders -------------------------------------------------------

def theme_hyprland_borders(out: dict) -> None:
    """Live only, via `hyprctl eval` -- NOT written into appearance.lua
    (editing the live Lua config unattended was judged too risky). Reverts
    to appearance.lua's static default on the next full Hyprland restart;
    wallpaper-watch.sh reapplies this on every theme regen in the meantime.
    Plain `hyprctl keyword` doesn't work here: this config is loaded
    through hyprland.lua's hl.config() (the Lua binding, see
    hyprland_lua_binding_dispatch_syntax), and Hyprland refuses `keyword`
    entirely once a non-legacy (Lua) config parser is active ("keyword
    can't work with non-legacy parsers. Use eval.") -- re-invoking
    hl.config() live via `hyprctl eval` is the equivalent that actually
    works with this setup.

    4 color stops (not 2) -- Hyprland distributes a gradient's colors
    evenly around the whole border loop, so 2 stops reads as a hard
    diagonal split between two flat halves, while 4 (with 2 of them
    interpolated between primary/secondary) reads as an actual gradient
    that varies corner to corner, matching what the user recalled seeing
    originally. alpha e0 (was ee) -- the first attempt at "subtle" (b8,
    ~72%) visibly read as a thinner border even though border_size itself
    never changed (confirmed via `hyprctl getoption`), just fainter.

    Colors are vivid_hex(primary/secondary), not the raw out['primary']/
    out['secondary'] -- those are Material You's own harmonious (often
    fairly muted) UI tones, which read as "barely visible against desktop
    colors" once actually on a window border (2026-08-28); border_size is
    also re-set here (not just color) so this whole call is idempotent
    with appearance.lua's own static border_size=3 rather than silently
    depending on it."""
    primary = vivid_hex(out["primary"]).lstrip("#")
    secondary = vivid_hex(out["secondary"]).lstrip("#")
    mid1 = lerp_hex(vivid_hex(out["primary"]), vivid_hex(out["secondary"]), 0.33).lstrip("#")
    mid2 = lerp_hex(vivid_hex(out["primary"]), vivid_hex(out["secondary"]), 0.66).lstrip("#")
    outline = out["outlineVariant"].lstrip("#")
    stops = ",".join(f'"rgba({c}e0)"' for c in (primary, mid1, secondary, mid2))
    lua = (
        'hl.config({general={'
        'border_size=3,col={'
        f'active_border={{colors={{{stops}}},angle=45}},'
        f'inactive_border="rgba({outline}aa)"'
        '}}})'
    )
    try:
        result = subprocess.run(
            ["hyprctl", "eval", lua],
            capture_output=True, text=True, timeout=5,
        )
        if result.stdout.strip() != "ok":
            print(f"hyprctl eval border update returned unexpected output: {result.stdout!r} {result.stderr!r}", file=sys.stderr)
        else:
            print("applied Hyprland border colors live")
    except (subprocess.SubprocessError, OSError) as e:
        print(f"hyprctl border update failed (non-fatal): {e}", file=sys.stderr)


# --- Alacritty ---------------------------------------------------------------

def theme_alacritty(out: dict) -> None:
    """Regex-scoped to just the [colors.primary/normal/bright] tables --
    everything else in the file (keybinds, font, comments) passes through
    untouched. alacritty.yml exists alongside this but is dead weight:
    alacritty 0.17 only reads the .toml."""
    if not ALACRITTY_TOML.exists():
        return
    text = ALACRITTY_TOML.read_text()

    series = out["seriesPalette"]
    tables = {
        "colors.primary": {"background": out["background"], "foreground": out["onBackground"]},
        "colors.normal": {
            "black": out["background"], "red": series[5], "green": series[0],
            "yellow": series[6], "blue": series[2], "magenta": series[4],
            "cyan": out["primary"], "white": out["onSurfaceVariant"],
        },
        "colors.bright": {
            "black": out["onSurfaceVariant"], "red": series[5], "green": series[0],
            "yellow": series[6], "blue": series[2], "magenta": series[4],
            "cyan": out["primary"], "white": out["onBackground"],
        },
    }

    for table_name, values in tables.items():
        header_re = re.compile(rf'(\[{re.escape(table_name)}\]\s*\n)(.*?)(?=\n\[|\Z)', re.DOTALL)
        m = header_re.search(text)
        if not m:
            continue
        body = m.group(2)
        for key, hexval in values.items():
            key_re = re.compile(rf'^(\s*{key}\s*=\s*)"[^"]*"', re.MULTILINE)
            if key_re.search(body):
                body = key_re.sub(rf'\g<1>"{hexval}"', body)
            else:
                body += f'{key} = "{hexval}"\n'
        text = text[:m.start(2)] + body + text[m.end(2):]

    ALACRITTY_TOML.write_text(text)
    print(f"patched {ALACRITTY_TOML} ([colors.*] tables only)")


# --- Rofi --------------------------------------------------------------------

def theme_rofi(out: dict) -> None:
    rasi = f"""/* Generated by ~/.config/hypr/scripts/gen-theme.py. Re-styles the
 * widgets directly (rather than relying on @variable names the imported
 * system themes may or may not define) so this always takes effect
 * regardless of which base theme config.rasi imports. */
* {{
    background-color: {out['background']};
    text-color: {out['onBackground']};
}}
window {{
    background-color: {out['background']};
    border-color: {out['primary']};
}}
inputbar {{
    background-color: {out['surfaceContainer']};
    text-color: {out['onBackground']};
}}
element {{
    text-color: {out['onBackground']};
}}
element selected {{
    background-color: {out['primary']};
    text-color: {out['onPrimary']};
}}
element-text, element-icon {{
    background-color: transparent;
}}
"""
    ROFI_DIR.mkdir(parents=True, exist_ok=True)
    ROFI_THEME.write_text(rasi)

    if ROFI_CONFIG.exists():
        config_text = ROFI_CONFIG.read_text()
        import_line = f'@import "{ROFI_THEME}"'
        if import_line not in config_text:
            ROFI_CONFIG.write_text(config_text.rstrip("\n") + f"\n{import_line}\n")
    print(f"wrote {ROFI_THEME}")


def theme_tmux(out: dict) -> None:
    """~/.tmux.conf source-file's this (see that file's "change colors of
    status bar" section) instead of hardcoding status-bg/status-fg
    directly, so this can regenerate it without touching the main config.
    Applied live to the running server via `tmux source-file` -- non-fatal
    if no server is up yet (nothing to reload)."""
    conf = f"""# Generated by ~/.config/hypr/scripts/gen-theme.py -- sourced from
# ~/.tmux.conf, not edited directly.
set -g status-bg "{out['primary']}"
set -g status-fg "{out['onPrimary']}"
set -g window-status-current-style "bg={out['secondary']},fg={out['onSecondary']}"
"""
    TMUX_THEME.parent.mkdir(parents=True, exist_ok=True)
    TMUX_THEME.write_text(conf)
    result = subprocess.run(
        ["tmux", "source-file", str(TMUX_THEME)],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"tmux source-file failed (non-fatal, likely no server running yet): {result.stderr.strip()}", file=sys.stderr)
    print(f"wrote {TMUX_THEME}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", type=Path, help="extract seed colors from this image instead of the hardcoded accent")
    args = parser.parse_args()

    if args.image:
        primary_argb, secondary_argb = seeds_from_image(args.image)
        print(f"seeded from {args.image}: primary={argb_to_hex(primary_argb)} secondary={argb_to_hex(secondary_argb)}")
    else:
        primary_argb = hex_to_argb(PRIMARY_SEED)
        secondary_argb = hex_to_argb(SECONDARY_SEED)

    out = build_scheme(primary_argb, secondary_argb)
    write_scheme_json(out)
    theme_gtk(out)
    theme_kde(out)
    theme_hyprland_borders(out)
    theme_alacritty(out)
    theme_rofi(out)
    theme_tmux(out)


if __name__ == "__main__":
    main()
