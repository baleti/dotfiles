# Picker query DSL

The small query language typed into the search box of every fzf-driven
picker in this repo, plus winswitch's grid search, the GTK
clipboard/notification pickers, and the quickshell app launcher and RSS
reader. Arrived at independently in `window-search.py`, then reused (by
hand, not by import) in `claude-history` and `focus-picker.py`, then
reimplemented in Rust for winswitch's `query.rs`, then ported by hand a
second time into the shared `picker.rs` engine behind clipboard-picker
and notification-picker, then a third time into JS for the quickshell
launcher (`QueryDsl.qml`), then reused again (same `QueryDsl.qml` import,
not a fourth port) for the RSS reader. Stays copy-pasted rather than a
shared library on purpose - the implementations split across three
languages and differ enough in what they're searching (ranked scrollback
vs. an unranked couple-dozen windows) that a shared abstraction was judged
not worth it - so this doc is what keeps the *semantics* consistent even
though the code doesn't. This table is the complete inventory - if you
add a new consumer, add its row here too.

| Name | Keybind | File | Searches |
|---|---|---|---|
| window-search | tmux prefix+C-w | `~/.config/tmux/scripts/window-search.py` | live tmux pane scrollback, BM25-ranked |
| claude-history | tmux prefix+C-c | `~/bin/claude-history` | saved Claude Code conversation transcripts, BM25-ranked |
| focus-picker | tmux prefix+w | `~/.config/tmux/scripts/focus-picker.py` | tmux panes, MRU-ordered (no ranking) |
| winswitch | Alt+Tab (hold) | `~/.config/hypr/winswitch/src/query.rs` | open windows (Hyprland), grid layout - plus tmux/Claude Code metadata cross-referenced onto them |
| clipboard-picker | mod+v | `~/.config/hypr/clipboard-picker/src/picker.rs` | cliphist clipboard history, list layout |
| notification-picker | (notifyd action) | same `picker.rs`, `src/bin/notification-picker.rs` | notifyd's retained notification history |
| app-launcher | mod+Super_l | `~/.config/quickshell/launcher/` (`QueryDsl.qml` + `AppLauncher.qml`) | freedesktop `.desktop` apps, launch-frecency ordered (QML) |
| rss-reader | Alt+Shift+R | `~/.config/quickshell/rssreader/RssReader.qml` (imports the launcher's `QueryDsl.qml`) | rssd's fetched articles, title/feed/tag/body |

See [tmux.md](tmux.md) for the tmux bindings and [rust-tools.md](rust-tools.md)
for winswitch and the GTK pickers.

**Completion-UI maturity varies** - the grammar/semantics above are shared
by every row in that table, but not every picker has caught up on how its
Tab-completion is *presented* (see Autocompletion, below, for the current
rule: hidden until Tab, and even then only as a popup when there's more
than one candidate). winswitch, clipboard-picker, notification-picker,
app-launcher and rss-reader all follow it; claude-history followed it from
the start (a nested fzf, since it has no in-layout widget tree to put a
popup in). focus-picker never shows an overlapping popup at all - it
prints a quiet `[tab → x]` hint into the header line instead and Tab
always completes to the first candidate outright, with no way to see or
choose among the others when there's more than one; window-search has no
completion assistance at all yet. Both are pre-existing, independent of
the popup-visibility rule (nothing pops up in either to begin with) -
worth bringing forward if either picker's DSL usage grows enough to need
it, but not fixed as part of establishing that rule.

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
/verb/path arg...  same command, with its type path glued on via a 2nd / (see Via paths)
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

**Verb names are exact-matched** against exactly the six short forms and
six long forms above - nothing else, no substring or fuzzy resolution on
the verb itself, ever. That's the one property this grammar was built
around and never gives up, no matter how the rest of it grows: the old
`/claude.title:value` form (and, briefly, a since-reverted design that
registered `/claude`, `/claude.title` etc. as their own verbs) both made
a type name sit in the same position a command would, so every new type
risked colliding with the verb vocabulary. Exact-matching the verb token
itself - always these twelve spellings, nothing more - keeps that
ambiguity closed permanently; it's a *typed argument*'s (or, now, a *via
path*'s - see below) own substring resolution that's allowed to be fuzzy,
precisely because argument position and verb position are kept so
strictly separate. An unrecognised `/xyz` token is inert (contributes
nothing) rather than an error or a literal search - same "half-typed
stays a no-op" rule the rest of the grammar follows.

Both the short and long form of a verb are always accepted and mean
exactly the same thing; the short forms are what the autocomplete offers
first, since the box is typed into far more than it is read.

### Via paths

A verb's type-path argument (see Type paths, below) can be written two
ways, meaning exactly the same thing either way - picked based on what
reads more naturally for a given query:

```
/fv path:value        path as part of the argument (the original form)
/fv/path value         path glued onto the verb with a second /, as its own token
```

The second `/` is a **via operator**: `/fv/claude.title` reads as "filter
by value, *via* `claude.title`" - it names the scope the very next value
is measured against, without needing a colon to glue path and value
together in one token. This is what a whole new command per group and
subfield (the reverted `/claude`, `/claude.title` design mentioned above)
was really reaching for: `/claude.title foo` was trying to be its own
verb when it was always just `/fv`, scoped - `/fv/claude.title foo` says
that directly. `.` still does what it always did within the path itself
(the **subset** operator - `claude.title` picks one subfield out of the
`claude` group, `claude.*` every subfield); `/` is what now introduces
that path to the verb in the first place - two different jobs, two
different characters, not to be confused even though both sit between
name-like segments.

Every path-taking verb accepts a via path the same way: `/ft/claude`,
`/at/claude.*`, `/rt/tmux.session`, `/s/claude.time` all mean exactly
what `/ft claude`, `/at claude.*`, `/rt tmux.session`, `/s claude.time`
already meant - the via form is purely an additional spelling, never a
replacement, so nothing that already worked stops working. `/fv/path`
with nothing following is the colonless existence/free-text form
(`/fv path`'s own rules apply unchanged - see `/filter-value`, below);
`/fv/path value` is the scoped substring filter (`/fv path:value`'s
rules, unchanged); no colon is involved in the via form at all, in
either case. A bare group's *via* default (what `/fv/claude` alone
resolves to) is the same `GROUP_DEFAULT_SUB` the colon form already
uses - see Type paths.

**`/filter-type`'s via path can also be a value pattern.** If the via
path after `/ft/` doesn't resolve to any known type or group at all (by
the ordinary substring rule), `/ft` falls back to reading it as a
**glob pattern** against every field's actual *values* across the
current rows, rather than treating the unresolvable path as a no-op:
`/ft/64*` means "show me whichever column(s) actually have a value
starting with `64` right now" - useful when you remember a value but not
which field it lives in. This is the one place in the whole grammar a
literal `*` means "match anything here" rather than the reserved
"all subfields" segment, and the one place matching isn't plain substring
by default: no `*` anywhere in the pattern still substring-matches, same
as everywhere else in the DSL (`/ft/64` behaves like `/ft/*64*`); a `*`
anywhere in the pattern switches to real glob anchoring instead (`64*` =
starts with, `*64` = ends with, `*64*` = contains, same as plain
substring).
Nothing else in this DSL uses a real pattern-matching engine (see Design
principles) - this one narrow case does, because a value (unlike a type
or group name) was never expected to have a small, enumerable vocabulary
to fuzzy-match against, so "discover the column, not just narrow it"
needs its own mechanism. Matching columns *replace* whatever was shown
(a discovery reset, not an intersect against the current set) - winswitch
is the reference implementation; autocomplete for this stage offers live
values pooled across every field (not just one), narrowed by whatever's
typed so far, the same corpus `/fv path:` completion already draws from.
`/at`, `/rt`, and `/s` don't get this fallback - an unresolvable via path
there stays the existing no-op / narrows-to-nothing behaviour.

### Type paths

Every verb except `/reverse` takes a **type path**: dot-separated
segments naming a flat type or a group subfield - `.` is the **subset**
operator, picking one piece out of the group to its left (see Via paths,
above, for the *other* separator this grammar uses, `/`, and how the two
differ).

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
  scrollback; notification app+summary+body; app name + generic name;
  article title+feed+tag+body). This is the one form every picker
  guarantees and the one a casual user needs no syntax for. `/fv val` and
  a bare `val` are identical. Keep this haystack to short, controlled
  strings: the app launcher deliberately leaves `.desktop` `Comment=` and
  `Keywords=` *out* of it (reachable only as scoped `/fv comment:` /
  `/fv keywords:`), because substring-matching prose mid-word turned
  `/fv ala` into a hit on "sc**ala**ble" and "b**ala**nce".
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

**The popup is Tab-triggered, never shown just from typing.** Nothing
pops up on its own as you type `/frag` - typing alone only ever affects
the row filter/columns/order the same way it always did. Pressing Tab is
what asks "what could this become": if there's exactly one candidate, it
completes immediately with no popup ever built or shown at all, the same
way ordinary shell tab-completion silently completes an unambiguous path;
only 2+ candidates actually reveal a popup, to choose among them. Typing
anything further after a popup is showing closes it (the fragment it was
built from is stale now) - Tab recomputes it fresh for wherever the
cursor is. This applies uniformly everywhere: the GTK pickers show/hide
an in-layout `GtkListBox`, the QML consumers an overlay `Rectangle`,
claude-history spawns/dismisses a nested fzf (see below) - always
Tab-gated, never live. An always-on popup that repainted on every
keystroke was tried first and dropped: it read as obtrusive, and once in
a while it stole a focus/resize cycle at exactly the wrong moment.

Typing `/` then pressing Tab is enough to discover the whole grammar (the
list just won't appear until you actually press Tab - see above). All the
GTK pickers (winswitch, clipboard-picker, notification-picker) grow a
GTK-native completion popup - a plain in-layout `GtkListBox` under the
search entry, not a `GtkPopover` (gtk-layer-shell's layer surface has no
xdg_popup positioner to anchor one to); the quickshell app launcher and
RSS reader grow the equivalent in QML. Stages:

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

**An empty fragment lists everything for that stage, once Tab asks.** `/`
+ Tab is all six verbs; `/ft ` / `/at ` / `/rt ` / `/s ` / `/fv ` + Tab
(verb, one space, nothing typed yet) is every type name; `/fv path: ` +
Tab is every value that type has. Discovery doesn't need a first
character typed - just Tab, at any point - which is what makes "hidden
until Tab" (above) fine for discoverability rather than a tradeoff
against it.

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

Shared popup UI: `Tab` triggers completion when nothing's open yet (see
above - unique candidate applies directly, 2+ opens the popup), and
accepts the highlighted suggestion once it *is* open; `Ctrl+j` / `Ctrl+k`
move the highlight (clamped, not wrapped) - only meaningful while the
popup is showing; `Escape` dismisses just the popup, never the picker. In
a picker where Tab already meant something else while nothing's open
(clipboard-picker/notification-picker's and the RSS reader's search-list
focus toggle), completion only claims the key when it actually found a
candidate - a bare Tab with nothing to complete falls through to that
other meaning unchanged, it doesn't just eat the keypress. One bug worth
remembering if the popup ever silently stops appearing: a `GtkListBox`
built with `no-show-all` (so the picker's one-time startup `show_all()`
doesn't reveal an empty popup) also ignores a *later* `show_all()` meant
to reveal it - every row/label has to be shown explicitly and the list
revealed with a direct `.show()`.

**Inline command-validity coloring.** As a command is typed, the whole
`/verb` (or `/verb/via`) token is colored to show whether it currently
resolves to a real command, not left in the query's ordinary text color:
one color once it's a recognized verb, a distinctly different one while
it isn't (an unrecognized verb, or a genuinely-wrong-looking `/xyz` that
isn't even a prefix of one) - the same at-a-glance "is this valid" a
shell's own syntax highlighting already gives a command name. A
still-forming prefix of a real verb (typing `/f` on the way to `/fv`)
stays neutral - not wrong yet, just incomplete - rather than flashing the
invalid color on every keystroke. Scoped to **verb-name validity only**:
`/fv/bogus_field` still colors as valid, because an unresolved via isn't
necessarily a mistake (`/ft`'s via falls back to a legitimate value
pattern when it doesn't resolve as a path - see above - so "did the via
resolve" isn't a reliable valid/invalid signal the way "is this a real
verb" is). This is presentation only and never changes matching or
resolution - a "wrong" color is exactly what `is_verb_prefix`/
`Verb::parse` (or a picker's own equivalent) already says is unresolved,
nothing new to compute, just something new to render the answer with.
`command_spans` (winswitch's `query.rs`, ported by hand into `picker.rs`
and, as JS, into `QueryDsl.qml`'s two consumers) is the one function that
answers it, from a token list identical to what `starts_command`/
`tok_verb` already tokenize the query into.

Never hardcode either color - both come from whatever dynamic theme
source the app already has, since this desktop regenerates its whole
palette from the wallpaper (`gen-theme.py`); a color baked into a
picker's source would just go stale the next regeneration, or clash
outright. winswitch and `picker.rs` read `~/.local/state/quickshell/
scheme.json` directly (`load_command_validity_colors`) - its `primary`/
`error` keys are the valid/invalid pair here (not `secondary`: this
theme's `secondary` sits too close in hue to `primary` to read as a
distinct "wrong" signal, where `error` is a deliberately different one -
check the live values before picking a role, don't assume the name
alone); the QML consumers already have a `Theme` singleton fed from the
same generated file (`Theme.cyan` / `Theme.red` map to those same two
roles). Which specific role name means "valid" vs "invalid" is still each
app's own call in principle - the DSL only cares that the two stay
visually distinct and both move when the theme does, never that they're
any particular hex value.

GTK's Pango-backed `Entry` supports real per-range text-color attributes
(`EntryExt::set_attributes` with a `pango::AttrList` of `AttrColor`
spans), so winswitch and `picker.rs` recolor the actual glyphs. QtQuick's
plain `TextInput` has no equivalent (no per-range rich-text styling), and
recoloring the *whole* input would falsely tint bare filter words
alongside the command - so the QML consumers draw a thin colored
underline under just the command span instead, positioned via
`TextInput.positionToRectangle` (which stays correct once the field
scrolls, unlike computing an x-offset by hand with `TextMetrics`) rather
than recoloring the glyphs themselves. The three fzf-driven pickers
(window-search, claude-history, focus-picker) don't have this at all yet:
fzf owns and renders its own query line with no hook for a script to
recolor it live per keystroke, so there's no direct equivalent of either
technique above - the closest fzf-native analogue would be a colored
validity hint folded into a dynamically-redrawn header (the way
focus-picker's `[tab → x]` hint already works), which is a materially
different mechanism and hasn't been built.

**Per-picker autocomplete scope.** A picker only offers the verbs that do
something for it. The app launcher shows no columns, so it offers `/fv`,
`/s`, `/rv` only - `/ft`/`/at`/`/rt` are still *parsed* (shared grammar)
but inert, so they're left out of the popup rather than suggested and
then ignored. claude-history only acts on `/fv` at all (see its own
header), so its Tab-completion only ever offers that - the verb stage
lists `fv`/`filter-value` and nothing else, and only via paths get
completed (`/fv/field value`, steering towards that spelling specifically
even though the older `/fv field:value` still works when typed by hand).
Its completion UI can't be an in-layout popup the GTK pickers' way (fzf
has one list, not a widget tree) - a unique candidate completes directly,
the same way shell tab-completion does with no ambiguity to show; an
ambiguous one opens a small *nested* fzf as the actual picker, launched
via `execute(...)` (which hands the terminal over to it, same as fzf's
own `execute(less {})`) and fed back into the query with
`transform-query(...)` once you pick one.

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
