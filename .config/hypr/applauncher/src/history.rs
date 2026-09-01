//! Launch frecency, so the apps you actually use sit on top -- the same
//! ranking the old quickshell launcher kept, reading and writing the same
//! file (`~/.cache/quickshell/launcher-history.json`,
//! `{ "<id>": {count, last} }`) so the history carries straight over with
//! no migration.

use std::collections::HashMap;
use std::io::Write;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Clone, Copy, Default)]
struct Rec {
    count: u64,
    last: u64,
}

pub struct History {
    path: PathBuf,
    data: HashMap<String, Rec>,
}

fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn history_path() -> PathBuf {
    let base = std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".cache"));
    base.join("quickshell").join("launcher-history.json")
}

impl History {
    pub fn load() -> Self {
        let path = history_path();
        let mut data = HashMap::new();
        if let Ok(txt) = std::fs::read_to_string(&path) {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&txt) {
                if let Some(obj) = v.as_object() {
                    for (k, val) in obj {
                        data.insert(
                            k.clone(),
                            Rec {
                                count: val.get("count").and_then(|c| c.as_u64()).unwrap_or(0),
                                last: val.get("last").and_then(|c| c.as_u64()).unwrap_or(0),
                            },
                        );
                    }
                }
            }
        }
        History { path, data }
    }

    /// Frecency: launch count weighted heavily, with a small recency bump so
    /// something used a lot long ago still loses to something used recently.
    /// Identical to `LauncherHistory.qml`'s `score`.
    pub fn score(&self, id: &str) -> i64 {
        let Some(e) = self.data.get(id) else { return 0 };
        let age_days = if e.last > 0 {
            (now_secs().saturating_sub(e.last)) as f64 / 86400.0
        } else {
            9999.0
        };
        let recency = if age_days < 3.0 {
            3
        } else if age_days < 14.0 {
            2
        } else if age_days < 60.0 {
            1
        } else {
            0
        };
        (e.count as i64) * 4 + recency
    }

    pub fn bump(&mut self, id: &str) {
        let e = self.data.entry(id.to_string()).or_default();
        e.count += 1;
        e.last = now_secs();
        self.save();
    }

    fn save(&self) {
        let mut obj = serde_json::Map::new();
        for (k, e) in &self.data {
            obj.insert(
                k.clone(),
                serde_json::json!({ "count": e.count, "last": e.last }),
            );
        }
        let body = serde_json::Value::Object(obj).to_string();
        if let Some(dir) = self.path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let tmp = self.path.with_extension("json.tmp");
        if std::fs::File::create(&tmp).and_then(|mut f| f.write_all(body.as_bytes())).is_ok() {
            let _ = std::fs::rename(&tmp, &self.path);
        }
    }
}
