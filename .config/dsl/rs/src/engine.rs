//! The schema-driven engine over the primitives: parse a query into its three axes (row filters, column
//! operations, sort) plus the view transform (`/g`) and any app-owned verbs, then evaluate them against
//! rows. A picker supplies a `Schema` (its type vocabulary and verbs) and a `Source` (the row values).
//! Ported from WinSwitchQueryDsl.qml; semantics in query-dsl.md.
use crate::*;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VerbKind {
    FilterValue,
    FilterType,
    AddType,
    RemoveType,
    Sort,
    Group,
    /// an app-owned verb (`/fts`, `/sw`): parsed into `Parsed::apps`, interpreted by the picker
    App { takes_arg: bool },
}

#[derive(Clone, Debug)]
pub struct VerbDef {
    pub short: &'static str,
    pub long: &'static str,
    pub kind: VerbKind,
    pub max_parts: usize,
}

pub fn core_verbs() -> Vec<VerbDef> {
    use VerbKind::*;
    let v = |short, long, kind, max_parts| VerbDef { short, long, kind, max_parts };
    vec![
        v("fv", "filter-value", FilterValue, 2),
        v("ft", "filter-type", FilterType, 2),
        v("at", "add-type", AddType, 2),
        v("rt", "remove-type", RemoveType, 2),
        v("s", "sort", Sort, 3),
        v("g", "group", Group, 4),
    ]
}

#[derive(Clone, Debug)]
pub struct Schema {
    /// every type name, flat (`title`, `tmux-session`, ...), in display order
    pub types: Vec<String>,
    pub verbs: Vec<VerbDef>,
    /// types compared exactly rather than by substring (a count: "3" means 3, not 13)
    pub exact_types: Vec<String>,
}

impl Schema {
    pub fn new(types: &[&str], extra_verbs: Vec<VerbDef>) -> Schema {
        let mut verbs = core_verbs();
        verbs.extend(extra_verbs);
        Schema { types: types.iter().map(|s| s.to_string()).collect(), verbs, exact_types: vec![] }
    }

    fn spellings(&self) -> Vec<(String, String)> {
        let mut m = vec![(String::new(), "fv".to_string())];
        for v in &self.verbs {
            m.push((v.short.to_string(), v.short.to_string()));
            if !v.long.is_empty() {
                m.push((v.long.to_string(), v.short.to_string()));
            }
        }
        m
    }

    fn max_parts(&self) -> Vec<(String, usize)> {
        self.verbs.iter().map(|v| (v.short.to_string(), v.max_parts)).collect()
    }

    pub fn kind_of(&self, canonical: &str) -> Option<VerbKind> {
        self.verbs.iter().find(|v| v.short == canonical).map(|v| v.kind)
    }

    /// `/verb...` parsed as a command; lead-quoted tokens are never commands.
    pub fn tok_verb(&self, tok: &Tok) -> Option<Cmd> {
        if tok.lead_quote {
            return None;
        }
        split_cmd(&tok.text, &self.spellings(), &self.max_parts())
    }

    /// Whether `s` (text after the slash) is a prefix of some verb spelling ("/" alone is one of every verb).
    pub fn is_verb_prefix(&self, s: &str) -> bool {
        self.verbs.iter().any(|v| v.short.starts_with(s) || (!v.long.is_empty() && v.long.starts_with(s)))
    }

    pub fn starts_command(&self, tok: &Tok) -> bool {
        if tok.lead_quote || !tok.text.starts_with('/') {
            return false;
        }
        let rest = &tok.text[1..];
        let name = rest.split('/').next().unwrap_or("");
        name.is_empty() && rest.contains('/') || self.spellings().iter().any(|(s, _)| s == name) || self.is_verb_prefix(rest)
    }

    pub fn resolve_keys(&self, keys: &str) -> Vec<String> {
        resolve_names(keys, &self.types)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Term {
    /// bare text: searched in the row's free-text haystack
    Free { text: String, exact: bool, neg: bool },
    /// `//keys value`: searched in the resolved types
    Scoped { keys: String, value: String, exact: bool, neg: bool },
}

impl Term {
    pub fn neg(&self) -> bool {
        match self {
            Term::Free { neg, .. } | Term::Scoped { neg, .. } => *neg,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ColOpKind {
    Filter,
    Add,
    Remove,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ColOp {
    pub op: ColOpKind,
    pub keys: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SortSpec {
    pub fields: Vec<String>,
    pub dir: Dir,
}

/// An app-owned verb occurrence: `/fts/keys term`, `/sw`.
#[derive(Clone, Debug, PartialEq)]
pub struct AppCmd {
    pub verb: String,
    pub keys: Option<String>,
    pub arg: Option<String>,
    pub neg: bool,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Parsed {
    pub terms: Vec<Term>,
    pub col_ops: Vec<ColOp>,
    /// resolved against the schema; None when absent or any key names nothing
    pub sort: Option<SortSpec>,
    /// the keys as typed even when they name nothing in the schema (an app view may sort by its own types)
    pub sort_raw: Option<(Vec<String>, Dir)>,
    /// the last `/g` token, resolved by `group::parse_group` against whichever types the view has
    pub group_raw: Option<String>,
    pub apps: Vec<AppCmd>,
}

pub fn parse(schema: &Schema, query: &str) -> Parsed {
    let toks = tokenize(query);
    let mut top = Parsed::default();
    let mut i = 0;
    while i < toks.len() {
        let tok = &toks[i];
        i += 1;
        let Some(cmd) = schema.tok_verb(tok) else {
            let mid_typing = !tok.lead_quote && tok.text.starts_with('/') && schema.is_verb_prefix(&tok.text[1..]);
            if !mid_typing {
                top.terms.push(Term::Free { text: tok.text.clone(), exact: tok.quoted, neg: tok.neg });
            }
            continue;
        };
        let Some(kind) = schema.kind_of(&cmd.verb) else { continue };
        if let VerbKind::App { takes_arg } = kind {
            if cmd.bad {
                continue;
            }
            let mut arg = None;
            if takes_arg && i < toks.len() && !schema.starts_command(&toks[i]) {
                arg = Some(toks[i].text.replace('"', ""));
                i += 1;
            }
            top.apps.push(AppCmd { verb: cmd.verb, keys: cmd.keys, arg, neg: tok.neg });
            continue;
        }
        // keyless or malformed: inert, takes no argument ("/fv foo" is just "foo")
        let Some(via) = cmd.keys.clone().filter(|_| !cmd.bad) else { continue };
        let via = via.to_lowercase();
        let keys_typed = !via.replace(',', "").is_empty();
        // "!" only means something on a row filter: "!/s", "!/ft" ... parse but change nothing
        let discard = tok.neg && kind != VerbKind::FilterValue;
        let mut sink = Parsed::default();
        let r = if discard { &mut sink } else { &mut top };
        match kind {
            VerbKind::FilterValue => {
                if i < toks.len() && !schema.starts_command(&toks[i]) {
                    r.terms.push(Term::Scoped { keys: via, value: toks[i].text.clone(), exact: toks[i].quoted, neg: tok.neg || toks[i].neg });
                    i += 1;
                } else if keys_typed && !schema.resolve_keys(&via).is_empty() {
                    // keys named, value still pending: a no-op for rows, but the field is auto-shown at once
                    r.terms.push(Term::Scoped { keys: via, value: String::new(), exact: false, neg: tok.neg });
                }
            }
            VerbKind::FilterType | VerbKind::AddType | VerbKind::RemoveType => {
                if keys_typed {
                    let op = match kind {
                        VerbKind::FilterType => ColOpKind::Filter,
                        VerbKind::AddType => ColOpKind::Add,
                        _ => ColOpKind::Remove,
                    };
                    r.col_ops.push(ColOp { op, keys: via });
                }
            }
            VerbKind::Group => r.group_raw = Some(tok.text.clone()),
            VerbKind::Sort => {
                let dir = match &cmd.dir {
                    Some(d) => match parse_direction(d) {
                        Some(d) => d,
                        None => continue,
                    },
                    None => Dir::Desc,
                };
                let keys: Vec<&str> = via.split(',').filter(|k| !k.is_empty()).collect();
                if !keys.is_empty() {
                    r.sort_raw = Some((keys.iter().map(|s| s.to_string()).collect(), dir));
                    if let Some(fields) = resolve_sort_keys(&keys, &schema.types) {
                        r.sort = Some(SortSpec { fields, dir });
                    }
                }
            }
            VerbKind::App { .. } => {}
        }
    }
    top
}

/// The row values a picker exposes to the engine.
pub trait Source {
    /// the value of type `ty` for `row`
    fn value(&self, row: usize, ty: &str) -> String;
    /// the free-text haystack a bare word is searched in
    fn haystack(&self, row: usize) -> String;
    /// a type answered outside the row text (e.g. a full-text index): Some(hit) overrides the substring test
    fn external(&self, _row: usize, _ty: &str, _value: &str) -> Option<bool> {
        None
    }
}

pub fn term_matches(schema: &Schema, src: &dyn Source, row: usize, term: &Term) -> bool {
    let m = match term {
        Term::Free { text, exact, .. } => substr(text, &src.haystack(row), *exact),
        Term::Scoped { keys, value, exact, .. } => schema.resolve_keys(keys).iter().any(|ty| {
            if let Some(hit) = src.external(row, ty, value) {
                return value.is_empty() || hit;
            }
            if schema.exact_types.contains(ty) {
                return value.is_empty() || src.value(row, ty) == *value;
            }
            substr(value, &src.value(row, ty), *exact)
        }),
    };
    m != term.neg()
}

pub fn row_matches(schema: &Schema, parsed: &Parsed, src: &dyn Source, row: usize) -> bool {
    parsed.terms.iter().all(|t| term_matches(schema, src, row, t))
}

/// Case-insensitive `*` glob (a pattern without `*` is a substring test).
pub fn glob_match(pattern: &str, value: &str) -> bool {
    let (pattern, value) = (pattern.to_lowercase(), value.to_lowercase());
    if !pattern.contains('*') {
        return value.contains(&pattern);
    }
    let (starts_wild, ends_wild) = (pattern.starts_with('*'), pattern.ends_with('*'));
    let parts: Vec<&str> = pattern.split('*').filter(|p| !p.is_empty()).collect();
    if parts.is_empty() {
        return true;
    }
    let mut pos = 0;
    for (idx, part) in parts.iter().enumerate() {
        let rest = &value[pos..];
        if idx == 0 && !starts_wild {
            if !rest.starts_with(part) {
                return false;
            }
            pos += part.len();
        } else if idx == parts.len() - 1 && !ends_wild {
            if !rest.ends_with(part) {
                return false;
            }
        } else {
            match rest.find(part) {
                Some(f) => pos += f + part.len(),
                None => return false,
            }
        }
    }
    true
}

/// The columns to show: the defaults run through the column ops in order, plus any type a `/fv` scoped
/// to (auto-show). `rows` is how many rows exist, for the `/ft pattern` value-glob fallback.
pub fn active_columns(schema: &Schema, parsed: &Parsed, defaults: &[String], src: &dyn Source, rows: usize) -> Vec<String> {
    let mut cols: Vec<String> = defaults.to_vec();
    for op in &parsed.col_ops {
        let fields = schema.resolve_keys(&op.keys);
        match op.op {
            ColOpKind::Filter if fields.is_empty() => {
                cols = schema.types.iter().filter(|ty| (0..rows).any(|r| glob_match(&op.keys, &src.value(r, ty)))).cloned().collect();
            }
            ColOpKind::Filter => cols.retain(|c| fields.contains(c)),
            ColOpKind::Add => {
                for f in fields {
                    if !cols.contains(&f) {
                        cols.push(f);
                    }
                }
            }
            ColOpKind::Remove => cols.retain(|c| !fields.contains(c)),
        }
    }
    for t in &parsed.terms {
        if let Term::Scoped { keys, .. } = t {
            for f in schema.resolve_keys(keys) {
                if !cols.contains(&f) {
                    cols.push(f);
                }
            }
        }
    }
    cols
}

/// Stable sort of `order` (row indexes) by the sort chain; ties keep the incoming order.
pub fn sort_rows(order: &mut [usize], sort: &SortSpec, src: &dyn Source) {
    order.sort_by(|&a, &b| {
        for f in &sort.fields {
            let c = compare_field_values(&src.value(a, f), &src.value(b, f), sort.dir);
            if c != 0 {
                return c.cmp(&0);
            }
        }
        std::cmp::Ordering::Equal
    });
}

/// Rows that survive the filters, in sorted order.
pub fn select_rows(schema: &Schema, parsed: &Parsed, src: &dyn Source, rows: usize) -> Vec<usize> {
    let mut order: Vec<usize> = (0..rows).filter(|&r| row_matches(schema, parsed, src, r)).collect();
    if let Some(s) = &parsed.sort {
        sort_rows(&mut order, s, src);
    }
    order
}

/// Byte-free spans of command tokens for syntax colouring: (start, end, valid) in chars.
pub fn command_spans(schema: &Schema, query: &str) -> Vec<(usize, usize, bool)> {
    let mut out = vec![];
    for tok in tokenize(query) {
        if tok.lead_quote || !tok.text.starts_with('/') {
            continue;
        }
        let rest = &tok.text[1..];
        if rest.is_empty() {
            continue;
        }
        let tv = schema.tok_verb(&tok);
        let valid = tv.as_ref().is_some_and(|c| !c.bad);
        if !valid && tv.is_none() && schema.is_verb_prefix(rest.split('/').next().unwrap_or("")) && !rest.contains('/') {
            continue;
        }
        out.push((tok.start, tok.start + tok.text.chars().count(), valid));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Rows(Vec<[&'static str; 3]>); // title, workspace, pid
    impl Source for Rows {
        fn value(&self, row: usize, ty: &str) -> String {
            let r = &self.0[row];
            match ty {
                "title" => r[0],
                "workspace" => r[1],
                "pid" => r[2],
                _ => "",
            }
            .to_string()
        }
        fn haystack(&self, row: usize) -> String {
            self.0[row].join(" ")
        }
    }

    fn schema() -> Schema {
        Schema::new(&["title", "workspace", "pid", "tmux-title"], vec![])
    }

    #[test]
    fn filters_sorts_and_columns() {
        let s = schema();
        let rows = Rows(vec![["Brave", "2", "30"], ["Alacritty", "1", "4"], ["Brave dev", "3", "100"]]);
        let p = parse(&s, "brave /s/pid/asc");
        assert_eq!(select_rows(&s, &p, &rows, 3), vec![0, 2]);
        let p = parse(&s, "//work 1 !dev /s/title/asc");
        assert_eq!(select_rows(&s, &p, &rows, 3), vec![1]);
        let defaults = vec!["title".to_string(), "workspace".to_string()];
        let p = parse(&s, "/rt/workspace //pid 3");
        assert_eq!(active_columns(&s, &p, &defaults, &rows, 3), vec!["title", "pid"]);
        let p = parse(&s, "/at/pid");
        assert_eq!(active_columns(&s, &p, &defaults, &rows, 3), vec!["title", "workspace", "pid"]);
    }

    #[test]
    fn half_typed_is_inert() {
        let s = schema();
        for q in ["/", "/f", "/fv", "/fv/", "/s/title/ascx", "!/s/title", "/zzz"] {
            let p = parse(&s, q);
            assert!(p.terms.iter().all(|t| matches!(t, Term::Free { .. })) && p.sort.is_none(), "{q}: {p:?}");
        }
        assert_eq!(parse(&s, "/fv foo").terms, vec![Term::Free { text: "foo".into(), exact: false, neg: false }]);
    }

    #[test]
    fn value_pending_and_negation() {
        let s = schema();
        let p = parse(&s, "/fv/title");
        assert!(matches!(&p.terms[..], [Term::Scoped { value, .. }] if value.is_empty()));
        let p = parse(&s, "!//title brave");
        assert!(p.terms[0].neg());
    }

    #[test]
    fn exact_types_and_quotes() {
        let mut s = schema();
        s.exact_types = vec!["pid".into()];
        let rows = Rows(vec![["a", "1", "3"], ["b", "1", "13"]]);
        assert_eq!(select_rows(&s, &parse(&s, "//pid 3"), &rows, 2), vec![0]);
        assert_eq!(select_rows(&s, &parse(&s, "\"3\""), &rows, 2), vec![0]);
    }

    #[test]
    fn spans_mark_invalid_commands() {
        let s = schema();
        assert_eq!(command_spans(&s, "a /fv/title /s/x/y/z"), vec![(2, 11, true), (12, 20, false)]);
    }
}
