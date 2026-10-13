//! Config file: `~/.config/hypr/notifyd/notifyd.toml`. Since notifyd went
//! headless (2026-08-30) this is just behaviour, not looks -- the card
//! styling lives in ~/.config/quickshell/notifications/ now. Every field's
//! default matches what dunst/notifyd did before, so an absent or partial
//! file changes nothing.

use std::path::PathBuf;

use serde::Deserialize;

#[derive(Deserialize, Clone)]
#[serde(default)]
pub struct UrgencyConfig {
    /// 0 means sticky (never times out on its own) -- matches dunstrc's
    /// `timeout = 0` and Notify()'s `expire_timeout = 0`. See the original
    /// notifyd history for why this is a plain `u32` and not `Option`.
    pub timeout_ms: u32,
}

#[derive(Deserialize, Clone, Default)]
#[serde(default)]
pub struct MuteBypass {
    pub apps: Vec<String>,
    pub summary_contains: Vec<String>,
}

impl MuteBypass {
    pub fn matches(&self, app_name: &str, summary: &str) -> bool {
        let summary = summary.to_lowercase();
        // notifyd's own mute-toggle feedback card must always show.
        app_name == "notifyd-mute"
            || self.apps.iter().any(|a| a.eq_ignore_ascii_case(app_name))
            || self.summary_contains.iter().any(|t| summary.contains(&t.to_lowercase()))
    }
}

#[derive(Deserialize, Clone)]
#[serde(default)]
pub struct Config {
    /// dunstrc: notification_limit -- max popups shown at once.
    pub notification_limit: usize,
    /// dunstrc: history_length -- max notifications retained after close,
    /// so their actions stay invokable (the whole point of notifyd).
    pub history_length: usize,
    /// dunstrc: ignore_dbusclose -- if true, a client's CloseNotification
    /// is ignored (only notifyd's own timeout / a dismiss closes a popup).
    pub ignore_dbusclose: bool,
    /// Notifications that still pop up while muted. A notification bypasses
    /// if its app_name matches any `apps` entry (case-insensitive, exact) or
    /// its summary contains any `summary_contains` entry (case-insensitive).
    pub mute_bypass: MuteBypass,
    pub urgency_low: UrgencyConfig,
    pub urgency_normal: UrgencyConfig,
    pub urgency_critical: UrgencyConfig,
}

impl Default for UrgencyConfig {
    fn default() -> Self {
        // dunstrc [urgency_normal] -- also the fallback for an
        // unrecognized/missing urgency hint (spec default is NORMAL).
        UrgencyConfig { timeout_ms: 10_000 }
    }
}

impl Config {
    fn urgency_low_default() -> UrgencyConfig {
        UrgencyConfig { timeout_ms: 10_000 }
    }

    fn urgency_critical_default() -> UrgencyConfig {
        UrgencyConfig { timeout_ms: 0 } // dunstrc: timeout = 0, sticky
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

    /// Reads `notifyd.toml` if present; any unset field (or the whole file,
    /// if missing) falls back to `Default`. A present-but-invalid file is
    /// reported and treated as absent rather than failing startup.
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
            notification_limit: 20,
            history_length: 20,
            ignore_dbusclose: false,
            mute_bypass: MuteBypass::default(),
            urgency_low: Self::urgency_low_default(),
            urgency_normal: UrgencyConfig::default(),
            urgency_critical: Self::urgency_critical_default(),
        }
    }
}
