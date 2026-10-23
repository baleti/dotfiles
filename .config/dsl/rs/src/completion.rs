//! Autocompletion (query-dsl.md "Autocompletion"): what the cursor is on, the candidates for it, how a
//! chosen candidate rewrites the query, and how a row of the popup reads. Ported from
//! WinSwitchQueryDsl.qml / WinSwitch.qml.
use crate::*;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CompKind {
    Verb,
    TypePath,
    BareValue,
    SortDirection,
    /// Ctrl+R: whole-line replace
    History,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Completion {
    pub kind: CompKind,
    /// char index where the replaced fragment starts
    pub start: usize,
    pub fragment: String,
    /// canonical verb (TypePath)
    pub verb: Option<String>,
    /// types a pending `/fv/keys` value is for; None = every type (the `/ft` value-glob fallback)
    pub fields: Option<Vec<String>>,
}

impl Completion {
    fn new(kind: CompKind, start: usize, fragment: &str) -> Completion {
        Completion { kind, start, fragment: fragment.to_string(), verb: None, fields: None }
    }
}

fn chars(s: &str) -> usize {
    s.chars().count()
}

/// The `/fv/keys` whose value is still pending after `context`, as its keys.
fn replay(schema: &Schema, context: &[Tok]) -> Option<String> {
    let mut open: Option<String> = None;
    for tok in context {
        if open.is_some() {
            open = None;
            if !schema.starts_command(tok) {
                continue; // the value is consumed
            }
        }
        if let Some(c) = schema.tok_verb(tok) {
            if !c.bad && c.verb == "fv" {
                if let Some(k) = c.keys.filter(|k| !k.replace(',', "").is_empty()) {
                    open = Some(k);
                }
            }
        }
    }
    open
}

pub fn all_paths(schema: &Schema) -> Vec<String> {
    schema.types.iter().filter(|t| !schema.hidden_types.contains(t)).cloned().collect()
}

pub fn completion_context(schema: &Schema, query: &str) -> Option<Completion> {
    let toks = tokenize(query);
    if toks.is_empty() {
        return None;
    }
    let trailing_space = query.chars().last().is_some_and(|c| c.is_whitespace());
    let (context, start, frag, lead): (&[Tok], usize, String, bool) = if trailing_space {
        (&toks, chars(query), String::new(), false)
    } else {
        let last = toks.last().unwrap();
        (&toks[..toks.len() - 1], last.start, last.text.clone(), last.lead_quote)
    };
    if lead {
        return None;
    }
    if let Some(rest) = frag.strip_prefix('/') {
        let parts: Vec<&str> = rest.split('/').collect();
        if parts.len() == 1 {
            return Some(Completion::new(CompKind::Verb, start, rest));
        }
        let verb = schema.canonical(parts[0])?;
        if parts.len() == 2 {
            let comma = parts[1].rfind(',');
            let key_frag = comma.map_or(parts[1], |c| &parts[1][c + 1..]);
            let via_start = start + 1 + chars(parts[0]) + 1 + comma.map_or(0, |c| chars(&parts[1][..c + 1]));
            if verb == "ft" && comma.is_none() && path_suggestions(schema, key_frag).is_empty() {
                return Some(Completion::new(CompKind::BareValue, via_start, key_frag));
            }
            let mut c = Completion::new(CompKind::TypePath, via_start, key_frag);
            c.verb = Some(verb);
            return Some(c);
        }
        if parts.len() == 3 && verb == "s" {
            return Some(Completion::new(CompKind::SortDirection, start + chars(&frag) - chars(parts[2]), parts[2]));
        }
        return None;
    }
    let keys = replay(schema, context)?;
    let mut c = Completion::new(CompKind::BareValue, start, &frag);
    c.fields = Some(schema.resolve_keys(&keys));
    Some(c)
}

pub fn path_suggestions(schema: &Schema, fragment: &str) -> Vec<String> {
    all_paths(schema).into_iter().filter(|n| substr(fragment, n, false)).collect()
}

/// Every verb-stage candidate: bare verbs, the app extras, then each key-taking verb crossed with every type.
pub fn verb_stage_universe(schema: &Schema) -> Vec<String> {
    let offered = |v: &&VerbDef| !schema.hidden_verbs.iter().any(|h| h == v.short);
    let mut out: Vec<String> = schema.verbs.iter().filter(offered).map(|v| v.short.to_string()).collect();
    out.extend(schema.extra_universe.iter().cloned());
    let paths = all_paths(schema);
    for v in schema.verbs.iter().filter(offered) {
        if matches!(v.kind, VerbKind::FilterValue | VerbKind::FilterType | VerbKind::AddType | VerbKind::RemoveType | VerbKind::Sort | VerbKind::Group) {
            for p in &paths {
                out.push(format!("{}/{}", v.short, p));
            }
        }
    }
    out
}

fn value_suggestions(src: &dyn Source, rows: usize, ty: &str, fragment: &str) -> Vec<String> {
    let mut seen: Vec<String> = vec![];
    for r in 0..rows {
        for v in src.values(r, ty) {
            if !v.is_empty() && substr(fragment, &v, false) && !seen.contains(&v) {
                seen.push(v);
            }
        }
    }
    seen.sort();
    seen
}

pub fn candidates(schema: &Schema, comp: &Completion, src: &dyn Source, rows: usize) -> Vec<String> {
    match comp.kind {
        CompKind::Verb => verb_stage_universe(schema).into_iter().filter(|v| substr(&comp.fragment, v, false)).collect(),
        CompKind::TypePath => {
            let verb = comp.verb.as_deref().unwrap_or("");
            if let Some((_, keys)) = schema.app_keys.iter().find(|(v, _)| v == verb) {
                return keys.iter().filter(|n| substr(&comp.fragment, n, false)).cloned().collect();
            }
            path_suggestions(schema, &comp.fragment)
        }
        CompKind::BareValue => {
            let fields = comp.fields.clone().unwrap_or_else(|| all_paths(schema));
            let mut seen: Vec<String> = vec![];
            for f in &fields {
                for v in value_suggestions(src, rows, f, &comp.fragment) {
                    if !seen.contains(&v) {
                        seen.push(v);
                    }
                }
            }
            seen.sort();
            seen
        }
        CompKind::SortDirection => ["asc", "desc"]
            .into_iter()
            .filter(|d| (if *d == "asc" { "ascending" } else { "descending" }).starts_with(&comp.fragment.to_lowercase()))
            .map(String::from)
            .collect(),
        CompKind::History => vec![],
    }
}

/// The query after accepting `chosen`.
pub fn accept(query: &str, comp: &Completion, chosen: &str) -> String {
    let prefix: String = query.chars().take(comp.start).collect();
    let quote = |c: &str| if c.chars().any(|x| x.is_whitespace()) { format!("\"{c}\"") } else { c.to_string() };
    match comp.kind {
        CompKind::Verb => format!("{prefix}/{chosen} "),
        CompKind::TypePath => {
            let space = matches!(comp.verb.as_deref(), Some("fv") | Some("fts"));
            format!("{prefix}{chosen}{}", if space { " " } else { "" })
        }
        CompKind::SortDirection => format!("{prefix}{chosen} "),
        CompKind::BareValue => format!("{prefix}{} ", quote(chosen)),
        CompKind::History => chosen.to_string(),
    }
}

/// A popup row: label, long-form alias, description.
pub fn row_info(schema: &Schema, kind: CompKind, item: &str) -> (String, String, String) {
    let desc_of = |name: &str| schema.type_descs.iter().find(|(n, _)| n == name).map(|(_, d)| d.clone());
    match kind {
        CompKind::Verb => {
            let (verb, path) = match item.split_once('/') {
                Some((v, p)) => (v, Some(p)),
                None => (item, None),
            };
            let def = schema.verbs.iter().find(|v| v.short == verb);
            // an app action offered as a verb (extra_universe) has no VerbDef: its text is in type_descs
            let (long, desc) = def.map_or((String::new(), desc_of(item).unwrap_or_default()), |d| (d.long.to_string(), d.desc.to_string()));
            let long = if long.is_empty() { String::new() } else { format!("/{long}") };
            let desc = path.and_then(desc_of).unwrap_or(desc);
            (format!("/{item}"), long, desc)
        }
        CompKind::TypePath => (item.to_string(), String::new(), desc_of(item).unwrap_or_default()),
        _ => (item.to_string(), String::new(), String::new()),
    }
}

/// Ctrl+R history: fzf-like ordered-subsequence match over the entries, most recent first.
pub fn history_candidates(entries_oldest_first: &[String], query: &str) -> Vec<String> {
    let q: Vec<char> = query.to_lowercase().chars().collect();
    entries_oldest_first
        .iter()
        .rev()
        .filter(|e| {
            let mut i = 0;
            for c in e.to_lowercase().chars() {
                if i < q.len() && c == q[i] {
                    i += 1;
                }
            }
            i == q.len()
        })
        .cloned()
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::Source;

    struct Rows(Vec<[&'static str; 2]>);
    impl Source for Rows {
        fn value(&self, row: usize, ty: &str) -> String {
            match ty {
                "title" => self.0[row][0],
                "workspace" => self.0[row][1],
                _ => "",
            }
            .to_string()
        }
        fn haystack(&self, row: usize) -> String {
            self.0[row].join(" ")
        }
    }

    fn schema() -> Schema {
        Schema::new(&["title", "workspace", "tmux-title"], vec![])
    }

    #[test]
    fn stages() {
        let s = schema();
        let c = completion_context(&s, "brave /fv/wo").unwrap();
        assert_eq!((c.kind, c.start, c.fragment.as_str()), (CompKind::TypePath, 10, "wo"));
        assert_eq!(accept("brave /fv/wo", &c, "workspace"), "brave /fv/workspace ");
        let c = completion_context(&s, "/s/title,wo").unwrap();
        assert_eq!((c.start, c.fragment.as_str()), (9, "wo"));
        assert_eq!(accept("/s/title,wo", &c, "workspace"), "/s/title,workspace");
        let c = completion_context(&s, "/s/title/a").unwrap();
        assert_eq!(c.kind, CompKind::SortDirection);
        assert_eq!(candidates(&s, &c, &Rows(vec![]), 0), vec!["asc"]);
        assert_eq!(completion_context(&s, "\"/f"), None);
        assert_eq!(completion_context(&s, ""), None);
    }

    #[test]
    fn verb_stage_depth_and_values() {
        let s = schema();
        let c = completion_context(&s, "/wo").unwrap();
        let cand = candidates(&s, &c, &Rows(vec![]), 0);
        assert!(cand.contains(&"fv/workspace".to_string()) && !cand.contains(&"fv".to_string()));
        let rows = Rows(vec![["Brave", "2"], ["Alacritty", "1"], ["Brave dev", "2"]]);
        let c = completion_context(&s, "/fv/title br").unwrap();
        assert_eq!(c.kind, CompKind::BareValue);
        assert_eq!(candidates(&s, &c, &rows, 3), vec!["Brave", "Brave dev"]);
        assert_eq!(accept("/fv/title br", &c, "Brave dev"), "/fv/title \"Brave dev\" ");
    }

    #[test]
    fn history_is_subsequence_most_recent_first() {
        let h: Vec<String> = ["/s/title", "brave", "/fv/workspace 2"].iter().map(|s| s.to_string()).collect();
        assert_eq!(history_candidates(&h, "fvw"), vec!["/fv/workspace 2"]);
        assert_eq!(history_candidates(&h, ""), vec!["/fv/workspace 2", "brave", "/s/title"]);
    }
}
