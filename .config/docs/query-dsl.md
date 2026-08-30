# Picker query DSL

The small query language typed into the search box of every fzf-driven
picker in this repo, plus winswitch's grid search and the GTK
clipboard/notification pickers. Arrived at independently in
`window-search.py`, then reused (by hand, not by import) in
`claude-history` and `focus-picker.py`, then reimplemented in Rust for
winswitch's `query.rs`, then ported by hand a second time into the shared
`picker.rs` engine behind clipboard-picker and notification-picker. Stays
copy-pasted rather than a shared library on purpose - the implementations
split across two languages and differ enough in what they're searching
(ranked scrollback vs. an unranked couple-dozen windows) that a shared
abstraction was judged not worth it - so this doc is what keeps the
*semantics* consistent even though the code doesn't.

| Name | File | Searches |
|---|---|---|
| window-search | `~/.config/tmux/scripts/window-search.py` | live tmux pane scrollback, BM25-ranked |
| claude-history | `~/bin/claude-history` | saved Claude Code conversation transcripts, BM25-ranked |
| focus-picker | `~/.config/tmux/scripts/focus-picker.py` | tmux panes, MRU-ordered (no ranking) |
| winswitch | `~/.config/hypr/winswitch/src/query.rs` | open windows (Hyprland), grid layout - plus tmux/Claude Code metadata cross-referenced onto them |
| clipboard-picker | `~/.config/hypr/clipboard-picker/src/picker.rs` | cliphist clipboard history, list layout |
| notification-picker | same `picker.rs`, `src/bin/notification-picker.rs` | notifyd's retained notification history |

See [tmux.md](tmux.md) for the tmux bindings and [rust-tools.md](rust-tools.md)
for winswitch and the GTK pickers.

## The shape of it

Every picker shows a **result set** (windows, panes, clipboard entries,
scrollback-bearing windows, ...) with, potentially, several named
**types** per entry - a "type" here is any one field that can be filtered
on or shown as a column: a flat one (`title`, `class`, `workspace`,
`pid`; `type`, `date`, `app`) or a subfield of a **group** (winswitch's
`tmux.session`, `claude.title`, ...). The DSL does three orthogonal
things to that set, and nothing else:

- **filter rows** - which entries survive (`/filter-value`, and bare
  typed text, which is the same thing)
- **filter columns** - which types are shown (`/filter-type`,
  `/add-type`, `/remove-type`)
- **order** - what sequence the survivors appear in (`/sort`,
  `/reverse`)

This is the `SELECT ... WHERE ... ORDER BY` triad, in the interactive
piped-verb dialect that Kusto/KQL (`where` / `project` / `project-away` /
`sort by`), Splunk SPL (`where` / `fields` / `fields -` / `sort`) and
PowerShell (`Where-Object` / `Select-Object` / `Sort-Object`) all landed
on before this. Each `/verb` token is one pipeline stage; there is no
explicit pipe character, whitespace between tokens is the pipe.

## Grammar

The search box text is split on whitespace into tokens (a `"..."`-quoted
run stays one token, interior whitespace intact - see Quoting). Each
token is either:

```
/verb arg...       a command - verb is exact-matched against the table below
"phrase"           quoted literal - never a command, always row-filter text
bareword           anything else - an implicit /filter-value argument
```

A command's arguments are the whitespace-separated tokens that follow it,
up to the next `/verb` (or end of input). `/sort date descending` is one
command with two args; `/filter-value foo /sort date` is two commands.

### Verbs

| Short | Long | Axis | Effect |
|---|---|---|---|
| `/fv` | `/filter-value` | rows | keep rows whose value matches the argument; drop the rest |
| `/ft` | `/filter-type` | columns | keep only the columns whose *name* matches; hide the rest |
| `/at` | `/add-type` | columns | add the columns whose name matches into view |
| `/rt` | `/remove-type` | columns | drop the columns whose name matches from view |
| `/s` | `/sort` | order | order rows by one type, optional direction |
| `/rv` | `/reverse` | order | reverse whatever order is currently in effect |

**Verb names are exact-matched**, against exactly the six short forms and
six long forms above - nothing else, no substring or fuzzy resolution on
the verb itself. That is the entire reason the grammar moved to verbs:
the old `/claude.title:value` form made a type name (`claude`) sit in the
same position a command would, so every new command risked colliding with
some picker's field list. A closed, exact-matched verb vocabulary up
front removes that class of ambiguity permanently. An unrecognised
`/xyz` token is inert (contributes nothing) rather than an error or a
literal search - same "half-typed stays a no-op" rule the rest of the
grammar follows.

Both the short and long form of a verb are always accepted and mean
exactly the same thing; the short forms are what the autocomplete offers
first, since the box is typed into far more than it is read.

### Type paths

Every verb except `/reverse` takes a **type path**: dot-separated
segments naming a flat type or a group subfield.

```
title              a flat type
claude             a group (resolves to its default subfield, /title, for
                   filtering and sorting; to all its subfields for column verbs)
claude.title       one explicit group subfield
claude.*           every subfield of the group
```

Each segment is **substring-matched**, case-insensitively, against the
known names at its level, and **every match is unioned** - `/ft dsl`
reaches every type whose name contains `dsl`; `/fv cla.ti:x` reaches
`claude.title` (and anything else whose first segment contains `cla` and
second contains `ti`). An ambiguous segment acts on every type it could
mean. `*` is one hand-parsed reserved segment meaning "all subfields",
**not** a regex - nothing in this DSL uses a real regex engine (see
Design principles).

A path segment that resolves to nothing makes its command inert (for a
filter: "narrows to nothing", an honest empty result; for a column verb:
a silent no-op).

### `/filter-value` (`/fv`) - and bare text

Filters which rows survive. Three forms:

- **`/fv text`** (or just `text` typed bare, no verb) - substring-match
  `text`, case-insensitively, against the picker's always-present
  free-text haystack (window title+class; clipboard preview; pane
  scrollback; notification app+summary+body). This is the one form every
  picker guarantees and the one a casual user needs no syntax for.
  `/fv val` and a bare `val` are identical.
- **`/fv path:value`** - scope: keep rows where a type matching `path`
  has a value containing `value` (substring, case-insensitive).
- **`/fv path`** (no colon), where `path` resolves to a **group** - an
  *existence* filter: keep rows that have any non-empty value anywhere in
  that group. `/fv claude` narrows to claude-hosting windows before a
  value is ever typed. A colonless path that resolves only to flat types,
  or to nothing, is treated as free text instead (there is no useful
  "does this row have a title" filter).

Multiple `/fv` terms (and multiple bare words) are **AND-ed**, order
independent: every one must match a surviving row. Bare words are each
their own term (`foo bar` requires both, independently) except in
clipboard-picker / notification-picker, whose bare words join into one
space-separated phrase matched as a single contiguous run - that predates
this DSL and is left as-is (see `picker.rs`).

BM25-ranked pickers (window-search, claude-history) keep their own extra
row-filter spelling on top of this - prefix-expanded bare words, `!token`
negation, `"phrase"` as *required exact* text - because ranking a large
scrollback corpus needs them and an unranked couple-dozen-window grid
does not. Those are documented in each script's own header; everything in
*this* doc applies to them unchanged otherwise.

### `/filter-type` (`/ft`), `/add-type` (`/at`), `/remove-type` (`/rt`)

Change which columns are shown. **Never filter rows** - orthogonal by
construction. All three take a type path and are processed **left to
right** against one running ordered set that starts at the picker's
default columns:

- **`/ft path`** - intersect: keep only the currently-shown columns whose
  name matches `path`, drop the others. "Filter down to these."
- **`/at path`** - union: add every matching column that isn't already
  shown, at the end.
- **`/rt path`** - subtract: remove every matching column.

Order is significant: `/ft claude /at workspace` shows the claude
subfields plus `workspace`; `/at workspace /ft claude` shows only claude
subfields (the `/ft` drops the `workspace` the `/at` just added). Adding
a column that is already shown, or removing/filtering one that is not, is
a silent no-op.

Defaults per picker:

- **winswitch**: `workspace` and `title` (today's `#N Title` grid label).
  `class`, `pid`, and every `tmux`/`claude` subfield are hidden until an
  `/at` (or a surviving `/ft`) brings them in.
- **clipboard-picker / notification-picker**: nothing beyond the entry's
  own preview text or thumbnail. `type`/`date`/`app` appear only once
  added.
- **fzf pickers**: focus-picker renders columns and honours all three
  verbs; window-search / claude-history render a single ranked line and
  ignore column verbs (inert, not an error).

`claude` (bare group) as a column-verb path means *all* of the group's
subfields, each its own column - unlike its filter/sort meaning
(default subfield only). `/at claude.*` is the same as `/at claude`;
`/at claude.title` is just the one.

### `/sort` (`/s`), `/reverse` (`/rv`)

Reorder the survivors; never filter or hide.

- **`/sort path [direction]`** - order rows by the single type `path`
  resolves to (it must resolve to exactly one - `claude.*` is not valid
  here, a sort key is one field). `direction` substring-matches
  `ascending` / `descending` (so `asc` / `desc` / `de` all work),
  defaulting to `ascending`. Only the **last** `/sort` in a query takes
  effect (replace, not stack). Absent entirely, the picker's own default
  order stands (MRU, cliphist recency, winswitch focus-history, BM25
  score). Honoured by winswitch and focus-picker; inert in
  clipboard-picker / notification-picker (no re-sort machinery) and the
  BM25 pickers (score *is* the order).
- **`/reverse`** - flips whatever order is in effect (default, or a
  `/sort`). No arguments. Idempotent: any number of `/reverse` tokens ==
  one, not a toggle. Useful alone to flip a picker's default order (see
  the least-recently-used window first) without naming a field.

**Sort comparison, precisely.** Every type is stored and matched as a
string, but plain lexicographic comparison is wrong for two shapes the
pickers already have. The comparator (`compare_field_values`) sniffs both
values being compared:

- **Plain integers** (`workspace`, `pid`): `"10"` must sort after `"2"`,
  not before. Both sides parse as non-negative ints -> numeric compare.
- **Age buckets** (`date`, from `humanize_ago` - `"30s"`, `"5m"`, `"3h"`,
  `"2d"`): comparing the strings is nonsense across units. Both sides
  match `^\d+[smhd]$` -> convert to seconds and compare that.
- Otherwise -> lexicographic (correct already for `title` / `class` /
  `app` / `type`).

**The direction trap.** `date`'s stored value is an *age* (seconds ago) -
smaller means more recent. `/sort date descending` means "newest first"
in the ordinary calendar sense, which is *ascending by age in seconds*.
So for age-shaped values the requested direction is inverted before it
reaches the numeric comparison: `ascending` (oldest first,
chronological) compares age descending internally; `descending` (newest
first) compares age ascending. Plain ints and text apply the direction
literally. The trap is specific to "time since" values.

### Quoting

`"..."` is checked first at every token position, so it is the universal
escape hatch: a token that starts with `"` is **never** parsed as a
command, and a literal `/` (or any other reserved character) inside
quotes is just text. Beyond escaping, quoting lets a value or path
segment span whitespace without splitting into separate tokens:
`/fv title:"imperial rome"`, `/fv app:"discord canary"`.

A quoted value is matched as a **literal contiguous substring**,
whitespace included - `/fv title:"imp rom"` matches only a title that
actually contains the run `imp rom`, not "Imperial Rome". (This is a
change from the older behaviour, where quoting meant subsequence-across-
whitespace. Substring is now the single matching rule everywhere;
"imperial rome" is what you type to match "Imperial Rome".) The BM25
pickers keep their own quoting meaning (required exact phrase) as noted
above.

## Autocompletion

Typing `/` alone is enough to discover the whole grammar. All the GTK
pickers (winswitch, clipboard-picker, notification-picker) grow a
GTK-native completion popup - a plain in-layout `GtkListBox` under the
search entry, not a `GtkPopover` (gtk-layer-shell's layer surface has no
xdg_popup positioner to anchor one to). Stages:

1. **Verb** (`/frag`, nothing after it yet): candidates are every short
   verb form whose name contains `frag` as a substring (`/f` -> `/fv`,
   `/ft`; `/` alone -> all six). Accepting a verb inserts it plus a
   trailing space and re-triggers completion at the argument stage.
2. **Type path** (`/ft frag`, `/at frag`, `/rt frag`, `/s frag`, or
   `/fv frag` before any `:`): candidates are flat type names and group
   names containing `frag`; after a `.`, that group's subfields plus `*`.
   Accepting a column-verb path or a group completes the token; accepting
   a `/fv` path inserts a trailing `:` ready for a value.
3. **Filter value** (`/fv path:frag`, `path` unambiguous): candidates are
   every distinct non-empty value that type actually has across the
   current entries right now, substring-narrowed by `frag`, deduplicated
   and sorted. This is the one stage genuinely scoped to a small corpus.
4. **Sort direction** (`/s path frag`, `path` unambiguous): candidates
   are `ascending` / `descending`, narrowed by `frag`.

Shared popup UI: `Tab` accepts the highlighted suggestion; `Ctrl+j` /
`Ctrl+k` move the highlight (clamped, not wrapped); `Escape` dismisses
just the popup, never the picker. One bug worth remembering if the popup
ever silently stops appearing: a `GtkListBox` built with `no-show-all`
(so the picker's one-time startup `show_all()` doesn't reveal an empty
popup) also ignores a *later* `show_all()` meant to reveal it - every
row/label has to be shown explicitly and the list revealed with a direct
`.show()`.

## Resolution, precisely

- **Verb**: exact match against the 12 fixed forms (6 short, 6 long).
  Nothing else.
- **Type path segments, filter values, sort directions**: substring
  containment, case-insensitive (`"dsl" in name`, `"rome" in value`).
  Every match is unioned for a path segment; a value/direction just needs
  the one containment to hold.
- **BM25 pickers' bare words**: prefix-expansion against the corpus
  vocabulary, BM25-scored - their own thing, on top of the above.

No subsequence matching anywhere anymore (it was the old winswitch/GTK
rule - `"crit"` matching `"alacritty"`). Substring is stricter and more
predictable, and at these corpus sizes the looseness bought nothing.

## Design principles

- **Never flash to zero results on a valid-so-far partial keystroke.** A
  token still being typed (`/`, `/f`, `/ft `, `/ft cla`, `/s date `, an
  unterminated `"phrase`) is inert - contributes no requirement - rather
  than searched for literally as typed.
- **Every picker keeps one plain-typing default with no syntax at all.**
  Bare text is always `/filter-value` over the free-text haystack. The
  DSL is additive, never a wall a casual user has to learn first.
- **Verbs are a closed, exact-matched vocabulary.** This is the point of
  the redesign - a command can never be confused for a type name.
- **No real regex anywhere.** Every match is substring containment (or,
  in the BM25 pickers, prefix-expansion). `*` is one hand-parsed reserved
  segment, not a wildcard engine.
- **The three axes are orthogonal.** Row filters (`/fv`, bare text) never
  change columns; column verbs (`/ft`, `/at`, `/rt`) never change which
  rows survive; order verbs (`/sort`, `/reverse`) never change either.
- **Column verbs are a left-to-right pipeline;** row filters are an
  order-independent AND; `/sort` is last-wins; `/reverse` is idempotent.
- **Quoting is the universal escape hatch,** checked before every other
  grammar form.
- **An unresolvable *complete* path narrows to nothing** (honest empty
  result) rather than degrading to a literal text search - these corpora
  are small and unranked enough that "matches nothing" is the clearer
  answer. (The BM25 pickers, being ranked, still degrade a typo'd
  scoped term to a plain ranked search.)
- **Selection follows the user, not the query - where there's no reason
  for it to follow something else.** clipboard-picker / notification-
  picker open with nothing selected; the first navigation selects the top
  visible entry; a selection filtered out of view is cleared. `Enter`
  with nothing selected activates the top visible entry. winswitch's grid
  is the deliberate exception - it auto-selects on open, because landing
  on the previously active window the instant a single Alt+Tab tap
  completes is the whole point of alt-tab.
