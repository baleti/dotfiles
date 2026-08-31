# Picker query DSL

The small query language typed into the search box of every fzf-driven
picker in this repo, plus winswitch's grid search, the GTK
clipboard/notification pickers, and the quickshell app launcher. Arrived
at independently in `window-search.py`, then reused (by hand, not by
import) in `claude-history` and `focus-picker.py`, then reimplemented in
Rust for winswitch's `query.rs`, then ported by hand a second time into
the shared `picker.rs` engine behind clipboard-picker and
notification-picker, then a third time into JS for the quickshell
launcher (`QueryDsl.qml`). Stays copy-pasted rather than a shared library
on purpose - the implementations split across three languages and differ
enough in what they're searching (ranked scrollback vs. an unranked
couple-dozen windows) that a shared abstraction was judged not worth it -
so this doc is what keeps the *semantics* consistent even though the code
doesn't.

| Name | File | Searches |
|---|---|---|
| window-search | `~/.config/tmux/scripts/window-search.py` | live tmux pane scrollback, BM25-ranked |
| claude-history | `~/bin/claude-history` | saved Claude Code conversation transcripts, BM25-ranked |
| focus-picker | `~/.config/tmux/scripts/focus-picker.py` | tmux panes, MRU-ordered (no ranking) |
| winswitch | `~/.config/hypr/winswitch/src/query.rs` | open windows (Hyprland), grid layout - plus tmux/Claude Code metadata cross-referenced onto them |
| clipboard-picker | `~/.config/hypr/clipboard-picker/src/picker.rs` | cliphist clipboard history, list layout |
| notification-picker | same `picker.rs`, `src/bin/notification-picker.rs` | notifyd's retained notification history |
| app-launcher | `~/.config/quickshell/launcher/` (`QueryDsl.qml` + `AppLauncher.qml`) | freedesktop `.desktop` apps, launch-frecency ordered (QML, mod+Super_l) |

See [tmux.md](tmux.md) for the tmux bindings and [rust-tools.md](rust-tools.md)
for winswitch and the GTK pickers.

## The shape of it

Every picker shows a **result set** (windows, panes, clipboard entries,
scrollback-bearing windows, ...) with, potentially, several named
**types** per entry - a "type" here is any one field that can be filtered
on or shown as a column: a flat one (`title`, `workspace`, `pid`; `type`,
`date`, `app`) or a subfield of a **group** (winswitch's `tmux.session`,
`claude.title`, ...). The DSL does three orthogonal things to that set,
and nothing else:

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
up to the next `/verb`, end of input, or the verb's own fixed **arity**
(max argument tokens it will ever take) - whichever comes first. Every
verb has a small fixed arity (see the table below), and it never reaches
past that many tokens even when nothing else stops it early. A token past
a verb's arity is not absorbed by that command - it resumes as an
ordinary token, exactly as if the command had ended right there. Since a
plain token with no verb in front of it is a bare `/filter-value`, this
means **`/fv` is the fallback**: any token left over once every other
verb has taken only the arguments it actually needs becomes a row filter,
never silently dropped.

`/sort date descending` is one command with both its args inside `/sort`'s
arity of 2 (path, optional direction). `/filter-value foo /sort date` is
two commands. `/sort name blender` is *two* things, not one: `/sort`
takes `name` as its path, then looks at `blender` for a direction - but
`blender` doesn't substring-match `ascending`/`descending`, so `/sort`
doesn't consume it, and `blender` falls through to become its own
`/fv blender` term. Typing `/s nam blen` therefore sorts by name (`nam`
resolves to `name`) *and* filters down to rows matching `blen` - the two
verbs never fight over the same token, and a filter word typed after a
sort's path is never silently swallowed just because it happened to sit
inside `/sort`'s argument span.

### Verbs

| Short | Long | Axis | Arity | Effect |
|---|---|---|---|---|
| `/fv` | `/filter-value` | rows | 1 | keep rows whose value matches the argument; drop the rest |
| `/ft` | `/filter-type` | columns | 1 | keep only the columns whose *name* matches; hide the rest |
| `/at` | `/add-type` | columns | 1 | add the columns whose name matches into view |
| `/rt` | `/remove-type` | columns | 1 | drop the columns whose name matches from view |
| `/s` | `/sort` | order | 1-2 | order rows by one type, optional direction |
| `/rv` | `/reverse` | order | 0 | reverse whatever order is currently in effect |

**Arity is a ceiling, not a requirement** - it's the most tokens a verb
will ever reach for, not how many it must have. `/sort`'s second slot is
additionally *conditional*: it only counts as consumed if the token
there actually substring-matches `ascending`/`descending`; otherwise the
verb stops at arity 1 (path only) and the next token is free again. A
verb with 1 token of arity (`/fv`, `/ft`, `/at`, `/rt`) never looks past
its single argument, no matter how many bare tokens follow before the
next `/verb` or end of input - see Grammar, above, for what happens to
the rest.

**Verb names are exact-matched** against the six short/long forms above
plus, per picker, any **field-verbs** it defines (below) - nothing else,
no substring or fuzzy resolution on the verb itself, ever. That's the
one property every extension has to keep: the old `/claude.title:value`
form made a type name (`claude`) sit in the same position a command
would, so every new command risked colliding with some picker's field
list. Exact-matching the verb *token* - however many verbs exist - keeps
that ambiguity closed permanently; it's a *typed argument*'s own
substring resolution (`/at cla` -> every type containing `cla`) that's
allowed to be fuzzy, precisely because argument position and verb
position are kept so strictly separate. An unrecognised `/xyz` token is
inert (contributes nothing) rather than an error or a literal search -
same "half-typed stays a no-op" rule the rest of the grammar follows.

Both the short and long form of a core verb are always accepted and mean
exactly the same thing; the short forms are what the autocomplete offers
first, since the box is typed into far more than it is read.

**Field-verbs.** The six core verbs are fixed and shared by every picker;
beyond them, a picker may register `group` and `group.sub` themselves as
additional verbs - exact-matched the same way, one per real group/
subfield name, never invented or substring-derived. Each is sugar for
`/fv` scoped to that one field: `/claude.contents value` and
`/fv claude.contents:value` mean the same thing, and either form with no
value at all (`/claude.contents`, `/fv claude.contents`) is an existence
check on that one field instead. A field-verb takes at most one argument
token (0 = existence, 1 = substring value), and a value glued directly
onto the verb with a colon (`/claude.contents:value`, no space) is
tolerated too, for anyone reaching for `/fv`'s own `path:value` habit -
the colon is just punctuation there, never a path separator, since the
verb itself already named the field.

A bare `group` field-verb (no `.sub`) defaults to that group's own
**verb default** - deliberately a *separate* setting from the group's
general colon-form default (what `/fv group:value` falls back to, see
Type paths below). winswitch is the reference implementation: `/claude`
(bare) is sugar for `/claude.contents` specifically - transcript content
is far more useful to search by default than the title, which is what
the general `/fv claude:value` colon form still defaults to - while
`/tmux` keeps `.title`, matching the general default there (tmux has
nothing more useful to default to). `/claude.title`, `/claude.path`,
`/claude.time` (a `date`-shaped age bucket, see the comparator section
below) and `/claude.contents` are each their own exact-matched verb the
same way; `/tmux.session`, `/tmux.window`, `/tmux.title` mirror it for
the tmux group. Other pickers are free to add their own field-verbs the
same way as their own field lists grow.

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

- **winswitch**: `title` alone (today's grid label). `workspace`, `pid`,
  and every `tmux`/`claude` subfield are hidden until an `/at` (or a
  surviving `/ft`) brings them in. There is no `class` type at all - it
  wasn't a useful column or filter key, so it was dropped from the type
  registry entirely (it still contributes to the free-text haystack
  alongside `title`, same as always - see `/filter-value`, above).
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
  here, a sort key is one field). The token after `path`, if there is
  one, is only taken as `direction` when it substring-matches
  `ascending` / `descending` (so `asc` / `desc` / `de` all work); if it
  doesn't match either, `/sort` stops at `path` (direction defaults to
  `ascending`) and that token is never consumed - it falls through and
  is parsed from scratch, typically landing as its own `/fv` term (see
  Grammar). This is what makes `/s name blender` sort by `name` *and*
  filter to `blender`, instead of `blender` silently vanishing as a
  rejected direction argument. Only the **last** `/sort` in a query takes
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
- Otherwise -> lexicographic (correct already for `title` / `app` /
  `type`).

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
xdg_popup positioner to anchor one to); the quickshell app launcher grows
the equivalent in QML. Stages:

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

**An empty fragment lists everything for that stage.** `/` alone is all
six verbs; `/ft ` / `/at ` / `/rt ` / `/s ` / `/fv ` (verb, one space,
nothing typed yet) is every type name; `/fv path: ` is every value that
type has. The popup does not wait for a first character - the whole point
is that it can be *discovered*, not just narrowed.

### Suggestion row anatomy

Each row is three fields, left to right, in the style of emacs
`marginalia` / zsh's completion descriptions:

```
/ft   (/filter-type)   show only the matching columns
└─┬─  └──────┬──────┘   └──────────────┬─────────────┘
 what      the long-form alias,        a one-line description
 accepting  greyed - a hint that       of what the verb does,
 inserts    /ft *is* /filter-type,     also greyed
            not a second command
```

- **Verb stage**: label is the short form; the alias is its `/long-form`
  in parens, greyed; the description is the verb's one-liner (below).
- **Type-path stage**: label is the type (or group) name; no alias; the
  description is what that field/group *is* in this picker (e.g. `title`
  -> "the window title", `claude` -> "Claude Code session metadata").
  A picker with no per-field blurbs may leave the description empty.
- **Value / direction stages**: label only; these are concrete data, not
  grammar, so there's nothing to describe.

Only the alias and description are greyed; the label itself takes the
normal / selected-row colour. A picker that can't render three columns
(the BM25 single-line pickers) shows the label alone.

Verb one-liners (keep these consistent across implementations - the
quickshell launcher reads them from `QueryDsl.qml`'s `verbInfo`):

| Verb | Alias | Description |
|---|---|---|
| `/fv` | `/filter-value` | keep rows whose value matches (substring) |
| `/ft` | `/filter-type` | show only the matching columns |
| `/at` | `/add-type` | add the matching columns |
| `/rt` | `/remove-type` | drop the matching columns |
| `/s` | `/sort` | order rows by one field, optional asc / desc |
| `/rv` | `/reverse` | flip the current order |

Shared popup UI: `Tab` accepts the highlighted suggestion; `Ctrl+j` /
`Ctrl+k` move the highlight (clamped, not wrapped); `Escape` dismisses
just the popup, never the picker. One bug worth remembering if the popup
ever silently stops appearing: a `GtkListBox` built with `no-show-all`
(so the picker's one-time startup `show_all()` doesn't reveal an empty
popup) also ignores a *later* `show_all()` meant to reveal it - every
row/label has to be shown explicitly and the list revealed with a direct
`.show()`.

**Per-picker autocomplete scope.** A picker only offers the verbs that do
something for it. The app launcher shows no columns, so it offers `/fv`,
`/s`, `/rv` only - `/ft`/`/at`/`/rt` are still *parsed* (shared grammar)
but inert, so they're left out of the popup rather than suggested and
then ignored.

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
- **`/filter-value` is the universal fallback, not just the no-syntax
  default.** Every verb has a fixed arity (max tokens it consumes,
  `/sort`'s direction slot additionally conditional on resolving); a
  token beyond what the *preceding* verb actually needed is never
  swallowed into that command just because no new `/verb` intervened -
  it resumes as an ordinary token and, if nothing else claims it, becomes
  its own `/fv` term. `/s name blender` sorts by `name` and filters to
  `blender`, rather than losing `blender` as a discarded sort-direction
  argument.
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
