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
| winswitch | Alt+Tab (hold) | `~/.config/quickshell/winswitch/WinSwitchQueryDsl.qml` + `WinSwitch.qml` (grammar ported off `~/.config/hypr/winswitch/src/query.rs`, unused since the 2026-09-09 GTK->Quickshell UI rewrite) | open windows (Hyprland), grid layout - plus tmux/Claude Code metadata cross-referenced onto them |
| clipboard-picker | mod+v | `~/.config/hypr/clipboard-picker/src/picker.rs` | cliphist clipboard history, list layout |
| notification-picker | (notifyd action) | same `picker.rs`, `src/bin/notification-picker.rs` | notifyd's retained notification history |
| app-launcher | mod+Super_l | `~/.config/quickshell/launcher/` (`QueryDsl.qml` + `AppLauncher.qml`) | freedesktop `.desktop` apps, launch-frecency ordered (QML) |
| rss-reader | Alt+Shift+R | `~/.config/quickshell/rssreader/RssReader.qml` (imports the launcher's `QueryDsl.qml`) | rssd's fetched articles, title/feed/tag/body |
| claude-usage | `/` (panel open, CTRL+ALT+c) | `~/.config/quickshell/bar/ClaudeUsageExpanded.qml` (imports the launcher's `QueryDsl.qml`) | active Claude Code processes across all 3 accounts, title/pid/status/tokens/path/account plus `tmux.*`/`hypr.*` fields |
| claude-agents (Android) | search box, conversation list | `~/src/claudeagents-android/src/dev/local/claudeagents/QueryDsl.kt` | live (currently-running) host3 Claude Code conversations synced to the phone; flat `title`/`account`/`tokens`/`age` fields, no groups. Only `/fv`, `/s`, `/rv` do anything (no dynamic columns, same as app-launcher); `/ft`/`/at`/`/rt` still parsed for correct arity, inert. Autocompletion is live-as-you-type rather than Tab-gated (no physical Tab key on a phone) and always completes to whichever form (colon or via) is already being typed, never steers to via the way rss-reader/claude-history do |

See [tmux.md](tmux.md) for the tmux bindings and [rust-tools.md](rust-tools.md)
for winswitch and the GTK pickers.

**Completion-UI maturity varies** - the grammar/semantics above are shared
by every row in that table, but not every picker has caught up on how its
Tab-completion is *presented* (see Autocompletion, below, for the current
rule: hidden until Tab, and even then only as a popup when there's more
than one candidate). winswitch, clipboard-picker, notification-picker,
app-launcher, rss-reader and claude-usage all follow it; claude-history
followed it from the start (a nested fzf, since it has no in-layout widget
tree to put a popup in). focus-picker (2026-09-13) followed the same
nested-fzf pattern: the header's quiet `[tab → x]` hint still shows what
a unique candidate would complete to (and Tab still completes it directly,
no popup, when there's only one), but 2+ candidates now open a small
nested fzf (`complete()`, run via `tab:execute(...)+transform-query(cat
...)` - `transform-query` alone never hands a command the real terminal a
nested interactive fzf needs, only `execute(...)` does, same reasoning as
claude-history's own split) instead of silently picking the first one with
no way to see or choose the others. window-search still has no completion
assistance at all - pre-existing, independent of the popup-visibility rule
(nothing pops up there to begin with) - worth bringing forward if its DSL
usage grows enough to need it, but not fixed as part of this change.

## The shape of it

Every picker shows a **result set** (windows, panes, clipboard entries,
scrollback-bearing windows, ...) with, potentially, several named
**types** per entry - a "type" here is any one field that can be filtered
on or shown as a column: a flat one (`title`, `workspace`, `pid`; `type`,
`date`, `app`) or a subfield of a **group** (winswitch's `tmux.session`,
`claude.title`, ...).

**Group and flat-type names are each picker's own vocabulary, not
required to be shared across the table above.** Only the DSL's grammar
and semantics are meant to stay consistent picker to picker (see the
intro above); concrete field names are each picker's own call, and one
picker lacking a group or flat type another picker has is not
automatically a gap to fix. winswitch's `tmux` group exists because
winswitch's own entities - Hyprland windows - only optionally run
inside tmux, so tmux metadata needs a group to sit apart from a
window's own flat fields (and from its equally-optional `claude`
group); the pickers whose rows already *are* tmux entities have
nothing for a `tmux.` prefix to disambiguate the way it does for
winswitch, since every row already is one. Whether to add it anyway
purely for cross-picker naming consistency is a call each picker makes
on its own: focus-picker and window-search both did (2026-09-13,
`FILTER_FIELDS`/`SORT_KEYS` (focus-picker) and `FIELD_NAMES`
(window-search) - plain flat strings that happen to contain a `.`, not
real nested-group machinery; see each script's own module docstring),
so `/fv/tmux.session`, `/fv tmux.session:foo`, and a bare-group
`/fv tmux:foo` (unions `tmux.session`/`tmux.window`/`tmux.title`, same
rule as any ambiguous path segment - Type paths, above) all work in
both now - window-search only ever had the colon form to begin with
(`QUERY_ELEM_RE`'s field-name character class widened from
`[a-zA-Z]+` to `[a-zA-Z.]+` to let the dot through; it has no via-path
support at all, colon or otherwise - see the maturity note above).
window-search kept `body` flat rather than `tmux.body` - unlike
session/window/title it has no winswitch counterpart to name-match, so
there was nothing to gain grouping it. claude-history hasn't picked
this up and specifically can't the same way even if asked: it already
has a *flat* field literally named `tmux` (a `session:window.pane`
display string), so a `tmux` *group* there would collide with
existing, differently-shaped meaning rather than just be redundant.

The DSL does three orthogonal things to that set, and nothing else:

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
//path arg...      the verb left empty: shorthand for /fv/path arg... (see Default verb)
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
the rest. `/sort`'s arity of "1" for its path slot counts the whole
`path1/path2/path3` via-chain (see `/sort`'s own section, below) as that
one slot, however many `/`-separated keys it holds - arity counts
*space*-separated argument tokens, not the `/`-separated segments glued
onto a single via-form argument.

**Verb names are exact-matched** against exactly the six short forms and
six long forms above - nothing else, no substring or fuzzy resolution on
the verb itself, ever. That's the one property this grammar was built
around and never gives up, no matter how the rest of it grows: the old
`/claude.title:value` form (and, briefly, a since-reverted design that
registered `/claude`, `/claude.title` etc. as their own verbs) both made
a type name sit in the same position a command would, so every new type
risked colliding with the verb vocabulary. Exact-matching the verb token
itself - always these twelve spellings, plus the one empty spelling
`//` (see Default verb, below) that only ever appears with a via `/`
after it, never as a fuzzy match - keeps that
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
replacement, so nothing that already worked stops working (`/sort`'s via
form is the one exception - see its own section, below, for the
multi-key chaining only it supports).

`/fv/path value` is the scoped substring filter (`/fv path:value`'s
rules, unchanged) - no colon is involved in the via form at all. `/fv/path`
with nothing following it *yet* is where the via and space forms finally
diverge from each other:

- If `path` resolves to a **group**, it's still the same existence filter
  `/fv path` (colonless) already is - `/fv/claude` narrows to
  claude-hosting rows before a value is ever typed, via or not. Once a
  value does follow, a bare group's *via* default (what `/fv/claude ovh`
  scopes against) is **every subfield of the group**, same as the colon
  form (`/fv claude:ovh`) and same as `claude.*` already means for a
  column verb - see Type paths.
- If `path` resolves only to **flat types**, the via form is a **no-op**
  while it waits for a value - not the space form's free-text fallback
  (see `/filter-value`, below, for why the space form still needs that
  fallback). `/fv/tokens` sitting alone contributes nothing to the query;
  rows only start narrowing once a value token actually follows
  (`/fv/tokens 3`). This was a real gap, not a deliberate choice: the
  "never flash to zero on a valid partial keystroke" principle (Design
  principles, below) already promises this for a still-forming verb - a
  chosen-but-not-yet-valued via path is exactly as incomplete, and
  treating it as free text broke that promise (reported 2026-09-02:
  typing `/fv/tokens ` mid-query, about to add a value, emptied the
  whole result set instead of leaving it untouched).

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

### Default verb (`//`)

`/fv` is the **default verb of the via operator**: leave the verb slot
empty and the second `/` still introduces a path, to `/fv`.

```
//claude ovh          =  /fv/claude ovh
//claude.title ovh    =  /fv/claude.title ovh
//                    =  /fv/     (nothing typed after the via yet)
```

So the whole via family costs one character less to reach for the most
common command: `//` reads as "filter, via ...". This is the *only*
default the grammar has - `//` always means `/fv/`, never `/ft/` or
`/s/`; the other path-taking verbs still have to be named
(`/ft/claude`, `/s/tokens`). It also only exists in via position: a lone
`/` followed by a path word is still an unrecognised verb, and a
`/verb/path` token whose verb *is* named is unaffected.

Everything that holds for `/fv/path` holds for `//path` unchanged - it is
a spelling, resolved at tokenizing time, not a new command:

- **Arity, no-op and existence rules** are `/fv/path`'s (see Via paths):
  `//tokens` alone is a no-op, `//claude` alone (a group) is the
  existence filter, `//claude ovh` scopes to every subfield.
- **Auto-show** triggers the same way (Auto-shown filter fields), and the
  empty via (`//` alone) is "nothing typed yet" exactly like `/fv/`.
- **Inline coloring** treats `//...` as a valid command token.
- **Verb matching stays exact.** The empty spelling is not a prefix
  match on anything; `/xyz/path` with an unknown `xyz` is still inert.
- **Quoting still escapes it**: `"//foo"` is literal text. A pasted
  `//host/share` or similar is now read as a filter via `host/share`
  (which resolves to nothing and narrows to nothing) - quote it to
  search for the literal text.
- **Completion**: `//` + Tab is the type-path stage of `/fv/` (every
  field, narrowed by whatever follows the second `/`), and a value
  stage follows a resolved `//path ` the way it does for `/fv/path `.
  Accepting a type path keeps the `//` spelling that was typed.

**Where it's implemented.** Every consumer that parses via paths at all:
the shared launcher `QueryDsl.qml` (app-launcher, rss-reader,
claude-usage), `WinSwitchQueryDsl.qml`, `ClipboardQueryDsl.qml`,
`focus-picker.py`, `claude-history` (`QUERY_ELEM_RE`, including the
negated `!//field word` form) and the Android app's `QueryDsl.kt`. It
does **not** apply to `picker.rs` (notification-picker) or
`window-search.py`, which have no via-path parser at all (see the
maturity note above) - `//x` there is plain literal text, same as any
other via spelling. The unused `query.rs` was left alone.

### Type paths

Every verb except `/reverse` takes a **type path**: dot-separated
segments naming a flat type or a group subfield - `.` is the **subset**
operator, picking one piece out of the group to its left (see Via paths,
above, for the *other* separator this grammar uses, `/`, and how the two
differ).

```
title              a flat type
claude             a group (resolves to all its subfields for filtering and
                   column verbs; to its default subfield, GROUP_DEFAULT_SUB,
                   for /sort, which needs exactly one field)
claude.title       one explicit group subfield
claude.*           every subfield of the group
```

**A bare group used as a `/fv` scope searches every subfield, not just its
default one.** `/fv/claude ovh` (or `/fv claude:ovh`) keeps a row if *any*
subfield - `claude.title`, `claude.path`, `claude.session`, `claude.time`,
`claude.contents`, whichever the group has - contains `ovh`, the same union
`claude.*` already means for a column verb (see `/add-type` etc., below).
This changed 2026-09-13: it used to narrow to just `GROUP_DEFAULT_SUB`
(`claude.contents` in winswitch), which silently missed a row whose only hit
was in a different subfield, e.g. `claude.title`. `/sort` keeps the
default-subfield behavior, since a sort key must resolve to exactly one
field - see its own section, below.

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
  "does this row have a title" filter) - **space form only**: the via
  form's `/fv/path` alone is a no-op here instead, not free text, while a
  value is still pending (see Via paths, above, for why the two forms
  diverge on exactly this one case).

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

- **`/sort/path1[/path2/path3/...] [direction]`** (via form, preferred -
  reads as "sort via these fields, in this order") - order rows by
  `path1`; rows that tie on `path1` are broken by `path2`, then `path3`,
  and so on for however many `/`-separated fields are chained. Each
  segment is its own type path and must resolve to exactly one field
  each (`claude.*` is not valid at any position - a sort key is one
  field), same rule as a single-key sort, just applied per segment; a
  segment that resolves to nothing or ambiguously makes the *whole*
  `/sort` inert (Type paths, above), not just that one key. `/sort/tokens`
  alone (one segment) is exactly the single-key sort this always was.
  This is the one verb whose via form is *not* just an alternate spelling
  of the space form (see Via paths, above) - chaining only exists here,
  because it needs the second `/` to *separate* keys, not just to
  introduce the first one to the verb.
- **`/sort path [direction]`** (space form) - single-key only, no
  chaining (use the via form above for more than one key). Order rows by
  the single type `path` resolves to.
- **`[direction]`**, on either form: the token right after the path
  chain, if there is one, is only taken as `direction` when it
  substring-matches `ascending` / `descending` (so `asc` / `desc` / `de`
  all work); if it doesn't match either, `/sort` stops at the path chain
  (direction defaults to `ascending`) and that token is never consumed -
  it falls through and is parsed from scratch, typically landing as its
  own `/fv` term (see Grammar). This is what makes `/s name blender` sort
  by `name` *and* filter to `blender`, instead of `blender` silently
  vanishing as a rejected direction argument. One direction applies to
  every key in a chain uniformly - there is no per-key direction syntax;
  reach for `/reverse` (below) if a chain needs to run backwards as a
  whole, or drop a key that needs to run the other way into its own
  second `/sort` and accept the last-wins replacement (see next). Only
  the **last** `/sort` in a query takes effect (replace, not stack).
  Absent entirely, the picker's own default order stands (MRU, cliphist
  recency, winswitch focus-history, BM25 score). Honoured by winswitch
  and focus-picker; inert in clipboard-picker / notification-picker (no
  re-sort machinery) and the BM25 pickers (score *is* the order).
- **`/reverse`** - flips whatever order is in effect (default, or a
  `/sort`, chained or not - reverses the whole ordered sequence, not any
  one key within it). No arguments. Idempotent: any number of `/reverse`
  tokens == one, not a toggle. Useful alone to flip a picker's default
  order (see the least-recently-used window first) without naming a
  field.

Multi-key chaining was added 2026-09-02, prompted by wanting
`/sort/tokens/title` - sort by token count, and within an equal count,
by title - on the claude-usage process table; single-key `/sort` existed
long before that and is unchanged by it.

**Sort comparison, precisely.** Every type is stored and matched as a
string, but plain lexicographic comparison is wrong for two shapes the
pickers already have. The comparator (`compare_field_values`) sniffs both
values being compared:

- **Plain integers** (`workspace`, `pid`, a raw token count): `"10"` must
  sort after `"2"`, not before - both sides parse as non-negative ints ->
  numeric compare. This applies to the *underlying* value, not a display-
  formatted one: a token count shown as `"58k"` sorts on the real integer
  it came from, not that string (formatted-with-a-suffix strings don't
  parse as plain ints at all, so without this they'd silently fall to the
  lexicographic case below and sort nonsensically by leading digit).
  Reported 2026-09-02 for exactly this field, missed in an early
  implementation's DSL-driven `/sort` path - **any sort UI a picker
  offers must share this one comparator**, DSL-driven or not (e.g. a
  clickable column header that also re-sorts the same rows) - two sort
  entry points disagreeing on `"100"` vs. `"2"` because only one of them
  got the numeric-sniffing treatment is the bug, not a variant worth
  keeping.
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

**The popup is Tab-triggered to open, never shown just from typing.**
Nothing pops up on its own as you type `/frag` - typing alone only ever
affects the row filter/columns/order the same way it always did. Pressing
Tab is what asks "what could this become": if there's exactly one
candidate, it completes immediately with no popup ever built or shown at
all, the same way ordinary shell tab-completion silently completes an
unambiguous path; only 2+ candidates actually reveal a popup, to choose
among them. This applies uniformly everywhere: the GTK pickers show/hide
an in-layout `GtkListBox`, the QML consumers an overlay `Rectangle`,
claude-history spawns/dismisses a nested fzf (see below) - always
Tab-gated to *open*, never live. An always-on popup that repainted on
every keystroke was tried first and dropped: it read as obtrusive, and
once in a while it stole a focus/resize cycle at exactly the wrong moment.

**Once open, typing further narrows it instead of closing it** (changed
2026-09-10 - the original rule closed the popup on the next keystroke,
"the fragment it was built from is stale now, Tab recomputes fresh for
wherever the cursor is"; reported as the wrong call once popups routinely
held more than a handful of entries: `/fv/` + Tab lists every field, and
typing `p` should narrow that list to `path`/`pid`/... in place, not
force another Tab press). Every keystroke while the popup is showing
recomputes candidates fresh from the current text - the same
computation Tab itself uses, just re-run on each change rather than
gated behind the key - and replaces the shown rows with whatever comes
back, resetting the highlight to the top: narrows as the fragment
narrows, jumps to a whole new candidate set if the edit crosses into a
different stage (finishing a type path and typing the value that follows
it, say), and closes itself once nothing matches at all - the same
"narrows to nothing" honest-empty-result rule the rest of the grammar
already follows (see Design principles), not a special case. Unlike
Tab's own trigger, narrowing down to exactly one candidate by typing
never auto-accepts it - the popup still shows that one row and still
waits for an explicit accept (Enter / Space / Tab, per picker - see
below), since silently applying a completion just because typing
happened to narrow to a single match would be a surprise, not a
convenience. Typing while nothing is open still never opens anything
from scratch - that half of the original rule is unchanged, only the
"once shown" half flipped from close-and-retrigger to narrow-in-place.

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
   `/fv frag` before any `:`; the via form `/verb/frag` is the same stage):
   candidates are flat type names and group names containing `frag`; after
   a `.`, that group's subfields plus `*`. Accepting a column-verb path or
   a group completes the token; accepting a `/fv` or `/s` path inserts a
   trailing space ready for the value/direction, in the **via spelling** -
   `/fv frag` + accept lands `/fv/<type> `, not `/fv <type>:` (rss-reader
   and claude-history both steer completion toward the via form this way;
   the colon form still parses when typed by hand). The GTK pickers and
   app launcher still land the `:` form here.
3. **Filter value** (`/fv path:frag` or `/fv/path frag`, `path`
   unambiguous): candidates are
   every distinct non-empty value that type actually has across the
   current entries right now, substring-narrowed by `frag`, deduplicated
   and sorted. This is the one stage genuinely scoped to a small corpus.
4. **Sort direction** (`/s path frag`, `path` unambiguous): candidates
   are `ascending` / `descending`, narrowed by `frag`.

**An empty fragment lists everything for that stage, once Tab asks.** `/`
+ Tab is the six verbs plus every verb/path combination the grammar can
build (see Verb-stage depth, below); `/ft ` / `/at ` / `/rt ` / `/s ` /
`/fv ` + Tab
(verb, one space, nothing typed yet) is every type name; `/fv path: ` +
Tab is every value that type has. Discovery doesn't need a first
character typed - just Tab, at any point - which is what makes "hidden
until Tab" (above) fine for discoverability rather than a tradeoff
against it.

### Verb-stage depth

Added 2026-09-11 (superseding an earlier, same-day attempt at a hardcoded
single shortcut - see below): the Verb stage (stage 1, above) doesn't stop
at the six short verb forms - its candidate list is the six verb shorts
**plus every path-taking verb crossed with every resolvable path**
(flat types, groups, and group subfields - the same universe stage 2's
type-path completion already draws from), rendered as the complete
`verb/path` string. A fragment of the *path*, not just the verb, is
therefore enough to reach a whole command: `/wo` + Tab reaches
`/fv/workspace`, `/ft/workspace`, `/at/workspace`, `/rt/workspace`, and
`/s/workspace` (every path-taking verb crossed with the one path
containing `wo`); `/cla` + Tab reaches all five verbs crossed with
`claude` and each of its five subfields (`claude.title`, `claude.path`,
`claude.session`, `claude.time`, `claude.contents`) - thirty rows, further
narrowed by typing more (`/claude.t` cuts it to the two subfields
containing `t`). `/reverse` takes no path and is never crossed.

Matching reuses the exact rule stage 1 already used for the plain verbs -
`substr(fragment, candidate_text)` against the *complete* `verb/path`
string, not just one half of it - so a fragment of either the verb or the
path reaches the same row. Accepting one inserts its full text
(`/fv/workspace `) in one step, exactly the string `/fv/workspace` already
parsed to when typed by hand (see Via paths) - this only adds completion
candidates, nothing new to the grammar or to matching. An empty fragment
now surfaces this whole depth too (see "An empty fragment lists
everything," above, updated by this change) - `/` + Tab is no longer just
the six verbs, it's the six verbs plus every verb/path combination the
grammar can build, the complete stage-1 vocabulary in one popup.

Computed from the existing type registry (`COLUMNS`/`GROUPS`/group
subfields), not hardcoded - the first attempt at this (hardcode just
`/fv/claude` as a single Verb-stage candidate) was the wrong shape: it
special-cased one group behind one verb instead of the general
`verb x path` depth being asked for, and `/wo` + Tab correctly found
nothing under it, since `/fv/workspace` was never in the hardcoded list.
Superseded same-day, no version of the hardcoded-list design shipped
beyond winswitch.

**Row anatomy for a deep candidate** (extends Suggestion row anatomy,
below): label is the full `/verb/path` string; alias is the verb's own
`/long-form` (`/filter-value` for an `/fv/...` row), same role it already
plays for a plain verb candidate; description is the *path's* one-liner
(`typeDescs`/`type_desc` - "the Hyprland workspace" for `workspace`), not
the verb's - the path is the newer, less-obvious half once the verb is
visible in the label itself.

**Rollout: winswitch first, ported everywhere else 2026-09-11-12.**
Landed in winswitch first (`WinSwitchQueryDsl.qml`'s `completionCandidates`'s
`"verb"` case, alongside the existing `shortVerbs` filter - not
`query.rs`, which stopped being winswitch's live implementation once its
UI was rewritten onto Quickshell/QML on 2026-09-09; `query.rs`'s own grammar
code is unused today), confirmed correct there, then ported by hand to
every other consumer that has a Tab-triggered popup at all: `picker.rs`'s
`verb_stage_universe` (clipboard-picker/notification-picker - crosses only
`/fv`, the one verb that's actually acting there, against its flat
`field_names`, landing the colon form since this grammar has no via-path
support at all) and each QML consumer's own
`_verbStageUniverse`/`_acCandidates` (app-launcher, landing colon to match
its established convention; rss-reader and claude-usage, landing via form
to match theirs). window-search stays out of scope (see the maturity note
at the top of Autocompletion - it has no completion assistance at all);
focus-picker and claude-history caught up 2026-09-13, both via nested-fzf
popups (`focus-picker.py`'s `completion_stage`/`verb_stage_universe`,
crossing `/fv` and `/s` against this picker's flat filter/sort fields and
`/at`/`/rt`/`/ft` against its column groups since it has no single shared
type registry the way winswitch does; `claude-history`'s
`complete_query`, crossing only `/fv` against `FIELD_NAMES` - the one verb
that does anything there, same reasoning as `picker.rs`). Landing this in
focus-picker also meant giving it the via-path grammar (`/verb/path ...`)
it had never actually had - it silently degraded to dead literal-text
bare terms before (reported 2026-09-13): a picker can't usefully offer
Tab-completion toward a spelling its own parser can't read back.

**Ctrl+Space AND-narrows a Verb-stage popup instead of accepting it.** With
the popup open on a `"verb"`-stage completion, `Ctrl+Space` inserts a
literal space and keeps the popup open, rather than accepting the
highlighted row the way plain `Space` does (see Suggestion row anatomy,
below, for `Space`'s ordinary meaning) - so `/wo` + Tab (five rows: every
verb crossed with `workspace`) + `Ctrl+Space` + `fv` narrows that same
five down to just `/fv/workspace`, the one row whose full `verb/path` text
contains *both* `wo` and `fv`. Each fragment (space-separated, including
the one the popup was already open on) must independently substring-match
a candidate's complete text - an AND over the fragments, not a second,
narrower substring search - so fragment order never matters and a third
`Ctrl+Space` narrows further the same way a second one does. Scoped to the
Verb stage only: a value or sort-direction popup has no `verb x path`
universe to cross, so `Ctrl+Space` there is a no-op (the space isn't
inserted). No-op, not a grammar change, either - the text that ends up
typed (`/wo fv`) is never itself parsed as two tokens the way plain typing
normally would be (that would make `wo` a literal `/fv` text search once a
space followed it, since `wo` isn't a prefix of any verb - see Design
principles' "never flash to zero"): the popup intercepts recomputation
while this mode is active and replaces the whole span from the completion's
original opening `/` through the cursor in one go on accept, the same as
accepting any other Verb-stage row already does.

Same rollout as Verb-stage depth, same day: winswitch first
(`WinSwitch.qml`'s `acVerbMulti`/`acVerbMultiStart`), then `picker.rs`
(clipboard-picker/notification-picker) and each QML consumer
(app-launcher, rss-reader, claude-usage) by hand.

**The fzf-native completion popup (focus-picker, claude-history) picked
this up 2026-09-13**, once it had a real popup at all (see Verb-stage
depth's own rollout note, above) - `Ctrl+Space` is bound there to fzf's
own `put( )` action (insert a literal space into fzf's *own* query box,
without accepting), the same functional outcome as the GTK/QML families'
custom AND-narrowing logic, but for a structurally different reason:
this popup has no separate "Space accepts" rule to work around in the
first place (`Enter` is what accepts here, plain `Tab`/`Space` do fzf's
own ordinary things - moving the highlight and typing a literal
character, respectively - see Shared popup UI, below, for why this
family never got the other two's "Space also accepts" convention), so
plain `Space` already inserts a literal space and narrows same as
`Ctrl+Space` would; the binding exists anyway so the *key* matches
winswitch's, not because the space needed rescuing from an accept
binding. The AND-narrowing itself needs no DSL code either: this popup
runs fzf's own untouched fuzzy matcher already (see Search-box history,
below, for why that's deliberate here and not the grammar's usual
substring rule), which already ANDs space-separated fragments together
natively - typing a second fragment after any space, `Ctrl+Space`-typed
or not, was already narrowing further before this change; `put( )` only
adds the specific keystroke. Not scoped to a "Verb stage" the way
winswitch's is, either - this popup only ever shows one flat candidate
list per Tab press (Verb-stage depth already flattens verb and path
together into one popup - see above), so there's no separate stage for
it to be inert in. window-search has no completion popup at all to
extend this into (see the maturity note at the top of Autocompletion).

## Auto-shown filter fields

Added 2026-09-11-12, alongside Verb-stage depth: a field actively
`/fv field:value`-scoped (or, for a group, `/fv group` existence-filtered)
is shown even without an explicit `/at` - and even past an `/ft`/`/rt`
that would otherwise hide it - so the value that actually matched is
visible the moment there's more than one candidate left to choose between,
rather than a filter narrowing the result set for reasons that aren't on
screen. This is additive to whatever `/ft`/`/at`/`/rt` already computed
(or, in a picker with no column system at all, additive to that picker's
fixed default display) - never a replacement, and it disappears again the
moment the scoping term is deleted from the query.

**Triggers the moment the field is named, not just once a value narrows
anything.** Added 2026-09-12: a via-form `/fv/path` with nothing typed
after it *yet* (`/fv/claude.session`, about to add a value) already
resolves `path` to a real field - see Via paths, above - even though
that resolution stays a no-op for row filtering (the whole point of the
2026-09-02 fix this doc already documents there). Auto-show reads that
same resolution and shows the field immediately, rather than waiting for
`/fv/claude.session 3` to actually be typed - the column that's about to
be filtered on is exactly what a still-forming command benefits from
showing early, same "don't make the user wait to see what they're doing"
spirit as inline command-validity coloring or Tab-completion itself. An
unresolvable or still-ambiguous via path (a typo, or a fragment on its
way to becoming a real field name) resolves to nothing here exactly like
it always does for a complete term, so nothing flickers into view for
`/fv/zzz` or a `/fv/cl` still being typed - only a path that has actually
landed on one real field (or a real group, for the existence form) counts.
Scoped to the via form specifically (and the pre-existing `/fv path:`
colon-with-empty-value case, which already triggered this before today):
the *space* form's colonless `/fv path` stays exactly as ambiguous as it
always was between "a field name about to get a colon" and "a bare
free-text word" (see `/filter-value`'s own section) - via's leading `/`
is what removes that ambiguity, so only via gets the early trigger.

**A genuinely empty via segment is nothing typed yet, not an ambiguous
fragment.** `/fv/` with nothing typed after the second `/` yet has an
empty-string path - and every resolver in this grammar treats an empty
*needle* as matching everything (`substr`'s own contract - see
Resolution, precisely), which is exactly right for a value ("no text
required" is the whole point of a colonless filter) but disastrous for a
*path*: resolved naively, an empty segment reads as "ambiguous across
every group and type," and the union-everything rule an ambiguous
fragment legitimately gets (`/fv/cl` reaching every group starting with
`cl`) would auto-show every group's default subfield at once - reported
2026-09-13, `/fv/` alone flashing Claude session info under every
thumbnail before any type had even been chosen. Fixed by gating this
whole early-trigger path on a non-empty via string specifically (each
implementation's own `via.length > 0` check) - not a new resolution rule,
just refusing to resolve at all when there is, literally, nothing there
yet. This is scoped to the auto-show trigger alone: an empty via still
means what it always did everywhere else in the grammar (the verb itself
is still valid, still colored as such - see Inline command-validity
coloring - and the *value* stage of a query like `/fv/ text` still
resolves that empty path the normal ambiguous-union way, for whatever
that construct is worth typed on purpose).

What "shown" means is necessarily picker-specific:

- **winswitch**: the referenced field becomes an active column exactly
  like an `/at` would (`WinSwitchQueryDsl.qml`'s `filterReferencedFields`,
  folded into `activeColumns`) - rendered as its own extra line under the
  thumbnail (`WinSwitch.qml`'s `labelLines`, one line per active column,
  not space-joined), with the grid's cells growing (`labelAllowance`) to
  fit however many lines are now showing rather than clipping them.
- **clipboard-picker / notification-picker**: a dim extra line under the
  entry's preview/thumbnail (`picker.rs`'s `update_extra_labels`) - this
  picker has no real column system to fold into (see its own header), so
  this is the one place these two pickers show a field's value at all.
- **app-launcher / rss-reader**: a dim second (or third, for the RSS
  reader) line under the app name / article title - skipped for whichever
  fields that row already shows unconditionally (the RSS reader excludes
  `title`/`feed`/`date`, always visible; the app launcher has nothing to
  exclude, since it shows only the name by default).
- **claude-usage**: a deliberate no-op - its table already renders every
  field as a permanent column (see its own `/ft`/`/at`/`/rt`-are-inert
  comment), so there is nothing hidden left to surface.

Scoped to consumers that support a Tab-triggered popup at all - window-search,
focus-picker and claude-history stay out of scope for *this* feature (see
the maturity note at the top of Autocompletion), even though focus-picker
and claude-history did pick up both Verb-stage depth and Ctrl+Space
themselves 2026-09-13 (see each feature's own Rollout note) - all three
features landed separately, not as one package, and this one specifically
hasn't been ported to the fzf-native completion popup yet.

**A group subfield's auto-shown line is labeled with the subfield's own
name, and gated per row once the scoping term is a bare group.** Added
2026-09-13, winswitch only (the one picker with groups today): since a bare
group now searches every subfield rather than just `GROUP_DEFAULT_SUB` (see
Type paths, above), which subfield actually matched can differ row to row -
`/fv/claude ovh` might hit `claude.title` on one window and `claude.contents`
on another. Two changes follow from that:

- **Labeling.** A group-subfield line now renders as `sub: value`
  (`title: ovh proposal draft`, `contents: ...call it OVH-style...`) instead
  of a bare, unlabeled value - the reader otherwise has no way to tell which
  subfield they're looking at, especially once a query can surface more than
  one. This applies to *every* group-subfield line, not just ones reached
  through a bare-group filter - a column added via `/at claude.*` gets the
  same `sub: value` treatment.
- **Per-row gating.** A field reached through a bare-group scoped filter is
  only shown on rows where it's actually the subfield that matched -
  `claude.title` doesn't get a line on a row whose hit was only in
  `claude.contents`, and vice versa. A field shown for any other reason
  (`/at`, an explicit `claude.title` scope, the existence-filter default) is
  unaffected and always shown once it has a non-empty value, same as before.
- **Match-centered preview.** The shown value is still capped (80 chars in
  winswitch), but when the line is tied to a matched filter value the window
  is now centered on the match's first occurrence instead of always starting
  at character 0 - a plain `value.slice(0, 80)` of a long field like
  `claude.contents` (a whole transcript) essentially never contains the
  matched substring within its first 80 characters, so the preview read as
  unrelated noise even on a correct match (reported 2026-09-13 against
  winswitch's alt-tab search: `/fv/claude ovh` matched real hits in
  transcript contents, but every thumbnail showed the same unrelated leading
  fragment instead of anything resembling `ovh`). Fields not tied to a
  matched value (an `/at`-added column with nothing scoping it) keep the
  plain start-truncation, since there's no match position to center on.

`WinSwitchQueryDsl.qml`'s `scopedGroupFilters` (the bare-group `{group,
value}` pairs currently in the query) and `excerpt` (the centering helper)
are the reference implementation; `WinSwitch.qml`'s `labelLines` is where
both are applied per row.

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
above - unique candidate applies directly, 2+ opens the popup). Once the
popup *is* open, `Tab`'s meaning splits by implementation family:

- **QML pickers** (app-launcher, rss-reader, claude-usage, winswitch):
  `Tab` / `Shift+Tab` cycle the highlight, wrapping around both ends;
  `Down`/`Up` (and, in app-launcher/winswitch, `Ctrl+j`/`Ctrl+k`) move it
  too, clamped instead of wrapped. Highlighting alone never accepts -
  `Enter` or `Space` does (reported 2026-09-09 against winswitch's
  original pattern: accepting on every `Tab` press without ever letting
  you cycle through options was confusing, so `Tab` was changed to move
  the highlight like `Down` and a dedicated accept key was kept instead;
  the same fix landed in app-launcher and rss-reader immediately after,
  and in claude-usage on 2026-09-10 once it was noticed to have missed
  the fix).
- **GTK pickers** (clipboard-picker, notification-picker, sharing
  `picker.rs`): `Tab` itself accepts the highlighted suggestion outright,
  same as `Enter` would; `Ctrl+j`/`Ctrl+k` move the highlight (clamped,
  not wrapped) without accepting.

`Space` accepts the highlighted suggestion everywhere the popup is open,
in both families, alongside whichever of `Tab`/`Enter` already did
(added 2026-09-10 - the AutoCAD convention of the spacebar confirming the
current command/entry). It's consumed only while the popup is showing;
with no popup open, `Space` types a literal space into the query exactly
as it always did.

- **fzf-native pickers** (focus-picker, claude-history - a nested fzf
  process, not an in-layout widget the picker itself draws and can
  rebind at will): `Enter` accepts, fzf's own ordinary default; `Tab`
  moves the highlight down (fzf's stock `toggle+down`, not a custom
  bind - the "toggle" half is a no-op without `--multi`) and `Space`
  types a literal space into fzf's *own* query box, neither one
  repurposed to accept. This family never adopted the other two's
  "Space also accepts" convention above - there was nothing to add a
  bind *for*, since accepting was already one keystroke (`Enter`) away
  and every other key already does something fzf-native and useful
  (`Space` narrowing further is what Ctrl+Space AND-narrowing, above,
  builds on directly).

`Escape` dismisses just the popup, never the picker. In
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
`/verb` (or `/verb/via`, or `//via`) token is colored to show whether it currently
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

## Search-box history (Up-arrow, Ctrl+R)

Two bindings, modeled directly on zsh's own line editor plus this user's fzf
`ctrl-r` widget (`~/.zshrc`'s `_fzf_history_widget_wrapper`, plain
`fzf-history-widget` underneath - its only customization is *where* the
popup renders, `--tmux` placement, never *how* it matches or orders), so
the shell muscle memory transfers straight into every picker's search box
with no new mechanism to learn.

- **Up-arrow** cycles the search box's whole text backward through that
  picker's own previously-submitted queries, most-recent-first - the same
  job zsh's default `up-line-or-history` binding does. **Down-arrow**
  walks forward again, symmetric with Up, eventually landing back on
  whatever was actually being typed before the first Up press (the
  pre-cycle draft, restored verbatim, even if it was empty) rather than
  getting stuck on the oldest entry once you've walked past it - zsh does
  the same. Scoped to whenever the search box is focused and **no popup
  (completion or history) is currently open** - both because Up/Down are
  already claimed for moving the completion popup's highlight once one is
  open (QML pickers: `Down`/`Up` move it, clamped - see Shared popup UI,
  above), and because replacing the box's text out from under an open
  completion popup that's narrowed to the *old* text would be actively
  confusing. **The fzf-native pickers give up Up/Down as row-navigation
  entirely** to make room for this (there's no separate "popup" state to
  scope around there the way there is for a QML completion overlay -
  Up/Down are the *main list's* own navigation by default) - row
  navigation moves to `ctrl-j`/`ctrl-k` instead, which cost nothing new to
  bind since they're already fzf's own default synonyms for down/up.
- **Ctrl+R** opens a popup - the same shared popup machinery
  Tab-completion already uses (nested fzf for the fzf-native pickers,
  in-layout `GtkListBox`/QML overlay elsewhere - see Autocompletion,
  above), but pointed at a different corpus and a different matcher:
  - **Corpus**: the picker's own history list, most-recent-first, same
    list Up-arrow cycles through - not the DSL's verb/type/value
    candidates.
  - **Matcher**: fzf's own default fuzzy algorithm, not this DSL's plain
    substring rule (Resolution, precisely, below) - a deliberate second
    exception to "no subsequence matching anywhere" (the first being
    `/ft`'s glob-pattern fallback), made because the whole point of this
    binding is reusing zsh ctrl-r muscle memory, not staying internally
    consistent with the rest of the grammar. This is free for the three
    fzf-native pickers: the nested completion fzf already runs with fzf's
    untouched default matcher (no `--disabled`, no `--exact` - only the
    *outer* fzf runs `--disabled`, to hand filtering to the DSL), so
    pointing that exact same nested-fzf plumbing at the history file
    instead of the candidate list needs no new matching code, only a new
    corpus and a new trigger key. Non-fzf pickers approximate the same
    feel with a fuzzy/subsequence scorer in their own popup instead of
    substring, since there's no nested fzf to borrow one from.
  - **Seed**: the popup opens pre-filtered by whatever's currently in the
    search box (`fzf --query "$LBUFFER"`'s own behavior), not empty -
    then narrows further exactly like a Tab-completion popup already does
    on every keystroke (recompute-in-place, reset highlight to top, close
    on zero matches - see Autocompletion, above; nothing new to invent
    here either).
  - **Accept** (Enter - the fzf-native family's own accept key, see
    Shared popup UI's fzf-native bullet, above; not Space/Tab, which do
    fzf's own ordinary things in this popup too) replaces the **entire**
    search-box text with the chosen history entry, cursor at the end - a
    whole-line replace, not an insert at cursor, matching zsh's own
    `LBUFFER=$selected`.
  - **Escape** dismisses just the popup, search box left exactly as it
    was before Ctrl+R was pressed - same as every other popup in this
    DSL.

**What gets recorded, and when.** A query is appended to that picker's own
history the moment the user *acts on it in the results grid* - not on
every keystroke, and not while a query is only still being typed. Two
things count as "acted on," added 2026-09-13 after the first cut (accept
only) turned out to be too narrow in practice: an actual **accept** (Enter
activating a row - the shell analogue, "a command" being whatever was run)
and, separately, **moving the row selection** after typing (arrow/ctrl-j/
ctrl-k navigating the results without ever accepting one) - browsing a
query's results is itself evidence the query was finished and useful,
even if the session ends without jumping anywhere. Neither fires mid-typing:
a keystroke that only changes the query text itself is never on its own a
trigger, only what comes *after* typing pauses - so a query still being
composed never gets a half-typed fragment recorded (this DSL's own "never
flash to zero on a valid partial keystroke" spirit, applied to history
instead of results - see Design principles, below). An empty search box at
either moment records nothing (a shell doesn't journal a blank line
either). Whitespace
runs are collapsed to one space before storing or comparing (mirrors this
user's `HIST_REDUCE_BLANKS`), and a submitted query identical, after that
normalization, to an existing entry anywhere in history removes the older
occurrence and re-appends fresh at the end instead of growing a duplicate -
mirrors `HIST_IGNORE_ALL_DUPS`, which this user's `.zshrc` already sets,
so a query typed a third time floats back to "most recent" instead of
piling up three near-identical rows in the Ctrl+R popup.

**One history list per picker, not shared across them.** Same reasoning
the doc already gives for field/group vocabularies not needing to match
picker to picker (The shape of it, above): each picker's queries are
shaped by, and only meaningful against, that picker's own corpus and type
vocabulary - a `claude.title` scope typed in claude-usage means nothing
replayed into window-search. Stored per picker under its own cache
directory (mirroring `~/.zsh_history` itself - one file per shell, not a
merged global one), unbounded, like this user's own
`HISTSIZE=99999999`/`SAVEHIST`, rather than capped and pruned.

**Written immediately, read fresh on every Ctrl+R - not just cached at
picker startup.** Mirrors `INC_APPEND_HISTORY` + `SHARE_HISTORY`: a
one-shot fzf-native picker (window-search, focus-picker, claude-history)
is a fresh process every invocation anyway, so this is automatic there -
there's no earlier in-memory snapshot to go stale. It matters more for the
long-lived QML/GTK pickers - the quickshell shell process and its panels
stay resident across many separate open/close cycles, unlike a shell that
exits with its terminal - so each of those should re-read its history
file at the moment Ctrl+R opens the popup rather than rely on whatever it
loaded once at `qs` startup, so a query submitted in one open-close cycle
is visible to Ctrl+R the very next time that same picker is opened, the
same way a second concurrent zsh session sees a first session's
just-run command under `SHARE_HISTORY`.

**Out of scope: claude-agents (Android).** No physical Up-arrow or Ctrl+R
exists on a phone keyboard, and its `QueryDsl.kt` already departs from the
desktop completion model for the same reason (live-as-you-type, no
Tab-gating - see the table entry above); a touch-native equivalent (e.g. a
swipe-to-recall gesture, or a persistent "recent searches" chip row) would
be its own design, not a port of this section, and hasn't been asked for.

**Rollout: focus-picker and claude-history, 2026-09-13; the rest not yet
built.** Landed first in the two fzf-native tmux pickers, where it turned
out to need almost no new mechanism: fzf's own `--history=FILE` flag
already *is* Up-arrow-style cycling (confirmed directly, a scripted
`expect` session against real fzf - loads oldest-first, writes the file
only on a genuine accept, never on Escape/ctrl-c, and restores the
pre-cycle draft verbatim once you walk forward past the newest entry -
every part of the Up-arrow bullet above, for free). Bound to the literal
`up`/`down` actions (`--bind up:prev-history --bind down:next-history`),
not fzf's own ctrl-p/ctrl-n auto-remap default, since real usage showed
that's what "Up-arrow" actually needs to mean here - row navigation moves
to `ctrl-j`/`ctrl-k` instead (see the Up-arrow bullet's own note on this).
`dedupe_history()` (`focus-picker.py`, `claude-history`) is the one thing
fzf's flag doesn't do on its own - it appends unconditionally, no
`HIST_IGNORE_ALL_DUPS` equivalent - so both run it right after the outer
fzf exits, collapsing the file to last-occurrence-wins order before the
*next* invocation's `--history` load or this invocation's own Ctrl+R
popup ever reads it. The "moving the selection also records" half of
"What gets recorded, and when" (above) is `ctrl-j`/`ctrl-k`'s own
`execute-silent` bind, appending the live query with no read-modify-write
(`record_history()` in focus-picker.py; `history_candidates()`'s sibling
`record` mode + socket handler in claude-history) - left as a raw,
undeduped append on every nav keystroke rather than a full read-dedupe-
write each time, since `dedupe_history()` already cleans it up once at
exit and a same-session Ctrl+R seeing a few repeats of one line in the
meantime is cosmetic, not a correctness problem. Ctrl+R
(`history_search()` in focus-picker.py; `history_candidates()` +
`CLIENT_SRC`'s new `history` mode in claude-history) reuses the exact
same execute()+transform-query() nested-fzf plumbing Tab-completion
already had, pointed at the history file instead of the DSL candidate
list, with one behavioral difference from Tab: it always opens the popup
(zsh's own ctrl-r widget does too, unconditionally) rather than
Tab's "a unique candidate completes silently" rule, since Ctrl+R's whole
point is *browsing*, not narrowing to an obvious single answer.
window-search stays out of scope for the same reason it already sits out
of the rest of Autocompletion (see the maturity note at the top of this
document).

**Rollout, continued: all four QML pickers plus the Rust GTK pickers,
also 2026-09-13.** None of these have fzf's `--history` to lean on, so
each needed its own Up/Down-vs-list-navigation call and its own
from-scratch fuzzy-match popup for Ctrl+R - but every one reused its
*existing* Tab-completion popup machinery for that popup (acItems/acSel/
accept in QML; `suggestions`/`suggestion_idx`/`accept_suggestion` in
Rust) rather than building a second component: only what *computes* the
popup's candidates differs (`_acHistoryCandidates`/
`compute_history_candidates` - an ordered-subsequence fuzzy match, ported
by hand into JS three times and once into Rust as `_fuzzySubsequence`/
`fuzzy_subsequence`) and, in the QML pickers, a mode flag/kind variant so
`onTextChanged`/`connect_changed` know which computation to keep
re-running while the popup stays open.

- **app-launcher** (`LauncherQueryHistory.qml`, `AppLauncher.qml`): Down/
  Up already meant "move the completion popup's highlight, else move the
  results list" - moving the *results list* half to Ctrl+J/Ctrl+K (split
  out of the combined Down/`Key_J`-with-ctrl condition that used to alias
  them) freed Down/Up for history-cycling. Recorded on `launch()` (accept)
  and on Ctrl+J/Ctrl+K/PageDown/PageUp (selection-move).
- **winswitch** (`WinSwitchQueryHistory.qml`, `WinSwitch.qml`): same
  Down/Up-vs-Ctrl+J/K split, but only in the locked/search-box-focused
  key handler - the *other* (unlocked, plain Alt+Tab hold-and-cycle)
  handler is untouched, since it never has a query typed for history to
  be about. `_acAccept`'s existing `kind.kind` switch (already how every
  completion stage decides what to splice into the query) grew one more
  case, `"history"`, that replaces the whole query instead of splicing at
  a fragment. Recorded on `confirm()` and inside `_advance`/`_advanceRow`
  (both grid-navigation paths, locked or not - `record()` no-ops on an
  empty query, so plain Alt+Tab cycling with nothing typed stays a no-op).
- **rss-reader** (`RssQueryHistory.qml`, `RssReader.qml`): the search
  box's Down/Up, with the completion popup closed, used to just
  `_returnFocusToList()` - already redundant with Tab and Escape, which
  do the same job, so repurposing them for history-cycling loses nothing.
  Recorded on `openCurrent()` and inside `move()`.
- **claude-usage** (`ClaudeUsageQueryHistory.qml`, `ClaudeUsageExpanded.qml`):
  the one QML picker with no pre-existing Ctrl+J/Ctrl+K alias for Down/Up
  at all (its two-tier key-handler split - `handleKey()` for the panel,
  a separate one for the search box - had never needed one, since Down/Up
  simply bubbled from the unhandled-in-search-box case up to `handleKey`).
  Added Ctrl+J/Ctrl+K there from scratch, forwarding to `handleKey()`
  explicitly the same way the search box already explicitly forwards
  Enter, and pulled Down/Up out of that bubble path entirely so they land
  on history-cycling in the search box instead. Recorded on
  `focusHyprWindow()` and inside `handleKey`'s own Down/Up/Ctrl+J/Ctrl+K
  arms.
- **clipboard-picker / notification-picker** (`picker.rs`, shared): no
  QML-style two-popup split needed - `SuggestionKind` grew a `History`
  variant next to `Verb`/`Field`/`Value`, and `accept_suggestion`'s
  existing per-kind switch grew one more arm (whole-query replace, same
  as winswitch's `"history"` case). Ctrl+j/Ctrl+k were *already* the only
  way to move the results list once a popup could be showing (this
  picker's Up/Down were dual-purpose from the start, unlike the QML
  pickers' history/list split being new work) - the change was pulling
  plain Up/Down out of the shared `step` calculation entirely, freeing
  them for `history_prev`/`history_next`. `connect_changed` recognises a
  live history popup via `state.suggestion_kind` being `Some(History)` -
  the same field every other stage already used to mean "a popup session
  is open," rather than a second boolean. The history file itself is
  plain text, one query per line, oldest-first - deliberately the same
  shape fzf's own `--history` file already uses (see the tmux pickers'
  rollout above), even though nothing here reads it with fzf; each binary
  gets its own file via `cache_dir(program_name)`, already how this file
  keeps clipboard-picker's and notification-picker's own per-program
  state apart. Recorded on `connect_row_activated` (accept, covers both a
  mouse double-click and Enter's synthetic `row.activate()`) and inside
  the arrow-key list-navigation arm of the key-press handler
  (selection-move). Verified with `cargo check --all-targets`, `cargo
  clippy` (zero new warnings) and `cargo test` (21/21, including a new
  `fuzzy_subsequence_is_ordered_not_contiguous` case) - not yet
  live-tested in a real picker invocation.

None of the seven implementations above have been exercised against a
running instance yet (the QML pickers only `qmllint`-checked, the Rust
ones only `cargo check`/`test`-checked) - live behavior should be
confirmed via each picker's own keybind before relying on this day to
day.

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
  token still being typed (`/`, `/f`, `/ft `, `/ft cla`, `/s date `, a
  flat-type `/fv/path` with no value yet, an unterminated `"phrase`) is
  inert - contributes no requirement - rather than searched for literally
  as typed. A bare `/` (the empty string as the verb-name fragment) is
  the boundary case here worth calling out explicitly: every verb form
  trivially "starts with" the empty string, so `is_verb_prefix`/
  `isVerbPrefix` needs no special-casing to cover it - a guard excluding
  the empty string (`!s.is_empty()`, `s.length > 0`, `bool(s)`) looks like
  reasonable defensive code but actively reintroduces this exact
  regression, since it makes the very first keystroke of *any* command
  fall through as literal text instead of staying inert. Reported
  2026-09-13 against winswitch (typing `/` alone cleared the whole grid)
  and found identically broken in every hand-written port that had this
  guard (`QueryDsl.qml`, `ClipboardQueryDsl.qml`, `picker.rs`,
  `focus-picker.py`) - window-search.py and claude-history are naturally
  immune, since their regex-based bare-word fallback tokenizes `/` down
  to zero alphanumeric characters and contributes nothing on its own.
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
