//! The `$column:value` filter DSL: tokens split on whitespace, `$col:val`
//! tokens fuzzy-match both the column name and the value independently
//! (subsequence matching, case-insensitive -- `$tit:crit` matches column
//! "title" and any window whose title subsequence-matches "crit"), bare
//! words substring-match a combined title+class haystack, and multiple
//! tokens in one query are ANDed together.

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

fn parse(query: &str) -> Vec<Token> {
    query
        .split_whitespace()
        .map(|word| {
            if let Some(rest) = word.strip_prefix('$') {
                if let Some((col, val)) = rest.split_once(':') {
                    return Token::Column {
                        column_query: col.to_string(),
                        value: val.to_string(),
                    };
                }
            }
            Token::Free(word.to_string())
        })
        .collect()
}

fn token_matches(win: &Window, token: &Token) -> bool {
    match token {
        Token::Free(word) => {
            let haystack = format!("{} {}", win.title, win.class).to_lowercase();
            haystack.contains(&word.to_lowercase())
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
}
