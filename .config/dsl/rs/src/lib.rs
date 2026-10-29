//! The picker query DSL's primitives and engine (query-dsl.md). Mirrors `~/.config/dsl/dsl.py`; every
//! function here is checked against the shared vectors in `~/.config/dsl/tests.json`.
#![allow(dead_code)]

#[path = "../../group.rs"]
pub mod group;

pub mod completion;
pub mod engine;
pub use completion::*;
pub use engine::*;

#[derive(Clone, Debug, PartialEq)]
pub struct Tok {
    pub text: String,
    pub lead_quote: bool,
    pub quoted: bool,
    pub neg: bool,
    /// char index of the first character (the opening quote included, never the `!`)
    pub start: usize,
}

/// Whitespace-split; a quoted run stays whole with the quote characters dropped; a leading `!` is
/// carried as `neg`. `'` opens a quote only at the start of a token.
pub fn tokenize(q: &str) -> Vec<Tok> {
    let mut out = vec![];
    let mut cur = String::new();
    let (mut start, mut lead, mut in_q, mut qc, mut quoted, mut neg) = (None::<usize>, false, false, '\0', false, false);
    for (i, c) in q.chars().enumerate() {
        if c == '!' && start.is_none() && !neg {
            neg = true;
            continue;
        }
        let opens = c == '"' || (c == '\'' && start.is_none());
        if if in_q { c == qc } else { opens } {
            if start.is_none() {
                lead = true;
            }
            if !in_q {
                qc = c;
            } else {
                quoted = true;
            }
            in_q = !in_q;
            start.get_or_insert(i);
            continue;
        }
        if c.is_whitespace() && !in_q {
            if let Some(s) = start.take() {
                out.push(Tok { text: std::mem::take(&mut cur), lead_quote: lead, quoted, neg, start: s });
                lead = false;
                quoted = false;
            }
            neg = false;
            continue;
        }
        start.get_or_insert(i);
        cur.push(c);
    }
    if let Some(s) = start {
        out.push(Tok { text: cur, lead_quote: lead, quoted, neg, start: s });
    }
    out
}

/// Whitespace split that keeps the quotes in the tokens.
pub fn split_raw(q: &str) -> Vec<String> {
    let (mut out, mut cur, mut in_q) = (vec![], String::new(), false);
    for ch in q.chars() {
        if ch == '"' {
            in_q = !in_q;
            cur.push(ch);
        } else if ch.is_whitespace() && !in_q {
            if !cur.is_empty() {
                out.push(std::mem::take(&mut cur));
            }
        } else {
            cur.push(ch);
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

fn is_word(c: Option<&char>) -> bool {
    c.is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == '_')
}

/// Index of the first match of `needle` in `hay` (case-insensitive); with `exact` (a quoted term) the
/// match must stand alone: no word character directly before or after it.
pub fn substr_idx(needle: &str, hay: &str, exact: bool) -> Option<usize> {
    let n: Vec<char> = needle.to_lowercase().chars().collect();
    let h: Vec<char> = hay.to_lowercase().chars().collect();
    if n.is_empty() {
        return Some(0);
    }
    if n.len() > h.len() {
        return None;
    }
    let (lead, trail) = (is_word(n.first()), is_word(n.last()));
    (0..=h.len() - n.len()).find(|&i| {
        h[i..i + n.len()] == n[..] && (!exact || (!(lead && i > 0 && is_word(h.get(i - 1))) && !(trail && is_word(h.get(i + n.len())))))
    })
}

/// `a||b` -> ["a", "b"] (empty parts dropped; none left -> [""], the empty needle). A quoted term is literal.
pub fn alternatives(needle: &str, exact: bool) -> Vec<&str> {
    if exact || !needle.contains("||") {
        return vec![needle];
    }
    let a: Vec<&str> = needle.split("||").filter(|x| !x.is_empty()).collect();
    if a.is_empty() { vec![""] } else { a }
}

/// Substring test; an unquoted `a||b` needle matches when any alternative does.
pub fn substr(needle: &str, hay: &str, exact: bool) -> bool {
    alternatives(needle, exact).iter().any(|a| substr_idx(a, hay, exact).is_some())
}

/// Keys: a comma list; per key the name equal to it wins alone, else every name containing it;
/// unioned, in `known` order. Case-insensitive; empty keys skipped.
pub fn resolve_names(keys: &str, known: &[String]) -> Vec<String> {
    let mut hit = vec![false; known.len()];
    for key in keys.to_lowercase().split(',') {
        if key.is_empty() {
            continue;
        }
        let exact: Vec<usize> = (0..known.len()).filter(|&i| known[i].to_lowercase() == key).collect();
        let idx = if exact.is_empty() { (0..known.len()).filter(|&i| known[i].to_lowercase().contains(key)).collect() } else { exact };
        for i in idx {
            hit[i] = true;
        }
    }
    known.iter().zip(hit).filter(|(_, h)| *h).map(|(n, _)| n.clone()).collect()
}

/// The ordered sort keys a `/s/key,key` chain resolves to (fuzzy keys expand alphabetically,
/// duplicates dropped); None when any key names nothing.
pub fn resolve_sort_keys(keys: &[&str], known: &[String]) -> Option<Vec<String>> {
    let mut out: Vec<String> = vec![];
    for key in keys {
        let mut r = resolve_names(key, known);
        r.sort();
        if r.is_empty() {
            return None;
        }
        for n in r {
            if !out.contains(&n) {
                out.push(n);
            }
        }
    }
    Some(out)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Dir {
    Asc,
    Desc,
}

impl Dir {
    pub fn word(self) -> &'static str {
        match self {
            Dir::Asc => "asc",
            Dir::Desc => "desc",
        }
    }
}

/// Any non-empty prefix of ascending / descending.
pub fn parse_direction(word: &str) -> Option<Dir> {
    let t = word.to_lowercase();
    if t.is_empty() {
        None
    } else if "ascending".starts_with(&t) {
        Some(Dir::Asc)
    } else if "descending".starts_with(&t) {
        Some(Dir::Desc)
    } else {
        None
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Cmd {
    pub verb: String,
    pub keys: Option<String>,
    pub dir: Option<String>,
    pub bad: bool,
}

/// `/verb/keys[/dir]` or `//keys` -> the command, or None when the token names no verb. `verbs`:
/// spelling -> canonical (the empty spelling is the default verb of `//keys`); `max_parts`: canonical
/// -> n (default 2).
pub fn split_cmd(text: &str, verbs: &[(String, String)], max_parts: &[(String, usize)]) -> Option<Cmd> {
    let rest = text.strip_prefix('/')?;
    let parts: Vec<&str> = rest.split('/').collect();
    let spelling = if parts[0].is_empty() && parts.len() < 2 { return None } else { parts[0] };
    let verb = verbs.iter().find(|(s, _)| s == spelling)?.1.clone();
    let limit = max_parts.iter().find(|(v, _)| *v == verb).map(|(_, n)| *n).unwrap_or(2);
    Some(Cmd {
        keys: parts.get(1).map(|s| s.to_string()),
        dir: if parts.len() == 3 { Some(parts[2].to_string()) } else { None },
        bad: parts.len() > limit,
        verb,
    })
}

fn digits(s: &str) -> bool {
    !s.is_empty() && s.chars().all(|c| c.is_ascii_digit())
}

fn age_secs(s: &str) -> Option<i64> {
    let (n, u) = s.split_at(s.len().checked_sub(1)?);
    if !digits(n) {
        return None;
    }
    let k = match u {
        "s" => 1,
        "m" => 60,
        "h" => 3600,
        "d" => 86400,
        _ => return None,
    };
    Some(n.parse::<i64>().ok()? * k)
}

/// Sort comparison: plain ints numerically, age buckets (30s/5m/3h/2d) by seconds with the direction
/// inverted, else case-insensitive lexicographic. Negative / zero / positive like cmp.
pub fn compare_field_values(a: &str, b: &str, dir: Dir) -> i64 {
    let c: i64 = if digits(a) && digits(b) {
        match (a.parse::<i128>(), b.parse::<i128>()) {
            (Ok(x), Ok(y)) => (x - y).signum() as i64,
            _ => 0,
        }
    } else {
        if let (Some(x), Some(y)) = (age_secs(a), age_secs(b)) {
            let c = y - x;
            return if dir == Dir::Asc { c } else { -c };
        }
        match a.to_lowercase().cmp(&b.to_lowercase()) {
            std::cmp::Ordering::Less => -1,
            std::cmp::Ordering::Equal => 0,
            std::cmp::Ordering::Greater => 1,
        }
    };
    if dir == Dir::Desc { -c } else { c }
}

#[cfg(test)]
mod conformance {
    use super::*;

    fn vectors() -> serde_json::Value {
        let path = std::env::var("HOME").unwrap() + "/.config/dsl/tests.json";
        serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
    }
    fn strs(v: &serde_json::Value) -> Vec<String> {
        v.as_array().unwrap().iter().map(|x| x.as_str().unwrap().to_string()).collect()
    }

    #[test]
    fn resolve() {
        for c in vectors()["resolve"].as_array().unwrap() {
            assert_eq!(resolve_names(c["keys"].as_str().unwrap(), &strs(&c["names"])), strs(&c["expect"]), "keys {}", c["keys"]);
        }
    }

    #[test]
    fn sortkeys() {
        for c in vectors()["sortkeys"].as_array().unwrap() {
            let keys = strs(&c["keys"]);
            let k: Vec<&str> = keys.iter().map(|s| s.as_str()).collect();
            let want = if c["expect"].is_null() { None } else { Some(strs(&c["expect"])) };
            assert_eq!(resolve_sort_keys(&k, &strs(&c["names"])), want, "keys {}", c["keys"]);
        }
    }

    #[test]
    fn direction() {
        for c in vectors()["direction"].as_array().unwrap() {
            let want = c["expect"].as_str();
            assert_eq!(parse_direction(c["word"].as_str().unwrap()).map(|d| d.word()), want, "word {}", c["word"]);
        }
    }

    #[test]
    fn splitcmd() {
        let t = vectors();
        let sc = &t["splitcmd"];
        let verbs: Vec<(String, String)> = sc["verbs"].as_object().unwrap().iter().map(|(k, v)| (k.clone(), v.as_str().unwrap().to_string())).collect();
        let mp: Vec<(String, usize)> = sc["maxParts"].as_object().unwrap().iter().map(|(k, v)| (k.clone(), v.as_u64().unwrap() as usize)).collect();
        for c in sc["cases"].as_array().unwrap() {
            let got = split_cmd(c["text"].as_str().unwrap(), &verbs, &mp);
            if c["expect"].is_null() {
                assert!(got.is_none(), "text {}", c["text"]);
            } else {
                let e = c["expect"].as_array().unwrap();
                let g = got.unwrap_or_else(|| panic!("text {}", c["text"]));
                assert_eq!(g.verb, e[0].as_str().unwrap());
                assert_eq!(g.keys.as_deref(), e[1].as_str());
                assert_eq!(g.dir.as_deref(), e[2].as_str());
                assert_eq!(g.bad, e[3].as_bool().unwrap(), "text {}", c["text"]);
            }
        }
    }

    #[test]
    fn tokenize_vectors() {
        for c in vectors()["tokenize"].as_array().unwrap() {
            let got: Vec<serde_json::Value> = tokenize(c["query"].as_str().unwrap())
                .into_iter()
                .map(|k| serde_json::json!([k.text, k.lead_quote, k.quoted, k.neg, k.start]))
                .collect();
            assert_eq!(serde_json::Value::Array(got), c["expect"], "query {}", c["query"]);
        }
    }

    #[test]
    fn splitraw() {
        for c in vectors()["splitraw"].as_array().unwrap() {
            assert_eq!(split_raw(c["query"].as_str().unwrap()), strs(&c["expect"]), "query {}", c["query"]);
        }
    }

    #[test]
    fn substr_vectors() {
        for c in vectors()["substr"].as_array().unwrap() {
            assert_eq!(substr(c["needle"].as_str().unwrap(), c["hay"].as_str().unwrap(), c["exact"].as_bool().unwrap()), c["expect"].as_bool().unwrap());
        }
    }

    #[test]
    fn compare() {
        for c in vectors()["compare"].as_array().unwrap() {
            let dir = parse_direction(c["dir"].as_str().unwrap()).unwrap();
            let got = compare_field_values(c["a"].as_str().unwrap(), c["b"].as_str().unwrap(), dir).signum();
            assert_eq!(got, c["sign"].as_i64().unwrap().signum(), "{c}");
        }
    }

    struct PipeRows<'a> {
        rows: &'a [serde_json::Value],
        hay: Vec<String>,
    }
    impl Source for PipeRows<'_> {
        fn value(&self, row: usize, ty: &str) -> String {
            self.rows[row][ty].as_str().unwrap_or("").to_string()
        }
        fn haystack(&self, row: usize) -> String {
            self.hay.iter().map(|f| self.value(row, f)).collect::<Vec<_>>().join(" ")
        }
    }

    #[test]
    fn pipeline() {
        let v = vectors();
        let p = &v["pipeline"];
        let mut schema = Schema::new(&strs(&p["schema"]["types"]).iter().map(|s| s.as_str()).collect::<Vec<_>>(), vec![]);
        for a in p["schema"]["appVerbs"].as_array().unwrap() {
            let short: &'static str = Box::leak(a[0].as_str().unwrap().to_string().into_boxed_str());
            schema.verbs.push(VerbDef { short, long: "", kind: VerbKind::App { takes_arg: a[2].as_bool().unwrap() }, max_parts: 2, desc: "" });
        }
        schema.exact_types = strs(&p["schema"]["exact"]);
        let rows = p["rows"].as_array().unwrap();
        let src = PipeRows { rows, hay: strs(&p["hay"]) };
        for c in p["cases"].as_array().unwrap() {
            let q = c["query"].as_str().unwrap();
            let parsed = parse(&schema, q);
            let ids: Vec<String> = select_rows(&schema, &parsed, &src, rows.len()).iter().map(|&r| rows[r]["id"].as_str().unwrap().to_string()).collect();
            assert_eq!(ids.concat(), strs(&c["ids"]).concat(), "ids {q}");
            assert_eq!(active_columns(&schema, &parsed, &strs(&p["defaults"]), &src, rows.len()), strs(&c["cols"]), "cols {q}");
            let apps: Vec<serde_json::Value> = parsed.apps.iter().map(|a| serde_json::json!([a.verb, a.keys, a.arg, a.neg])).collect();
            assert_eq!(serde_json::Value::Array(apps), c["apps"], "apps {q}");
            let g = parsed.group_raw.map(serde_json::Value::from).unwrap_or(serde_json::Value::Null);
            assert_eq!(g, c["group"], "group {q}");
        }
    }
}
