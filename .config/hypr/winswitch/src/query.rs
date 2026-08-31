//! The picker query DSL, verb-command generation (see
//! ~/.config/docs/query-dsl.md for the full cross-implementation spec).
//!
//! The search box text is whitespace-split into tokens (a `"..."` run
//! stays one token, and a token that *starts* with `"` is never read as a
//! command - the literal escape hatch). Each token is either a `/verb`
//! that opens a command and consumes the tokens after it as arguments, or
//! a bare value that is an implicit `/filter-value` term.
//!
//! Six verbs, each exact-matched against a short and a long form - no
//! fuzzy resolution on the verb itself, that is the entire reason the
//! grammar is verb-first (a type name can never be mistaken for a
//! command):
//!
//!   /fv /filter-value   keep rows matching the arg (bare text = this)
//!   /ft /filter-type    keep only columns whose name matches; hide the rest
//!   /at /add-type       add columns whose name matches into view
//!   /rt /remove-type    drop columns whose name matches from view
//!   /s  /sort           order rows by one type, optional direction
//!   /rv /reverse        reverse the current order
//!
//! Every path-taking verb (all but `/rv`) can carry its type path glued
//! directly onto the verb with a second `/` instead of as a separate
//! space-separated argument - `/fv/claude.title foo` means exactly what
//! `/fv claude.title:foo` already did, no colon involved. `tok_verb`
//! returns `(Verb, Option<via>)` for this; see query-dsl.md's "Via paths"
//! for the full reasoning (this replaced an earlier, since-reverted
//! design that registered `/claude`, `/claude.title` etc. as their own
//! verbs - `/fv/claude.title` is what that was really reaching for).
//! `/ft`'s via path additionally falls back to a glob **value** pattern
//! (`glob_match`) when it doesn't resolve to any known type/group at all
//! - `/ft/64*` shows whichever column(s) actually have a matching value
//! right now, a discovery reset rather than a narrow-down (see
//! `fields_matching_value_pattern`).
//!
//! Everything that is *not* a verb - type-path segments, filter values,
//! sort directions - is matched by case-insensitive substring
//! containment, with every match unioned for a path segment. No
//! subsequence, no regex; `*` (as in `claude.*`) is one hand-parsed
//! reserved segment meaning "every subfield of the group" - except inside
//! an `/ft` value pattern, where `*` is a real glob wildcard instead (see
//! `glob_match`).
//!
//! Three orthogonal axes, three entry points: `matches_str` (row
//! filters), `active_columns` (column verbs, left-to-right pipeline over
//! the picker defaults), `parse_actions` (`/sort` last-wins + `/reverse`
//! idempotent). `compare_field_values` carries the age-bucket "direction
//! trap" for sorting `date`-shaped values - see query-dsl.md.

use crate::enrich::TmuxClaudeMeta;
use crate::hyprctl::Window;

/// Every flat type name a path segment can resolve to. Add new types here
/// and in `column_value` together.
const COLUMNS: &[&str] = &["title", "workspace", "pid"];

/// Group name -> its own subfield list, in display order. Add a new
/// group's data to `enrich::TmuxClaudeMeta` and `group_sub_value`
/// together.
const GROUPS: &[(&str, &[&str])] = &[
    ("tmux", &["session", "window", "title"]),
    ("claude", &["title", "path", "session", "time", "contents"]),
];

/// Per-group default subfield for a bare `group` path with no explicit
/// `.sub` - what `/fv group:value` (or `/fv/group value`) falls back to
/// for *filtering and sorting* (a column verb instead takes every
/// subfield - see `resolve_column_fields`). `claude` defaults to
/// `contents`: transcript text is far more useful to search or sort by
/// default than the title. `tmux` defaults to `title` - nothing more
/// useful to default to there.
const GROUP_DEFAULT_SUB: &[(&str, &str)] = &[("tmux", "title"), ("claude", "contents")];

fn group_default_sub(group: &str) -> &'static str {
    GROUP_DEFAULT_SUB.iter().find(|(g, _)| *g == group).map(|(_, s)| *s).unwrap_or("")
}

const DIRECTIONS: &[&str] = &["ascending", "descending"];

/// The six verbs. Both the short and long spelling map here; nothing else
/// does.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Verb {
    FilterValue,
    FilterType,
    AddType,
    RemoveType,
    Sort,
    Reverse,
}

impl Verb {
    /// Exact match against the short and long form. `tok` is the text
    /// after the leading `/`.
    fn parse(tok: &str) -> Option<Verb> {
        match tok {
            "fv" | "filter-value" => Some(Verb::FilterValue),
            "ft" | "filter-type" => Some(Verb::FilterType),
            "at" | "add-type" => Some(Verb::AddType),
            "rt" | "remove-type" => Some(Verb::RemoveType),
            "s" | "sort" => Some(Verb::Sort),
            "rv" | "reverse" => Some(Verb::Reverse),
            _ => None,
        }
    }

    /// Whether this verb's argument (the first one, for `/sort`) is a type
    /// path - used by completion to know it's in the path stage.
    fn takes_path(self) -> bool {
        !matches!(self, Verb::Reverse)
    }
}

/// Every verb short form, for top-level completion, in canonical order.
const VERB_SHORTS: &[&str] = &["fv", "ft", "at", "rt", "s", "rv"];

/// Every accepted verb spelling, short and long.
const VERB_FORMS: &[&str] = &[
    "fv", "ft", "at", "rt", "s", "rv", "filter-value", "filter-type", "add-type", "remove-type", "sort",
    "reverse",
];

/// True if `s` is a non-empty prefix of some verb form - i.e. a `/s...`
/// token that could still become a verb once more is typed, so it stays
/// inert (mid-typing) rather than being searched for literally. A `/xyz`
/// that is neither a verb nor a prefix of one (e.g. `/usr/bin`) is real
/// text and does get searched. Only ever checked against the verb-name
/// portion of a token - a via path glued on after a second `/` is a
/// separate concern `tok_verb`/`starts_command` handle themselves.
fn is_verb_prefix(s: &str) -> bool {
    !s.is_empty() && VERB_FORMS.iter().any(|v| v.starts_with(s))
}

/// Case-insensitive substring containment. Empty needle always matches.
/// The one matching rule for every path segment, filter value and sort
/// direction in this DSL.
fn substr(needle: &str, hay: &str) -> bool {
    hay.to_lowercase().contains(&needle.to_lowercase())
}

fn column_value(win: &Window, column: &str) -> String {
    match column {
        "title" => win.title.clone(),
        "workspace" => win.workspace.clone(),
        "pid" => win.pid.to_string(),
        _ => String::new(),
    }
}

fn group_sub_value(meta: &TmuxClaudeMeta, group: &str, sub: &str) -> String {
    match (group, sub) {
        ("tmux", "session") => meta.tmux_session.clone(),
        ("tmux", "window") => meta.tmux_window.clone(),
        ("tmux", "title") => meta.tmux_title.clone(),
        ("claude", "title") => meta.claude_title.clone(),
        ("claude", "path") => meta.claude_path.clone(),
        ("claude", "session") => meta.claude_session.clone(),
        ("claude", "time") => meta.claude_time.clone(),
        ("claude", "contents") => meta.claude_contents.clone(),
        _ => None,
    }
    .unwrap_or_default()
}

fn group_subs(group: &str) -> &'static [&'static str] {
    GROUPS.iter().find(|(g, _)| *g == group).map(|(_, subs)| *subs).unwrap_or(&[])
}

/// True if `group` has any non-empty subfield on this window - what a
/// colonless `/fv group` (existence filter) checks for.
fn group_has_any_value(meta: &TmuxClaudeMeta, group: &str) -> bool {
    group_subs(group).iter().any(|s| !group_sub_value(meta, group, s).is_empty())
}

fn resolve_groups(seg: &str) -> Vec<&'static str> {
    GROUPS.iter().map(|(g, _)| *g).filter(|g| substr(seg, g)).collect()
}

fn resolve_group_subs(group: &str, seg: &str) -> Vec<&'static str> {
    group_subs(group).iter().copied().filter(|s| substr(seg, s)).collect()
}

/// Which concrete field(s) a path names. `Flat` for a top-level type,
/// `Group` for a group subfield.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ResolvedField {
    Flat(&'static str),
    Group(&'static str, &'static str),
}

impl ResolvedField {
    /// Dotted key - `"title"` or `"claude.title"` - for splicing an
    /// accepted completion back in and for `SuggestionKind::Value`.
    pub fn key(&self) -> String {
        match self {
            ResolvedField::Flat(c) => c.to_string(),
            ResolvedField::Group(g, s) => format!("{g}.{s}"),
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Direction {
    Ascending,
    Descending,
}

/// `/sort` result plus whether `/reverse` was also typed. Both can apply
/// at once: `/sort` picks an order, `/reverse` flips whatever order is in
/// effect.
#[derive(Clone, Default)]
pub struct Actions {
    pub sort: Option<(ResolvedField, Direction)>,
    pub reverse: bool,
}

/// A parsed row-filter term, from a bare word or a `/fv` command (via
/// path or space form - both funnel through `filter_term`, see `parse`).
enum FilterTerm {
    /// Substring over the free-text haystack (title + class).
    Free(String),
    /// `path:value` - substring `value` against every type `path`
    /// resolves to. Reached either by an actual colon in the argument
    /// (`/fv path:value`, or bare `path:value`) or by reconstructing this
    /// same shape from a via path plus a following bare token
    /// (`/fv/path value` - see `parse`), so both spellings share one
    /// matching rule.
    Scoped { path: String, value: String },
    /// Colonless `group` that resolved to a group - existence check.
    GroupExists(String),
}

/// A column verb and its raw path argument.
#[derive(Clone, Copy)]
enum ColOp {
    Filter,
    Add,
    Remove,
}

// --- tokenizer -------------------------------------------------------------

/// One token: its byte offset in the source, its text (quotes stripped,
/// interior whitespace kept), and whether the source run *started* with a
/// `"` (which makes it a literal, never a command).
struct Tok {
    start: usize,
    text: String,
    lead_quote: bool,
}

/// Split on whitespace like `str::split_whitespace`, except a `"..."` run
/// keeps its interior whitespace and stays one token. An unterminated
/// quote still closes at end-of-input rather than being dropped (same
/// "half-typed stays usable" rule the rest of the DSL follows). The
/// `lead_quote` flag records whether the run began with a `"`, so a
/// caller can honour `"/literal"` as text.
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

/// The verb a token names, plus its via path if one was glued on with a
/// second `/` (`/fv/claude.title` -> `(FilterValue, Some("claude.title"))`
/// - see query-dsl.md's "Via paths"). `None` if the token isn't a `/verb`
/// at all (or is a quote-led literal).
fn tok_verb(tok: &Tok) -> Option<(Verb, Option<&str>)> {
    if tok.lead_quote {
        return None;
    }
    let rest = tok.text.strip_prefix('/')?;
    match rest.split_once('/') {
        Some((name, via)) => Verb::parse(name).map(|v| (v, Some(via))),
        None => Verb::parse(rest).map(|v| (v, None)),
    }
}

/// True if a token would begin (or continue typing) a command rather than
/// serve as an argument - a complete `/verb` (with or without a via path
/// glued on) or a `/prefix` still on its way to being one. A literal
/// `/usr/bin` is neither, so it *can* be an argument.
fn starts_command(tok: &Tok) -> bool {
    if tok.lead_quote {
        return false;
    }
    match tok.text.strip_prefix('/') {
        Some(rest) => {
            let name = rest.split_once('/').map(|(n, _)| n).unwrap_or(rest);
            Verb::parse(name).is_some() || is_verb_prefix(rest)
        }
        None => false,
    }
}

// --- direction parsing ---------------------------------------------------

/// A sort-direction token -> `Direction`. Any substring match counts;
/// `descending` only when it matches that and not `ascending`, otherwise
/// (including an ambiguous or empty fragment) `Ascending`.
fn parse_direction(tok: &str) -> Option<Direction> {
    let matched: Vec<&str> = DIRECTIONS.iter().copied().filter(|d| substr(tok, d)).collect();
    match matched[..] {
        [] => None,
        ["descending"] => Some(Direction::Descending),
        _ => Some(Direction::Ascending),
    }
}

fn resolve_directions(frag: &str) -> Vec<&'static str> {
    DIRECTIONS.iter().copied().filter(|d| substr(frag, d)).collect()
}

// --- path resolution ---------------------------------------------------

/// Split a path on `.` into at most two meaningful segments.
fn path_segs(path: &str) -> (&str, Option<&str>) {
    match path.split_once('.') {
        Some((g, s)) => (g, Some(s)),
        None => (path, None),
    }
}

/// Fields a path names for *filtering* - a bare `group` becomes its
/// default subfield only.
fn resolve_filter_fields(path: &str) -> Vec<ResolvedField> {
    match path_segs(path) {
        (g_seg, Some("*")) => resolve_groups(g_seg)
            .iter()
            .flat_map(|&g| group_subs(g).iter().map(move |&s| ResolvedField::Group(g, s)))
            .collect(),
        (g_seg, Some(s_seg)) => resolve_groups(g_seg)
            .iter()
            .flat_map(|&g| resolve_group_subs(g, s_seg).into_iter().map(move |s| ResolvedField::Group(g, s)))
            .collect(),
        (seg, None) => {
            let mut out: Vec<ResolvedField> =
                COLUMNS.iter().copied().filter(|c| substr(seg, c)).map(ResolvedField::Flat).collect();
            out.extend(resolve_groups(seg).into_iter().map(|g| ResolvedField::Group(g, group_default_sub(g))));
            out
        }
    }
}

/// Fields a path names for a *column verb* - a bare `group` becomes every
/// subfield.
fn resolve_column_fields(path: &str) -> Vec<ResolvedField> {
    match path_segs(path) {
        (g_seg, Some("*")) => resolve_groups(g_seg)
            .iter()
            .flat_map(|&g| group_subs(g).iter().map(move |&s| ResolvedField::Group(g, s)))
            .collect(),
        (g_seg, Some(s_seg)) => resolve_groups(g_seg)
            .iter()
            .flat_map(|&g| resolve_group_subs(g, s_seg).into_iter().map(move |s| ResolvedField::Group(g, s)))
            .collect(),
        (seg, None) => {
            let mut out: Vec<ResolvedField> =
                COLUMNS.iter().copied().filter(|c| substr(seg, c)).map(ResolvedField::Flat).collect();
            for g in resolve_groups(seg) {
                out.extend(group_subs(g).iter().map(|&s| ResolvedField::Group(g, s)));
            }
            out
        }
    }
}

/// The single field a path names, or `None` if ambiguous, unknown, or a
/// `*` set - what `/sort` needs.
fn resolve_one(path: &str) -> Option<ResolvedField> {
    match path_segs(path) {
        (_, Some("*")) => None,
        (g_seg, Some(s_seg)) => {
            let groups = resolve_groups(g_seg);
            let [group] = groups[..] else { return None };
            let subs = resolve_group_subs(group, s_seg);
            let [sub] = subs[..] else { return None };
            Some(ResolvedField::Group(group, sub))
        }
        (seg, None) => {
            let mut c: Vec<ResolvedField> =
                COLUMNS.iter().copied().filter(|x| substr(seg, x)).map(ResolvedField::Flat).collect();
            c.extend(resolve_groups(seg).into_iter().map(|g| ResolvedField::Group(g, group_default_sub(g))));
            match c[..] {
                [only] => Some(only),
                _ => None,
            }
        }
    }
}

// --- command parsing -------------------------------------------------------

/// Everything one query parses to, across all three axes. Cheap to
/// recompute per keystroke.
struct Parsed {
    filters: Vec<FilterTerm>,
    /// `(op, path, is_via)` - `is_via` is only ever consulted for
    /// `ColOp::Filter` (see `active_columns`'s value-pattern fallback);
    /// `/at`/`/rt` carry it too, for symmetry, but never act on it.
    col_ops: Vec<(ColOp, String, bool)>,
    sort: Option<(ResolvedField, Direction)>,
    reverse: bool,
}

/// One raw filter argument -> a `FilterTerm`. A colon makes it scoped; a
/// colonless single segment that resolves to a group is an existence
/// check; anything else is free text.
fn filter_term(arg: &str) -> FilterTerm {
    if let Some((path, value)) = arg.split_once(':') {
        return FilterTerm::Scoped { path: path.to_string(), value: value.to_string() };
    }
    if !arg.contains('.') && !resolve_groups(arg).is_empty() {
        return FilterTerm::GroupExists(arg.to_string());
    }
    FilterTerm::Free(arg.to_string())
}

fn parse(query: &str) -> Parsed {
    let toks = tokenize(query);
    let mut out = Parsed { filters: Vec::new(), col_ops: Vec::new(), sort: None, reverse: false };

    let mut i = 0;
    while i < toks.len() {
        let tok = &toks[i];
        let Some((verb, via)) = tok_verb(tok) else {
            // Not a verb. A `/prefix` still on its way to being one is
            // inert; anything else (a bare value, or a literal `/usr/bin`)
            // is an implicit /fv term.
            let mid_typing = !tok.lead_quote
                && tok.text.strip_prefix('/').map(is_verb_prefix).unwrap_or(false);
            if !mid_typing {
                out.filters.push(filter_term(&tok.text));
            }
            i += 1;
            continue;
        };
        i += 1;

        if let Some(via) = via {
            // Via form: the path lives in the verb token itself (see
            // query-dsl.md's "Via paths"). Every verb still takes exactly
            // the same *remaining* arguments it always did - just minus
            // the path, since via already supplied it.
            match verb {
                Verb::FilterValue => {
                    // No colon in this form - reconstruct the exact
                    // "path:value" (or colonless "path") shape
                    // `filter_term` already knows how to read, so both
                    // spellings share one matching rule.
                    if i < toks.len() && !starts_command(&toks[i]) {
                        out.filters.push(filter_term(&format!("{via}:{}", toks[i].text)));
                        i += 1;
                    } else {
                        out.filters.push(filter_term(via));
                    }
                }
                Verb::FilterType => out.col_ops.push((ColOp::Filter, via.to_string(), true)),
                Verb::AddType => out.col_ops.push((ColOp::Add, via.to_string(), true)),
                Verb::RemoveType => out.col_ops.push((ColOp::Remove, via.to_string(), true)),
                Verb::Sort => {
                    let mut dir = Direction::Ascending;
                    if i < toks.len() && !starts_command(&toks[i]) {
                        if let Some(d) = parse_direction(&toks[i].text) {
                            dir = d;
                            i += 1;
                        }
                    }
                    if let Some(field) = resolve_one(via) {
                        out.sort = Some((field, dir));
                    }
                }
                Verb::Reverse => out.reverse = true, // via is meaningless here - ignored, harmless
            }
            continue;
        }

        // Space form: collect this verb's argument tokens (the following
        // tokens that are not themselves commands, up to each verb's
        // arity).
        let mut args: Vec<String> = Vec::new();
        let max_args = match verb {
            Verb::Reverse => 0,
            Verb::Sort => 2,
            _ => 1,
        };
        while args.len() < max_args && i < toks.len() && !starts_command(&toks[i]) {
            // /sort's optional 2nd arg is only taken if it reads as a
            // direction; otherwise it's a fresh /fv term.
            if verb == Verb::Sort && args.len() == 1 && parse_direction(&toks[i].text).is_none() {
                break;
            }
            args.push(toks[i].text.clone());
            i += 1;
        }

        match verb {
            Verb::FilterValue => {
                if let Some(a) = args.first() {
                    out.filters.push(filter_term(a));
                }
            }
            Verb::FilterType => {
                if let Some(a) = args.first() {
                    out.col_ops.push((ColOp::Filter, a.clone(), false));
                }
            }
            Verb::AddType => {
                if let Some(a) = args.first() {
                    out.col_ops.push((ColOp::Add, a.clone(), false));
                }
            }
            Verb::RemoveType => {
                if let Some(a) = args.first() {
                    out.col_ops.push((ColOp::Remove, a.clone(), false));
                }
            }
            Verb::Sort => {
                if let Some(field) = args.first().and_then(|p| resolve_one(p)) {
                    let dir = args.get(1).and_then(|d| parse_direction(d)).unwrap_or(Direction::Ascending);
                    out.sort = Some((field, dir));
                }
            }
            Verb::Reverse => out.reverse = true,
        }
    }
    out
}

// --- axis 1: row filtering -----------------------------------------------

fn field_value(win: &Window, meta: &TmuxClaudeMeta, field: ResolvedField) -> String {
    match field {
        ResolvedField::Flat(c) => column_value(win, c),
        ResolvedField::Group(g, s) => group_sub_value(meta, g, s),
    }
}

fn term_matches(win: &Window, meta: &TmuxClaudeMeta, term: &FilterTerm) -> bool {
    match term {
        FilterTerm::Free(s) => {
            let haystack = format!("{} {}", win.title, win.class);
            substr(s, &haystack)
        }
        FilterTerm::Scoped { path, value } => {
            let fields = resolve_filter_fields(path);
            !fields.is_empty() && fields.iter().any(|&f| substr(value, &field_value(win, meta, f)))
        }
        FilterTerm::GroupExists(seg) => {
            let groups = resolve_groups(seg);
            !groups.is_empty() && groups.iter().any(|g| group_has_any_value(meta, g))
        }
    }
}

pub fn matches_str(win: &Window, meta: &TmuxClaudeMeta, query: &str) -> bool {
    if query.is_empty() {
        return true;
    }
    parse(query).filters.iter().all(|t| term_matches(win, meta, t))
}

// --- axis 2: column visibility -----------------------------------------

/// Every known field this picker has at all - every flat `COLUMNS` entry
/// plus every subfield of every `GROUPS` entry, in declaration order.
/// What the `/ft/<pattern>` value-fallback (below) searches across, since
/// discovery has to consider fields that aren't even shown right now.
fn every_field() -> Vec<ResolvedField> {
    let mut out: Vec<ResolvedField> = COLUMNS.iter().copied().map(ResolvedField::Flat).collect();
    for (g, subs) in GROUPS {
        out.extend(subs.iter().map(|&s| ResolvedField::Group(g, s)));
    }
    out
}

/// Glob-matches `pattern` against `value`, case-insensitively. No `*` at
/// all in `pattern` is plain substring containment, same as everywhere
/// else in this DSL; a `*` anywhere switches to real glob anchoring
/// (`64*` = starts with, `*64` = ends with, `*64*` = contains - same as
/// plain substring). The one place in the whole grammar `*` means "match
/// anything here" rather than the reserved "all subfields" path segment -
/// see query-dsl.md's "/filter-type's via path can also be a value
/// pattern."
fn glob_match(pattern: &str, value: &str) -> bool {
    let pattern = pattern.to_lowercase();
    let value = value.to_lowercase();
    if !pattern.contains('*') {
        return value.contains(&pattern);
    }
    let starts_wild = pattern.starts_with('*');
    let ends_wild = pattern.ends_with('*');
    let parts: Vec<&str> = pattern.split('*').filter(|p| !p.is_empty()).collect();
    if parts.is_empty() {
        return true; // pattern is just "*" (or "**", ...) - matches anything
    }
    let mut pos = 0usize;
    for (idx, part) in parts.iter().enumerate() {
        let is_first = idx == 0;
        let is_last = idx == parts.len() - 1;
        if is_first && !starts_wild {
            if !value[pos..].starts_with(part) {
                return false;
            }
            pos += part.len();
        } else if is_last && !ends_wild {
            if !value[pos..].ends_with(part) {
                return false;
            }
        } else {
            match value[pos..].find(part) {
                Some(found) => pos += found + part.len(),
                None => return false,
            }
        }
    }
    true
}

/// The `/ft/<pattern>` fallback: every known field (see `every_field`)
/// that has at least one row whose value glob-matches `pattern`. A
/// discovery reset, not a narrowing - the result *replaces* whatever
/// columns were active before, since the point is "show me whichever
/// column(s) actually have this value," not intersecting with what
/// happened to be shown already.
fn fields_matching_value_pattern(pattern: &str, windows: &[Window], metas: &[TmuxClaudeMeta]) -> Vec<ResolvedField> {
    let empty = TmuxClaudeMeta::default();
    every_field()
        .into_iter()
        .filter(|&f| {
            windows.iter().enumerate().any(|(i, w)| {
                let meta = metas.get(i).unwrap_or(&empty);
                glob_match(pattern, &field_value(w, meta, f))
            })
        })
        .collect()
}

/// Applies every column verb in `query`, left to right, to `defaults`.
/// `/ft` intersects the running set with the matching fields, `/at`
/// unions them in at the end, `/rt` subtracts them - unless a `/ft`'s via
/// path doesn't resolve to any known field at all, in which case it
/// falls back to the value-pattern discovery reset instead (see
/// `fields_matching_value_pattern`); `windows`/`metas` are only ever
/// touched for that one fallback case. See query-dsl.md.
pub fn active_columns(
    query: &str,
    defaults: &[ResolvedField],
    windows: &[Window],
    metas: &[TmuxClaudeMeta],
) -> Vec<ResolvedField> {
    let mut cols: Vec<ResolvedField> = defaults.to_vec();
    for (op, path, is_via) in parse(query).col_ops {
        let fields = resolve_column_fields(&path);
        if fields.is_empty() && is_via && matches!(op, ColOp::Filter) {
            cols = fields_matching_value_pattern(&path, windows, metas);
            continue;
        }
        match op {
            ColOp::Filter => cols.retain(|c| fields.contains(c)),
            ColOp::Add => {
                for f in fields {
                    if !cols.contains(&f) {
                        cols.push(f);
                    }
                }
            }
            ColOp::Remove => cols.retain(|c| !fields.contains(c)),
        }
    }
    cols
}

// --- axis 3: sort / reverse -------------------------------------------

pub fn parse_actions(query: &str) -> Actions {
    let p = parse(query);
    Actions { sort: p.sort, reverse: p.reverse }
}

/// A value's shape, sniffed on each side of a comparison independently.
enum ValueShape {
    Int(u64),
    AgeSeconds(u64),
    Text,
}

fn sniff_shape(v: &str) -> ValueShape {
    if let Ok(n) = v.parse::<u64>() {
        return ValueShape::Int(n);
    }
    if let Some(digits) = v.strip_suffix(['s', 'm', 'h', 'd']) {
        if let Ok(n) = digits.parse::<u64>() {
            let mult = match v.chars().last() {
                Some('s') => 1,
                Some('m') => 60,
                Some('h') => 3600,
                Some('d') => 86400,
                _ => unreachable!(),
            };
            return ValueShape::AgeSeconds(n * mult);
        }
    }
    ValueShape::Text
}

/// Compares two type values for `/sort`, sniffing shape on each side:
/// plain ints numerically, `humanize_ago` age buckets by seconds (larger
/// age = earlier moment = sorts first, i.e. chronological ascending),
/// everything else lexicographically. Direction is applied by
/// `compare_with_direction`, except the age-bucket inversion which is
/// baked in here - see query-dsl.md's "direction trap".
fn compare_field_values(a: &str, b: &str) -> std::cmp::Ordering {
    match (sniff_shape(a), sniff_shape(b)) {
        (ValueShape::Int(x), ValueShape::Int(y)) => x.cmp(&y),
        (ValueShape::AgeSeconds(x), ValueShape::AgeSeconds(y)) => y.cmp(&x),
        _ => a.cmp(b),
    }
}

pub fn compare_with_direction(a: &str, b: &str, direction: Direction) -> std::cmp::Ordering {
    let ord = compare_field_values(a, b);
    match direction {
        Direction::Ascending => ord,
        Direction::Descending => ord.reverse(),
    }
}

pub fn sort_field_value(win: &Window, meta: &TmuxClaudeMeta, field: ResolvedField) -> String {
    field_value(win, meta, field)
}

// --- autocompletion ---------------------------------------------------

/// Every distinct non-empty value `field` has across `windows`/`metas`
/// right now, substring-narrowed by `fragment`, deduped and sorted.
pub fn value_suggestions(
    windows: &[Window],
    metas: &[TmuxClaudeMeta],
    field: ResolvedField,
    fragment: &str,
) -> Vec<String> {
    let empty = TmuxClaudeMeta::default();
    let mut seen = std::collections::BTreeSet::new();
    for (i, w) in windows.iter().enumerate() {
        let meta = metas.get(i).unwrap_or(&empty);
        let v = field_value(w, meta, field);
        if !v.is_empty() && substr(fragment, &v) {
            seen.insert(v);
        }
    }
    seen.into_iter().collect()
}

/// Type-path candidates for `fragment` (which may contain a `.`): flat
/// type names and group names before a dot, that group's subfields plus
/// `*` after one. Each ready to splice in after the verb.
fn path_suggestions(fragment: &str) -> Vec<String> {
    if let Some((g_seg, s_seg)) = fragment.split_once('.') {
        let groups = resolve_groups(g_seg);
        let [group] = groups[..] else { return Vec::new() };
        let mut out: Vec<String> =
            resolve_group_subs(group, s_seg).into_iter().map(|s| format!("{group}.{s}")).collect();
        if substr(s_seg, "*") {
            out.push(format!("{group}.*"));
        }
        return out;
    }
    let mut out: Vec<String> =
        COLUMNS.iter().filter(|c| substr(fragment, c)).map(|c| c.to_string()).collect();
    out.extend(resolve_groups(fragment).iter().map(|g| g.to_string()));
    out
}

/// Which stage the completion popup is in. Exactly one is live at a time.
pub enum Completion {
    /// `/frag` - a verb is being typed. Candidates are the short forms.
    Verb { start: usize, fragment: String },
    /// A type path is being typed as `verb`'s argument - either the
    /// space-form argument, or (`via: true`) a path glued onto the verb
    /// with a second `/` (`start` already points past that `/`, either
    /// way). Accepting a via path never appends a colon even for `/fv`
    /// (see `SuggestionKind::TypePath` in ui.rs) - the via form has no
    /// colon in it at all.
    TypePath { start: usize, verb: Verb, fragment: String, via: bool },
    /// `/fv path:frag` - `path` unambiguous - candidates are that type's
    /// live values; accepting has to reconstruct the whole `path:value`
    /// (see `SuggestionKind::Value` in ui.rs), since `frag` here is only
    /// the value half of one combined token.
    Value { start: usize, field: ResolvedField, fragment: String },
    /// A bare value with nothing to reconstruct on accept - either scoped
    /// to one field (`/fv/path frag`, the via form already supplied the
    /// path) or pooled across *every* field when `field` is `None`
    /// (`/ft/frag` where `frag` doesn't resolve to any known type/group at
    /// all - the value-pattern fallback, see query-dsl.md - the whole
    /// point there is discovering *which* field has a match).
    BareValue { start: usize, field: Option<ResolvedField>, fragment: String },
    /// `/s path frag`, `path` unambiguous - candidates are the directions.
    /// `field` is kept for call sites that want to show the resolved sort
    /// key alongside the direction choices.
    #[allow(dead_code)]
    SortDirection { start: usize, field: ResolvedField, fragment: String },
}

/// Replays argument consumption over every token *except the last*, to
/// learn which slot the last (still-being-typed) token occupies.
enum Open {
    /// No command is waiting for more arguments.
    None,
    /// `verb` has consumed `args` argument(s) and can take more. A via
    /// path (see `tok_verb`) seeds this exactly as if it had already been
    /// consumed as the first space-form argument - the two spellings are
    /// indistinguishable from here on, which is what lets `/fv/path frag`
    /// reach the same `Value` completion stage `/fv path frag` (space
    /// form, path already typed) already did.
    Verb { verb: Verb, args: Vec<String> },
}

fn replay(context: &[Tok]) -> Open {
    let mut open = Open::None;
    for tok in context {
        loop {
            match &mut open {
                Open::None => {
                    match tok_verb(tok) {
                        None => {} // bare value or inert /... - nothing to track
                        Some((Verb::Reverse, _)) => {} // consumes nothing (via ignored), stays closed
                        // FilterType/AddType/RemoveType have no argument
                        // beyond their one path - a via already supplies
                        // it, so there's nothing left open.
                        Some((Verb::FilterType | Verb::AddType | Verb::RemoveType, Some(_))) => {}
                        Some((v, Some(via))) => open = Open::Verb { verb: v, args: vec![via.to_string()] },
                        Some((v, None)) => open = Open::Verb { verb: v, args: Vec::new() },
                    }
                    break;
                }
                Open::Verb { verb, args } => {
                    let verb = *verb;
                    if starts_command(tok) {
                        open = Open::None;
                        continue; // reprocess this token as a fresh command
                    }
                    match verb {
                        Verb::Sort => {
                            if args.is_empty() {
                                args.push(tok.text.clone()); // path; still open for a direction
                            } else if parse_direction(&tok.text).is_some() {
                                open = Open::None; // direction consumed
                            } else {
                                open = Open::None; // not a direction - sort closes
                                continue;
                            }
                        }
                        Verb::Reverse => unreachable!(),
                        _ => {
                            open = Open::None; // single arg consumed
                        }
                    }
                    break;
                }
            }
        }
    }
    open
}

pub fn completion_context(query: &str) -> Option<Completion> {
    let toks = tokenize(query);
    if toks.is_empty() {
        return None; // nothing typed - no popup
    }
    // A trailing space means the last token is complete and the cursor is
    // at a fresh (empty) argument position; otherwise the last token is
    // still being typed.
    let trailing_space = query.ends_with(char::is_whitespace);
    let (context, start, frag, lead_quote) = if trailing_space {
        (&toks[..], query.len(), String::new(), false)
    } else {
        let last = toks.last().unwrap();
        (&toks[..toks.len() - 1], last.start, last.text.clone(), last.lead_quote)
    };
    if lead_quote {
        return None; // a quoted literal offers nothing
    }

    // Typing a verb: `/frag`, no space after it yet - or, if a verb name
    // is already complete and a second `/` follows, typing *its* via
    // path instead (`/ft/frag2`). `start` is adjusted past both `/`s so
    // completion offers just the via path, not the verb name too.
    if let Some(rest) = frag.strip_prefix('/') {
        if let Some((name, via_frag)) = rest.split_once('/') {
            let verb = Verb::parse(name)?;
            let via_start = start + 1 + name.len() + 1; // "/" + name + "/"
            if verb == Verb::FilterType && path_suggestions(via_frag).is_empty() {
                // Doesn't resolve as any known type/group - offer the
                // value-pattern fallback's own completion instead (see
                // query-dsl.md).
                return Some(Completion::BareValue { start: via_start, field: None, fragment: via_frag.to_string() });
            }
            return Some(Completion::TypePath { start: via_start, verb, fragment: via_frag.to_string(), via: true });
        }
        return Some(Completion::Verb { start, fragment: rest.to_string() });
    }

    // Otherwise `frag` is an argument. Which command owns it?
    match replay(context) {
        Open::Verb { verb, args } if verb.takes_path() => {
            if verb == Verb::Sort && args.len() == 1 {
                // path already given (space-form or via) - `frag` is the
                // direction, if the path resolved unambiguously;
                // otherwise keep completing the (ambiguous) path.
                return match resolve_one(&args[0]) {
                    Some(field) => Some(Completion::SortDirection { start, field, fragment: frag }),
                    None => Some(Completion::TypePath { start, verb, fragment: frag, via: false }),
                };
            }
            if verb == Verb::FilterValue {
                if args.len() == 1 {
                    // via already supplied the path (`/fv/path `) - `frag`
                    // is a bare value: same live-value corpus `/fv
                    // path:frag` (below) draws from, but nothing to
                    // reconstruct on accept (the path's already in the
                    // query text, not part of this token).
                    return match resolve_one(&args[0]) {
                        Some(field) => Some(Completion::BareValue { start, field: Some(field), fragment: frag }),
                        None => Some(Completion::TypePath { start, verb, fragment: frag, via: false }),
                    };
                }
                // `/fv path:frag` - value stage once a colon is present.
                if let Some((path, val_frag)) = frag.split_once(':') {
                    let field = resolve_one(path)?;
                    return Some(Completion::Value { start, field, fragment: val_frag.to_string() });
                }
            }
            Some(Completion::TypePath { start, verb, fragment: frag, via: false })
        }
        _ => None, // a bare value, or nothing open after a space
    }
}

/// Candidate strings for a `Completion`. `windows`/`metas` are only used
/// for the `Value` and `BareValue` stages.
pub fn completion_candidates(completion: &Completion, windows: &[Window], metas: &[TmuxClaudeMeta]) -> Vec<String> {
    match completion {
        Completion::Verb { fragment, .. } => {
            VERB_SHORTS.iter().filter(|v| substr(fragment, v)).map(|v| v.to_string()).collect()
        }
        Completion::TypePath { fragment, .. } => path_suggestions(fragment),
        Completion::Value { field, fragment, .. } => value_suggestions(windows, metas, *field, fragment),
        Completion::BareValue { field: Some(field), fragment, .. } => value_suggestions(windows, metas, *field, fragment),
        Completion::BareValue { field: None, fragment, .. } => {
            // Pooled across every field (not just one) - the whole point
            // is discovering *which* field has a matching value.
            let mut seen = std::collections::BTreeSet::new();
            for field in every_field() {
                seen.extend(value_suggestions(windows, metas, field, fragment));
            }
            seen.into_iter().collect()
        }
        Completion::SortDirection { fragment, .. } => {
            resolve_directions(fragment).iter().map(|d| d.to_string()).collect()
        }
    }
}

/// Whether a completed type-path token names a group (so accepting it can
/// leave a trailing `.` ready for a subfield) rather than a flat type.
pub fn is_group(candidate: &str) -> bool {
    !candidate.contains('.') && GROUPS.iter().any(|(g, _)| *g == candidate)
}

// --- inline command-validity spans (see query-dsl.md's "Inline
// command-validity coloring") -------------------------------------------

/// Every `/`-led token in `query` that's unambiguously a *command*
/// attempt - `(byte_start, byte_end, is_valid)` for each, in order. Skips
/// a still-forming prefix of a real verb (e.g. `/f` while typing `/fv`) -
/// that's not wrong yet, just incomplete, so a caller rendering this
/// should leave it in the ordinary text color rather than either accent.
/// Scoped to the verb name only: `/fv/bogus_field` is still "valid" here
/// even though `bogus_field` won't resolve to anything - a `/ft` via that
/// doesn't resolve is a *legitimate* value-pattern (see
/// `fields_matching_value_pattern`), not a mistake, so this doesn't try
/// to also judge the via/argument, only whether the command itself
/// exists.
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
            continue; // just "/" typed so far - too early to call wrong
        }
        let name = rest.split_once('/').map(|(n, _)| n).unwrap_or(rest);
        let valid = Verb::parse(name).is_some();
        if !valid && is_verb_prefix(rest) {
            continue; // still forming - neutral, not wrong yet
        }
        out.push((tok.start, tok.start + tok.text.len(), valid));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn win(title: &str, class: &str, workspace: &str, pid: i32) -> Window {
        Window {
            address: "0x0".to_string(),
            class: class.to_string(),
            title: title.to_string(),
            workspace: workspace.to_string(),
            pid,
            width: 800,
            height: 600,
        }
    }

    fn no_meta() -> TmuxClaudeMeta {
        TmuxClaudeMeta::default()
    }

    fn matches_win(w: &Window, q: &str) -> bool {
        matches_str(w, &no_meta(), q)
    }

    /// `active_columns` with no windows/metas - for every test that
    /// doesn't exercise the `/ft/<pattern>` value-fallback.
    fn cols(query: &str, defaults: &[ResolvedField]) -> Vec<ResolvedField> {
        active_columns(query, defaults, &[], &[])
    }

    #[test]
    fn substr_is_containment_not_subsequence() {
        assert!(substr("rit", "alacritty"));
        assert!(substr("crit", "alacritty")); // alaCRITty - contiguous
        assert!(!substr("actt", "alacritty")); // not contiguous
        assert!(substr("", "anything"));
        assert!(substr("ALA", "alacritty"));
    }

    #[test]
    fn verb_parsing_is_exact_short_and_long() {
        assert_eq!(Verb::parse("fv"), Some(Verb::FilterValue));
        assert_eq!(Verb::parse("filter-value"), Some(Verb::FilterValue));
        assert_eq!(Verb::parse("s"), Some(Verb::Sort));
        assert_eq!(Verb::parse("sort"), Some(Verb::Sort));
        assert_eq!(Verb::parse("filter"), None); // no fuzzy
        assert_eq!(Verb::parse("f"), None);
    }

    #[test]
    fn bare_text_and_fv_are_identical() {
        let w = win("My Terminal", "Alacritty", "1", 100);
        assert!(matches_win(&w, "terminal"));
        assert!(matches_win(&w, "/fv terminal"));
        assert!(matches_win(&w, "/filter-value terminal"));
        assert!(!matches_win(&w, "firefox"));
        assert!(!matches_win(&w, "/fv firefox"));
    }

    #[test]
    fn scoped_filter_by_type_and_value() {
        let w = win("hyprpm build log", "Alacritty", "1", 100);
        assert!(matches_win(&w, "/fv title:hyprpm"));
        assert!(!matches_win(&w, "/fv title:firefox"));
        // type name substring-resolves
        assert!(matches_win(&w, "/fv tit:build"));
        assert!(matches_win(&w, "/fv wor:1")); // workspace, not title
        assert!(!matches_win(&w, "/fv wor:2"));
    }

    #[test]
    fn multiple_filters_are_anded() {
        let w = win("hyprpm build log", "Alacritty", "1", 100);
        assert!(matches_win(&w, "/fv title:hyprpm /fv workspace:1"));
        assert!(matches_win(&w, "hyprpm /fv workspace:1"));
        assert!(!matches_win(&w, "hyprpm firefox"));
    }

    #[test]
    fn unresolvable_scoped_filter_narrows_to_nothing() {
        let w = win("hyprpm", "Alacritty", "1", 100);
        assert!(!matches_win(&w, "/fv zzz:hyprpm"));
    }

    #[test]
    fn quoted_value_is_a_literal_substring() {
        let w = win("Imperial Rome", "Alacritty", "1", 100);
        assert!(matches_win(&w, r#"/fv title:"imperial rome""#));
        assert!(matches_win(&w, r#"/fv title:"perial ro""#));
        assert!(!matches_win(&w, r#"/fv title:"imp rom""#)); // not contiguous
    }

    #[test]
    fn unknown_slash_token_is_literal_but_verb_prefix_is_inert() {
        let w = win("open /usr/bin/env", "X", "1", 1);
        assert!(matches_win(&w, "/usr/bin")); // not a verb, not a prefix -> literal
        assert!(!matches_win(&w, "/usr/nope"));
        // "/f" could still become /fv or /ft -> inert, matches everything
        assert!(matches_win(&w, "/f"));
        assert!(matches_win(&w, "/filter"));
    }

    #[test]
    fn quote_led_token_is_never_a_command() {
        let w = win(r#"say /fv out loud"#, "X", "1", 1);
        assert!(matches_win(&w, r#""/fv""#)); // literal text search for "/fv"
    }

    #[test]
    fn pid_field_matches_numeric_string() {
        let w = win("t", "c", "1", 12345);
        assert!(matches_win(&w, "/fv pid:234"));
        assert!(!matches_win(&w, "/fv pid:999"));
    }

    #[test]
    fn group_scoped_and_star_and_existence() {
        let w = win("t", "c", "1", 100);
        let mut meta = TmuxClaudeMeta::default();
        meta.tmux_session = Some("work".to_string());
        meta.tmux_title = Some("hyprpm build log".to_string());

        assert!(matches_str(&w, &meta, "/fv tmux:hyprpm")); // bare group -> .title
        assert!(!matches_str(&w, &meta, "/fv tmux:work"));
        assert!(matches_str(&w, &meta, "/fv tmux.session:work"));
        assert!(matches_str(&w, &meta, "/fv tmux.*:work"));
        assert!(matches_str(&w, &meta, "/fv tmux.*:hyprpm"));
        assert!(!matches_str(&w, &meta, "/fv tmux.*:nope"));

        // colonless group -> existence
        assert!(matches_str(&w, &meta, "/fv tmux"));
        assert!(matches_str(&w, &meta, "tmux")); // bare, identical
        assert!(!matches_str(&w, &meta, "/fv claude"));
    }

    #[test]
    fn via_path_shorthand() {
        let w = win("desk", "c", "1", 100);
        let mut meta = TmuxClaudeMeta::default();
        meta.claude_title = Some("Waybar to quickshell migration".to_string());
        meta.claude_path = Some("/home/user1/dotfiles".to_string());
        meta.claude_contents = Some("discussed sysmond socket reconnect".to_string());

        // `/fv/path value` - the path glued onto the verb with a 2nd `/`,
        // no colon needed - means exactly what `/fv path:value` does.
        assert!(matches_str(&w, &meta, "/fv/claude.contents sysmond"));
        assert!(!matches_str(&w, &meta, "/fv/claude.contents quickshell")); // .contents only, not .title
        assert!(matches_str(&w, &meta, "/fv/claude.title quickshell"));
        assert!(matches_str(&w, &meta, "/fv/claude.path dotfiles"));
        // same thing, the original colon spelling
        assert!(matches_str(&w, &meta, "/fv claude.contents:sysmond"));

        // Bare `/fv/claude` defaults to `.contents` specifically
        // (`GROUP_DEFAULT_SUB`), not `.title` - transcript text is far
        // more useful to search by default than the title.
        assert!(matches_str(&w, &meta, "/fv/claude sysmond"));
        assert!(!matches_str(&w, &meta, "/fv/claude quickshell"));
        // the colon form honors the same (now-unified) default
        assert!(matches_str(&w, &meta, "/fv claude:sysmond"));

        // No value at all, bare group -> existence check across the
        // *whole* group (`filter_term`'s existing colonless-group rule,
        // unchanged) - not scoped to the default sub, which only matters
        // once a value follows. A *dotted* colonless via like
        // `/fv/claude.title` isn't special-cased there either, same as it
        // never was for the space form: it degrades to a literal text
        // search instead, not a per-subfield existence check.
        let mut title_only = TmuxClaudeMeta::default();
        title_only.claude_title = Some("some session".to_string());
        assert!(matches_str(&w, &title_only, "/fv/claude")); // title alone is enough
        assert!(!matches_str(&w, &no_meta(), "/fv/claude"));

        // A via term combines with an ordinary bare word, AND'ed like any
        // other pair of filter terms.
        assert!(matches_str(&w, &meta, "/fv/claude.contents sysmond desk"));
        assert!(!matches_str(&w, &meta, "/fv/claude.contents sysmond nope"));

        // Every path-taking verb accepts a via path the same way -
        // `/s/claude.time`, `/ft/claude`, `/at/claude.*`, `/rt/tmux.session`
        // all mean exactly what the space form already did (see the
        // column-verb and sort tests below for those).
        let mut tmux_meta = TmuxClaudeMeta::default();
        tmux_meta.tmux_title = Some("hyprpm build log".to_string());
        assert!(matches_str(&w, &tmux_meta, "/fv/tmux hyprpm")); // defaults to .title, same as the general default
        assert!(matches_str(&w, &tmux_meta, "/fv/tmux.title hyprpm"));
    }

    #[test]
    fn via_path_works_on_every_path_taking_verb() {
        let defaults = [ResolvedField::Flat("title")];
        assert_eq!(cols("/ft/claude", &defaults), Vec::<ResolvedField>::new());
        assert_eq!(
            cols("/at/claude.title", &defaults),
            vec![ResolvedField::Flat("title"), ResolvedField::Group("claude", "title")]
        );
        assert_eq!(
            cols("/at/claude.title /rt/claude.title", &defaults),
            vec![ResolvedField::Flat("title")]
        );
        let a = parse_actions("/s/claude.time");
        assert_eq!(a.sort, Some((ResolvedField::Group("claude", "time"), Direction::Ascending)));
        let a = parse_actions("/s/workspace descending");
        assert_eq!(a.sort, Some((ResolvedField::Flat("workspace"), Direction::Descending)));
        // a trailing token that isn't a direction falls through as its
        // own /fv term, same as the space form
        let w = win("workspace foo", "X", "1", 1);
        assert!(matches_str(&w, &no_meta(), "/s/title foo"));
        assert!(!matches_str(&w, &no_meta(), "/s/title bar"));
    }

    // --- column verbs --------------------------------------------------

    #[test]
    fn add_and_remove_columns_left_to_right() {
        let defaults = [ResolvedField::Flat("workspace"), ResolvedField::Flat("title")];
        assert_eq!(cols("", &defaults), defaults.to_vec());
        assert_eq!(cols("/rt workspace", &defaults), vec![ResolvedField::Flat("title")]);
        assert_eq!(
            cols("/at claude.title", &defaults),
            vec![
                ResolvedField::Flat("workspace"),
                ResolvedField::Flat("title"),
                ResolvedField::Group("claude", "title"),
            ]
        );
        // remove then re-add ends with it back, at the end
        assert_eq!(
            cols("/at claude.title /rt claude.title /at claude.title", &defaults),
            vec![
                ResolvedField::Flat("workspace"),
                ResolvedField::Flat("title"),
                ResolvedField::Group("claude", "title"),
            ]
        );
    }

    #[test]
    fn filter_type_intersects_current_columns() {
        let defaults = [
            ResolvedField::Flat("workspace"),
            ResolvedField::Flat("title"),
            ResolvedField::Flat("pid"),
        ];
        // keep only the columns whose name contains "t" ("workspace"/"pid" have none)
        assert_eq!(cols("/ft t", &defaults), vec![ResolvedField::Flat("title")]);
        // "s" keeps workspace only
        assert_eq!(cols("/ft s", &defaults), vec![ResolvedField::Flat("workspace")]);
        // ft never reveals a hidden column
        assert_eq!(cols("/ft claude", &defaults), Vec::<ResolvedField>::new());
        // ft then at: narrow, then bring one back
        assert_eq!(
            cols("/ft title /at workspace", &defaults),
            vec![ResolvedField::Flat("title"), ResolvedField::Flat("workspace")]
        );
    }

    #[test]
    fn add_bare_group_adds_every_subfield() {
        let expected = vec![
            ResolvedField::Group("claude", "title"),
            ResolvedField::Group("claude", "path"),
            ResolvedField::Group("claude", "session"),
            ResolvedField::Group("claude", "time"),
            ResolvedField::Group("claude", "contents"),
        ];
        assert_eq!(cols("/at claude", &[]), expected);
        assert_eq!(cols("/at claude.*", &[]), expected);
        assert_eq!(cols("/at claude.title", &[]), vec![ResolvedField::Group("claude", "title")]);
    }

    #[test]
    fn column_verbs_are_not_row_filters() {
        let w = win("something else entirely", "X", "1", 1);
        assert!(matches_str(&w, &no_meta(), "/at workspace"));
        assert!(matches_str(&w, &no_meta(), "/ft title"));
        assert!(matches_str(&w, &no_meta(), "/rt pid"));
    }

    // --- sort / reverse ----------------------------------------------

    #[test]
    fn sort_resolves_field_and_direction() {
        let a = parse_actions("/sort workspace");
        assert_eq!(a.sort, Some((ResolvedField::Flat("workspace"), Direction::Ascending)));
        let a = parse_actions("/s workspace descending");
        assert_eq!(a.sort, Some((ResolvedField::Flat("workspace"), Direction::Descending)));
        let a = parse_actions("/s workspace desc");
        assert_eq!(a.sort, Some((ResolvedField::Flat("workspace"), Direction::Descending)));
        // nested group field
        let a = parse_actions("/sort tmux.session asc");
        assert_eq!(a.sort, Some((ResolvedField::Group("tmux", "session"), Direction::Ascending)));
    }

    #[test]
    fn sort_second_arg_thats_not_a_direction_is_a_separate_fv_term() {
        let w = win("workspace foo", "X", "1", 1);
        // "foo" is not a direction -> it's an implicit /fv term
        assert!(matches_str(&w, &no_meta(), "/sort title foo"));
        assert!(!matches_str(&w, &no_meta(), "/sort title bar"));
        assert_eq!(
            parse_actions("/sort title foo").sort,
            Some((ResolvedField::Flat("title"), Direction::Ascending))
        );
    }

    #[test]
    fn last_sort_wins_reverse_idempotent() {
        assert_eq!(
            parse_actions("/sort workspace /sort title").sort,
            Some((ResolvedField::Flat("title"), Direction::Ascending))
        );
        assert!(parse_actions("/reverse").reverse);
        assert!(parse_actions("/rv").reverse);
        assert!(parse_actions("/rv /rv").reverse);
        assert!(!parse_actions("plain text").reverse);
    }

    #[test]
    fn malformed_sort_is_inert() {
        assert!(parse_actions("/sort zzz").sort.is_none());
        assert!(parse_actions("/sort").sort.is_none());
        assert!(parse_actions("/sort claude.*").sort.is_none()); // not one field
    }

    #[test]
    fn actions_are_not_row_filters() {
        let w = win("title descending", "X", "1", 1);
        assert!(matches_str(&w, &no_meta(), "/sort class descending"));
        assert!(matches_str(&w, &no_meta(), "/reverse"));
    }

    // --- completion --------------------------------------------------

    #[test]
    fn verb_stage() {
        let Some(Completion::Verb { fragment, .. }) = completion_context("/") else { panic!() };
        assert_eq!(fragment, "");
        let cands = completion_candidates(&Completion::Verb { start: 0, fragment }, &[], &[]);
        assert_eq!(cands, vec!["fv", "ft", "at", "rt", "s", "rv"]);
        let Some(Completion::Verb { fragment, .. }) = completion_context("/f") else { panic!() };
        let cands = completion_candidates(&Completion::Verb { start: 0, fragment }, &[], &[]);
        assert_eq!(cands, vec!["fv", "ft"]);
    }

    #[test]
    fn via_path_stage_after_a_verb_and_second_slash() {
        // `/ft/cla` - verb already complete, now typing its via path
        // (not the space form) - same TypePath stage the space form
        // reaches, `via: true`, `start` past both `/`s.
        let Some(Completion::TypePath { verb, fragment, via, start }) = completion_context("/ft/cla") else {
            panic!()
        };
        assert_eq!((verb, fragment.as_str(), via, start), (Verb::FilterType, "cla", true, 4));
        let cands = completion_candidates(
            &Completion::TypePath { start: 0, verb: Verb::FilterType, fragment: "cla".to_string(), via: true },
            &[],
            &[],
        );
        assert_eq!(cands, vec!["claude"]);
    }

    #[test]
    fn type_path_stage_after_a_verb_and_space() {
        let Some(Completion::TypePath { verb, fragment, .. }) = completion_context("/ft ") else { panic!() };
        assert_eq!(verb, Verb::FilterType);
        assert_eq!(fragment, "");
        let Some(Completion::TypePath { fragment, .. }) = completion_context("/at cla") else { panic!() };
        assert_eq!(fragment, "cla");
        let cands = completion_candidates(
            &Completion::TypePath { start: 0, verb: Verb::AddType, fragment: "cla".to_string(), via: false },
            &[],
            &[],
        );
        // "class" is gone (not a useful column, see query-dsl.md); "cla" now
        // resolves only to "claude" -- no more accidental double-match.
        assert_eq!(cands, vec!["claude"]);
        let cands = completion_candidates(
            &Completion::TypePath { start: 0, verb: Verb::AddType, fragment: "tmux.".to_string(), via: false },
            &[],
            &[],
        );
        assert!(cands.contains(&"tmux.session".to_string()));
        assert!(cands.contains(&"tmux.*".to_string()));
    }

    #[test]
    fn value_stage_after_fv_path_colon() {
        let Some(Completion::Value { field, fragment, .. }) = completion_context("/fv workspace:") else {
            panic!()
        };
        assert_eq!((field, fragment.as_str()), (ResolvedField::Flat("workspace"), ""));
        let Some(Completion::Value { field, .. }) = completion_context("/fv tmux:foo") else { panic!() };
        assert_eq!(field, ResolvedField::Group("tmux", "title"));
        // ambiguous path before the colon -> no completion offered
        assert!(completion_context("/fv c:x").is_none());
    }

    #[test]
    fn via_path_value_stage() {
        // `/fv/claude.contents ` (space, no value typed yet) - live value
        // completion for that one field, same corpus as `/fv path:`, but
        // as a `BareValue` (not `Value`) since accepting splices back
        // differently - no `field:` prefix to reconstruct (see
        // `SuggestionKind::BareValue` in ui.rs).
        let Some(Completion::BareValue { field: Some(field), fragment, .. }) =
            completion_context("/fv/claude.contents ")
        else {
            panic!()
        };
        assert_eq!((field, fragment.as_str()), (ResolvedField::Group("claude", "contents"), ""));
        let Some(Completion::BareValue { field: Some(field), fragment, .. }) =
            completion_context("/fv/claude.contents li")
        else {
            panic!()
        };
        assert_eq!((field, fragment.as_str()), (ResolvedField::Group("claude", "contents"), "li"));
        // bare `/fv/claude` defaults to `.contents` here too
        let Some(Completion::BareValue { field: Some(field), .. }) = completion_context("/fv/claude ") else {
            panic!()
        };
        assert_eq!(field, ResolvedField::Group("claude", "contents"));
    }

    #[test]
    fn ft_value_pattern_fallback() {
        let windows = vec![win("a", "c", "64", 1), win("b", "c", "2", 2)];
        let metas = vec![no_meta(), no_meta()];
        let defaults = [ResolvedField::Flat("title")];
        // "64*" doesn't resolve as any known type/group -> falls back to
        // matching column *values*: "workspace" is "64" on window a.
        assert_eq!(
            active_columns("/ft/64*", &defaults, &windows, &metas),
            vec![ResolvedField::Flat("workspace")]
        );
        // no `*` at all -> plain substring, same result here
        assert_eq!(
            active_columns("/ft/64", &defaults, &windows, &metas),
            vec![ResolvedField::Flat("workspace")]
        );
        // a pattern matching nothing -> empty, not the original defaults
        // (this is a discovery reset, not an intersect)
        assert_eq!(active_columns("/ft/zzz_no_match", &defaults, &windows, &metas), Vec::<ResolvedField>::new());
        // a path that *does* resolve as a real type/group never falls
        // back, even if it happens to contain a "*"-free literal - this
        // is ordinary /ft-by-name, unchanged
        assert_eq!(active_columns("/ft/title", &defaults, &windows, &metas), vec![ResolvedField::Flat("title")]);

        // completion offers live values pooled across every field
        let Some(Completion::BareValue { field: None, fragment, .. }) = completion_context("/ft/6") else {
            panic!()
        };
        assert_eq!(fragment, "6");
        let cands = completion_candidates(
            &Completion::BareValue { start: 0, field: None, fragment: "6".to_string() },
            &windows,
            &metas,
        );
        assert!(cands.contains(&"64".to_string()));
    }

    #[test]
    fn glob_match_star_and_no_star() {
        assert!(glob_match("64", "64"));
        assert!(glob_match("64", "workspace 64 here")); // no star -> plain substring
        assert!(glob_match("64*", "64"));
        assert!(glob_match("64*", "64x"));
        assert!(!glob_match("64*", "x64"));
        assert!(glob_match("*64", "x64"));
        assert!(!glob_match("*64", "64x"));
        assert!(glob_match("*64*", "x64x"));
        assert!(glob_match("*", "anything"));
    }

    #[test]
    fn sort_direction_stage() {
        let Some(Completion::SortDirection { field, fragment, .. }) = completion_context("/s workspace ") else {
            panic!()
        };
        assert_eq!(field, ResolvedField::Flat("workspace"));
        assert_eq!(fragment, "");
        let Some(Completion::SortDirection { fragment, .. }) = completion_context("/sort title de") else {
            panic!()
        };
        let cands = completion_candidates(
            &Completion::SortDirection { start: 0, field: ResolvedField::Flat("title"), fragment },
            &[],
            &[],
        );
        assert_eq!(cands, vec!["descending"]);
    }

    #[test]
    fn value_suggestions_deduped_sorted_substring() {
        let windows = vec![
            win("a", "Firefox", "1", 1),
            win("b", "Alacritty", "1", 2),
            win("c", "Alacritty", "2", 3),
            win("d", "kitty", "", 4),
        ];
        let metas = vec![no_meta(), no_meta(), no_meta(), no_meta()];
        assert_eq!(value_suggestions(&windows, &metas, ResolvedField::Flat("workspace"), ""), vec!["1", "2"]);
        assert_eq!(value_suggestions(&windows, &metas, ResolvedField::Flat("pid"), ""), vec!["1", "2", "3", "4"]);
    }

    // --- comparator ------------------------------------------------

    #[test]
    fn numeric_and_age_compare() {
        use std::cmp::Ordering;
        assert_eq!(compare_field_values("2", "10"), Ordering::Less);
        assert_eq!(compare_field_values("2d", "3h"), Ordering::Less); // older first
        assert_eq!(compare_field_values("30s", "5m"), Ordering::Greater);
        assert_eq!(compare_with_direction("5m", "3h", Direction::Descending), Ordering::Less); // newest first
        assert_eq!(compare_with_direction("apple", "banana", Direction::Descending), Ordering::Greater);
    }

    // --- command-validity spans -------------------------------------

    #[test]
    fn command_spans_marks_real_verbs_valid() {
        let q = "/fv foo";
        assert_eq!(command_spans(q), vec![(0, 3, true)]); // "/fv"
        let q = "/fv/claude.title foo";
        assert_eq!(command_spans(q), vec![(0, 16, true)]); // whole "/fv/claude.title" token
        let q = "foo /sort bar";
        assert_eq!(command_spans(q), vec![(4, 9, true)]); // "/sort"
    }

    #[test]
    fn command_spans_marks_unknown_verbs_invalid() {
        let q = "/xyz foo";
        assert_eq!(command_spans(q), vec![(0, 4, false)]);
        // looks command-shaped (starts with /) but isn't a real verb or a
        // prefix of one - not silently ignored, flagged
        let q = "/usr/bin";
        assert_eq!(command_spans(q), vec![(0, 8, false)]);
    }

    #[test]
    fn command_spans_leaves_still_forming_prefixes_neutral() {
        assert!(command_spans("/f").is_empty());
        assert!(command_spans("/filter").is_empty());
        assert!(command_spans("/").is_empty());
        // a bare word, or a quoted literal, is never a command attempt
        assert!(command_spans("plain text").is_empty());
        assert!(command_spans(r#""/fv""#).is_empty());
    }

    #[test]
    fn command_spans_multiple_tokens_independent() {
        let q = "/fv foo /xyz bar /sort baz";
        let spans = command_spans(q);
        assert_eq!(spans.len(), 3);
        assert_eq!(spans[0], (0, 3, true)); // /fv
        assert_eq!(spans[1], (8, 12, false)); // /xyz
        assert_eq!(spans[2], (17, 22, true)); // /sort
    }
}
