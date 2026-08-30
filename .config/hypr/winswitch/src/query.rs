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
//! Everything that is *not* a verb - type-path segments, filter values,
//! sort directions - is matched by case-insensitive substring
//! containment, with every match unioned for a path segment. No
//! subsequence, no regex; `*` (as in `claude.*`) is one hand-parsed
//! reserved segment meaning "every subfield of the group".
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
const COLUMNS: &[&str] = &["title", "class", "workspace", "pid"];

/// Group name -> its own subfield list, in display order. Add a new
/// group's data to `enrich::TmuxClaudeMeta` and `group_sub_value`
/// together.
const GROUPS: &[(&str, &[&str])] = &[
    ("tmux", &["session", "window", "title"]),
    ("claude", &["title", "path", "session", "contents"]),
];

/// What a bare `group` path resolves its group to for *filtering and
/// sorting* (a column verb instead takes every subfield - see
/// `resolve_column_fields`).
const GROUP_DEFAULT_SUB: &str = "title";

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
/// text and does get searched.
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
        "class" => win.class.clone(),
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

/// A parsed row-filter term (from a bare word or a `/fv` command).
enum FilterTerm {
    /// Substring over the free-text haystack (title + class).
    Free(String),
    /// `path:value` - substring `value` against every type `path`
    /// resolves to.
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

/// The verb a token names, or `None` if it isn't a `/verb` (or is a
/// quote-led literal).
fn tok_verb(tok: &Tok) -> Option<Verb> {
    if tok.lead_quote {
        return None;
    }
    tok.text.strip_prefix('/').and_then(Verb::parse)
}

/// True if a token would begin (or continue typing) a command rather than
/// serve as an argument - a complete `/verb` or a `/prefix` still on its
/// way to being one. A literal `/usr/bin` is neither, so it *can* be an
/// argument.
fn starts_command(tok: &Tok) -> bool {
    if tok.lead_quote {
        return false;
    }
    match tok.text.strip_prefix('/') {
        Some(rest) => Verb::parse(rest).is_some() || is_verb_prefix(rest),
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
            out.extend(resolve_groups(seg).into_iter().map(|g| ResolvedField::Group(g, GROUP_DEFAULT_SUB)));
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
            c.extend(resolve_groups(seg).into_iter().map(|g| ResolvedField::Group(g, GROUP_DEFAULT_SUB)));
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
    col_ops: Vec<(ColOp, String)>,
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
        let Some(verb) = tok_verb(tok) else {
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
        // Collect this verb's argument tokens: the following tokens that
        // are not themselves commands, up to each verb's arity.
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
                    out.col_ops.push((ColOp::Filter, a.clone()));
                }
            }
            Verb::AddType => {
                if let Some(a) = args.first() {
                    out.col_ops.push((ColOp::Add, a.clone()));
                }
            }
            Verb::RemoveType => {
                if let Some(a) = args.first() {
                    out.col_ops.push((ColOp::Remove, a.clone()));
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

/// Applies every column verb in `query`, left to right, to `defaults`.
/// `/ft` intersects the running set with the matching fields, `/at`
/// unions them in at the end, `/rt` subtracts them. See query-dsl.md.
pub fn active_columns(query: &str, defaults: &[ResolvedField]) -> Vec<ResolvedField> {
    let mut cols: Vec<ResolvedField> = defaults.to_vec();
    for (op, path) in parse(query).col_ops {
        let fields = resolve_column_fields(&path);
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
    /// A type path is being typed as `verb`'s argument.
    TypePath { start: usize, verb: Verb, fragment: String },
    /// `/fv path:frag`, `path` unambiguous - candidates are that type's
    /// live values.
    Value { start: usize, field: ResolvedField, fragment: String },
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
    /// `verb` has consumed `args` argument(s) and can take more.
    Verb { verb: Verb, args: Vec<String> },
}

fn replay(context: &[Tok]) -> Open {
    let mut open = Open::None;
    for tok in context {
        loop {
            match &mut open {
                Open::None => {
                    if let Some(v) = tok_verb(tok) {
                        if v == Verb::Reverse {
                            // consumes nothing, stays closed
                        } else {
                            open = Open::Verb { verb: v, args: Vec::new() };
                        }
                    }
                    // bare value or inert /... - nothing to track
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

    // Typing a verb: `/frag`, no space after it yet.
    if let Some(verb_frag) = frag.strip_prefix('/') {
        return Some(Completion::Verb { start, fragment: verb_frag.to_string() });
    }

    // Otherwise `frag` is an argument. Which command owns it?
    match replay(context) {
        Open::Verb { verb, args } if verb.takes_path() => {
            if verb == Verb::Sort && args.len() == 1 {
                // path already given - `frag` is the direction, if the
                // path resolved unambiguously; otherwise keep completing
                // the (ambiguous) path.
                return match resolve_one(&args[0]) {
                    Some(field) => Some(Completion::SortDirection { start, field, fragment: frag }),
                    None => Some(Completion::TypePath { start, verb, fragment: frag }),
                };
            }
            // `/fv path:frag` - value stage once a colon is present.
            if verb == Verb::FilterValue {
                if let Some((path, val_frag)) = frag.split_once(':') {
                    let field = resolve_one(path)?;
                    return Some(Completion::Value { start, field, fragment: val_frag.to_string() });
                }
            }
            Some(Completion::TypePath { start, verb, fragment: frag })
        }
        _ => None, // a bare value, or nothing open after a space
    }
}

/// Candidate strings for a `Completion`. `windows`/`metas` are only used
/// for the `Value` stage.
pub fn completion_candidates(completion: &Completion, windows: &[Window], metas: &[TmuxClaudeMeta]) -> Vec<String> {
    match completion {
        Completion::Verb { fragment, .. } => {
            VERB_SHORTS.iter().filter(|v| substr(fragment, v)).map(|v| v.to_string()).collect()
        }
        Completion::TypePath { fragment, .. } => path_suggestions(fragment),
        Completion::Value { field, fragment, .. } => value_suggestions(windows, metas, *field, fragment),
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
        assert!(matches_win(&w, "/fv cl:alac")); // class, not title
        assert!(!matches_win(&w, "/fv cl:hyprpm"));
    }

    #[test]
    fn multiple_filters_are_anded() {
        let w = win("hyprpm build log", "Alacritty", "1", 100);
        assert!(matches_win(&w, "/fv title:hyprpm /fv class:alac"));
        assert!(matches_win(&w, "hyprpm /fv class:alac"));
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

    // --- column verbs --------------------------------------------------

    #[test]
    fn add_and_remove_columns_left_to_right() {
        let defaults = [ResolvedField::Flat("workspace"), ResolvedField::Flat("title")];
        assert_eq!(active_columns("", &defaults), defaults.to_vec());
        assert_eq!(active_columns("/rt workspace", &defaults), vec![ResolvedField::Flat("title")]);
        assert_eq!(
            active_columns("/at claude.title", &defaults),
            vec![
                ResolvedField::Flat("workspace"),
                ResolvedField::Flat("title"),
                ResolvedField::Group("claude", "title"),
            ]
        );
        // remove then re-add ends with it back, at the end
        assert_eq!(
            active_columns("/at claude.title /rt claude.title /at claude.title", &defaults),
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
            ResolvedField::Flat("class"),
        ];
        // keep only the columns whose name contains "t" ("workspace" has none)
        assert_eq!(active_columns("/ft t", &defaults), vec![ResolvedField::Flat("title")]);
        // "s" keeps workspace and class
        assert_eq!(
            active_columns("/ft s", &defaults),
            vec![ResolvedField::Flat("workspace"), ResolvedField::Flat("class")]
        );
        // ft never reveals a hidden column
        assert_eq!(active_columns("/ft pid", &defaults), Vec::<ResolvedField>::new());
        // ft then at: narrow, then bring one back
        assert_eq!(
            active_columns("/ft title /at workspace", &defaults),
            vec![ResolvedField::Flat("title"), ResolvedField::Flat("workspace")]
        );
    }

    #[test]
    fn add_bare_group_adds_every_subfield() {
        let cols = active_columns("/at claude", &[]);
        assert_eq!(
            cols,
            vec![
                ResolvedField::Group("claude", "title"),
                ResolvedField::Group("claude", "path"),
                ResolvedField::Group("claude", "session"),
                ResolvedField::Group("claude", "contents"),
            ]
        );
        assert_eq!(active_columns("/at claude.*", &[]), cols);
        assert_eq!(active_columns("/at claude.title", &[]), vec![ResolvedField::Group("claude", "title")]);
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
    fn type_path_stage_after_a_verb_and_space() {
        let Some(Completion::TypePath { verb, fragment, .. }) = completion_context("/ft ") else { panic!() };
        assert_eq!(verb, Verb::FilterType);
        assert_eq!(fragment, "");
        let Some(Completion::TypePath { fragment, .. }) = completion_context("/at cla") else { panic!() };
        assert_eq!(fragment, "cla");
        let cands = completion_candidates(
            &Completion::TypePath { start: 0, verb: Verb::AddType, fragment: "cla".to_string() },
            &[],
            &[],
        );
        assert_eq!(cands, vec!["class", "claude"]); // "class" contains "cla" too
        let cands = completion_candidates(
            &Completion::TypePath { start: 0, verb: Verb::AddType, fragment: "tmux.".to_string() },
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
        assert_eq!(
            value_suggestions(&windows, &metas, ResolvedField::Flat("class"), "itt"),
            vec!["Alacritty", "kitty"]
        );
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
}
