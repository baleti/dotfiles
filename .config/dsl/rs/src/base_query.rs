//! Base query (query-dsl.md "/base-query"): a standing query per picker, written in front of whatever is typed.
//! Store: ~/.cache/quickshell/base-queries.json, `{ key: { query, history[] } }` - the same file the QML pickers
//! (services/BaseQuery.qml) use, so a base query set in one implementation of a picker shows in the other.

use serde_json::{json, Value};
use std::path::PathBuf;

fn store_path() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_default();
    PathBuf::from(home).join(".cache/quickshell/base-queries.json")
}

fn read_store() -> Value {
    std::fs::read_to_string(store_path()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_else(|| json!({}))
}

/// The base query stored for `key` ("" if none).
pub fn get(key: &str) -> String {
    read_store()[key]["query"].as_str().unwrap_or("").trim().to_string()
}

/// Store `q` as the base query for `key` (empty clears it); the outgoing value goes into the history.
pub fn set(key: &str, q: &str) {
    let mut st = read_store();
    let prev = st[key]["query"].as_str().unwrap_or("").trim().to_string();
    let mut hist: Vec<String> = st[key]["history"].as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default();
    if !q.is_empty() && !prev.is_empty() && prev != q && !hist.contains(&prev) {
        hist.insert(0, prev);
    }
    if !q.is_empty() {
        hist.retain(|x| x != q);
        hist.insert(0, q.to_string());
        hist.truncate(100);
    }
    st[key] = json!({ "query": q, "history": hist });
    let p = store_path();
    if let Some(d) = p.parent() {
        let _ = std::fs::create_dir_all(d);
    }
    let tmp = p.with_extension("tmp");
    if std::fs::write(&tmp, st.to_string()).is_ok() {
        let _ = std::fs::rename(&tmp, &p);
    }
}

/// `/bq` or `!/bq` as the first token: (negated, whitespace follows the verb, the rest of the line).
pub fn parse_cmd(text: &str) -> Option<(bool, bool, String)> {
    let t = text.trim_start();
    let (neg, t) = match t.strip_prefix('!') {
        Some(r) => (true, r),
        None => (false, t),
    };
    let after = t.strip_prefix("/base-query").or_else(|| t.strip_prefix("/bq"))?;
    if after.is_empty() {
        return Some((neg, false, String::new()));
    }
    if !after.starts_with(char::is_whitespace) {
        return None;
    }
    Some((neg, true, after.trim_start().to_string()))
}

/// What actually runs: `base` written in front of `text`; under `/bq` / `!/bq` only the rest (base switched off).
pub fn effective(base: &str, text: &str) -> String {
    let flat = |s: &str| s.replace('\n', " ");
    if let Some((_, _, rest)) = parse_cmd(text) {
        return flat(&rest);
    }
    let t = flat(text);
    let b = base.trim();
    if b.is_empty() {
        t
    } else if t.trim().is_empty() {
        b.to_string()
    } else {
        format!("{} {}", b, t)
    }
}

/// `/dbq` or `/disable-base-query` (nothing after it): Enter clears the stored base query.
pub fn is_disable_cmd(text: &str) -> bool {
    matches!(text.trim(), "/dbq" | "/disable-base-query")
}

/// Enter on a `/bq` or `/dbq` command: `/dbq` -> clears the base query, `Some("")`; bare `/bq` -> `Some("/bq <current>")` for the box; `/bq <q>` -> saves, `Some("")`. `None` if not (saving) `/bq`.
pub fn run(key: &str, text: &str) -> Option<String> {
    if is_disable_cmd(text) {
        set(key, "");
        return Some(String::new());
    }
    let (neg, ws, rest) = parse_cmd(text)?;
    if neg {
        return None;
    }
    if !ws {
        return Some(format!("/bq {}", get(key)));
    }
    set(key, rest.trim());
    Some(String::new())
}

/// Tab on a bare `!/bq`: `Some(text)` = the opposite of the base query written after it (`Some` even if empty = handled).
pub fn expand_neg(key: &str, text: &str) -> Option<String> {
    let (neg, _, rest) = parse_cmd(text)?;
    if !neg || !rest.trim().is_empty() {
        return None;
    }
    let inv = invert(&get(key));
    Some(if inv.is_empty() { text.to_string() } else { format!("!/bq {}", inv) })
}

fn tokens(q: &str) -> Vec<String> {
    let cs: Vec<char> = q.chars().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < cs.len() {
        if cs[i].is_whitespace() {
            i += 1;
            continue;
        }
        let st = i;
        if cs[i] == '!' && i + 1 < cs.len() && cs[i + 1] == '"' {
            i += 1;
        }
        if cs[i] == '"' {
            i += 1;
            while i < cs.len() && cs[i] != '"' {
                i += 1;
            }
            if i < cs.len() {
                i += 1;
            }
        } else {
            while i < cs.len() && !cs[i].is_whitespace() {
                i += 1;
            }
        }
        out.push(cs[st..i].iter().collect());
    }
    out
}

fn is_verb(t: &str) -> bool {
    let u = t.strip_prefix('!').unwrap_or(t);
    if let Some(r) = u.strip_prefix("//") {
        return !r.contains('/') && !r.contains(char::is_whitespace);
    }
    const V: [&str; 18] = ["fv", "filter-value", "ft", "filter-type", "at", "add-type", "rt", "remove-type", "s", "sort", "g", "group", "fts", "full-text-search", "bq", "base-query", "", ""];
    match u.strip_prefix('/') {
        Some(r) => V.iter().any(|v| !v.is_empty() && (r == *v || r.starts_with(&format!("{}/", v)))),
        None => false,
    }
}

/// The opposite of a base query, written out. Terms are ANDed, so the complement is "any term fails": exact for one term
/// (flip its `!`) and for several negated terms on the same keys (one positive `//keys a||b` term); otherwise every term is
/// flipped (an approximation, they stay ANDed). Other verbs are copied unchanged.
pub fn invert(q: &str) -> String {
    enum It {
        Other(String),
        Filt { neg: bool, keys: Option<String>, value: String },
    }
    let toks = tokens(q);
    let mut items: Vec<It> = Vec::new();
    let mut i = 0;
    while i < toks.len() {
        let t = &toks[i];
        let neg = t.starts_with('!');
        let u = if neg { &t[1..] } else { t.as_str() };
        let keys = u.strip_prefix("//").map(String::from).or_else(|| u.strip_prefix("/fv/").map(String::from)).or_else(|| u.strip_prefix("/filter-value/").map(String::from));
        if let Some(k) = keys.filter(|k| !k.is_empty() && k.chars().all(|c| c.is_ascii_lowercase() || c == ',' || c == '-')) {
            if i + 1 < toks.len() && !is_verb(&toks[i + 1]) {
                items.push(It::Filt { neg, keys: Some(k), value: toks[i + 1].clone() });
                i += 2;
                continue;
            }
            items.push(It::Other(t.clone()));
            i += 1;
            continue;
        }
        if is_verb(t) {
            let mut tx = t.clone();
            i += 1;
            if u.starts_with("/fts") || u.starts_with("/full-text-search") {
                while i < toks.len() && !is_verb(&toks[i]) {
                    tx.push(' ');
                    tx.push_str(&toks[i]);
                    i += 1;
                }
            }
            items.push(It::Other(tx));
            continue;
        }
        items.push(It::Filt { neg, keys: None, value: u.to_string() });
        i += 1;
    }
    let fs: Vec<(&bool, &Option<String>, &String)> = items.iter().filter_map(|x| if let It::Filt { neg, keys, value } = x { Some((neg, keys, value)) } else { None }).collect();
    if fs.is_empty() {
        return q.trim().to_string();
    }
    let merge = fs.len() > 1 && fs.iter().all(|f| *f.0 && f.1 == fs[0].1 && !f.2.contains('"'));
    let mut out: Vec<String> = Vec::new();
    let mut done = false;
    for x in &items {
        match x {
            It::Other(t) => out.push(t.clone()),
            It::Filt { neg, keys, value } => {
                if merge {
                    if !done {
                        done = true;
                        let vals: Vec<&str> = fs.iter().map(|f| f.2.as_str()).collect();
                        out.push(format!("{}{}", fs[0].1.as_ref().map(|k| format!("//{} ", k)).unwrap_or_default(), vals.join("||")));
                    }
                    continue;
                }
                out.push(format!("{}{}{}", if *neg { "" } else { "!" }, keys.as_ref().map(|k| format!("//{} ", k)).unwrap_or_default(), value));
            }
        }
    }
    out.join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn invert_cases() {
        assert_eq!(invert("!//path /src/a !//path /src/b"), "//path /src/a||/src/b");
        assert_eq!(invert("!//path /src/a"), "//path /src/a");
        assert_eq!(invert("//path a !//title b"), "!//path a //title b");
        assert_eq!(invert("foo !bar"), "!foo bar");
        assert_eq!(invert("!foo !bar"), "foo||bar");
        assert_eq!(invert("//title x /fts hello world //path y"), "!//title x /fts hello world !//path y");
    }
    #[test]
    fn cmd_and_effective() {
        assert_eq!(parse_cmd("/bq"), Some((false, false, String::new())));
        assert_eq!(parse_cmd("!/bq a b"), Some((true, true, "a b".into())));
        assert_eq!(parse_cmd("/bqx"), None);
        assert_eq!(effective("!//path x", "foo"), "!//path x foo");
        assert_eq!(effective("!//path x", "/bq foo"), "foo");
        assert_eq!(effective("", "foo"), "foo");
        assert!(is_disable_cmd(" /dbq ") && is_disable_cmd("/disable-base-query") && !is_disable_cmd("/dbq x") && !is_disable_cmd("/bq"));
    }
}
