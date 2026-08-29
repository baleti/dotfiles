# Picker query DSL

The small query language typed into the search box of every fzf-driven
picker in this repo, plus winswitch's grid search. It was arrived at
independently in `window-search.py`, then reused (by hand, not by import) in
`claude-history` and `focus-picker.py`, then partially reimplemented in Rust
for winswitch's `query.rs`. It stays copy-pasted rather than a shared
library on purpose: three of the four implementations are Python but the
fourth is Rust, and the Python three, while structurally similar, differ
enough in what they're searching (scored full-text vs. flat substring,
tabular vs. grid) that a shared abstraction was judged not worth it yet —
this doc exists so the *semantics* stay consistent even though the code
doesn't.

Implementations, so this doc has a name for each:

| Name | File | Searches |
|---|---|---|
| window-search | `~/.config/tmux/scripts/window-search.py` | live tmux pane scrollback, BM25-ranked |
| claude-history | `~/bin/claude-history` | saved Claude Code conversation transcripts, BM25-ranked |
| focus-picker | `~/.config/tmux/scripts/focus-picker.py` | tmux panes, MRU-ordered (no ranking) |
| winswitch | `~/.config/hypr/winswitch/src/query.rs` | open windows (Hyprland), grid layout |

See [tmux.md](tmux.md) for the tmux bindings and [rust-tools.md](rust-tools.md)
for winswitch.

## Grammar

At each position in the query, one form is matched, tried in this order —
order matters because later forms are unanchored and would otherwise
swallow an earlier one's syntax:

```
"phrase"        exact quoted text — also the escape hatch, see below
!token          negation prefix (window-search/claude-history only)
+$group[.sub]   add a display column (focus-picker only)
-$group[.sub]   remove a display column (focus-picker only)
$field:value    scope value to one field
bareword        everything else
```

A query is a sequence of these, implicitly ANDed: every requirement present
must hold for a result to survive at all. Column directives (`+$`/`-$`)
never filter — they only ever change what a matched row *displays*.

### `$field:value` — the one syntax every implementation shares

Scopes `value` to a single field instead of the whole document/row. `field`
is itself **fuzzy** in every implementation, resolved against the known
field list rather than requiring the exact name — but *which* fuzzy
algorithm resolves it is not uniform (see "Fuzzy resolution, precisely"
below for the two algorithms in play): window-search/claude-history/
focus-picker use substring-containment (`$ti:foo` reaches `title` because
`"ti" in "title"`), winswitch uses subsequence (`$tsk:foo` would reach
`workspace` — "t","s","k" appear in that order inside "workspace" — a
match substring-containment alone would miss). All four union every field
that resolves rather than picking just one, so an ambiguous prefix
searches every field it could mean, not an arbitrarily-chosen first match.

- **window-search / claude-history**: `value` is itself BM25-scored against
  that one field's own per-document vocabulary (prefix-expanded the same way
  a bare word is — see below). An unresolvable field degrades to a literal
  bare-word search over the whole `"$field:value"` text, since a typo'd
  field prefix in front of real search text is still a real search someone
  typed.
- **focus-picker**: `value` is a plain case-insensitive substring test
  against that field's literal text (no scoring — this picker doesn't rank).
  Same unresolvable-field fallback to literal text.
- **winswitch**: both `field` *and* `value` are subsequence matches (see
  below) — the one implementation where the column-name resolution isn't
  substring-containment either, since `query.rs` already had subsequence
  wired up for values and reused it for names rather than adding a second
  algorithm. An unresolvable field is unmatchable (contributes nothing that
  can match), rather than a literal fallback — winswitch's grid is small
  and un-ranked, so a stray filter here reads as "narrow to nothing" rather
  than "silently degrade to a weaker search."

### `+$group[.sub]` / `-$group[.sub]` — column visibility (focus-picker only)

focus-picker is the one implementation with data that's tracked for every
row but not always worth displaying (SSH destination/host/IP, computed once
per invocation regardless — see `focus-picker.py`'s `ssh_info()`). `+$group`
reveals every column in that group; `+$group.sub` reveals just one.
`-$group[.sub]` is the exact mirror, removing what a `+$` added. Both
`group` and `sub` are fuzzy the same substring-containment way `$field` is
(`+$ssh.h` and `+$ssh.host` both reach `SSH.HOST`).

Tokens are processed **left to right** against one running ordered set, so
`+$ssh -$ssh.host +$ssh.host` ends with the column back (removed, then
re-added) — order is significant, unlike the AND-of-requirements semantics
everything else in the grammar has. Removing a column that was never added,
or whose group doesn't resolve, is a silent no-op, not an error.

The other three implementations have no `+$`/`-$` at all: window-search and
claude-history's fields are always either scored-in or not part of the
document, with nothing "hideable"; winswitch's grid has no column layout to
toggle in the first place (see winswitch's own `$field:value` note above).
Any future picker that gains optional, expensive-if-always-shown per-row
data should reach for this same `+$`/`-$` pair rather than inventing a new
shape.

### Negation (`!token` / `!"phrase"`) — window-search / claude-history only

`!` drops any result containing `token` (prefix-expanded the same as a bare
word — `!log` also drops `logs`/`login`) or, quoted, the exact phrase.
Chosen over the more conventional leading `-` specifically because these two
corpora are full of literal minus signs worth searching *for* (`-rf`,
`--stat`, CLI flags in general) — `-` was not available. `!` has no such
collision, since these two implementations' tokenizers never produce a bare
`!`. focus-picker and winswitch have no negation.

### Quoted phrases (`"..."`)

Doubles, everywhere, as the **literal escape hatch** for every other
prefix character this grammar reserves (`$`, `+$`, `-$`, `!`): quoting is
checked first at each position, so `"+$"` always means the two literal
characters, never the column-add directive. Beyond that, what quoting
*does* to the text inside it is the one place the four implementations
genuinely diverge, not just in which forms they support:

- **window-search / claude-history / focus-picker**: exact text,
  whitespace-normalized, never fuzzy/prefix-expanded — the opposite end of
  the spectrum from a bare word. window-search/claude-history additionally
  give quoted (and punctuation-bearing bare) text a "soft literal" ranking
  bonus, see the bare-word section above; focus-picker just takes it as a
  literal substring/AND term.
- **winswitch**: quoting means something different here on purpose —
  not "exact," but "let this span whitespace." winswitch's tokenizer
  otherwise splits on every whitespace run the way all four
  implementations do, which normally makes a multi-word field name or
  value impossible to type as one unit (`$title:imperial rome` would
  become two separate tokens, `$title:imperial` and a stray `rome`).
  Quoting — `$title:"imperial rome"`, or `$"multi word field":x` for a
  hypothetical future column — keeps the run as one token without
  splitting it, and it's still matched by the *same* subsequence()
  fuzzy-match every unquoted `$field:value` already uses, not a literal
  comparison. Concretely: `$title:"imp rom"` matches a window titled
  "Imperial Rome" the identical way `$title:imp` already fuzzy-matches
  "Imperial", because subsequence() already treats a literal space in the
  needle as just another character to find in order — matching "imp",
  then the space between the two haystack words, then "rom" — so no new
  matching algorithm was needed, only a tokenizer that stops splitting the
  run apart before subsequence() ever sees it. This applies to bare
  (non-`$`) quoted text too: `"imp rom"` alone, quoted, subsequence-matches
  title+class the same way; unquoted `imp rom` still ANDs two independent
  substring tests the older way, order not enforced, both still work but
  mean slightly different things. See `query.rs`'s module doc for the
  worked-through reasoning, and `tokenize_with_spans`/`token_matches` for
  the implementation — the whitespace *inside* a token, after tokenizing,
  is itself the signal that it came from a quoted run, since unquoted
  whitespace can never survive into a token at all.

### Bare words

The default: no special character, no quotes. What counts as a "match"
differs by implementation and is the main axis they differ on:

- **window-search / claude-history**: prefix-expanded against the corpus's
  own vocabulary (`"ric"` finds `"ricing"`), BM25-scored, and required
  (`MATCH_MODE=all`, i.e. every bare word's expansion must appear
  *somewhere* in the document — see [[bm25_score_gate_vs_filter_only_fields]]
  memory for a gotcha hit while wiring required-vs-scoring together for
  `$field:` terms specifically). A bare word carrying punctuation (`ctrl+.`)
  additionally gets a **soft literal** bonus: it still searches for just the
  alnum token (`ctrl`, since punctuation is stripped at the tokenizer), but
  a document containing the literal punctuated text scores higher — nothing
  is excluded by this, it only affects ranking.
- **focus-picker**: plain case-insensitive substring test against the row's
  full searchable text (session + window + title + any tracked-but-hidden
  data), required, unranked — the base list is always MRU order; typing only
  narrows it.
- **winswitch**: substring test against `title + " " + class` only (not
  workspace/pid — those need the explicit `$field:` form), required,
  unranked — unless quoted (see above), in which case it's a
  whitespace-preserving subsequence match instead.

## Autocompletion

Typing `$` alone should be enough to discover what fields exist — an empty
field name is otherwise indistinguishable from "not typed yet," so without
some form of visible completion, `$title`/`$class`/`$workspace`/`$pid`
(winswitch's actual set, easy to under- or over-guess from memory) has to
be memorized or re-derived from source. The same problem repeats one level
down: once past `$workspace:`, what *values* actually exist right now (`1`?
`2`? a named workspace?) is just as undiscoverable without looking. winswitch
is the first implementation to grow a real completion popup, covering both:
GTK-native, not fzf-driven the way the tmux pickers' tab-completion already
is (see below).

**Field-name completion** (`$fragment`, no `:` yet):

- **Trigger**: the query's trailing token, considered on the same
  "editing happens at the end of what's typed" assumption
  `focus-picker.py`'s `suggest_completion` already uses, starts with `$`
  and has no `:` yet — `query::trailing_field_fragment` in `query.rs`
  detects this off the same quote-aware tokenizer the matching logic uses
  (so `$"col na` — an in-progress quoted field name — triggers it too),
  returning the fragment text after `$` and the byte offset a chosen
  completion should replace.
- **Candidates**: `query::column_suggestions(fragment)` — every `COLUMNS`
  entry that `subsequence()`-fuzzy-matches `fragment`, in `COLUMNS`' own
  order; an empty fragment (bare `$`) matches everything, which is what
  makes the full set visible on the very first keystroke. Works as a
  *complete, browsable* list because winswitch's field set is small and
  fully enumerable (4 entries today).
- Accepting inserts `$<column>:`, cursor landing right after the colon,
  ready to type a value — which is where field completion hands off to:

**Value completion** (`$field:fragment`, `:` already typed):

- **Trigger**: `query::trailing_value_fragment` — the trailing token starts
  `$col:`, and `col` resolves, via the same fuzzy rule field-name
  completion uses, to *exactly one* column. An ambiguous `col` (ties
  between two or more columns) has no single value set to offer, so this
  simply doesn't trigger then — same "narrow to nothing rather than guess"
  choice winswitch already makes for an ambiguous filter match (see
  `$field:value` above).
- **Candidates**: `query::value_suggestions(windows, column, fragment)` —
  every *distinct, non-empty* value that column actually has across the
  currently open windows right now, subsequence-fuzzy-narrowed by
  `fragment`, deduplicated and sorted for a stable order. This is what
  answers `$workspace:` with the workspaces that actually exist this
  instant, not a hardcoded guess — and works for any column the same way
  (`$class:` lists the open app classes, `$title:` the open titles), not
  just workspace. Unlike field-name completion's fixed 4-entry list, this
  one's size tracks how many distinct values are live, which is why it's
  scoped to winswitch's small corpus (a couple dozen open windows at most)
  rather than attempted anywhere with a larger one.
- Accepting inserts `$<column>:<value> ` — quoted (`"..."`) if the value
  itself contains whitespace, since splicing a multi-word title back in
  unquoted would immediately re-split it into two tokens, undoing the
  quote-aware tokenizing that made it matchable in the first place (see
  "Quoted phrases" above) — with a **trailing space**, unlike field
  completion's trailing colon: a value is always a complete term the
  instant it's chosen, so the query is left ready for the *next* AND term
  rather than mid-typing this one.

**Shared UI**, for both:

- A plain in-layout `GtkListBox` under the search entry (`ui.rs`),
  shown/hidden as either trigger condition comes and goes — not a
  `GtkPopover`, because gtk-layer-shell's layer surface has no xdg_popup
  positioner to anchor one to. Narrows on every keystroke the same
  `search-changed` signal already drives the grid filter from. Which of
  the two modes is live is tracked as `ui.rs`'s `SuggestionKind` enum
  (`Field` vs. `Value(column)`), since it decides what `Tab` inserts but
  the popup itself renders identically either way.
- `Tab` accepts the highlighted suggestion; `Ctrl+j`/`Ctrl+k` move the
  highlight down/up (clamped, not wrapped); `Escape` dismisses just the
  popup, without also closing the grid (the grid's own `Escape` is
  unconditional the rest of the time). These three keys' normal meaning
  elsewhere — Tab cycling the grid selection, Escape closing the grid — is
  unaffected once the popup is gone; the popup-specific handling in
  `ui.rs`'s key-press handler runs first and only while `state.suggestions`
  is non-empty.

The tmux pickers already have a *narrower* form of field-name completion:
`focus-picker.py`
tab-completes a trailing `+$`/`-$`/`$field:` fragment to its first fuzzy
match, shown as a `[tab → ...]` hint in the fzf header (see
`suggest_completion`/`header_line` in `focus-picker.py`). That's real
completion, but text-only and single-candidate — no visible list, no
up/down browsing among several matches. Whether to build winswitch's fuller
popup-with-navigation treatment for the tmux pickers too (fzf supports a
preview-window-driven candidate list, which could play the same role) is
open — winswitch was deliberately built and tested first, once, before
deciding whether to carry this further.

## Fuzzy resolution, precisely

Two different "fuzzy" algorithms are in play here, and it matters which one
a given implementation uses:

- **Substring-containment** (field/group *names* — window-search,
  claude-history, focus-picker; not winswitch, see below): `needle in
  haystack`, i.e. `needle` appears somewhere in the field name, not
  necessarily at the start. Cheap, and field name lists are short (4-8
  entries) and hand-picked, so ambiguity is rare and a union of matches is
  the safe default where it happens.
- **Prefix expansion** (bare-word and `$field:` *values*, window-search /
  claude-history only): every corpus vocabulary term starting with the
  typed text is a candidate, found by binary search over a sorted term list
  — this is what makes live-as-you-type search work at all (`"ric"` matching
  nothing until the whole word `"ricing"` is typed would be useless).
- **Subsequence match** (winswitch, `$field:value` *values and field names
  both*, plus quoted bare words — see "Quoted phrases" above): every
  character of the typed text must appear in the target string in order,
  not necessarily contiguous (`subsequence("crit", "alacritty")` is true).
  Chosen there because winswitch's corpus (open windows) is tiny — at most
  a couple dozen — so subsequence's looser, "type any letters roughly in
  order" feel costs nothing in precision at that scale, unlike a scored
  full-text corpus where it would produce noise. This is also what powers
  autocompletion's narrowing (`column_suggestions`, see below) — the same
  algorithm doing double duty for both filtering and suggestion-ranking.
- **Plain substring** (focus-picker's bare words and `$field:` values, and
  winswitch's *unquoted* bare words): `needle in haystack.lower()`, no
  fuzziness beyond case-insensitivity. Used wherever there's no scoring
  model to rank fuzzy matches by, so a looser match algorithm would just be
  noise with no way to sort the good hits above it.

## Design principles

These are the rules that were arrived at by trial and error (see each
script's own inline comments for the specific incident, where one exists)
and that any new implementation of this DSL should keep:

- **Never flash to zero results on a valid-so-far partial keystroke.** A
  token that's mid-typed — `$`, `$ti` (no colon yet), `+$`, `+$ssh.` (no sub
  yet), an unterminated `"phrase` — must be treated as inert (contributes no
  requirement) rather than literal-searched-for-as-typed. Literal-searching
  a half-typed DSL fragment is what makes a live-filtering list blank out
  for the one keystroke before the user finishes typing the field name; see
  `focus-picker.py`'s `parse_query()` docstring for the exact bug this
  guards against, and contrast with the *next* rule.
- **...but a genuinely unresolvable, *complete* token still degrades to a
  literal search**, not a dropped/erroring one — `$zzz:foo` (window-search /
  claude-history / focus-picker) becomes a literal search for the text
  `"zzz:foo"`, because at that point it's not mid-typing anymore, it's
  plausible real search text with a misspelled or unknown prefix in front of
  it. winswitch is the one exception (see its `$field:value` note above) —
  its small, unranked corpus makes "matches nothing" the more honest answer
  than a fallback literal search would be.
- **Column-visibility directives never filter.** `+$`/`-$` change what's
  *shown*, never what *matches* — keeping "which rows survive" and "what
  columns those rows show" as two orthogonal concerns is what let `-$` get
  added on top of an existing `+$` without touching a single filtering code
  path (see `focus-picker.py` git history).
- **Quoting is the universal escape hatch**, tried before every other
  grammar form at each position, so any reserved-character text a user
  actually wants to search for verbatim (`"+$"`, `"$title:"`, `"!foo"`) is
  always reachable, never permanently shadowed by the DSL.
- **Field/group name resolution is never plain prefix matching.** Every
  implementation resolves a field name more loosely than "starts with" —
  substring-containment in three of the four, subsequence in winswitch (see
  "Fuzzy resolution, precisely" above) — specifically so an abbreviation
  doesn't have to start at the beginning of the real name: `$ti:` reaching
  `title` is the common case, but `$ssion:` reaching `session` (substring)
  or `$tsk:` reaching `workspace` (subsequence) is exactly as valid, and no
  implementation special-cases "assume they meant the front."
- **AND, not OR, across distinct tokens.** Every requirement a query
  expresses (bare words, phrases, `$field:` terms) must all be satisfied by
  a surviving result — this is what makes a query readable left to right as
  "narrow, then narrow further," matching how every other filter-box tool
  (recoll, Xapian-backed search, `fzf` itself in extended mode) already
  behaves, so nothing here has to be relearned per picker.
