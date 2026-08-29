//! The `$column:value` filter DSL: tokens split on whitespace, `$col:val`
//! tokens fuzzy-match both the column name and the value independently
//! (subsequence matching, case-insensitive -- `$tit:crit` matches column
//! "title" and any window whose title subsequence-matches "crit"), bare
//! words substring-match a combined title+class haystack, and multiple
//! tokens in one query are ANDed together.
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

use crate::hyprctl::Window;

/// Every column name a `$column:` prefix can fuzzy-resolve to. Add new
/// fields here and in `column_value` together.
const COLUMNS: &[&str] = &["title", "class", "workspace", "pid"];

fn column_value(win: &Window, column: &str) -> String {
    match column {
        "title" => win.title.clone(),
        "class" => win.class.clone(),
        "workspace" => win.workspace.clone(),
        "pid" => win.pid.to_string(),
        _ => String::new(),
    }
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

enum Token {
    Column { column_query: String, value: String },
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

/// If `query` currently ends mid-typing a `$field` fragment -- bare or
/// still quote-open, no `:` yet -- -> the byte offset in `query` where that
/// trailing token starts (so a caller can replace `query[start..]`
/// wholesale with a chosen completion) and the fragment text after `$` to
/// match column names against. `None` once a `:` has been typed (that's a
/// value in progress, not a field name -- not this function's business) or
/// if the query isn't trailing a `$...` token at all.
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

/// Every column name, in `COLUMNS`' own display order, that
/// subsequence-fuzzy-matches `fragment` -- the "what could `$<fragment>`
/// resolve to" list an autocomplete popup narrows as the user types. An
/// empty fragment matches (and so lists) every column, which is what makes
/// typing a bare `$` immediately show the full set -- see
/// ~/.config/docs/query-dsl.md's autocompletion section for why this only
/// works at all because the field list is small and fully enumerable.
pub fn column_suggestions(fragment: &str) -> Vec<&'static str> {
    COLUMNS.iter().copied().filter(|c| subsequence(fragment, c)).collect()
}

/// If `query` currently ends in a `$col:fragment` token whose `col` resolves
/// -- via the same fuzzy rule `column_suggestions` uses -- to *exactly one*
/// column, -> the byte offset where that trailing token starts, the
/// resolved column name, and the fragment after `:` to narrow values by.
/// `None` if `col` is ambiguous (resolves to zero or more than one column):
/// there's no single value set to suggest from in that case, the same way
/// `trailing_field_fragment` only fires before a `:` exists at all -- the
/// two functions are mutually exclusive on any given query.
///
/// Quote-agnostic for free: `tokenize_with_spans` has already folded a
/// still-open `$title:"imp` into one token by the time this looks at it, so
/// `fragment` here is already dequoted.
pub fn trailing_value_fragment(query: &str) -> Option<(usize, &'static str, String)> {
    let (start, last) = tokenize_with_spans(query).into_iter().last()?;
    let (col_query, val_frag) = last.strip_prefix('$')?.split_once(':')?;
    let mut resolved = COLUMNS.iter().copied().filter(|c| subsequence(col_query, c));
    let col = resolved.next()?;
    if resolved.next().is_some() {
        return None;
    }
    Some((start, col, val_frag.to_string()))
}

/// Every distinct, non-empty value `column` actually has across `windows`
/// right now, subsequence-fuzzy-narrowed by `fragment` -- exactly the same
/// matching a manually typed `$column:value` would apply, so what's offered
/// here is guaranteed to be something that would actually match if typed.
/// Sorted and deduplicated (`BTreeSet`) for a stable, predictable order
/// rather than window-list order, which shuffles as focus/list order
/// changes underneath the popup. Unlike `column_suggestions`'s fixed
/// `COLUMNS`, this list's *size* isn't bounded by anything but how many
/// distinct values are currently live -- fine at winswitch's scale (at most
/// a couple dozen open windows), but why this is winswitch-only for now,
/// not (yet) attempted for a corpus with hundreds of live values.
pub fn value_suggestions(windows: &[Window], column: &str, fragment: &str) -> Vec<String> {
    let mut seen = std::collections::BTreeSet::new();
    for w in windows {
        let v = column_value(w, column);
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
                if let Some((col, val)) = rest.split_once(':') {
                    return Token::Column {
                        column_query: col.to_string(),
                        value: val.to_string(),
                    };
                }
            }
            Token::Free(word)
        })
        .collect()
}

fn token_matches(win: &Window, token: &Token) -> bool {
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
        Token::Column { column_query, value } => COLUMNS
            .iter()
            .filter(|col| subsequence(column_query, col))
            .any(|col| subsequence(value, &column_value(win, col))),
    }
}

fn matches(win: &Window, tokens: &[Token]) -> bool {
    tokens.iter().all(|t| token_matches(win, t))
}

/// Convenience wrapper for call sites that don't need to hold onto the
/// parsed tokens (they're cheap to reparse -- at most a few dozen windows,
/// once per keystroke).
pub fn matches_str(win: &Window, query: &str) -> bool {
    if query.is_empty() {
        return true;
    }
    matches(win, &parse(query))
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
        assert!(matches_str(&w, "terminal"));
        assert!(matches_str(&w, "alacritty"));
        assert!(!matches_str(&w, "firefox"));
    }

    #[test]
    fn exact_column_and_value() {
        let w = win("hyprpm build log", "Alacritty", "1", 100);
        assert!(matches_str(&w, "$title:hyprpm"));
        assert!(!matches_str(&w, "$title:firefox"));
    }

    #[test]
    fn fuzzy_column_and_value_both_subsequence() {
        // $tit:crit -> column "tit" fuzzy-matches "title", value "crit"
        // subsequence-matches "alacritty".
        let w = win("Alacritty", "Alacritty", "1", 100);
        assert!(matches_str(&w, "$tit:crit"));
    }

    #[test]
    fn column_prefix_resolves_to_the_matching_column_only() {
        let w = win("something", "Firefox", "1", 100);
        assert!(matches_str(&w, "$cl:fire"));
        assert!(!matches_str(&w, "$cl:something")); // "something" is the title, not the class
    }

    #[test]
    fn multiple_tokens_are_anded() {
        let w = win("hyprpm build log", "Alacritty", "1", 100);
        assert!(matches_str(&w, "$title:hyprpm $class:alac"));
        assert!(!matches_str(&w, "$title:hyprpm $class:firefox"));
    }

    #[test]
    fn unknown_column_matches_nothing() {
        let w = win("hyprpm", "Alacritty", "1", 100);
        assert!(!matches_str(&w, "$zzz:hyprpm"));
    }

    #[test]
    fn pid_column_matches_numeric_string() {
        let w = win("t", "c", "1", 12345);
        assert!(matches_str(&w, "$pid:234"));
        assert!(!matches_str(&w, "$pid:999"));
    }

    #[test]
    fn quoted_value_survives_as_one_token_and_matches_by_subsequence() {
        let w = win("Imperial Rome", "Alacritty", "1", 100);
        assert!(matches_str(&w, r#"$title:"imp rom""#));
        assert!(matches_str(&w, r#"$title:"imperial rome""#));
        assert!(!matches_str(&w, r#"$title:"rom imp""#)); // wrong order
    }

    #[test]
    fn quoted_column_name_survives_as_one_token() {
        // No real multi-word column exists today, but the tokenizer must
        // not choke on (or split apart) one if it ever does.
        let w = win("Imperial Rome", "Alacritty", "1", 100);
        assert!(matches_str(&w, r#"$"tit":imperial"#));
    }

    #[test]
    fn quoted_free_word_matches_by_subsequence_across_the_space() {
        let w = win("Imperial Rome", "Alacritty", "1", 100);
        assert!(matches_str(&w, r#""imp rom""#));
        assert!(!matches_str(&w, r#""rom imp""#)); // wrong order
        // unquoted "imp rom" still ANDs two independent substrings, order
        // notwithstanding, unaffected by any of this
        assert!(matches_str(&w, "rom imp"));
    }

    #[test]
    fn unterminated_quote_does_not_panic_or_drop_the_token() {
        let w = win("Imperial Rome", "Alacritty", "1", 100);
        assert!(matches_str(&w, r#"$title:"imp"#));
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
    }

    #[test]
    fn column_suggestions_narrow_fuzzily_and_empty_fragment_lists_all() {
        assert_eq!(column_suggestions(""), vec!["title", "class", "workspace", "pid"]);
        assert_eq!(column_suggestions("ti"), vec!["title"]);
        assert_eq!(column_suggestions("ss"), vec!["class"]); // "workspace" has only one 's'
        assert!(column_suggestions("zzz").is_empty());
    }

    #[test]
    fn trailing_value_fragment_needs_an_unambiguous_column() {
        assert_eq!(
            trailing_value_fragment("$workspace:"),
            Some((0, "workspace", "".to_string()))
        );
        assert_eq!(
            trailing_value_fragment("$workspace:2"),
            Some((0, "workspace", "2".to_string()))
        );
        assert_eq!(
            trailing_value_fragment("foo $ti:al"),
            Some((4, "title", "al".to_string()))
        );
        // "c" is a subsequence of both "class" and "workspace" - ambiguous,
        // no single value set to suggest from
        assert_eq!(trailing_value_fragment("$c:x"), None);
        assert_eq!(trailing_value_fragment("$title"), None); // no ':' yet
        assert_eq!(trailing_value_fragment("plain"), None);
    }

    #[test]
    fn value_suggestions_are_deduped_sorted_and_fuzzy_narrowed() {
        let windows = vec![
            win("a", "Firefox", "1", 1),
            win("b", "Alacritty", "1", 2),
            win("c", "Alacritty", "2", 3),
            win("d", "kitty", "", 4), // empty workspace never suggested
        ];
        assert_eq!(value_suggestions(&windows, "workspace", ""), vec!["1", "2"]);
        assert_eq!(value_suggestions(&windows, "class", ""), vec!["Alacritty", "Firefox", "kitty"]);
        assert_eq!(value_suggestions(&windows, "class", "ala"), vec!["Alacritty"]);
        assert!(value_suggestions(&windows, "class", "zzz").is_empty());
    }
}
