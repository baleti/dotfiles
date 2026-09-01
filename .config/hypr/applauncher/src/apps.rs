//! Enumerating installed applications and launching them, via GIO's
//! `DesktopAppInfo` -- which parses every `.desktop` file on `XDG_DATA_DIRS`
//! (Name / GenericName / Comment / Exec / Icon / Categories / Keywords),
//! honours `NoDisplay` / `OnlyShowIn` / `Hidden` through `should_show()`,
//! and does the `Exec=` field-code expansion + detached spawn on launch.
//! GTK's own icon theme resolves the `Icon=` name (hicolor fallback
//! included) -- the thing quickshell's provider got wrong and the reason
//! the old launcher needed a `resolve-icons.py` helper.

use gio::prelude::*;

/// The DSL-visible field names, in the order they appear in the `/fv`
/// autocomplete. `name` + `generic` are also the bare-text haystack.
pub const FIELD_NAMES: &[&str] = &["name", "generic", "comment", "exec", "categories", "keywords"];

pub const FIELD_DESCS: &[(&str, &str)] = &[
    ("name", "the application name"),
    ("generic", "the generic name (\"Web Browser\")"),
    ("comment", "the freedesktop Comment= description"),
    ("exec", "the launch command"),
    ("categories", "freedesktop Categories= entries"),
    ("keywords", "freedesktop Keywords= entries"),
];

pub struct App {
    /// `DesktopEntry` id with the `.desktop` suffix stripped, matching the
    /// keys the old quickshell launcher wrote into
    /// `~/.cache/quickshell/launcher-history.json` (kept, not migrated).
    pub id: String,
    pub name: String,
    pub generic: String,
    pub comment: String,
    pub exec: String,
    pub categories: String,
    pub keywords: String,
    /// Lowercased `"name generic"` -- what a bare (unscoped) query matches.
    pub haystack: String,
    pub icon: Option<gio::Icon>,
    info: gio::DesktopAppInfo,
}

impl App {
    /// The value of one DSL field, for `/fv field:value` and `/s field`.
    pub fn field(&self, name: &str) -> &str {
        match name {
            "name" => &self.name,
            "generic" => &self.generic,
            "comment" => &self.comment,
            "exec" => &self.exec,
            "categories" => &self.categories,
            "keywords" => &self.keywords,
            _ => "",
        }
    }

    pub fn launch(&self) {
        let ctx = gio::AppLaunchContext::NONE;
        if let Err(e) = self.info.launch(&[], ctx) {
            eprintln!("applauncher: failed to launch {}: {e}", self.id);
        }
    }
}

/// Every visible installed application, unsorted.
pub fn load() -> Vec<App> {
    let mut out = Vec::new();
    for info in gio::AppInfo::all() {
        let Ok(desktop) = info.clone().downcast::<gio::DesktopAppInfo>() else {
            continue;
        };
        if !desktop.should_show() {
            continue;
        }
        let raw_id = desktop.id().map(|s| s.to_string()).unwrap_or_default();
        if raw_id.is_empty() {
            continue;
        }
        let id = raw_id.strip_suffix(".desktop").unwrap_or(&raw_id).to_string();

        let name = desktop.name().to_string();
        let generic = desktop.generic_name().map(|s| s.to_string()).unwrap_or_default();
        let comment = desktop.description().map(|s| s.to_string()).unwrap_or_default();
        let exec = desktop.commandline().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
        let categories = desktop.categories().map(|s| s.to_string().replace(';', " ")).unwrap_or_default();
        let keywords = desktop
            .keywords()
            .iter()
            .map(|s| s.to_string())
            .collect::<Vec<_>>()
            .join(" ");

        let haystack = format!("{name} {generic}").to_lowercase();

        out.push(App {
            id,
            name,
            generic,
            comment,
            exec,
            categories,
            keywords,
            haystack,
            icon: desktop.icon(),
            info: desktop,
        });
    }
    out
}
