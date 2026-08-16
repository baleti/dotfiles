//! Config file (Phase 9): `~/.config/hypr/notifyd/notifyd.toml`, mapping
//! the "Replicated" half of the plan's dunstrc disposition table
//! (~/.claude2/plans/silly-percolating-rose.md). Every field's `Default`
//! impl matches this project's actual dunstrc exactly, so an absent (or
//! partial) config file reproduces the behaviour already built and tested
//! in Phases 3-6 -- this phase makes those values *editable*, it doesn't
//! change any of them.
//!
//! Deliberately not config-driven: `follow` (always focused-monitor, a
//! structural choice not a value), `sort`/`alignment`/`vertical_alignment`/
//! `icon_position` (exactly one variant of each is implemented --
//! generalizing to support values this config never actually uses would be
//! speculative), and the three mouse bindings (dunstrc's mouse_*_click are
//! a small action-chaining DSL; hardcoding do_action/close_current/
//! close_all, which is what this config asks for anyway, avoids
//! reimplementing that DSL for no behavioural difference).

use std::path::PathBuf;

use serde::Deserialize;

#[derive(Deserialize, Clone)]
#[serde(default)]
pub struct UrgencyConfig {
    pub background: String,
    pub foreground: String,
    /// 0 means sticky (never times out on its own), matching both
    /// dunstrc's own `timeout = 0` and `Notify()`'s `expire_timeout = 0`.
    /// Deliberately not `Option<u32>`: serde's container-level
    /// `#[serde(default)]` fills in a *present-but-partial* TOML table's
    /// missing fields from `UrgencyConfig::default()` specifically (the
    /// "normal" tier's values), not from whichever tier's own default
    /// this field belongs to -- so a `[urgency_critical]` table that
    /// otherwise overrides colors but leaves `timeout_ms` unset would
    /// silently get a 10s timeout instead of staying sticky. `Option`
    /// makes that worse, not better: TOML has no null literal, so there'd
    /// be no way to *write* sticky explicitly once that happens. A plain
    /// `0` sidesteps it -- always set this explicitly per tier.
    pub timeout_ms: u32,
    /// `None` falls back to the card's normal frame color -- only
    /// urgency_critical overrides it in this dunstrc.
    pub frame_color: Option<String>,
    pub default_icon: String,
}

#[derive(Deserialize, Clone)]
#[serde(default)]
pub struct Config {
    pub width: i32,
    pub max_height: i32,
    pub offset_x: i32,
    pub offset_y: i32,
    /// dunstrc: separator_height, reused as the gap between independent
    /// stacked surfaces -- see popup.rs's module doc.
    pub gap: i32,
    pub frame_width: i32,
    pub frame_color: String,
    pub corner_radius: i32,
    pub padding: i32,
    pub font: String,
    pub format: String,
    /// dunstrc: notification_limit -- max popups shown at once.
    pub notification_limit: usize,
    /// dunstrc: history_length -- max notifications retained after close.
    pub history_length: usize,
    /// dunstrc: ignore_dbusclose -- if true, CloseNotification calls from
    /// clients are ignored (only the daemon's own timeout/mouse closes a
    /// popup). "Useful to enforce the timeout... without this, an
    /// application may close the notification sent before the user
    /// defined timeout."
    pub ignore_dbusclose: bool,
    pub icon_theme: String,
    pub icon_search_paths: Vec<String>,
    /// See popup.rs's ICON_SIZE doc for why this is one fixed size rather
    /// than dunstrc's min/max clamp pair.
    pub icon_size: i32,
    pub urgency_low: UrgencyConfig,
    pub urgency_normal: UrgencyConfig,
    pub urgency_critical: UrgencyConfig,
}

impl Default for UrgencyConfig {
    fn default() -> Self {
        // dunstrc [urgency_normal] -- the fallback urgency (per spec, an
        // unrecognized/missing urgency hint defaults to NORMAL).
        UrgencyConfig {
            background: "#285577".to_string(),
            foreground: "#ffffff".to_string(),
            timeout_ms: 10_000,
            frame_color: None,
            default_icon: "dialog-information".to_string(),
        }
    }
}

impl Config {
    fn urgency_low_default() -> UrgencyConfig {
        UrgencyConfig {
            background: "#222222".to_string(),
            foreground: "#888888".to_string(),
            timeout_ms: 10_000,
            frame_color: None,
            default_icon: "dialog-information".to_string(),
        }
    }

    fn urgency_critical_default() -> UrgencyConfig {
        UrgencyConfig {
            background: "#900000".to_string(),
            foreground: "#ffffff".to_string(),
            timeout_ms: None, // dunstrc: timeout = 0, sticky
            frame_color: Some("#ff0000".to_string()),
            default_icon: "dialog-warning".to_string(),
        }
    }

    pub fn urgency(&self, urgency: u8) -> &UrgencyConfig {
        match urgency {
            0 => &self.urgency_low,
            2 => &self.urgency_critical,
            _ => &self.urgency_normal,
        }
    }

    fn path() -> PathBuf {
        let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
        home.join(".config/hypr/notifyd/notifyd.toml")
    }

    /// Reads `notifyd.toml` if present; any field it doesn't set (or the
    /// whole file, if missing) falls back to `Default`, which reproduces
    /// this dunstrc exactly. A present-but-invalid file is reported and
    /// treated as absent, rather than failing the whole daemon to start.
    pub fn load() -> Config {
        let path = Self::path();
        let text = match std::fs::read_to_string(&path) {
            Ok(text) => text,
            Err(_) => return Config::default(),
        };
        match toml::from_str(&text) {
            Ok(config) => config,
            Err(err) => {
                eprintln!("notifyd: {} is invalid, using defaults: {err}", path.display());
                Config::default()
            }
        }
    }
}

impl Default for Config {
    fn default() -> Self {
        Config {
            width: 300,
            max_height: 300,
            offset_x: 10,
            offset_y: 50,
            gap: 2,
            frame_width: 3,
            frame_color: "#aaaaaa".to_string(),
            corner_radius: 0,
            padding: 8,
            font: "Monospace 8".to_string(),
            format: "<b>%s</b>\n%b".to_string(),
            notification_limit: 20,
            history_length: 20,
            ignore_dbusclose: false,
            icon_theme: "Adwaita".to_string(),
            icon_search_paths: vec![
                "/usr/share/icons/gnome/16x16/status".to_string(),
                "/usr/share/icons/gnome/16x16/devices".to_string(),
            ],
            icon_size: 32,
            urgency_low: Self::urgency_low_default(),
            urgency_normal: UrgencyConfig::default(),
            urgency_critical: Self::urgency_critical_default(),
        }
    }
}
