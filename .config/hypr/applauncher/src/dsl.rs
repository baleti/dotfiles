//! The shared `/verb` query-DSL grammar, vendored verbatim from
//! clipboard-picker's `picker.rs` (which ported it by hand from winswitch's
//! `query.rs` -- see ~/.config/docs/query-dsl.md for why every picker keeps
//! its own copy rather than sharing one crate).
//!
//! The launcher only *acts* on `/fv` (and bare text, the same thing) and
//! `/s` + `/rv` for ordering; `/ft`, `/at`, `/rt` are recognised-but-inert
//! (no columns here). Bare free words join into one phrase matched as a
//! single literal run against `haystack` -- same as clipboard-picker.

/// Case-insensitive substring containment -- the one matching rule for
/// every field name and every filter value. Empty needle always matches.
pub fn substr(needle: &str, hay: &str) -> bool {
    hay.to_lowercase().contains(&needle.to_lowercase())
}

const VERB_FORMS: &[&str] = &[
    "fv", "ft", "at", "rt", "s", "rv", "filter-value", "filter-type", "add-type", "remove-type", "sort",
    "reverse",
];

fn is_filter_value_verb(rest: &str) -> bool {
    rest == "fv" || rest == "filter-value"
}
fn is_sort_verb(rest: &str) -> bool {
    rest == "s" || rest == "sort"
}
fn is_reverse_verb(rest: &str) -> bool {
    rest == "rv" || rest == "reverse"
}
fn is_verb_prefix(s: &str) -> bool {
    !s.is_empty() && VERB_FORMS.iter().any(|v| v.starts_with(s))
}
fn is_verb(rest: &str) -> bool {
    VERB_FORMS.contains(&rest)
}

/// `(long-form alias, one-line description)` for a short verb form -- the
/// marginalia hints in the autocomplete popup. Only the verbs the launcher
/// actually does something with are ever suggested (see `verb_suggestions`).
pub fn verb_meta(short: &str) -> (&'static str, &'static str) {
    match short {
        "fv" => ("/filter-value", "keep rows whose value matches (substring)"),
        "s" => ("/sort", "order rows by one field, optional asc / desc"),
        "rv" => ("/reverse", "flip the current order"),
        _ => ("", ""),
    }
}

/// One `/fv field:value` selector.
pub struct FieldTerm {
    pub fields: Vec<&'static str>,
    pub value: String,
}

/// A `/s field[:asc|:desc]` selector.
pub struct SortTerm {
    pub field: &'static str,
    pub descending: bool,
}

/// A parsed search box string.
pub struct Query {
    pub field_terms: Vec<FieldTerm>,
    pub sort: Option<SortTerm>,
    pub reverse: bool,
    pub text: String,
}

struct Tok {
    start: usize,
    text: String,
    lead_quote: bool,
}

fn tokenize(query: &str) -> Vec<Tok> {
    let mut tokens = Vec::new();
    let mut cur = String::new();
    let mut start: Option<usize> = None;
    let mut lead_quote = false;
    let mut in_quotes = false;
    for (i, c) in query.char_indices() {
        if c == '"' {
            if start.is_none() {
                lead_quote = true;
            }
            in_quotes = !in_quotes;
            start.get_or_insert(i);
            continue;
        }
        if c.is_whitespace() && !in_quotes {
            if let Some(s) = start.take() {
                tokens.push(Tok { start: s, text: std::mem::take(&mut cur), lead_quote });
                lead_quote = false;
            }
            continue;
        }
        start.get_or_insert(i);
        cur.push(c);
    }
    if let Some(s) = start {
        tokens.push(Tok { start: s, text: cur, lead_quote });
    }
    tokens
}

fn starts_cmd(tok: &Tok) -> bool {
    if tok.lead_quote {
        return false;
    }
    match tok.text.strip_prefix('/') {
        Some(rest) => is_verb(rest) || is_verb_prefix(rest),
        None => false,
    }
}

/// Every `/`-led token that's unambiguously a command attempt --
/// `(byte_start, byte_end, is_valid)`. A still-forming prefix of a real
/// verb is skipped (not wrong yet).
pub fn command_spans(query: &str) -> Vec<(usize, usize, bool)> {
    let mut out = Vec::new();
    for tok in tokenize(query) {
        if tok.lead_quote {
            continue;
        }
        let Some(rest) = tok.text.strip_prefix('/') else {
            continue;
        };
        if rest.is_empty() {
            continue;
        }
        let valid = is_verb(rest);
        if !valid && is_verb_prefix(rest) {
            continue;
        }
        out.push((tok.start, tok.start + tok.text.len(), valid));
    }
    out
}

fn resolve_fields<'a>(query: &str, field_names: &[&'a str]) -> Vec<&'a str> {
    field_names.iter().copied().filter(|f| substr(query, f)).collect()
}

fn push_fv_arg(
    arg: &str,
    field_names: &[&'static str],
    field_terms: &mut Vec<FieldTerm>,
    words: &mut Vec<String>,
) {
    match arg.split_once(':') {
        Some((f, v)) => {
            field_terms.push(FieldTerm { fields: resolve_fields(f, field_names), value: v.to_string() })
        }
        None => words.push(arg.to_string()),
    }
}

fn parse_sort_arg(arg: &str, field_names: &[&'static str]) -> Option<SortTerm> {
    let (name, dir) = match arg.split_once(':') {
        Some((n, d)) => (n, d),
        None => (arg, ""),
    };
    let field = resolve_fields(name, field_names).into_iter().next()?;
    Some(SortTerm { field, descending: dir.starts_with("desc") || dir == "d" })
}

pub fn parse_query(input: &str, field_names: &[&'static str]) -> Query {
    let toks = tokenize(input);
    let mut field_terms = Vec::new();
    let mut words: Vec<String> = Vec::new();
    let mut sort = None;
    let mut reverse = false;

    let mut i = 0;
    while i < toks.len() {
        let tok = &toks[i];
        if !tok.lead_quote {
            if let Some(rest) = tok.text.strip_prefix('/') {
                if is_filter_value_verb(rest) {
                    i += 1;
                    if let Some(arg) = toks.get(i).filter(|t| !starts_cmd(t)) {
                        push_fv_arg(&arg.text, field_names, &mut field_terms, &mut words);
                        i += 1;
                    }
                    continue;
                }
                if is_sort_verb(rest) {
                    i += 1;
                    if let Some(arg) = toks.get(i).filter(|t| !starts_cmd(t)) {
                        sort = parse_sort_arg(&arg.text, field_names);
                        i += 1;
                    }
                    continue;
                }
                if is_reverse_verb(rest) {
                    reverse = !reverse;
                    i += 1;
                    continue;
                }
                if is_verb(rest) {
                    // inert here -- swallow one argument so it doesn't fall
                    // into the free-text phrase.
                    i += 1;
                    if toks.get(i).map(|t| !starts_cmd(t)).unwrap_or(false) {
                        i += 1;
                    }
                    continue;
                }
                if is_verb_prefix(rest) {
                    i += 1;
                    continue;
                }
            }
        }
        words.push(tok.text.clone());
        i += 1;
    }

    Query { field_terms, sort, reverse, text: words.join(" ").to_lowercase() }
}

// ---- autocomplete ------------------------------------------------------

pub enum Suggest {
    Verb { start: usize, frag: String },
    Field { start: usize, frag: String },
    Value { start: usize, field: &'static str, frag: String },
}

fn fv_or_sort_open(context: &[Tok]) -> bool {
    let mut open = false;
    let mut pending: usize = 0;
    for tok in context {
        if pending > 0 && !starts_cmd(tok) {
            pending -= 1;
            open = false;
            continue;
        }
        pending = 0;
        if !tok.lead_quote {
            if let Some(rest) = tok.text.strip_prefix('/') {
                if is_filter_value_verb(rest) || is_sort_verb(rest) {
                    open = true;
                    continue;
                }
                if is_verb(rest) {
                    open = false;
                    pending = 1;
                    continue;
                }
                if is_verb_prefix(rest) {
                    open = false;
                    continue;
                }
            }
        }
        open = false;
    }
    open
}

pub fn completion_context(query: &str, field_names: &[&'static str]) -> Option<Suggest> {
    let toks = tokenize(query);
    if toks.is_empty() {
        return None;
    }
    let trailing_space = query.ends_with(char::is_whitespace);
    let (context, start, frag, lead_quote) = if trailing_space {
        (&toks[..], query.len(), String::new(), false)
    } else {
        let last = toks.last().unwrap();
        (&toks[..toks.len() - 1], last.start, last.text.clone(), last.lead_quote)
    };
    if lead_quote {
        return None;
    }

    if let Some(verb_frag) = frag.strip_prefix('/') {
        return Some(Suggest::Verb { start, frag: verb_frag.to_string() });
    }

    if !fv_or_sort_open(context) {
        return None;
    }
    match frag.split_once(':') {
        Some((f, val_frag)) => {
            let mut resolved = field_names.iter().copied().filter(|c| substr(f, c));
            let field = resolved.next()?;
            if resolved.next().is_some() {
                return None;
            }
            Some(Suggest::Value { start, field, frag: val_frag.to_string() })
        }
        None => Some(Suggest::Field { start, frag }),
    }
}

/// Only the verbs the launcher does something with.
pub fn verb_suggestions(frag: &str) -> Vec<String> {
    ["fv", "s", "rv"].iter().filter(|v| substr(frag, v)).map(|v| v.to_string()).collect()
}

pub fn field_suggestions(field_names: &[&'static str], fragment: &str) -> Vec<&'static str> {
    field_names.iter().copied().filter(|f| substr(fragment, f)).collect()
}
