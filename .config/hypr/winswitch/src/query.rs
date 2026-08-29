//! The `$column:value` filter DSL: tokens split on whitespace, `$col:val`
//! tokens fuzzy-match both the column name and the value independently
//! (subsequence matching, case-insensitive -- `$tit:crit` matches column
//! "title" and any window whose title subsequence-matches "crit"), bare
//! words substring-match a combined title+class haystack, and multiple
//! tokens in one query are ANDed together.
//!
//! On top of the flat columns (`title`/`class`/`workspace`/`pid`), two
//! **groups** add a dotted namespace: `$tmux.<sub>:value` and
//! `$claude.<sub>:value`, backed by `enrich::TmuxClaudeMeta` rather than
//! `hyprctl::Window` -- see ~/.config/docs/query-dsl.md for the full
//! writeup, and `enrich.rs` for how that data is actually gathered
//! (asynchronously; a window's group fields may simply be absent for a
//! while after the grid opens, which behaves exactly like an unresolved
//! field always has here -- no match yet, not an error).
//!   - `$tmux.title:foo` / `$claude.contents:foo` -- explicit group.sub.
//!   - `$tmux:foo` -- bare group, defaults to `.title` (not "every sub").
//!   - `$tmux.*:foo` -- literal reserved suffix: matches if *any* subfield
//!     of the group matches. Not regex -- `.*` is one hand-parsed token,
//!     same "no real regex anywhere in this DSL" rule every other form here
//!     already follows.
//!   - `$claude` / `$clau` -- bare, **no colon at all**: an existence
//!     filter, not a text search -- "does this window have any claude data
//!     at all." This is what makes typing just `$clau` immediately narrow
//!     the grid down to claude-hosting windows, before a colon or value is
//!     ever typed. Only applies to groups (existence isn't a meaningful
//!     question for `title`/`class`/etc., which every window always has);
//!     an unresolved or dotted-but-colonless fragment (`$zzz`, `$tmux.se`)
//!     falls back to the pre-existing plain-text behaviour unchanged.
//!
//! `"..."` quoting lets a column name or value contain whitespace without
//! it splitting into separate (and separately required) tokens -- e.g.
//! `$title:"imperial rome"` or, for a hypothetical multi-word column name,
//! `$"col nam":x`. This is *not* the exact-literal-text quoting
//! `window-search.py`/`focus-picker.py`/`claude-history` use (see
//! ~/.config/docs/query-dsl.md): subsequence() already matches a needle
//! containing a literal space against a haystack with a real space in the
//! right place (`subsequence("imp rom", "imperial rome")` walks i-m-p,
//! then the space itself, then r-o-m, all in order), so no new matching
//! algorithm is needed here -- quoting only has to stop the tokenizer from
//! splitting the run apart before subsequence() ever sees it. A bare
//! (unquoted) Free word keeps the older literal-substring behaviour
//! unchanged; only a token that contains whitespace -- which, since
//! whitespace splits tokens, can only happen if it came from a quoted
//! run -- gets the subsequence treatment. See `tokenize`/`token_matches`.

use crate::enrich::TmuxClaudeMeta;
use crate::hyprctl::Window;

/// Every flat column name a `$column:` prefix can fuzzy-resolve to. Add new
/// fields here and in `column_value` together.
const COLUMNS: &[&str] = &["title", "class", "workspace", "pid"];

/// Group name -> its own subfield list, in display order. Add a new group's
/// data to `enrich::TmuxClaudeMeta` and `group_sub_value` together.
const GROUPS: &[(&str, &[&str])] = &[
    ("tmux", &["session", "window", "title"]),
    ("claude", &["title", "path", "session", "contents"]),
];

/// What a bare `$group:value` (no dot) resolves its group to.
const GROUP_DEFAULT_SUB: &str = "title";

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
/// bare `$group` (no colon at all, e.g. `$claude`/`$clau`) checks for. Not a
/// text search: it's an existence filter, "does this window have any
/// tmux/claude data at all," which is what makes `$claude` alone a useful
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

/// Which single concrete field a `$field:` prefix (flat or group.sub, dot
/// optional) unambiguously names -- what `trailing_value_fragment` and
/// `value_suggestions` need in order to know which one field's live values
/// to offer.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ResolvedField {
    Flat(&'static str),
    Group(&'static str, &'static str),
}

impl ResolvedField {
    /// The text that goes right after `$` and before `:` to name this field
    /// explicitly -- `"title"` or `"tmux.session"`.
    pub fn key(&self) -> String {
        match self {
            ResolvedField::Flat(c) => c.to_string(),
            ResolvedField::Group(g, s) => format!("{g}.{s}"),
        }
    }
}

enum Token {
    /// `field_query` is the text before an optional `.`; `sub_query` is
    /// `Some` (possibly `"*"`) only when a `.` was actually typed.
    Field { field_query: String, sub_query: Option<String>, value: String },
    /// A bare `$group` with **no colon at all** (`$claude`, `$clau`, `$tmux`)
    /// -- an existence filter ("does this window have any tmux/claude data
    /// at all"), distinct from `$group:` (colon, empty value), which
    /// trivially matches everything the same way every other `$field:`
    /// empty-value form already does. Only created when the fragment
    /// actually resolves to a group and contains no `.` -- a dotted,
    /// colonless fragment (`$tmux.se`, still mid-typing a sub) and an
    /// unresolvable one both fall back to `Free`, unchanged from before
    /// groups existed at all.
    GroupExists(String),
    Free(String),
}

/// Split `query` on whitespace like `str::split_whitespace`, except a
/// `"..."`-quoted run is kept as one token with its interior whitespace
/// intact (quote characters themselves are dropped, wherever in the token
/// they fall -- `$"col nam":x` and `$col:"multi word"` both come out with
/// the space simply folded into the token text, since either position
/// leaves the resulting `$col:val` split at the first `:` unambiguous).
/// Also returns each token's starting byte offset in `query`, for callers
/// that need to splice a replacement in (`trailing_field_fragment`).
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

/// If `query` currently ends mid-typing a `$field` fragment -- bare, dotted
/// (`$tmux.se`), or still quote-open, no `:` yet -- -> the byte offset in
/// `query` where that trailing token starts (so a caller can replace
/// `query[start..]` wholesale with a chosen completion) and the fragment
/// text after `$` (dot included, if typed) to resolve against column/group
/// names. `None` once a `:` has been typed (that's a value in progress, not
/// a field name -- not this function's business) or if the query isn't
/// trailing a `$...` token at all.
///
/// Only ever looks at the *last* token, on the same "editing happens at the
/// end of what's typed" assumption the rest of this DSL's completion logic
/// (see focus-picker.py's `suggest_completion`) already makes.
pub fn trailing_field_fragment(query: &str) -> Option<(usize, String)> {
    let (start, last) = tokenize_with_spans(query).into_iter().last()?;
    let frag = last.strip_prefix('$')?;
    if frag.contains(':') {
        return None;
    }
    Some((start, frag.to_string()))
}

/// Every completion candidate for `fragment` (the text `trailing_field_
/// fragment` returned, dot included if typed), each a full string ready to
/// splice right after `$` -- `"title"`, `"tmux"`, or `"tmux.session"`.
///
/// No dot yet: unions flat columns and group names, same "union everything
/// that resolves" rule `$field:value` itself already follows. A dot already
/// typed: only offers completions once the group name before it is
/// unambiguous (mirrors `trailing_value_fragment`'s "exactly one column"
/// rule, one level up) -- an ambiguous or unknown group has no fixed
/// subfield list to suggest from. `*` is offered as its own candidate
/// alongside real subfields so the "match any sub" form stays discoverable
/// without having to know it exists.
pub fn column_suggestions(fragment: &str) -> Vec<String> {
    if let Some((group_frag, sub_frag)) = fragment.split_once('.') {
        let groups = resolve_groups(group_frag);
        let [group] = groups[..] else { return Vec::new() };
        let mut out: Vec<String> =
            resolve_group_subs(group, sub_frag).into_iter().map(|s| format!("{group}.{s}")).collect();
        if subsequence(sub_frag, "*") {
            out.push(format!("{group}.*"));
        }
        return out;
    }
    let mut out: Vec<String> = COLUMNS.iter().filter(|c| subsequence(fragment, c)).map(|c| c.to_string()).collect();
    out.extend(resolve_groups(fragment).iter().map(|g| g.to_string()));
    out
}

/// Resolves the text before `:` in a `$...:` token (dot optional) to exactly
/// one concrete field, or `None` if it's ambiguous, unknown, or a `.*`
/// (which names a *set* of fields, not one value domain to suggest from --
/// same "no single value set to offer" reasoning `trailing_value_fragment`
/// already applies to an ambiguous flat column).
fn resolve_field_unambiguous(field_and_sub: &str) -> Option<ResolvedField> {
    if let Some((group_frag, sub_frag)) = field_and_sub.split_once('.') {
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

/// If `query` currently ends in a `$field:fragment` token whose field
/// resolves -- via `resolve_field_unambiguous` -- to exactly one concrete
/// field, -> the byte offset where that trailing token starts, the resolved
/// field, and the fragment after `:` to narrow values by. `None` if
/// ambiguous or unknown, the same way `trailing_field_fragment` only fires
/// before a `:` exists at all -- the two functions are mutually exclusive on
/// any given query.
///
/// Quote-agnostic for free: `tokenize_with_spans` has already folded a
/// still-open `$title:"imp` into one token by the time this looks at it, so
/// `fragment` here is already dequoted.
pub fn trailing_value_fragment(query: &str) -> Option<(usize, ResolvedField, String)> {
    let (start, last) = tokenize_with_spans(query).into_iter().last()?;
    let (field_and_sub, val_frag) = last.strip_prefix('$')?.split_once(':')?;
    let resolved = resolve_field_unambiguous(field_and_sub)?;
    Some((start, resolved, val_frag.to_string()))
}

fn field_value(win: &Window, meta: &TmuxClaudeMeta, field: ResolvedField) -> String {
    match field {
        ResolvedField::Flat(c) => column_value(win, c),
        ResolvedField::Group(g, s) => group_sub_value(meta, g, s),
    }
}

/// Every distinct, non-empty value `field` actually has across
/// `windows`/`metas` (parallel, same index) right now, subsequence-fuzzy-
/// narrowed by `fragment` -- exactly the same matching a manually typed
/// `$field:value` would apply, so what's offered here is guaranteed to be
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

fn parse(query: &str) -> Vec<Token> {
    tokenize(query)
        .into_iter()
        .map(|word| {
            if let Some(rest) = word.strip_prefix('$') {
                if let Some((field_and_sub, value)) = rest.split_once(':') {
                    let (field_query, sub_query) = match field_and_sub.split_once('.') {
                        Some((f, s)) => (f.to_string(), Some(s.to_string())),
                        None => (field_and_sub.to_string(), None),
                    };
                    return Token::Field { field_query, sub_query, value: value.to_string() };
                }
                if !rest.contains('.') && !resolve_groups(rest).is_empty() {
                    return Token::GroupExists(rest.to_string());
                }
            }
            Token::Free(word)
        })
        .collect()
}

/// A `$field:value` token's match, covering all three forms: bare (unions
/// flat columns and each matched group's `.title` default), `.sub`, and
/// `.*` (any sub of the matched group(s)). An unresolvable field/group -- or
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
            // upgrade $column:value quoting gets below.
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
    fn exact_column_and_value() {
        let w = win("hyprpm build log", "Alacritty", "1", 100);
        assert!(matches_win(&w, "$title:hyprpm"));
        assert!(!matches_win(&w, "$title:firefox"));
    }

    #[test]
    fn fuzzy_column_and_value_both_subsequence() {
        // $tit:crit -> column "tit" fuzzy-matches "title", value "crit"
        // subsequence-matches "alacritty".
        let w = win("Alacritty", "Alacritty", "1", 100);
        assert!(matches_win(&w, "$tit:crit"));
    }

    #[test]
    fn column_prefix_resolves_to_the_matching_column_only() {
        let w = win("something", "Firefox", "1", 100);
        assert!(matches_win(&w, "$cl:fire"));
        assert!(!matches_win(&w, "$cl:something")); // "something" is the title, not the class
    }

    #[test]
    fn multiple_tokens_are_anded() {
        let w = win("hyprpm build log", "Alacritty", "1", 100);
        assert!(matches_win(&w, "$title:hyprpm $class:alac"));
        assert!(!matches_win(&w, "$title:hyprpm $class:firefox"));
    }

    #[test]
    fn unknown_column_matches_nothing() {
        let w = win("hyprpm", "Alacritty", "1", 100);
        assert!(!matches_win(&w, "$zzz:hyprpm"));
    }

    #[test]
    fn pid_column_matches_numeric_string() {
        let w = win("t", "c", "1", 12345);
        assert!(matches_win(&w, "$pid:234"));
        assert!(!matches_win(&w, "$pid:999"));
    }

    #[test]
    fn quoted_value_survives_as_one_token_and_matches_by_subsequence() {
        let w = win("Imperial Rome", "Alacritty", "1", 100);
        assert!(matches_win(&w, r#"$title:"imp rom""#));
        assert!(matches_win(&w, r#"$title:"imperial rome""#));
        assert!(!matches_win(&w, r#"$title:"rom imp""#)); // wrong order
    }

    #[test]
    fn quoted_column_name_survives_as_one_token() {
        // No real multi-word column exists today, but the tokenizer must
        // not choke on (or split apart) one if it ever does.
        let w = win("Imperial Rome", "Alacritty", "1", 100);
        assert!(matches_win(&w, r#"$"tit":imperial"#));
    }

    #[test]
    fn quoted_free_word_matches_by_subsequence_across_the_space() {
        let w = win("Imperial Rome", "Alacritty", "1", 100);
        assert!(matches_win(&w, r#""imp rom""#));
        assert!(!matches_win(&w, r#""rom imp""#)); // wrong order
        // unquoted "imp rom" still ANDs two independent substrings, order
        // notwithstanding, unaffected by any of this
        assert!(matches_win(&w, "rom imp"));
    }

    #[test]
    fn unterminated_quote_does_not_panic_or_drop_the_token() {
        let w = win("Imperial Rome", "Alacritty", "1", 100);
        assert!(matches_win(&w, r#"$title:"imp"#));
    }

    #[test]
    fn trailing_field_fragment_detects_mid_typed_dollar_token() {
        assert_eq!(trailing_field_fragment("$"), Some((0, "".to_string())));
        assert_eq!(trailing_field_fragment("$tit"), Some((0, "tit".to_string())));
        assert_eq!(
            trailing_field_fragment("$title:foo $wor"),
            Some((11, "wor".to_string()))
        );
        assert_eq!(trailing_field_fragment("$title:foo"), None); // already has a value
        assert_eq!(trailing_field_fragment("$title:foo "), None); // trailing space, no new token yet
        assert_eq!(trailing_field_fragment("plain text"), None);
        assert_eq!(trailing_field_fragment(""), None);
        // dotted, still mid-typing the sub part -- no ':' yet either
        assert_eq!(trailing_field_fragment("$tmux.se"), Some((0, "tmux.se".to_string())));
    }

    #[test]
    fn column_suggestions_narrow_fuzzily_and_empty_fragment_lists_all() {
        assert_eq!(
            column_suggestions(""),
            vec!["title", "class", "workspace", "pid", "tmux", "claude"]
        );
        assert_eq!(column_suggestions("ti"), vec!["title"]);
        assert_eq!(column_suggestions("ss"), vec!["class"]); // "workspace" has only one 's'
        assert!(column_suggestions("zzz").is_empty());
    }

    #[test]
    fn group_dot_suggestions_need_an_unambiguous_group() {
        let subs = column_suggestions("tmux.");
        assert!(subs.contains(&"tmux.session".to_string()));
        assert!(subs.contains(&"tmux.window".to_string()));
        assert!(subs.contains(&"tmux.title".to_string()));
        assert!(subs.contains(&"tmux.*".to_string()));
        assert_eq!(column_suggestions("tmux.se"), vec!["tmux.session"]);
        // unknown group before the dot -> no fixed subfield list to offer
        assert!(column_suggestions("zzz.foo").is_empty());
    }

    #[test]
    fn trailing_value_fragment_needs_an_unambiguous_column() {
        assert_eq!(
            trailing_value_fragment("$workspace:"),
            Some((0, ResolvedField::Flat("workspace"), "".to_string()))
        );
        assert_eq!(
            trailing_value_fragment("$workspace:2"),
            Some((0, ResolvedField::Flat("workspace"), "2".to_string()))
        );
        assert_eq!(
            trailing_value_fragment("foo $ti:al"),
            Some((4, ResolvedField::Flat("title"), "al".to_string()))
        );
        // "c" is a subsequence of both "class" and "workspace" - ambiguous,
        // no single value set to suggest from
        assert_eq!(trailing_value_fragment("$c:x"), None);
        assert_eq!(trailing_value_fragment("$title"), None); // no ':' yet
        assert_eq!(trailing_value_fragment("plain"), None);
        // bare group defaults to its own "title" sub
        assert_eq!(
            trailing_value_fragment("$tmux:foo"),
            Some((0, ResolvedField::Group("tmux", "title"), "foo".to_string()))
        );
        assert_eq!(
            trailing_value_fragment("$tmux.session:foo"),
            Some((0, ResolvedField::Group("tmux", "session"), "foo".to_string()))
        );
        // ".*" names a set, not one field -- no single value domain
        assert_eq!(trailing_value_fragment("$tmux.*:foo"), None);
    }

    #[test]
    fn value_suggestions_are_deduped_sorted_and_fuzzy_narrowed() {
        let windows = vec![
            win("a", "Firefox", "1", 1),
            win("b", "Alacritty", "1", 2),
            win("c", "Alacritty", "2", 3),
            win("d", "kitty", "", 4), // empty workspace never suggested
        ];
        let metas = vec![no_meta(), no_meta(), no_meta(), no_meta()];
        assert_eq!(
            value_suggestions(&windows, &metas, ResolvedField::Flat("workspace"), ""),
            vec!["1", "2"]
        );
        assert_eq!(
            value_suggestions(&windows, &metas, ResolvedField::Flat("class"), ""),
            vec!["Alacritty", "Firefox", "kitty"]
        );
        assert_eq!(
            value_suggestions(&windows, &metas, ResolvedField::Flat("class"), "ala"),
            vec!["Alacritty"]
        );
        assert!(value_suggestions(&windows, &metas, ResolvedField::Flat("class"), "zzz").is_empty());
    }

    #[test]
    fn group_field_matches_bare_defaults_to_title_dot_matches_any_sub() {
        let w = win("t", "c", "1", 100);
        let mut meta = TmuxClaudeMeta::default();
        meta.tmux_session = Some("work".to_string());
        meta.tmux_title = Some("hyprpm build log".to_string());

        // bare $tmux: only reaches .title, not .session
        assert!(matches_str(&w, &meta, "$tmux:hyprpm"));
        assert!(!matches_str(&w, &meta, "$tmux:work"));
        // explicit sub reaches its own field
        assert!(matches_str(&w, &meta, "$tmux.session:work"));
        assert!(!matches_str(&w, &meta, "$tmux.session:hyprpm"));
        // .* reaches either
        assert!(matches_str(&w, &meta, "$tmux.*:work"));
        assert!(matches_str(&w, &meta, "$tmux.*:hyprpm"));
        assert!(!matches_str(&w, &meta, "$tmux.*:nope"));
    }

    #[test]
    fn group_field_not_yet_enriched_matches_nothing_not_a_crash() {
        // Before enrich.rs's background thread lands anything, every group
        // field is None -- the same "absence, not a fallback" rule an
        // unresolvable column already had.
        let w = win("t", "c", "1", 100);
        assert!(!matches_str(&w, &no_meta(), "$tmux.session:anything"));
        assert!(!matches_str(&w, &no_meta(), "$claude.contents:anything"));
        // ...but an *empty* typed value still matches trivially either way,
        // same as every other subsequence-matched field.
        assert!(matches_str(&w, &no_meta(), "$tmux.session:"));
    }

    #[test]
    fn bare_group_no_colon_is_an_existence_filter() {
        let w = win("t", "c", "1", 100);
        let mut has_claude = TmuxClaudeMeta::default();
        has_claude.claude_title = Some("Waybar to quickshell migration".to_string());
        let no_claude = TmuxClaudeMeta::default();

        assert!(matches_str(&w, &has_claude, "$claude"));
        assert!(matches_str(&w, &has_claude, "$clau")); // fuzzy prefix, same as $claude:
        assert!(!matches_str(&w, &no_claude, "$claude"));
        assert!(!matches_str(&w, &no_claude, "$clau"));

        // tmux group is independent of the claude group
        let mut has_tmux_only = TmuxClaudeMeta::default();
        has_tmux_only.tmux_session = Some("work".to_string());
        assert!(matches_str(&w, &has_tmux_only, "$tmux"));
        assert!(!matches_str(&w, &has_tmux_only, "$claude"));
    }

    #[test]
    fn dotted_or_unresolvable_colonless_fragment_is_not_an_existence_filter() {
        // "$tmux.se" has a dot but no colon yet -- still mid-typing a sub,
        // not a complete existence check; falls back to old literal
        // free-word behaviour (never matches a plain window title/class).
        let w = win("t", "c", "1", 100);
        let mut meta = TmuxClaudeMeta::default();
        meta.tmux_session = Some("work".to_string());
        assert!(!matches_str(&w, &meta, "$tmux.se"));
        // unresolvable group name, no colon -- same fallback
        assert!(!matches_str(&w, &meta, "$zzz"));
    }

    #[test]
    fn claude_group_fields_resolve_independently() {
        let w = win("t", "c", "1", 100);
        let mut meta = TmuxClaudeMeta::default();
        meta.claude_title = Some("Waybar to quickshell migration".to_string());
        meta.claude_path = Some("/home/user1/dotfiles".to_string());
        meta.claude_contents = Some("discussed sysmond socket reconnect".to_string());

        assert!(matches_str(&w, &meta, "$claude:quickshell")); // bare -> .title
        assert!(!matches_str(&w, &meta, "$claude:dotfiles")); // .title only, not .path
        assert!(matches_str(&w, &meta, "$claude.path:dotfiles"));
        assert!(matches_str(&w, &meta, "$claude.contents:sysmond"));
        assert!(!matches_str(&w, &meta, "$claude.contents:quickshell"));
    }
}
