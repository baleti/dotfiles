#!/usr/bin/env python3
"""Generates a Material You dark scheme, either seeded from this desktop's
existing cyan/green accent (appearance.lua's col.active_border gradient,
the default) or extracted from a wallpaper image via --image PATH.
wallpaper-2.png itself is monochrome (extracting from it would just
produce grays), which is why the default seeds from the accent colors
instead -- --image is for wallpapers that actually have color in them.
See memory/conversation 2026-08-27.

Uses python-materialyoucolor (the same real HCT/tonal-palette algorithm
caelestia-shell used) directly, without the shell around it.

Usage:
  gen-theme.py                    # seed from the cyan/green accent
  gen-theme.py --image PATH       # extract primary+secondary from an image

Writes:
  - ~/.local/state/quickshell/scheme.json   -- read by Theme.qml (FileView)
  - ~/.config/gtk-3.0/gtk.css, gtk-4.0/gtk.css -- @define-color overrides
  - ~/.config/kdeglobals                    -- [Colors:*] sections only,
    every other section/key preserved as-is

No watcher -- re-run manually after changing the wallpaper or the seed
colors below.
"""
import argparse
import configparser
import json
import os
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
from materialyoucolor.utils.image_utils import source_color_from_image_bytes
from materialyoucolor.utils.theme_utils import CustomColor, theme_from_source_color
from materialyoucolor.score.score import Score, ScoreOptions
from materialyoucolor.quantize import QuantizeCelebi

PRIMARY_SEED = "#33ccff"   # appearance.lua active_border gradient start
SECONDARY_SEED = "#00ff99"  # appearance.lua active_border gradient end

STATE_DIR = Path.home() / ".local/state/quickshell"
GTK3_CSS = Path.home() / ".config/gtk-3.0/gtk.css"
GTK4_CSS = Path.home() / ".config/gtk-4.0/gtk.css"
KDEGLOBALS = Path.home() / ".config/kdeglobals"


def hex_to_argb(hex_color: str) -> int:
    h = hex_color.lstrip("#")
    r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
    return 0xFF000000 | (r << 16) | (g << 8) | b


def argb_to_hex(argb: int) -> str:
    return f"#{argb & 0xFFFFFF:06x}"


def argb_to_rgb_tuple(argb: int) -> tuple[int, int, int]:
    return ((argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF)


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

    out = {
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

    STATE_DIR.mkdir(parents=True, exist_ok=True)
    (STATE_DIR / "scheme.json").write_text(json.dumps(out, indent=2) + "\n")
    print(f"wrote {STATE_DIR / 'scheme.json'}")

    # --- GTK: a deliberately small variable set (background/foreground/
    # accent only), not the full ~20-variable libadwaita set caelestia-shell
    # used -- that fuller set clashing with this non-libadwaita GTK theme
    # (Infinity-GTK) is the leading suspect for the earlier white-screen
    # regression (2026-08-26), so this trades completeness for safety.
    gtk_css = f"""/* Generated by ~/.config/hypr/scripts/gen-theme.py -- re-run after
 * changing the seed colors there, or delete these two files to revert to
 * Infinity-GTK's own colors untouched. */
@define-color accent_color {out['primary']};
@define-color accent_bg_color {out['primary']};
@define-color accent_fg_color {out['onPrimary']};
@define-color window_bg_color {out['background']};
@define-color window_fg_color {out['onBackground']};
@define-color view_bg_color {out['surface']};
@define-color view_fg_color {out['onSurface']};
"""
    GTK3_CSS.parent.mkdir(parents=True, exist_ok=True)
    GTK4_CSS.parent.mkdir(parents=True, exist_ok=True)
    GTK3_CSS.write_text(gtk_css)
    GTK4_CSS.write_text(gtk_css)
    print(f"wrote {GTK3_CSS}\nwrote {GTK4_CSS}")

    # --- KDE/Dolphin: patch only [Colors:*] sections of the existing
    # kdeglobals, in place -- every other section (fonts, icons, KDE
    # internals) is preserved untouched.
    cp = configparser.ConfigParser(strict=False, interpolation=None)
    cp.optionxform = str  # keys are case-sensitive in this file
    if KDEGLOBALS.exists():
        cp.read(KDEGLOBALS)

    def rgb(hexcolor: str) -> str:
        r, g, b = argb_to_rgb_tuple(hex_to_argb(hexcolor))
        return f"{r},{g},{b}"

    color_sections = {
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
    for section, keys in color_sections.items():
        if not cp.has_section(section):
            cp.add_section(section)
        for k, v in keys.items():
            cp.set(section, k, v)

    with open(KDEGLOBALS, "w") as f:
        cp.write(f, space_around_delimiters=False)
    print(f"wrote {KDEGLOBALS} (Colors:* sections only)")


if __name__ == "__main__":
    main()
