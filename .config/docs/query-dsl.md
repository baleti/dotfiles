# Picker query DSL

The small query language typed into the search box of every fzf-driven
picker in this repo, plus winswitch's grid search and the GTK
clipboard/notification pickers. It was arrived at independently in
`window-search.py`, then reused (by hand, not by import) in
`claude-history` and `focus-picker.py`, then reimplemented in Rust for
winswitch's `query.rs`, then ported by hand a second time into the shared
`picker.rs` engine behind clipboard-picker and notification-picker. It
stays copy-pasted rather than a shared library on purpose: the
implementations split across two languages, and even the four Python/Rust
ones, while structurally similar, differ enough in what they're searching
(scored full-text vs. flat substring, tabular vs. grid vs. list) that a
shared abstraction was judged not worth it — this doc exists so the
*semantics* stay consistent even though the code doesn't.

Implementations, so this doc has a name for each:

| Name | File | Searches |
|---|---|---|
| window-search | `~/.config/tmux/scripts/window-search.py` | live tmux pane scrollback, BM25-ranked |
| claude-history | `~/bin/claude-history` | saved Claude Code conversation transcripts, BM25-ranked |
| focus-picker | `~/.config/tmux/scripts/focus-picker.py` | tmux panes, MRU-ordered (no ranking) |
| winswitch | `~/.config/hypr/winswitch/src/query.rs` | open windows (Hyprland), grid layout |
| clipboard-picker | `~/.config/hypr/clipboard-picker/src/picker.rs` | cliphist clipboard history, list layout |
| notification-picker | same `picker.rs`, `src/bin/notification-picker.rs` | notifyd's retained notification history |

clipboard-picker and notification-picker share one engine (`picker.rs`) and
so share one DSL implementation between them — the table lists them
separately because they configure different `field_names` (clipboard:
`type`, `date`; notifications: `app`, `date`), not because the grammar
differs. See [tmux.md](tmux.md) for the tmux bindings and
[rust-tools.md](rust-tools.md) for winswitch and the GTK pickers.

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
`"ti" in "title"`), winswitch and the GTK pickers use subsequence
(`$tsk:foo` would reach `workspace` — "t","s","k" appear in that order
inside "workspace" — a match substring-containment alone would miss). Every
implementation unions every field that resolves rather than picking just
one, so an ambiguous prefix searches every field it could mean, not an
arbitrarily-chosen first match.

- **window-search / claude-history**: `value` is itself BM25-scored against
  that one field's own per-document vocabulary (prefix-expanded the same way
  a bare word is — see below). An unresolvable field degrades to a literal
  bare-word search over the whole `"$field:value"` text, since a typo'd
  field prefix in front of real search text is still a real search someone
  typed.
- **focus-picker**: `value` is a plain case-insensitive substring test
  against that field's literal text (no scoring — this picker doesn't rank).
  Same unresolvable-field fallback to literal text.
- **winswitch / clipboard-picker / notification-picker**: both `field` *and*
  `value` are subsequence matches (see below) — the one family where field
  resolution isn't substring-containment either, since these engines
  already had subsequence wired up for values and reused it for names
  rather than adding a second algorithm. An unresolvable field is
  unmatchable (contributes nothing that can match), rather than a literal
  fallback — these are all small, un-ranked corpora (a screen's worth of
  windows, a few hundred clipboard/notification entries at most), so a
  stray filter here reads as "narrow to nothing" rather than "silently
  degrade to a weaker search." clipboard-picker/notification-picker's
  `Entry::fields` additionally makes a field's *absence* on one entry
  distinct from an empty value — an entry with no `date` field at all (no
  logged timestamp for it yet) never matches any `$date:` query, whereas an
  entry that does have the field always matches `$date:` with nothing after
  the colon (an empty needle is a no-op for subsequence).

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

Every other implementation has no `+$`/`-$` at all: window-search and
claude-history's fields are always either scored-in or not part of the
document, with nothing "hideable"; winswitch's grid and the GTK pickers'
list rows have no column layout to toggle in the first place (see
winswitch's own `$field:value` note above — the same reasoning applies to
clipboard-picker/notification-picker's single-line rows). Any future
picker that gains optional, expensive-if-always-shown per-row data should
reach for this same `+$`/`-$` pair rather than inventing a new shape.

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
- **winswitch / clipboard-picker / notification-picker**: quoting means
  something different here on purpose — not "exact," but "let this span
  whitespace." Their tokenizers otherwise split on every whitespace run the
  way all implementations do, which normally makes a multi-word field name
  or value impossible to type as one unit (`$title:imperial rome` would
  become two separate tokens, `$title:imperial` and a stray `rome`).
  Quoting — `$title:"imperial rome"`, or `$app:"discord canary"` for
  notification-picker's app-name field — keeps the run as one token without
  splitting it, and it's still matched by the *same* subsequence()
  fuzzy-match every unquoted `$field:value` already uses, not a literal
  comparison. Concretely: `$title:"imp rom"` matches a window titled
  "Imperial Rome" the identical way `$title:imp` already fuzzy-matches
  "Imperial", because subsequence() already treats a literal space in the
  needle as just another character to find in order — matching "imp",
  then the space between the two haystack words, then "rom" — so no new
  matching algorithm was needed, only a tokenizer that stops splitting the
  run apart before subsequence() ever sees it. See each engine's
  `tokenize_with_spans`/matching code — the whitespace *inside* a token,
  after tokenizing, is itself the signal that it came from a quoted run,
  since unquoted whitespace can never survive into a token at all.

  This upgrade applies to bare (non-`$`) quoted text too in **winswitch**:
  `"imp rom"` alone, quoted, subsequence-matches title+class; unquoted
  `imp rom` still ANDs two independent substring tests the older way,
  order not enforced — both work, but mean slightly different things. It
  does **not** apply the same way in **clipboard-picker/notification-picker**,
  because their bare words were never independent tokens to begin with —
  multiple free words there always get joined into one space-separated
  phrase and matched as a single literal run against `Entry::haystack`
  (the original clipboard-picker behaviour, predating this DSL work and
  left exactly as it was — see `picker.rs`'s module doc). Quoting a free
  word there still works as the reserved-character escape hatch (searching
  clipboard history for a literal `"$50"`, say), but doesn't change *how*
  free text matches the way it does for `$field:value` or for winswitch's
  independent bare words.

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
- **clipboard-picker / notification-picker**: every bare word is joined
  into one space-separated phrase (not independent tokens — see the
  "Quoted phrases" section above) and matched as one literal substring
  against `Entry::haystack` (clipboard preview text; app name + summary +
  body for notifications), required, unranked. This is the strictest of
  the bunch: `hello world` requires that exact contiguous run, not "hello"
  and "world" each present somewhere — predates this DSL work and wasn't
  changed by it (see `picker.rs`'s module doc for why touching it wasn't
  in scope here).

## Autocompletion

Typing `$` alone should be enough to discover what fields exist — an empty
field name is otherwise indistinguishable from "not typed yet," so without
some form of visible completion, a picker's field set (winswitch's
`title`/`class`/`workspace`/`pid`; clipboard-picker's `type`/`date`;
notification-picker's `app`/`date`) has to be memorized or re-derived from
source. The same problem repeats one level down: once past `$workspace:`,
what *values* actually exist right now (`1`? `2`? a named workspace?) is
just as undiscoverable without looking. All three GTK pickers — winswitch
first, then clipboard-picker/notification-picker ported by hand from it —
grow a real completion popup covering both, GTK-native rather than
fzf-driven the way the tmux pickers' tab-completion already is (see below).

**Field-name completion** (`$fragment`, no `:` yet):

- **Trigger**: the query's trailing token, considered on the same
  "editing happens at the end of what's typed" assumption
  `focus-picker.py`'s `suggest_completion` already uses, starts with `$`
  and has no `:` yet — `trailing_field_fragment` (winswitch's `query.rs`;
  `picker.rs` for the GTK pickers) detects this off the same quote-aware
  tokenizer the matching logic uses (so `$"col na` — an in-progress quoted
  field name — triggers it too), returning the fragment text after `$` and
  the byte offset a chosen completion should replace.
- **Candidates**: `column_suggestions`/`field_suggestions` — every
  configured field name (winswitch's fixed `COLUMNS`; a picker's own
  `PickerConfig::field_names` for the GTK pickers) that
  `subsequence()`-fuzzy-matches `fragment`, in that list's own order; an
  empty fragment (bare `$`) matches everything, which is what makes the
  full set visible on the very first keystroke. Works as a *complete,
  browsable* list only because each picker's field set is small and fully
  enumerable (4 entries for winswitch, 2 each for the GTK pickers today).
- Accepting inserts `$<field>:`, cursor landing right after the colon,
  ready to type a value — which is where field completion hands off to:

**Value completion** (`$field:fragment`, `:` already typed):

- **Trigger**: `trailing_value_fragment` — the trailing token starts
  `$field:`, and `field` resolves, via the same fuzzy rule field-name
  completion uses, to *exactly one* field. An ambiguous typed name (ties
  between two or more fields) has no single value set to offer, so this
  simply doesn't trigger then — same "narrow to nothing rather than guess"
  choice these engines already make for an ambiguous filter match (see
  `$field:value` above).
- **Candidates**: `value_suggestions(entries, field, fragment)` — every
  *distinct, non-empty* value that field actually has across the current
  entries right now (open windows; clipboard/notification history),
  subsequence-fuzzy-narrowed by `fragment`, deduplicated and sorted for a
  stable order. This is what answers `$workspace:` with the workspaces
  that actually exist this instant, or `$type:` with `image`/`text` only
  if both are actually present, rather than a hardcoded guess — and works
  for any field the same way, not just the one it was first tried on.
  Unlike field-name completion's fixed short list, this one's size tracks
  how many distinct values are live, which is why it's scoped to these
  pickers' small corpora (a couple dozen open windows; a few hundred
  clipboard/notification entries at most, and typically far fewer
  *distinct* values among them) rather than attempted anywhere with a
  larger one.
- Accepting inserts `$<field>:<value> ` — quoted (`"..."`) if the value
  itself contains whitespace (e.g. notification-picker's `$app:"Discord
  Canary"`), since splicing a multi-word value back in unquoted would
  immediately re-split it into two tokens, undoing the quote-aware
  tokenizing that made it matchable in the first place (see "Quoted
  phrases" above) — with a **trailing space**, unlike field completion's
  trailing colon: a value is always a complete term the instant it's
  chosen, so the query is left ready for the *next* AND term rather than
  mid-typing this one.

**Shared UI**, for both, in all three GTK pickers:

- A plain in-layout `GtkListBox` under the search entry, shown/hidden as
  either trigger condition comes and goes — not a `GtkPopover`, because
  gtk-layer-shell's layer surface has no xdg_popup positioner to anchor
  one to. Narrows on every keystroke the same signal that already drives
  the underlying list/grid filter. Which of the two modes is live is
  tracked as a `SuggestionKind` enum (`Field` vs. `Value(field)`), since it
  decides what `Tab` inserts but the popup itself renders identically
  either way.
- `Tab` accepts the highlighted suggestion; `Ctrl+j`/`Ctrl+k` move the
  highlight down/up (clamped, not wrapped); `Escape` dismisses just the
  popup, without closing the picker itself (the picker's own `Escape` is
  unconditional the rest of the time). These three keys' normal meaning
  elsewhere — Tab cycling/toggling focus, Escape closing the picker — is
  unaffected once the popup is gone; the popup-specific handling in the
  key-press handler runs first and only while suggestions are non-empty.
- One real bug worth knowing if this popup ever silently stops appearing
  again: a `GtkListBox` built with `no-show-all` (set so the picker's own
  one-time `show_all()` at startup doesn't prematurely reveal an empty
  popup) will *also* ignore a later `show_all()` call meant to reveal it —
  the flag guards the widget it's set on, not just descendants reached
  through an ancestor's recursive call. Every row/label has to be shown
  explicitly, and the list itself revealed with a direct `.show()`, not
  `.show_all()`. Hit and fixed once in winswitch's `ui.rs`, carried
  correctly into `picker.rs` from the start the second time around.

The tmux pickers still only have a *narrower* form of field-name
completion: `focus-picker.py` tab-completes a trailing `+$`/`-$`/`$field:`
fragment to its first fuzzy match, shown as a `[tab → ...]` hint in the
fzf header (see `suggest_completion`/`header_line` in `focus-picker.py`).
That's real completion, but text-only and single-candidate — no visible
list, no up/down browsing among several matches. Whether to build the
fuller popup-with-navigation treatment for the tmux pickers too (fzf
supports a preview-window-driven candidate list, which could play the same
role) is still open — three GTK implementations now agree on the design,
which is a stronger case for eventually doing it than winswitch alone was,
but it hasn't been done.

## Fuzzy resolution, precisely

Two different "fuzzy" algorithms are in play here, and it matters which one
a given implementation uses:

- **Substring-containment** (field/group *names* — window-search,
  claude-history, focus-picker; not winswitch or the GTK pickers, see
  below): `needle in haystack`, i.e. `needle` appears somewhere in the
  field name, not necessarily at the start. Cheap, and field name lists are
  short (2-8 entries) and hand-picked, so ambiguity is rare and a union of
  matches is the safe default where it happens.
- **Prefix expansion** (bare-word and `$field:` *values*, window-search /
  claude-history only): every corpus vocabulary term starting with the
  typed text is a candidate, found by binary search over a sorted term list
  — this is what makes live-as-you-type search work at all (`"ric"` matching
  nothing until the whole word `"ricing"` is typed would be useless).
- **Subsequence match** (winswitch and the GTK pickers, `$field:value`
  *values and field names both*, plus winswitch's quoted bare words — see
  "Quoted phrases" above): every character of the typed text must appear in
  the target string in order, not necessarily contiguous
  (`subsequence("crit", "alacritty")` is true). Chosen there because these
  corpora are all tiny (a couple dozen open windows; a few hundred
  clipboard/notification entries) — so subsequence's looser, "type any
  letters roughly in order" feel costs nothing in precision at that scale,
  unlike a scored full-text corpus where it would produce noise. This is
  also what powers autocompletion's narrowing (`column_suggestions`/
  `field_suggestions`, see below) — the same algorithm doing double duty
  for both filtering and suggestion-ranking.
- **Plain substring** (focus-picker's bare words and `$field:` values,
  winswitch's *unquoted* bare words, and clipboard-picker/
  notification-picker's bare words, quoted or not — see "Quoted phrases"):
  `needle in haystack.lower()`, no fuzziness beyond case-insensitivity.
  Used wherever there's no scoring model to rank fuzzy matches by, so a
  looser match algorithm would just be noise with no way to sort the good
  hits above it.

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
  it. winswitch and the GTK pickers are the exception (see the
  `$field:value` note above) — their small, unranked corpora make "matches
  nothing" the more honest answer than a fallback literal search would be.
- **Every picker keeps one plain-typing default with no special syntax at
  all.** Whatever `$field:value` a picker grows, typing without any `$`
  must always still search *something* sensible by default — clipboard
  contents for clipboard-picker, window title+class for winswitch, pane
  scrollback for window-search.py, notification summary/body/app for
  notification-picker (`Entry::haystack` in the GTK pickers; the bare-word
  path in every other implementation). This is what makes the DSL
  additive rather than a wall a casual user has to learn before the picker
  is useful at all: `$field:value` narrows or targets, but nothing here is
  ever *required* to get a plausible result.
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
  substring-containment in three, subsequence in winswitch and the GTK
  pickers (see "Fuzzy resolution, precisely" above) — specifically so an
  abbreviation doesn't have to start at the beginning of the real name:
  `$ti:` reaching `title` is the common case, but `$ssion:` reaching
  `session` (substring) or `$tsk:` reaching `workspace` (subsequence) is
  exactly as valid, and no implementation special-cases "assume they meant
  the front."
- **AND, not OR, across distinct tokens.** Every requirement a query
  expresses (bare words, phrases, `$field:` terms) must all be satisfied by
  a surviving result — this is what makes a query readable left to right as
  "narrow, then narrow further," matching how every other filter-box tool
  (recoll, Xapian-backed search, `fzf` itself in extended mode) already
  behaves, so nothing here has to be relearned per picker.
- **Selection follows the user, not the query — where there's no reason
  for it to follow something else.** Auto-selecting the top result on open
  or on every filtering keystroke reads as a highlight jumping around
  unpredictably while typing, easy to mistake for something about to
  happen on its own. clipboard-picker and notification-picker open with
  nothing selected; the first explicit navigation (an arrow key, Tab into
  the list, a mouse click) is what selects anything, and lands on the top
  visible entry rather than skipping past it. `Enter` still falls back to
  activating the top visible entry with nothing explicitly selected — no
  visual pre-highlight, but a plain type-then-Enter flow still works, the
  same "spotlight search" convention most such boxes already use. A
  selection that a subsequent keystroke filters out of view is explicitly
  cleared rather than left dangling and invisibly active. winswitch's grid
  is the deliberate exception: it still auto-selects on open, because
  landing on the *previously active window* the instant a single Alt+Tab
  tap completes is the entire point of classic alt-tab behaviour, not a
  leftover default to clean up — see winswitch's own `run()` and its
  `initial_cmd`/`start_idx` handling.
