//! The `/field:value` filter DSL (v2 — see ~/.config/docs/query-dsl.md for
//! the full spec covering this and every other implementation): tokens
//! split on whitespace, `/field:val` fuzzy-matches both the field name and
//! the value independently (subsequence matching, case-insensitive --
//! `/tit:crit` matches field "title" and any window whose title
//! subsequence-matches "crit"), bare words substring-match a combined
//! title+class haystack, and multiple tokens in one query are ANDed
//! together.
//!
//! On top of the flat fields (`title`/`class`/`workspace`/`pid`), two
//! **groups** add a nested namespace: `/tmux/<sub>:value` and
//! `/claude/<sub>:value`, backed by `enrich::TmuxClaudeMeta` rather than
//! `hyprctl::Window` (data gathered asynchronously -- a window's group
//! fields may simply be absent for a while after the grid opens, which
//! behaves exactly like an unresolved field always has here -- no match
//! yet, not an error):
//!   - `/tmux/title:foo` / `/claude/contents:foo` -- explicit group/sub.
//!   - `/tmux:foo` -- bare group, defaults to `/title` (not "every sub").
//!   - `/tmux/*:foo` -- literal reserved segment: matches if *any* subfield
//!     of the group matches. Not regex -- `*` is one hand-parsed segment,
//!     same "no real regex anywhere in this DSL" rule every other form here
//!     already follows.
//!   - `/claude` / `/clau` -- bare, **no colon at all**: an existence
//!     filter, not a text search -- "does this window have any claude data
//!     at all." Only applies to groups; a multi-segment-but-colonless
//!     fragment (`/zzz`, `/tmux/se`) falls back to the plain-text bare-word
//!     behaviour unchanged.
//!
//! Column visibility (`/+path`, `/-path`) and actions (`/sort/field
//! [/direction]`, `/reverse`) are handled by `active_columns`/
//! `parse_actions` below, entirely separate from the matching logic above
//! -- neither one filters, both only affect what's displayed or in what
//! order. See query-dsl.md for the full grammar and, especially, the
//! "direction trap" for sorting `date`-shaped (age-bucket) values, which
//! `compare_field_values` implements.
//!
//! `"..."` quoting lets a field/group name or value contain whitespace
//! without it splitting into separate (and separately required) tokens --
//! subsequence() already matches a needle containing a literal space
//! against a haystack with a real space in the right place, so no new
//! matching algorithm is needed, only a tokenizer that stops splitting the
//! run apart first. A bare (unquoted) Free word keeps the older
//! literal-substring behaviour; only a token that contains whitespace --
//! which, since whitespace splits tokens, can only happen if it came from a
//! quoted run -- gets the subsequence treatment. See
//! `tokenize`/`token_matches`.

use crate::enrich::TmuxClaudeMeta;
use crate::hyprctl::Window;

/// Every flat field name a `/field:` prefix can fuzzy-resolve to. Add new
/// fields here and in `column_value` together.
const COLUMNS: &[&str] = &["title", "class", "workspace", "pid"];

/// Group name -> its own subfield list, in display order. Add a new group's
/// data to `enrich::TmuxClaudeMeta` and `group_sub_value` together.
const GROUPS: &[(&str, &[&str])] = &[
    ("tmux", &["session", "window", "title"]),
    ("claude", &["title", "path", "session", "contents"]),
];

/// What a bare `/group:value` (no `/sub`) resolves its group to.
const GROUP_DEFAULT_SUB: &str = "title";

/// Recognized action verbs (`/sort/...`, `/reverse`) -- see `parse_actions`.
/// Small and fixed by design (query-dsl.md's Design principles: no real
/// regex, and this stays a hand-curated vocabulary rather than growing
/// unboundedly); add a new one here plus its own arg-parsing/apply logic.
const ACTIONS: &[&str] = &["sort", "reverse"];

const DIRECTIONS: &[&str] = &["ascending", "descending"];

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

/// True if `group` has *any* non-empty subfield on this window -- what a
/// bare `/group` (no colon at all, e.g. `/claude`/`/clau`) checks for. Not a
/// text search: it's an existence filter, "does this window have any
/// tmux/claude data at all," which is what makes `/claude` alone a useful
/// complete query on its own rather than something that only starts doing
/// anything once a value is typed after a colon.
fn group_has_any_value(meta: &TmuxClaudeMeta, group: &str) -> bool {
    group_subs(group).iter().any(|s| !group_sub_value(meta, group, s).is_empty())
}

/// Every group name subsequence-fuzzy-matching `prefix`, in `GROUPS`' own
/// order -- the group-level analogue of resolving a flat column.
fn resolve_groups(prefix: &str) -> Vec<&'static str> {
    GROUPS.iter().map(|(g, _)| *g).filter(|g| subsequence(prefix, g)).collect()
}

/// Every subfield of `group` subsequence-fuzzy-matching `prefix`.
fn resolve_group_subs(group: &str, prefix: &str) -> Vec<&'static str> {
    group_subs(group).iter().copied().filter(|s| subsequence(prefix, s)).collect()
}

fn resolve_actions(prefix: &str) -> Vec<&'static str> {
    ACTIONS.iter().copied().filter(|a| subsequence(prefix, a)).collect()
}

fn resolve_directions(prefix: &str) -> Vec<&'static str> {
    DIRECTIONS.iter().copied().filter(|d| subsequence(prefix, d)).collect()
}

/// True if every character of `needle` appears in `hay`, in order, but not
/// necessarily contiguously (case-insensitive). Empty needle always matches.
fn subsequence(needle: &str, hay: &str) -> bool {
    let needle = needle.to_lowercase();
    let hay = hay.to_lowercase();
    let mut hay_chars = hay.chars();
    needle
        .chars()
        .all(|nc| hay_chars.any(|hc| hc == nc))
}

/// Which single concrete field a `/field:` prefix (flat or group/sub)
/// unambiguously names -- what value-completion/suggestion and sorting need
/// in order to know which one field's live values (or comparison rule)
/// applies.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ResolvedField {
    Flat(&'static str),
    Group(&'static str, &'static str),
}

impl ResolvedField {
    /// The text that goes right after `/` and before `:` (or, for a
    /// visibility/sort token, with no `:` at all) to name this field
    /// explicitly -- `"title"` or `"tmux/session"`.
    pub fn key(&self) -> String {
        match self {
            ResolvedField::Flat(c) => c.to_string(),
            ResolvedField::Group(g, s) => format!("{g}/{s}"),
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Direction {
    Ascending,
    Descending,
}

/// The result of `/sort/field[/direction]`, plus whether `/reverse` was
/// also typed -- see query-dsl.md's Actions section for the full grammar
/// and why `sort`/`reverse` are independent (both can apply at once:
/// `/sort` picks an order, `/reverse` flips whatever order is in effect).
#[derive(Clone, Default)]
pub struct Actions {
    pub sort: Option<(ResolvedField, Direction)>,
    pub reverse: bool,
}

enum Token {
    /// `field_query` is the text before an optional `/sub`; `sub_query` is
    /// `Some` (possibly `"*"`) only when a second segment was actually
    /// typed.
    Field { field_query: String, sub_query: Option<String>, value: String },
    /// A bare `/group` with **no colon at all** (`/claude`, `/clau`,
    /// `/tmux`) -- an existence filter ("does this window have any
    /// tmux/claude data at all"), distinct from `/group:` (colon, empty
    /// value), which trivially matches everything the same way every other
    /// `/field:` empty-value form already does. Only created when the
    /// fragment actually resolves to a group and contains no `/` -- a
    /// multi-segment, colonless fragment (`/tmux/se`, still mid-typing a
    /// sub) and an unresolvable one both fall back to `Free`.
    GroupExists(String),
    Free(String),
}

/// Split `query` on whitespace like `str::split_whitespace`, except a
/// `"..."`-quoted run is kept as one token with its interior whitespace
/// intact (quote characters themselves are dropped, wherever in the token
/// they fall). Also returns each token's starting byte offset in `query`,
/// for callers that need to splice a replacement in (`completion_context`).
///
/// An unterminated quote (mid-typing) still closes its token at the end of
/// the string rather than being dropped -- same "still usable half-typed"
/// principle the rest of this DSL follows.
fn tokenize_with_spans(query: &str) -> Vec<(usize, String)> {
    let mut tokens = Vec::new();
    let mut cur = String::new();
    let mut start: Option<usize> = None;
    let mut in_quotes = false;
    for (i, c) in query.char_indices() {
        if c == '"' {
            in_quotes = !in_quotes;
            start.get_or_insert(i);
            continue;
        }
        if c.is_whitespace() && !in_quotes {
            if let Some(s) = start.take() {
                tokens.push((s, std::mem::take(&mut cur)));
            }
            continue;
        }
        start.get_or_insert(i);
        cur.push(c);
    }
    if let Some(s) = start {
        tokens.push((s, cur));
    }
    tokens
}

fn tokenize(query: &str) -> Vec<String> {
    tokenize_with_spans(query).into_iter().map(|(_, t)| t).collect()
}

/// Every completion candidate for a bare field/group/action fragment (no
/// `+`/`-`, no `:` yet), each a full string ready to splice right after
/// `/` -- `"title"`, `"tmux"`, `"tmux/session"`, `"sort"`. `actions_too`
/// controls whether action verbs are included -- true for the real
/// top-level case, false for a visibility path or a sort target, neither
/// of which can themselves be an action.
///
/// No `/` yet in `fragment`: unions flat fields, group names, and (if
/// `actions_too`) action verbs -- same "union everything that resolves"
/// rule `/field:value` itself follows. A `/` already typed: only offers
/// completions once the group name before it is unambiguous (mirrors
/// `resolve_field_unambiguous`'s "exactly one" rule, one level up) -- an
/// ambiguous or unknown group has no fixed subfield list to suggest from.
/// `*` is offered as its own candidate alongside real subfields so "match
/// any sub" stays discoverable without already knowing it exists.
fn path_suggestions(fragment: &str, actions_too: bool) -> Vec<String> {
    if let Some((group_frag, sub_frag)) = fragment.split_once('/') {
        let groups = resolve_groups(group_frag);
        let [group] = groups[..] else { return Vec::new() };
        let mut out: Vec<String> =
            resolve_group_subs(group, sub_frag).into_iter().map(|s| format!("{group}/{s}")).collect();
        if subsequence(sub_frag, "*") {
            out.push(format!("{group}/*"));
        }
        return out;
    }
    let mut out: Vec<String> = COLUMNS.iter().filter(|c| subsequence(fragment, c)).map(|c| c.to_string()).collect();
    out.extend(resolve_groups(fragment).iter().map(|g| g.to_string()));
    if actions_too {
        out.extend(resolve_actions(fragment).iter().map(|a| a.to_string()));
    }
    out
}

/// True if `candidate` (a suggestion with no `/` in it) still has further
/// subtypes reachable via `/` -- i.e. it names a group, not a flat field.
/// Tab-completion uses this to decide whether landing on `/claude` (no
/// colon -- ready for either `/sub` next, or to stand on its own as the
/// bare existence-filter form) beats jumping straight to `/claude:` the way
/// a childless field like `/title:` always should.
pub fn has_subtypes(candidate: &str) -> bool {
    !candidate.contains('/') && GROUPS.iter().any(|(g, _)| *g == candidate)
}

/// Resolves `field_and_sub` (flat, or `group/sub`, `/` optional) to exactly
/// one concrete field, or `None` if it's ambiguous, unknown, or a `group/*`
/// (which names a *set* of fields, not one value domain -- same "no single
/// value set to offer" reasoning an ambiguous flat field already gets).
fn resolve_field_unambiguous(field_and_sub: &str) -> Option<ResolvedField> {
    if let Some((group_frag, sub_frag)) = field_and_sub.split_once('/') {
        if sub_frag == "*" {
            return None;
        }
        let groups = resolve_groups(group_frag);
        let [group] = groups[..] else { return None };
        let subs = resolve_group_subs(group, sub_frag);
        let [sub] = subs[..] else { return None };
        return Some(ResolvedField::Group(group, sub));
    }
    let mut candidates: Vec<ResolvedField> =
        COLUMNS.iter().copied().filter(|c| subsequence(field_and_sub, c)).map(ResolvedField::Flat).collect();
    candidates.extend(resolve_groups(field_and_sub).into_iter().map(|g| ResolvedField::Group(g, GROUP_DEFAULT_SUB)));
    match candidates[..] {
        [only] => Some(only),
        _ => None,
    }
}

/// Every `ResolvedField` a visibility path (`path` in `/+path`/`/-path`,
/// `/` already stripped along with the leading `+`/`-`) names -- unlike
/// `resolve_field_unambiguous`, this *unions* every match rather than
/// requiring exactly one, since showing/hiding is fine to apply to several
/// fields at once (an ambiguous flat/group prefix, or an explicit
/// `group/*`). Empty for an unresolvable path.
fn resolve_path(path: &str) -> Vec<ResolvedField> {
    if let Some((group_frag, sub_frag)) = path.split_once('/') {
        let groups = resolve_groups(group_frag);
        if sub_frag == "*" {
            return groups.iter().flat_map(|&g| group_subs(g).iter().map(move |&s| ResolvedField::Group(g, s))).collect();
        }
        return groups
            .iter()
            .flat_map(|&g| resolve_group_subs(g, sub_frag).into_iter().map(move |s| ResolvedField::Group(g, s)))
            .collect();
    }
    let mut out: Vec<ResolvedField> = COLUMNS.iter().copied().filter(|c| subsequence(path, c)).map(ResolvedField::Flat).collect();
    out.extend(resolve_groups(path).into_iter().map(|g| ResolvedField::Group(g, GROUP_DEFAULT_SUB)));
    out
}

/// Applies every `/+path`/`/-path` token in `query`, left to right, to
/// `defaults` (winswitch's baseline shown columns -- `workspace`+`title`
/// today) -- see query-dsl.md's column-visibility section for the
/// add-then-remove-then-re-add ordering semantics. Returns the resulting
/// ordered, de-duplicated column list. Recomputed fresh from the whole
/// query text on every keystroke (cheap -- a handful of tokens at most),
/// not diffed against the previous result.
pub fn active_columns(query: &str, defaults: &[ResolvedField]) -> Vec<ResolvedField> {
    let mut cols: Vec<ResolvedField> = defaults.to_vec();
    for (_, token) in tokenize_with_spans(query) {
        let Some(rest) = token.strip_prefix('/') else { continue };
        let (sign, path) = match rest.strip_prefix('+') {
            Some(p) => ('+', p),
            None => match rest.strip_prefix('-') {
                Some(p) => ('-', p),
                None => continue,
            },
        };
        for field in resolve_path(path) {
            if sign == '+' {
                if !cols.contains(&field) {
                    cols.push(field);
                }
            } else {
                cols.retain(|c| *c != field);
            }
        }
    }
    cols
}

/// One `/sort/field[/direction]` token's argument (`after_verb` is
/// everything after the `sort/`), or `None` if the field doesn't resolve.
/// The field path may itself be one segment (flat) or two (`group/sub`),
/// so this can't just split on a fixed segment count -- it tries the
/// *last* segment as a direction first (only committing to that split if
/// what's left before it also resolves to a field), and falls back to
/// treating the whole remainder as the field path with the default
/// direction. See query-dsl.md's Actions section for why direction can't
/// simply be "whatever's after the second slash."
fn parse_sort_arg(after_verb: &str) -> Option<(ResolvedField, Direction)> {
    let segs: Vec<&str> = after_verb.split('/').collect();
    if segs.len() >= 2 {
        let dirs = resolve_directions(segs[segs.len() - 1]);
        if let [only] = dirs[..] {
            let field_path = segs[..segs.len() - 1].join("/");
            if let Some(field) = resolve_field_unambiguous(&field_path) {
                let direction = if only == "ascending" { Direction::Ascending } else { Direction::Descending };
                return Some((field, direction));
            }
        }
    }
    resolve_field_unambiguous(after_verb).map(|f| (f, Direction::Ascending))
}

/// Every `/sort/...`/`/reverse` token in `query`, applied in order (a
/// later `/sort/` replaces an earlier one; any number of `/reverse` tokens
/// has the same effect as one -- see query-dsl.md's Actions section for
/// why). Malformed action args (an unresolvable sort field, say) are
/// silently inert, same "half-typed/invalid stays a no-op, never an error
/// or a fallback" principle the rest of this DSL follows.
pub fn parse_actions(query: &str) -> Actions {
    let mut actions = Actions::default();
    for (_, token) in tokenize_with_spans(query) {
        let Some(rest) = token.strip_prefix('/') else { continue };
        if rest.starts_with('+') || rest.starts_with('-') {
            continue;
        }
        let Some((verb, after_verb)) = rest.split_once('/') else {
            if let [only] = resolve_actions(rest)[..] {
                if only == "reverse" {
                    actions.reverse = true;
                }
            }
            continue;
        };
        if let [only] = resolve_actions(verb)[..] {
            match only {
                "sort" => {
                    if let Some(spec) = parse_sort_arg(after_verb) {
                        actions.sort = Some(spec);
                    }
                }
                "reverse" => actions.reverse = true,
                _ => {}
            }
        }
    }
    actions
}

fn field_value(win: &Window, meta: &TmuxClaudeMeta, field: ResolvedField) -> String {
    match field {
        ResolvedField::Flat(c) => column_value(win, c),
        ResolvedField::Group(g, s) => group_sub_value(meta, g, s),
    }
}

/// A value's shape, for `compare_field_values` -- sniffed independently on
/// each side of a comparison rather than trusted from the field, since a
/// field can legitimately be empty/absent on one of the two entries being
/// compared.
enum ValueShape {
    Int(u64),
    /// Seconds, parsed from an `humanize_ago`-shaped bucket (`"5m"`,
    /// `"3h"`, `"2d"`, `"30s"`).
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

/// Compares two field values for `/sort`, sniffing shape on each side
/// rather than trusting the field: plain integers compare numerically
/// (`"10"` > `"2"`, unlike lexicographically); age buckets
/// (`humanize_ago`'s `"5m"`/`"3h"`/`"2d"`/`"30s"`) convert to seconds and
/// compare *that*; anything else (or a shape mismatch between the two
/// sides) falls back to plain lexicographic string comparison, which is
/// already correct for genuinely textual fields like `title`/`class`.
///
/// Direction is applied by the caller, with one deliberate exception this
/// function itself handles: an age bucket is a value's *age* (smaller =
/// more recent), not its absolute time, so "ascending"/"descending" would
/// be backwards read literally against the raw seconds -- see
/// query-dsl.md's "direction trap." This function always returns
/// ascending-by-*chronological*-order for two age values (oldest-first),
/// already correct for a direct `Ordering` regardless of which numeric
/// direction that happens to be internally -- callers never need their own
/// special case for age fields, only for plain int/text ones.
fn compare_field_values(a: &str, b: &str) -> std::cmp::Ordering {
    match (sniff_shape(a), sniff_shape(b)) {
        (ValueShape::Int(x), ValueShape::Int(y)) => x.cmp(&y),
        // Larger age = earlier (older) moment = sorts first for "oldest
        // first" -- i.e. compare seconds *descending* to get chronological
        // ascending.
        (ValueShape::AgeSeconds(x), ValueShape::AgeSeconds(y)) => y.cmp(&x),
        _ => a.cmp(b),
    }
}

/// `compare_field_values` with `direction` applied -- the one place a
/// caller (winswitch's `ui.rs` flowbox sort func) needs to reach for, so
/// the age-bucket direction inversion documented above stays entirely
/// internal to this module rather than something every call site has to
/// remember.
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

/// Every distinct, non-empty value `field` actually has across
/// `windows`/`metas` (parallel, same index) right now, subsequence-fuzzy-
/// narrowed by `fragment` -- exactly the same matching a manually typed
/// `/field:value` would apply, so what's offered here is guaranteed to be
/// something that would actually match if typed. Sorted and deduplicated
/// (`BTreeSet`) for a stable, predictable order rather than window-list
/// order, which shuffles as focus/list order changes underneath the popup.
pub fn value_suggestions(windows: &[Window], metas: &[TmuxClaudeMeta], field: ResolvedField, fragment: &str) -> Vec<String> {
    let empty = TmuxClaudeMeta::default();
    let mut seen = std::collections::BTreeSet::new();
    for (i, w) in windows.iter().enumerate() {
        let meta = metas.get(i).unwrap_or(&empty);
        let v = field_value(w, meta, field);
        if !v.is_empty() && subsequence(fragment, &v) {
            seen.insert(v);
        }
    }
    seen.into_iter().collect()
}

/// What the autocomplete popup should offer right now, and where a chosen
/// completion gets spliced back in -- one entry point covering every stage
/// of the grammar (see query-dsl.md's Autocompletion section), so `ui.rs`
/// only has to match on this instead of re-deriving "which stage am I in"
/// itself. `start` is always the byte offset in the query text where the
/// trailing token begins.
pub enum Completion {
    /// `/fragment`, no `+`/`-`, no `:`, not (yet) committed to `/sort/`'s
    /// own sub-grammar -- candidates are fields, groups, and action verbs
    /// (plus the two literal `+`/`-` themselves, only when `fragment` has
    /// no `/` in it, since those only ever make sense as the very first
    /// thing after `/`).
    TopLevel { start: usize, fragment: String },
    /// `/+fragment` or `/-fragment` -- candidates are fields and groups
    /// only (see `path_suggestions`'s `actions_too: false`).
    VisibilityPath { start: usize, sign: char, fragment: String },
    /// `/sort/fragment`, not yet a second `/` -- candidates are fields and
    /// groups (the sort target), same as `VisibilityPath`.
    SortField { start: usize, fragment: String },
    /// `/sort/<unambiguous field>/fragment` -- candidates are
    /// `ascending`/`descending`.
    SortDirection { start: usize, field: ResolvedField, fragment: String },
    /// `/field:fragment`, field unambiguous -- candidates are that field's
    /// live values (`value_suggestions`).
    Value { start: usize, field: ResolvedField, fragment: String },
}

pub fn completion_context(query: &str) -> Option<Completion> {
    let (start, last) = tokenize_with_spans(query).into_iter().last()?;
    let rest = last.strip_prefix('/')?;

    if let Some((field_and_sub, val_frag)) = rest.split_once(':') {
        let field = resolve_field_unambiguous(field_and_sub)?;
        return Some(Completion::Value { start, field, fragment: val_frag.to_string() });
    }
    if let Some(path) = rest.strip_prefix('+') {
        return Some(Completion::VisibilityPath { start, sign: '+', fragment: path.to_string() });
    }
    if let Some(path) = rest.strip_prefix('-') {
        return Some(Completion::VisibilityPath { start, sign: '-', fragment: path.to_string() });
    }
    if let Some((verb, after_verb)) = rest.split_once('/') {
        if let [only] = resolve_actions(verb)[..] {
            if only == "sort" {
                // Same two-attempt shape as parse_sort_arg: try "last
                // segment is a direction fragment, everything before it is
                // the field" first, but only commit to that reading if it
                // actually resolves to *something* worth completing -- a
                // resolvable field prefix isn't enough on its own, since
                // "tmux/session" (a complete 2-segment field, no direction
                // typed) and "tmux/se" (field still mid-typing) both have a
                // resolvable "tmux" as segs[..1], yet only one of them is
                // really in the direction stage. What decides it is
                // whether the *last* segment resolves to any direction
                // candidate at all (empty included, since empty matches
                // both) -- "session" resolves to none, so that reading is
                // rejected and the fallback (still building the field
                // path) takes over instead.
                let segs: Vec<&str> = after_verb.split('/').collect();
                if segs.len() >= 2 {
                    let field_path = segs[..segs.len() - 1].join("/");
                    let dir_frag = segs[segs.len() - 1];
                    if let Some(field) = resolve_field_unambiguous(&field_path) {
                        if !resolve_directions(dir_frag).is_empty() {
                            return Some(Completion::SortDirection { start, field, fragment: dir_frag.to_string() });
                        }
                    }
                }
                return Some(Completion::SortField { start, fragment: after_verb.to_string() });
            }
        }
    }
    Some(Completion::TopLevel { start, fragment: rest.to_string() })
}

/// Candidate strings for a given `Completion` -- kept separate from
/// `completion_context` itself so `ui.rs` can compute the trigger once and
/// the candidate list separately (it needs `windows`/`metas` only for the
/// `Value` case).
pub fn completion_candidates(completion: &Completion, windows: &[Window], metas: &[TmuxClaudeMeta]) -> Vec<String> {
    match completion {
        Completion::TopLevel { fragment, .. } => {
            let mut out = path_suggestions(fragment, true);
            // "+"/"-" only ever make sense as the very first thing typed
            // after "/" -- once a "/" has been typed as part of the
            // fragment itself (e.g. "tmux/"), we're already inside a
            // group's own subfield list, where a visibility marker no
            // longer means anything.
            if !fragment.contains('/') {
                out.push("+".to_string());
                out.push("-".to_string());
            }
            out
        }
        Completion::VisibilityPath { fragment, .. } => path_suggestions(fragment, false),
        Completion::SortField { fragment, .. } => path_suggestions(fragment, false),
        Completion::SortDirection { fragment, .. } => resolve_directions(fragment).iter().map(|d| d.to_string()).collect(),
        Completion::Value { field, fragment, .. } => value_suggestions(windows, metas, *field, fragment),
    }
}

fn parse(query: &str) -> Vec<Token> {
    tokenize(query)
        .into_iter()
        .filter_map(|word| {
            if let Some(rest) = word.strip_prefix('/') {
                // Visibility and action tokens carry no filtering meaning at
                // all -- excluded here rather than falling through to Free,
                // same "narrow down what survives vs. what's shown/ordered
                // are orthogonal" split query-dsl.md's Design principles
                // call for.
                if rest.starts_with('+') || rest.starts_with('-') {
                    return None;
                }
                if let Some((verb, _)) = rest.split_once('/') {
                    if let [only] = resolve_actions(verb)[..] {
                        if only == "sort" {
                            return None;
                        }
                    }
                } else if let [only] = resolve_actions(rest)[..] {
                    if only == "reverse" {
                        return None;
                    }
                }
                if let Some((field_and_sub, value)) = rest.split_once(':') {
                    let (field_query, sub_query) = match field_and_sub.split_once('/') {
                        Some((f, s)) => (f.to_string(), Some(s.to_string())),
                        None => (field_and_sub.to_string(), None),
                    };
                    return Some(Token::Field { field_query, sub_query, value: value.to_string() });
                }
                if !rest.contains('/') && !resolve_groups(rest).is_empty() {
                    return Some(Token::GroupExists(rest.to_string()));
                }
            }
            Some(Token::Free(word))
        })
        .collect()
}

/// A `/field:value` token's match, covering all three forms: bare (unions
/// flat columns and each matched group's `/title` default), `/sub`, and
/// `/*` (any sub of the matched group(s)). An unresolvable field/group -- or
/// a group field whose data just hasn't been enriched in yet, see
/// `enrich.rs` -- naturally matches nothing here rather than needing a
/// special case: an empty resolved set makes the `any()` below vacuously
/// false, same as `column_value` returning `""` always failed to
/// `subsequence`-match a non-empty typed value before groups existed at all.
fn field_token_matches(win: &Window, meta: &TmuxClaudeMeta, field_query: &str, sub_query: Option<&str>, value: &str) -> bool {
    match sub_query {
        None => {
            let flat = COLUMNS.iter().filter(|c| subsequence(field_query, c)).any(|c| subsequence(value, &column_value(win, c)));
            let grouped = resolve_groups(field_query)
                .iter()
                .any(|g| subsequence(value, &group_sub_value(meta, g, GROUP_DEFAULT_SUB)));
            flat || grouped
        }
        Some("*") => resolve_groups(field_query)
            .iter()
            .any(|g| group_subs(g).iter().any(|s| subsequence(value, &group_sub_value(meta, g, s)))),
        Some(sub) => resolve_groups(field_query)
            .iter()
            .any(|g| resolve_group_subs(g, sub).iter().any(|s| subsequence(value, &group_sub_value(meta, g, s)))),
    }
}

fn token_matches(win: &Window, meta: &TmuxClaudeMeta, token: &Token) -> bool {
    match token {
        Token::Free(word) => {
            // A Free token can only contain whitespace if it came from a
            // quoted run (unquoted whitespace always splits tokens apart
            // before this point) -- that's the signal to switch from plain
            // substring to order-preserving subsequence matching, the same
            // upgrade /field:value quoting gets below.
            if word.contains(char::is_whitespace) {
                let haystack = format!("{} {}", win.title, win.class);
                subsequence(word, &haystack)
            } else {
                let haystack = format!("{} {}", win.title, win.class).to_lowercase();
                haystack.contains(&word.to_lowercase())
            }
        }
        Token::Field { field_query, sub_query, value } => {
            field_token_matches(win, meta, field_query, sub_query.as_deref(), value)
        }
        Token::GroupExists(field_query) => resolve_groups(field_query).iter().any(|g| group_has_any_value(meta, g)),
    }
}

fn matches(win: &Window, meta: &TmuxClaudeMeta, tokens: &[Token]) -> bool {
    tokens.iter().all(|t| token_matches(win, meta, t))
}

/// Convenience wrapper for call sites that don't need to hold onto the
/// parsed tokens (they're cheap to reparse -- at most a few dozen windows,
/// once per keystroke).
pub fn matches_str(win: &Window, meta: &TmuxClaudeMeta, query: &str) -> bool {
    if query.is_empty() {
        return true;
    }
    matches(win, meta, &parse(query))
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
    fn subsequence_matches_in_order_non_contiguous() {
        assert!(subsequence("crit", "alacritty"));
        assert!(subsequence("ALA", "alacritty"));
        assert!(!subsequence("actira", "alacritty")); // wrong order
        assert!(subsequence("", "anything"));
    }

    #[test]
    fn free_word_substring_matches_title_or_class() {
        let w = win("My Terminal", "Alacritty", "1", 100);
        assert!(matches_win(&w, "terminal"));
        assert!(matches_win(&w, "alacritty"));
        assert!(!matches_win(&w, "firefox"));
    }

    #[test]
    fn exact_field_and_value() {
        let w = win("hyprpm build log", "Alacritty", "1", 100);
        assert!(matches_win(&w, "/title:hyprpm"));
        assert!(!matches_win(&w, "/title:firefox"));
    }

    #[test]
    fn fuzzy_field_and_value_both_subsequence() {
        let w = win("Alacritty", "Alacritty", "1", 100);
        assert!(matches_win(&w, "/tit:crit"));
    }

    #[test]
    fn field_prefix_resolves_to_the_matching_field_only() {
        let w = win("something", "Firefox", "1", 100);
        assert!(matches_win(&w, "/cl:fire"));
        assert!(!matches_win(&w, "/cl:something")); // "something" is the title, not the class
    }

    #[test]
    fn multiple_tokens_are_anded() {
        let w = win("hyprpm build log", "Alacritty", "1", 100);
        assert!(matches_win(&w, "/title:hyprpm /class:alac"));
        assert!(!matches_win(&w, "/title:hyprpm /class:firefox"));
    }

    #[test]
    fn unknown_field_matches_nothing() {
        let w = win("hyprpm", "Alacritty", "1", 100);
        assert!(!matches_win(&w, "/zzz:hyprpm"));
    }

    #[test]
    fn pid_field_matches_numeric_string() {
        let w = win("t", "c", "1", 12345);
        assert!(matches_win(&w, "/pid:234"));
        assert!(!matches_win(&w, "/pid:999"));
    }

    #[test]
    fn quoted_value_survives_as_one_token_and_matches_by_subsequence() {
        let w = win("Imperial Rome", "Alacritty", "1", 100);
        assert!(matches_win(&w, r#"/title:"imp rom""#));
        assert!(matches_win(&w, r#"/title:"imperial rome""#));
        assert!(!matches_win(&w, r#"/title:"rom imp""#)); // wrong order
    }

    #[test]
    fn quoted_free_word_matches_by_subsequence_across_the_space() {
        let w = win("Imperial Rome", "Alacritty", "1", 100);
        assert!(matches_win(&w, r#""imp rom""#));
        assert!(!matches_win(&w, r#""rom imp""#)); // wrong order
        assert!(matches_win(&w, "rom imp")); // unquoted still ANDs independent substrings
    }

    #[test]
    fn field_suggestions_narrow_fuzzily_and_include_actions() {
        assert_eq!(
            path_suggestions("", true),
            vec!["title", "class", "workspace", "pid", "tmux", "claude", "sort", "reverse"]
        );
        assert_eq!(path_suggestions("ti", true), vec!["title"]);
        assert!(path_suggestions("", false).iter().all(|s| s != "sort" && s != "reverse"));
    }

    #[test]
    fn group_slash_suggestions_need_an_unambiguous_group() {
        let subs = path_suggestions("tmux/", true);
        assert!(subs.contains(&"tmux/session".to_string()));
        assert!(subs.contains(&"tmux/window".to_string()));
        assert!(subs.contains(&"tmux/title".to_string()));
        assert!(subs.contains(&"tmux/*".to_string()));
        assert_eq!(path_suggestions("tmux/se", true), vec!["tmux/session"]);
        assert!(path_suggestions("zzz/foo", true).is_empty());
    }

    #[test]
    fn trailing_value_fragment_needs_an_unambiguous_field() {
        let Some(Completion::Value { field, fragment, .. }) = completion_context("/workspace:") else { panic!() };
        assert_eq!((field, fragment.as_str()), (ResolvedField::Flat("workspace"), ""));
        assert!(matches!(completion_context("/c:x"), None)); // ambiguous: class/claude
        assert!(matches!(completion_context("/title"), Some(Completion::TopLevel { .. }))); // no ':' yet
        let Some(Completion::Value { field, .. }) = completion_context("/tmux:foo") else { panic!() };
        assert_eq!(field, ResolvedField::Group("tmux", "title")); // bare group defaults to title
        let Some(Completion::Value { field, .. }) = completion_context("/tmux/session:foo") else { panic!() };
        assert_eq!(field, ResolvedField::Group("tmux", "session"));
        assert!(completion_context("/tmux/*:foo").is_none()); // "*" names a set, not one field
    }

    #[test]
    fn value_suggestions_are_deduped_sorted_and_fuzzy_narrowed() {
        let windows = vec![
            win("a", "Firefox", "1", 1),
            win("b", "Alacritty", "1", 2),
            win("c", "Alacritty", "2", 3),
            win("d", "kitty", "", 4),
        ];
        let metas = vec![no_meta(), no_meta(), no_meta(), no_meta()];
        assert_eq!(value_suggestions(&windows, &metas, ResolvedField::Flat("workspace"), ""), vec!["1", "2"]);
        assert_eq!(
            value_suggestions(&windows, &metas, ResolvedField::Flat("class"), ""),
            vec!["Alacritty", "Firefox", "kitty"]
        );
    }

    #[test]
    fn group_field_matches_bare_defaults_to_title_star_matches_any_sub() {
        let w = win("t", "c", "1", 100);
        let mut meta = TmuxClaudeMeta::default();
        meta.tmux_session = Some("work".to_string());
        meta.tmux_title = Some("hyprpm build log".to_string());

        assert!(matches_str(&w, &meta, "/tmux:hyprpm"));
        assert!(!matches_str(&w, &meta, "/tmux:work"));
        assert!(matches_str(&w, &meta, "/tmux/session:work"));
        assert!(!matches_str(&w, &meta, "/tmux/session:hyprpm"));
        assert!(matches_str(&w, &meta, "/tmux/*:work"));
        assert!(matches_str(&w, &meta, "/tmux/*:hyprpm"));
        assert!(!matches_str(&w, &meta, "/tmux/*:nope"));
    }

    #[test]
    fn bare_group_no_colon_is_an_existence_filter() {
        let w = win("t", "c", "1", 100);
        let mut has_claude = TmuxClaudeMeta::default();
        has_claude.claude_title = Some("Waybar to quickshell migration".to_string());
        let no_claude = TmuxClaudeMeta::default();

        assert!(matches_str(&w, &has_claude, "/claude"));
        assert!(matches_str(&w, &has_claude, "/clau"));
        assert!(!matches_str(&w, &no_claude, "/claude"));

        let mut has_tmux_only = TmuxClaudeMeta::default();
        has_tmux_only.tmux_session = Some("work".to_string());
        assert!(matches_str(&w, &has_tmux_only, "/tmux"));
        assert!(!matches_str(&w, &has_tmux_only, "/claude"));
    }

    #[test]
    fn dotted_or_unresolvable_colonless_fragment_is_not_an_existence_filter() {
        let w = win("t", "c", "1", 100);
        let mut meta = TmuxClaudeMeta::default();
        meta.tmux_session = Some("work".to_string());
        assert!(!matches_str(&w, &meta, "/tmux/se")); // still mid-typing a sub
        assert!(!matches_str(&w, &meta, "/zzz"));
    }

    // --- visibility (/+path, /-path) --------------------------------------

    #[test]
    fn visibility_defaults_add_and_remove_left_to_right() {
        let defaults = [ResolvedField::Flat("workspace"), ResolvedField::Flat("title")];
        assert_eq!(active_columns("", &defaults), defaults.to_vec());
        assert_eq!(active_columns("/-workspace", &defaults), vec![ResolvedField::Flat("title")]);
        assert_eq!(
            active_columns("/+claude/title", &defaults),
            vec![
                ResolvedField::Flat("workspace"),
                ResolvedField::Flat("title"),
                ResolvedField::Group("claude", "title")
            ]
        );
        // remove then re-add ends with it back, at the end (order significant)
        let q = "/+claude/title /-claude/title /+claude/title";
        assert_eq!(
            active_columns(q, &defaults),
            vec![
                ResolvedField::Flat("workspace"),
                ResolvedField::Flat("title"),
                ResolvedField::Group("claude", "title")
            ]
        );
    }

    #[test]
    fn visibility_star_adds_or_removes_every_subfield() {
        let cols = active_columns("/+claude/*", &[]);
        assert_eq!(
            cols,
            vec![
                ResolvedField::Group("claude", "title"),
                ResolvedField::Group("claude", "path"),
                ResolvedField::Group("claude", "session"),
                ResolvedField::Group("claude", "contents"),
            ]
        );
        assert_eq!(active_columns("/+claude/* /-claude/*", &[]), Vec::<ResolvedField>::new());
    }

    #[test]
    fn visibility_bare_group_adds_default_sub() {
        assert_eq!(active_columns("/+claude", &[]), vec![ResolvedField::Group("claude", "title")]);
    }

    #[test]
    fn visibility_tokens_are_not_filters() {
        // A window that would never match "/+workspace" as literal text --
        // this must not accidentally act as a $free-word filter.
        let w = win("something else entirely", "X", "1", 1);
        assert!(matches_str(&w, &no_meta(), "/+workspace"));
        assert!(matches_str(&w, &no_meta(), "/-title"));
    }

    // --- actions (/sort, /reverse) -----------------------------------------

    #[test]
    fn sort_action_resolves_flat_field_and_direction() {
        let a = parse_actions("/sort/workspace");
        assert_eq!(a.sort, Some((ResolvedField::Flat("workspace"), Direction::Ascending)));
        let a = parse_actions("/sort/workspace/descending");
        assert_eq!(a.sort, Some((ResolvedField::Flat("workspace"), Direction::Descending)));
        // "de" is unambiguous ("ascending" has no 'e' after its own 'd'),
        // unlike a bare "d" below.
        let a = parse_actions("/sort/workspace/de");
        assert_eq!(a.sort, Some((ResolvedField::Flat("workspace"), Direction::Descending)));
    }

    #[test]
    fn single_char_direction_fragment_can_be_genuinely_ambiguous() {
        // "ascending" itself contains a 'd' (ascen-D-ing), so a bare "d"
        // fuzzy-matches *both* directions -- neither wins, and this must
        // fall back to "still typing the field path" (which then also
        // fails to resolve "workspace/d" as a field) rather than guessing.
        assert!(parse_actions("/sort/workspace/d").sort.is_none());
    }

    #[test]
    fn sort_action_resolves_nested_group_field() {
        let a = parse_actions("/sort/tmux/session/ascending");
        assert_eq!(a.sort, Some((ResolvedField::Group("tmux", "session"), Direction::Ascending)));
        // no direction typed - both remaining segments are the field path
        let a = parse_actions("/sort/tmux/session");
        assert_eq!(a.sort, Some((ResolvedField::Group("tmux", "session"), Direction::Ascending)));
    }

    #[test]
    fn last_sort_token_wins_not_stacked() {
        let a = parse_actions("/sort/workspace /sort/title");
        assert_eq!(a.sort, Some((ResolvedField::Flat("title"), Direction::Ascending)));
    }

    #[test]
    fn reverse_is_idempotent_and_takes_no_args() {
        assert!(parse_actions("/reverse").reverse);
        assert!(parse_actions("/rev").reverse); // fuzzy
        assert!(parse_actions("/reverse /reverse").reverse);
        assert!(!parse_actions("plain text").reverse);
    }

    #[test]
    fn action_tokens_excluded_from_matching() {
        let w = win("workspace descending", "X", "1", 1);
        // must not accidentally free-word-match the literal text
        assert!(matches_str(&w, &no_meta(), "/sort/date/descending"));
        assert!(matches_str(&w, &no_meta(), "/reverse"));
    }

    #[test]
    fn malformed_sort_arg_is_inert_not_an_error() {
        assert!(parse_actions("/sort/zzz").sort.is_none());
        assert!(parse_actions("/sort").sort.is_none());
    }

    // --- completion cascade for /sort -----------------------------------
    // The subtle case: a resolvable field-path prefix alone isn't enough
    // to commit to "direction stage" -- the trailing segment also has to
    // actually resolve to a direction candidate, or a still-mid-typing
    // group/sub field (which also has a resolvable 1-segment prefix) would
    // wrongly show zero candidates instead of falling back to field
    // completion. See completion_context's own comment on this.

    #[test]
    fn sort_field_stage_before_any_slash() {
        assert!(matches!(completion_context("/sort/"), Some(Completion::SortField { .. })));
        assert!(matches!(completion_context("/sort/wor"), Some(Completion::SortField { .. })));
    }

    #[test]
    fn sort_direction_stage_after_a_flat_field_and_slash() {
        let Some(Completion::SortDirection { field, fragment, .. }) = completion_context("/sort/workspace/") else {
            panic!("expected SortDirection")
        };
        assert_eq!(field, ResolvedField::Flat("workspace"));
        assert_eq!(fragment, "");
    }

    #[test]
    fn sort_stays_in_field_stage_while_still_typing_a_group_sub() {
        // "tmux" alone resolves (bare-default), but "session" isn't a
        // direction -- must fall back to field completion, not go silent.
        let Some(Completion::SortField { fragment, .. }) = completion_context("/sort/tmux/session") else {
            panic!("expected SortField, not SortDirection with no candidates")
        };
        assert_eq!(fragment, "tmux/session");
    }

    #[test]
    fn sort_direction_stage_after_a_complete_group_sub_and_slash() {
        let Some(Completion::SortDirection { field, .. }) = completion_context("/sort/tmux/session/") else {
            panic!("expected SortDirection")
        };
        assert_eq!(field, ResolvedField::Group("tmux", "session"));
    }

    #[test]
    fn top_level_completion_offers_visibility_markers_and_actions() {
        let Some(Completion::TopLevel { fragment, .. }) = completion_context("/") else { panic!() };
        let cands = completion_candidates(&Completion::TopLevel { start: 0, fragment }, &[], &[]);
        assert!(cands.contains(&"+".to_string()));
        assert!(cands.contains(&"-".to_string()));
        assert!(cands.contains(&"sort".to_string()));
        assert!(cands.contains(&"reverse".to_string()));
    }

    #[test]
    fn visibility_completion_excludes_actions_and_markers() {
        let Some(Completion::VisibilityPath { fragment, sign, .. }) = completion_context("/+") else { panic!() };
        assert_eq!(sign, '+');
        let cands = completion_candidates(&Completion::VisibilityPath { start: 0, sign, fragment }, &[], &[]);
        assert!(!cands.iter().any(|c| c == "sort" || c == "reverse" || c == "+" || c == "-"));
        assert!(cands.contains(&"title".to_string()));
    }

    // --- comparator ----------------------------------------------------

    #[test]
    fn numeric_compare_beats_lexicographic_for_plain_ints() {
        use std::cmp::Ordering;
        assert_eq!(compare_field_values("2", "10"), Ordering::Less); // not lexicographic
        assert_eq!(compare_field_values("10", "2"), Ordering::Greater);
    }

    #[test]
    fn age_bucket_compare_is_chronological_ascending_oldest_first() {
        use std::cmp::Ordering;
        // 5m is more recent than 3h is more recent than 2d
        assert_eq!(compare_field_values("2d", "3h"), Ordering::Less); // older sorts first (ascending)
        assert_eq!(compare_field_values("3h", "5m"), Ordering::Less);
        assert_eq!(compare_field_values("30s", "5m"), Ordering::Greater); // newer sorts last
    }

    #[test]
    fn descending_direction_on_age_means_newest_first() {
        use std::cmp::Ordering;
        // "descending" on a date field colloquially means newest-first.
        // 5m (recent) should sort BEFORE 3h (older) under Descending.
        assert_eq!(compare_with_direction("5m", "3h", Direction::Descending), Ordering::Less);
        assert_eq!(compare_with_direction("3h", "5m", Direction::Ascending), Ordering::Less);
    }

    #[test]
    fn text_fields_compare_lexicographically_direction_applied_literally() {
        use std::cmp::Ordering;
        assert_eq!(compare_with_direction("apple", "banana", Direction::Ascending), Ordering::Less);
        assert_eq!(compare_with_direction("apple", "banana", Direction::Descending), Ordering::Greater);
    }
}
