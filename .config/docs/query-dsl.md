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
is itself **fuzzy**: resolved by substring-containment against the
implementation's known field list, not by prefix — `$ti:foo` reaches
`title` because `"ti" in "title"`, and if two field names both contain the
typed substring, both are searched (unioned). This is deliberately looser
than prefix matching so an abbreviation from any position in the name still
resolves, e.g. `$ssion:` also reaching `session`.

- **window-search / claude-history**: `value` is itself BM25-scored against
  that one field's own per-document vocabulary (prefix-expanded the same way
  a bare word is — see below). An unresolvable field degrades to a literal
  bare-word search over the whole `"$field:value"` text, since a typo'd
  field prefix in front of real search text is still a real search someone
  typed.
- **focus-picker**: `value` is a plain case-insensitive substring test
  against that field's literal text (no scoring — this picker doesn't rank).
  Same unresolvable-field fallback to literal text.
- **winswitch**: `value` is a **subsequence** match (see below), and the
  fuzzy field resolution takes only the *first* matching column rather than
  unioning every match — `query.rs` has no scoring model to merge multiple
  fields under, so it doesn't try. An unresolvable field is unmatchable
  (contributes nothing that can match), rather than a literal fallback —
  winswitch's grid is small and un-ranked, so a stray filter here reads as
  "narrow to nothing" rather than "silently degrade to a weaker search."

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

Exact text, whitespace-normalized, never fuzzy/prefix-expanded — the
opposite end of the spectrum from a bare word. Doubles as the **literal
escape hatch** for every other prefix character this grammar reserves
(`$`, `+$`, `-$`, `!`): quoting is checked first at each position, so
`"+$"` always means the two literal characters, never the column-add
directive. Only window-search/claude-history give quoted text a further
"soft literal" treatment (a punctuation-preserving bonus, see below);
focus-picker and winswitch just take it as a literal substring/AND term.

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
  unranked.

## Fuzzy resolution, precisely

Two different "fuzzy" algorithms are in play here, and it matters which one
a given implementation uses:

- **Substring-containment** (field/group *names* only, every
  implementation): `needle in haystack`, i.e. `needle` appears somewhere in
  the field name, not necessarily at the start. Cheap, and field name lists
  are short (4-8 entries) and hand-picked, so ambiguity is rare and a union
  of matches is the safe default where it happens.
- **Prefix expansion** (bare-word and `$field:` *values*, window-search /
  claude-history only): every corpus vocabulary term starting with the
  typed text is a candidate, found by binary search over a sorted term list
  — this is what makes live-as-you-type search work at all (`"ric"` matching
  nothing until the whole word `"ricing"` is typed would be useless).
- **Subsequence match** (winswitch's `$field:value` *values only* — its
  column-name resolution stays substring-containment): every character of
  the typed text must appear in the target string in order, not necessarily
  contiguous (`subsequence("crit", "alacritty")` is true). Chosen there
  because winswitch's corpus (open windows) is tiny — at most a couple dozen
  — so subsequence's looser, "type any letters roughly in order" feel costs
  nothing in precision at that scale, unlike a scored full-text corpus where
  it would produce noise.
- **Plain substring** (focus-picker's bare words and `$field:` values, and
  winswitch's bare words): `needle in haystack.lower()`, no fuzziness beyond
  case-insensitivity. Used wherever there's no scoring model to rank fuzzy
  matches by, so a looser match algorithm would just be noise with no way
  to sort the good hits above it.

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
- **Field/group name resolution is substring-containment, not prefix.**
  Chosen over prefix matching specifically so an abbreviation doesn't have
  to start at the beginning of the real name — `$ti:` reaching `title` is
  the common case, but `$ssion:` reaching `session` is exactly as valid, and
  no implementation special-cases "assume they meant the front."
- **AND, not OR, across distinct tokens.** Every requirement a query
  expresses (bare words, phrases, `$field:` terms) must all be satisfied by
  a surviving result — this is what makes a query readable left to right as
  "narrow, then narrow further," matching how every other filter-box tool
  (recoll, Xapian-backed search, `fzf` itself in extended mode) already
  behaves, so nothing here has to be relearned per picker.
