//! Colours from gen-theme.py's live wallpaper-derived scheme
//! (`~/.local/state/quickshell/scheme.json`) -- the same file winswitch and
//! clipboard-picker read, so the card matches the quickshell launcher / rss
//! reader (accent border == `scheme.primary`). Every field has a fallback;
//! a missing or malformed file is never an error, just an un-themed card.

use std::path::PathBuf;

pub struct Theme {
    /// `#rrggbb` -- the 1px card border, matching `Theme.cyan`.
    pub accent: String,
    /// Card background (opaque hex; the CSS adds the alpha).
    pub background: String,
    pub text: String,
    pub text_dim: String,
    pub divider: String,
    /// Pango 16-bit rgb for the inline `/verb` colouring.
    pub cmd_valid: Option<(u16, u16, u16)>,
    pub cmd_invalid: Option<(u16, u16, u16)>,
}

fn scheme_path() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/state/quickshell/scheme.json"))
}

fn hex_to_rgb16(hex: &str) -> Option<(u16, u16, u16)> {
    let h = hex.strip_prefix('#').unwrap_or(hex);
    if h.len() != 6 {
        return None;
    }
    let r = u8::from_str_radix(&h[0..2], 16).ok()?;
    let g = u8::from_str_radix(&h[2..4], 16).ok()?;
    let b = u8::from_str_radix(&h[4..6], 16).ok()?;
    Some((r as u16 * 257, g as u16 * 257, b as u16 * 257))
}

impl Theme {
    pub fn load() -> Self {
        let mut t = Theme {
            accent: "#a1c9ff".into(),
            background: "#201a1b".into(),
            text: "#ece0e1".into(),
            text_dim: "#d6c2c5".into(),
            divider: "#514346".into(),
            cmd_valid: None,
            cmd_invalid: None,
        };
        let Some(v) = scheme_path()
            .and_then(|p| std::fs::read_to_string(p).ok())
            .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
        else {
            return t;
        };
        let get = |k: &str| v.get(k).and_then(|c| c.as_str()).filter(|s| s.len() == 7 && s.starts_with('#'));
        if let Some(s) = get("primary") {
            t.accent = s.to_string();
        }
        if let Some(s) = get("background") {
            t.background = s.to_string();
        }
        if let Some(s) = get("onBackground") {
            t.text = s.to_string();
        }
        if let Some(s) = get("onSurfaceVariant") {
            t.text_dim = s.to_string();
        }
        if let Some(s) = get("outlineVariant") {
            t.divider = s.to_string();
        }
        t.cmd_valid = get("primary").and_then(hex_to_rgb16);
        t.cmd_invalid = get("error").and_then(hex_to_rgb16);
        t
    }
}
