//! /group (/g) primitives for the Rust consumers: the same semantics as dsl.py / dsl.js
//! (parse_group, group_value, group_layout, group_visible, extract_group), proven by the shared vectors in
//! tests.json. Dependency-free; include it with
//! `#[path = "../../../../.config/dsl/group.rs"] mod group;` (path relative to the including file).
//! A raw epoch-seconds date is read as UTC here (the Python/JS twins read it as local time); the Rust
//! pickers hand over ISO strings, so the difference never shows.
#![allow(dead_code)]
use std::collections::{HashMap, HashSet};

const BUCKETS: [&str; 6] = ["pf", "parent-folder", "day", "week", "month", "year"];
const DATE_BUCKETS: [&str; 4] = ["day", "week", "month", "year"];

#[derive(Clone, Debug, PartialEq)]
pub struct Spec { pub name: String, pub bucket: String, pub level: usize }
#[derive(Clone, Debug, PartialEq)]
pub struct Parsed { pub specs: Vec<Spec>, pub desc: bool }
/// A laid-out entry: a group header or the index of a row.
#[derive(Clone, Debug, PartialEq)]
pub enum Entry { Header { depth: usize, id: String, label: String, count: usize }, Row(usize) }

pub fn kind(name: &str) -> &'static str {
    let n = name.to_lowercase();
    if n.contains("size") { "size" }
    else if n == "age" || n.ends_with("-age") { "age" }
    else if n == "dm" || ["date", "modified", "created", "mtime", "time", "when", "deadline", "scheduled"].iter().any(|w| n.contains(w)) { "date" }
    else if n.contains("path") || ["dir", "directory", "folder", "cwd", "remote"].contains(&n.as_str()) { "path" }
    else { "value" }
}

fn direction(word: &str) -> Option<bool> {
    let t = word.to_lowercase();
    if t.is_empty() { None } else if "ascending".starts_with(&t) { Some(false) } else if "descending".starts_with(&t) { Some(true) } else { None }
}

fn resolve_names(key: &str, known: &[&str]) -> Vec<String> {
    let k = key.to_lowercase();
    if k.is_empty() { return vec![]; }
    let exact: Vec<String> = known.iter().filter(|n| n.to_lowercase() == k).map(|n| n.to_string()).collect();
    if !exact.is_empty() { return exact; }
    known.iter().filter(|n| n.to_lowercase().contains(&k)).map(|n| n.to_string()).collect()
}

fn sort_keys(key: &str, known: &[&str]) -> Vec<String> {
    let mut r = resolve_names(key, known);
    r.sort();
    r
}

pub fn parse_group(text: &str, known: &[&str], aliases: &[(&str, &str)]) -> Option<Parsed> {
    let parts: Vec<&str> = text.split('/').collect();
    if parts.len() < 3 || !parts[0].is_empty() || !(parts[1] == "g" || parts[1] == "group") || parts[2].replace(',', "").is_empty() { return None; }
    let (mut bucket, mut level, mut dir): (Option<String>, Option<usize>, Option<bool>) = (None, None, None);
    for p in &parts[3..] {
        let low = p.to_lowercase();
        if BUCKETS.contains(&low.as_str()) {
            if bucket.is_some() { return None; }
            bucket = Some(if low == "parent-folder" { "pf".into() } else { low });
        } else if !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()) {
            let n: usize = p.parse().ok()?;
            if level.is_some() || n < 1 { return None; }
            level = Some(n);
        } else if let (Some(d), true) = (direction(p), dir.is_none()) {
            dir = Some(d);
        } else { return None; }
    }
    let (mut names, mut alias_pf): (Vec<String>, HashSet<String>) = (vec![], HashSet::new());
    for key in parts[2].split(',') {
        if key.is_empty() { continue; }
        let low = key.to_lowercase();
        let r: Vec<String> = if low == "pf" || low == "parent-folder" {
            let r: Vec<String> = sort_keys("path", known).into_iter().filter(|n| kind(n) == "path").take(1).collect();
            alias_pf.extend(r.iter().cloned());
            r
        } else if let Some((_, t)) = aliases.iter().find(|(a, t)| *a == low && known.contains(t)) {
            vec![t.to_string()]
        } else { sort_keys(key, known) };
        if r.is_empty() { return None; }
        for n in r { if !names.contains(&n) { names.push(n); } }
    }
    let mut specs = Vec::new();
    for n in names {
        let k = kind(&n);
        let b = if (alias_pf.contains(&n) || bucket.as_deref() == Some("pf")) && k == "path" { "pf".to_string() }
            else if k == "date" && bucket.as_deref().map_or(false, |b| DATE_BUCKETS.contains(&b)) { bucket.clone().unwrap() }
            else { match k { "date" => "day", "size" => "size", "age" => "age", _ => "value" }.to_string() };
        specs.push(Spec { name: n, bucket: b, level: level.unwrap_or(1) });
    }
    if let Some(b) = &bucket { if !specs.iter().any(|s| &s.bucket == b) { return None; } }
    if level.is_some() && !specs.iter().any(|s| s.bucket == "pf") { return None; }
    Some(Parsed { specs, desc: dir.unwrap_or(true) })
}

fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5 + d - 1;
    era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468
}
fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = mp + if mp < 10 { 3 } else { -9 };
    (y + (m <= 2) as i64, m, d)
}
fn ymd(raw: &str) -> Option<(i64, i64, i64)> {
    let s = raw.trim();
    let b = s.as_bytes();
    let dig = |r: std::ops::Range<usize>| -> Option<i64> { s.get(r).filter(|t| t.bytes().all(|c| c.is_ascii_digit())).and_then(|t| t.parse().ok()) };
    if b.len() >= 10 && b[4] == b'-' && b[7] == b'-' {
        if let (Some(y), Some(m), Some(d)) = (dig(0..4), dig(5..7), dig(8..10)) { return Some((y, m, d)); }
    }
    let int = s.split('.').next().unwrap_or("");
    if (9..=11).contains(&int.len()) && int.bytes().all(|c| c.is_ascii_digit()) && s[int.len()..].bytes().all(|c| c == b'.' || c.is_ascii_digit()) {
        return Some(civil_from_days(int.parse::<i64>().ok()?.div_euclid(86400)));
    }
    None
}
const MONTHS: [&str; 12] = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
const SIZE_EDGES: [(f64, &str); 8] = [(1024.0, "< 1 KB"), (10240.0, "1 - 10 KB"), (102400.0, "10 - 100 KB"), (1048576.0, "100 KB - 1 MB"),
    (10485760.0, "1 - 10 MB"), (104857600.0, "10 - 100 MB"), (1073741824.0, "100 MB - 1 GB"), (10737418240.0, "1 - 10 GB")];
const AGE_EDGES: [(i64, &str); 4] = [(3600, "Last hour"), (86400, "Last day"), (604800, "Last week"), (2592000, "Last month")];

fn size_bytes(raw: &str) -> Option<f64> {
    let s = raw.trim().to_lowercase();
    let split = s.find(|c: char| !(c.is_ascii_digit() || c == '.')).unwrap_or(s.len());
    let (num, unit) = (&s[..split], s[split..].trim());
    if num.is_empty() || num.starts_with('.') || num.ends_with('.') || num.matches('.').count() > 1 { return None; }
    let unit = unit.strip_suffix('b').unwrap_or(unit);
    let unit = unit.strip_suffix('i').unwrap_or(unit);
    let mult = match unit { "" => 1.0, "k" => 1024.0, "m" => 1048576.0, "g" => 1073741824.0, "t" => 1099511627776.0, _ => return None };
    Some(num.parse::<f64>().ok()? * mult)
}

/// (sort key, label) of the group `raw` falls in; today = "YYYY-MM-DD". Key "" = the (none) group.
pub fn group_value(spec: &Spec, raw: &str, today: &str) -> (String, String) {
    let none = || (String::new(), "(none)".to_string());
    match spec.bucket.as_str() {
        "pf" => {
            let t = raw.trim_end_matches('/');
            let mut dirs: Vec<&str> = t.split('/').collect();
            dirs.pop();
            if raw.is_empty() || dirs.is_empty() { return none(); }
            let keep = dirs.len().saturating_sub(spec.level - 1).max(1);
            let l = dirs[..keep].join("/");
            let l = if l.is_empty() { "/".to_string() } else { l };
            (l.clone(), l)
        }
        "day" | "week" | "month" | "year" => {
            let Some((y, m, d)) = ymd(raw) else { return none() };
            let Some((ty, tm, td)) = ymd(today) else { return none() };
            let (dn, tn) = (days_from_civil(y, m, d), days_from_civil(ty, tm, td));
            match spec.bucket.as_str() {
                "day" => { let k = format!("{y:04}-{m:02}-{d:02}"); let l = if dn == tn { "Today".into() } else if dn == tn - 1 { "Yesterday".into() } else { k.clone() }; (k, l) }
                "week" => {
                    let (ws, tws) = (dn - (dn + 3).rem_euclid(7), tn - (tn + 3).rem_euclid(7));
                    let (cy, cm, cd) = civil_from_days(ws);
                    let k = format!("{cy:04}-{cm:02}-{cd:02}");
                    let l = if ws == tws { "This week".into() } else if ws == tws - 7 { "Last week".into() } else { format!("Week of {k}") };
                    (k, l)
                }
                "month" => { let k = format!("{y:04}-{m:02}"); let l = if (y, m) == (ty, tm) { "This month".into() } else { format!("{} {y}", MONTHS[(m - 1) as usize]) }; (k, l) }
                _ => { let k = format!("{y:04}"); let l = if y == ty { "This year".into() } else { k.clone() }; (k, l) }
            }
        }
        "size" => {
            let Some(n) = size_bytes(raw) else { return none() };
            for (i, (edge, label)) in SIZE_EDGES.iter().enumerate() { if n < *edge { return (i.to_string(), label.to_string()); } }
            (SIZE_EDGES.len().to_string(), "10 GB or more".into())
        }
        "age" => {
            let (num, unit) = raw.split_at(raw.len().saturating_sub(1));
            let mult = match unit { "s" => 1, "m" => 60, "h" => 3600, "d" => 86400, _ => return none() };
            let Ok(n) = num.parse::<i64>() else { return none() };
            if num.is_empty() || !num.bytes().all(|c| c.is_ascii_digit()) { return none(); }
            let sec = n * mult;
            for (i, (edge, label)) in AGE_EDGES.iter().enumerate() { if sec < *edge { return (i.to_string(), label.to_string()); } }
            (AGE_EDGES.len().to_string(), "Older".into())
        }
        _ => if raw.is_empty() { none() } else { (raw.to_string(), raw.to_string()) },
    }
}

fn age_secs(s: &str) -> Option<i64> {
    let (num, unit) = s.split_at(s.len().checked_sub(1)?);
    if num.is_empty() || !num.bytes().all(|c| c.is_ascii_digit()) { return None; }
    Some(num.parse::<i64>().ok()? * match unit { "s" => 1, "m" => 60, "h" => 3600, "d" => 86400, _ => return None })
}
/// Sort comparison (query-dsl.md "Sort comparison, precisely"): ints numerically, age buckets by seconds
/// (direction inverted), else case-insensitive lexicographic.
pub fn compare_field_values(a: &str, b: &str, desc: bool) -> std::cmp::Ordering {
    use std::cmp::Ordering;
    let isint = |s: &str| !s.is_empty() && s.bytes().all(|c| c.is_ascii_digit());
    let ord = if isint(a) && isint(b) {
        let (x, y) = (a.trim_start_matches('0'), b.trim_start_matches('0'));
        x.len().cmp(&y.len()).then(x.cmp(y))
    } else if let (Some(x), Some(y)) = (age_secs(a), age_secs(b)) {
        return if desc { x.cmp(&y) } else { y.cmp(&x) };
    } else { a.to_lowercase().cmp(&b.to_lowercase()) };
    if desc { ord.reverse() } else { ord }
}

/// Rows (already filtered and ordered) -> headers + rows. `get(row, name)` is the raw value.
pub fn group_layout(n_rows: usize, parsed: &Parsed, get: &dyn Fn(usize, &str) -> String, today: &str) -> Vec<Entry> {
    use std::cmp::Ordering;
    fn build(idxs: Vec<usize>, depth: usize, prefix: &str, p: &Parsed, get: &dyn Fn(usize, &str) -> String, today: &str, out: &mut Vec<Entry>) {
        let spec = &p.specs[depth];
        let mut order: Vec<String> = Vec::new();
        let mut groups: HashMap<String, (String, Vec<usize>)> = HashMap::new();
        for i in idxs {
            let (k, l) = group_value(spec, &get(i, &spec.name), today);
            if !groups.contains_key(&k) { order.push(k.clone()); }
            groups.entry(k).or_insert((l, vec![])).1.push(i);
        }
        let (mut full, none): (Vec<String>, Vec<String>) = order.into_iter().partition(|k| !k.is_empty());
        full.sort_by(|a, b| {
            if spec.bucket == "value" { return compare_field_values(a, b, p.desc); }
            let c = a.cmp(b);
            if p.desc != (spec.bucket == "age") { c.reverse() } else { c }
        });
        for k in full.into_iter().chain(none) {
            let (label, members) = groups.remove(&k).unwrap();
            let id = if prefix.is_empty() { label.clone() } else { format!("{prefix}\u{1f}{label}") };
            out.push(Entry::Header { depth, id: id.clone(), label, count: members.len() });
            if depth + 1 < p.specs.len() { build(members, depth + 1, &id, p, get, today, out); }
            else { out.extend(members.into_iter().map(Entry::Row)); }
        }
    }
    let mut out = Vec::new();
    let _ = Ordering::Equal;
    build((0..n_rows).collect(), 0, "", parsed, get, today, &mut out);
    out
}

/// The layout minus everything inside a collapsed header (the header stays).
pub fn group_visible(layout: &[Entry], collapsed: &HashSet<String>) -> Vec<Entry> {
    let (mut out, mut hide): (Vec<Entry>, Option<usize>) = (vec![], None);
    for e in layout {
        match e {
            Entry::Header { depth, id, .. } => {
                if hide.map_or(false, |h| *depth > h) { continue; }
                hide = if collapsed.contains(id) { Some(*depth) } else { None };
                out.push(e.clone());
            }
            Entry::Row(_) => if hide.is_none() { out.push(e.clone()); },
        }
    }
    out
}

fn owns_next(tok: &str) -> bool {
    let t = tok.trim_start_matches('!');
    if t.starts_with("//") && t.len() > 2 { return true; }
    let p: Vec<&str> = t.split('/').collect();
    p.len() == 3 && p[0].is_empty() && (p[1] == "fv" || p[1] == "filter-value") && !p[2].is_empty()
}

/// Pipeline hook: pull the /g command out of a token list (position-independent, last valid wins, a token
/// owned as another command's value is never read as /g, an inert /g is dropped).
pub fn extract_group(tokens: &[String], known: &[&str], aliases: &[(&str, &str)]) -> (Vec<String>, Option<Parsed>) {
    let (mut rest, mut parsed, mut i) = (Vec::new(), None, 0);
    while i < tokens.len() {
        let t = &tokens[i];
        i += 1;
        if owns_next(t) {
            rest.push(t.clone());
            if i < tokens.len() { rest.push(tokens[i].clone()); i += 1; }
            continue;
        }
        let bare: Vec<&str> = t.split('/').collect();
        if bare.len() >= 2 && bare[0].is_empty() && (bare[1] == "g" || bare[1] == "group") && !t.starts_with('!') {
            if let Some(p) = parse_group(t, known, aliases) { parsed = Some(p); }
            continue;
        }
        rest.push(t.clone());
    }
    (rest, parsed)
}
