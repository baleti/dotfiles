# Picker query DSL

The small query language typed into the search box of every fzf-driven
picker in this repo, plus winswitch's grid search and the GTK
clipboard/notification pickers. Arrived at independently in
`window-search.py`, then reused (by hand, not by import) in
`claude-history` and `focus-picker.py`, then reimplemented in Rust for
winswitch's `query.rs`, then ported by hand a second time into the shared
`picker.rs` engine behind clipboard-picker and notification-picker. Stays
copy-pasted rather than a shared library on purpose — the implementations
split across two languages and differ enough in what they're searching
that a shared abstraction was judged not worth it — so this doc is what
keeps the *semantics* consistent even though the code doesn't.

**Two syntax generations exist side by side, deliberately.** The three GTK
pickers (winswitch, clipboard-picker, notification-picker) use **v2**,
described in full below: `/` instead of `$`, because `$` sits on the shift
layer on both UK and US layouts and `/` doesn't, and a picker's search box
is typed into far more often than it's read about. The three fzf/tmux
pickers (window-search, claude-history, focus-picker) still use **v1**
(`$`) — not an oversight, a scoping choice: v1's terminal/fzf-driven UI
doesn't have (or need) v2's `/sort`/`/reverse` actions or its
GtkFlowBox-native column rendering, and migrating three more working
implementations' muscle memory wasn't asked for alongside this redesign.
Migrating them to v2 later is a natural follow-up, same as winswitch's
autocomplete popup was built and proven once before being asked for
elsewhere — not done here.

| Name | Syntax | File | Searches |
|---|---|---|---|
| window-search | v1 (`$`) | `~/.config/tmux/scripts/window-search.py` | live tmux pane scrollback, BM25-ranked |
| claude-history | v1 (`$`) | `~/bin/claude-history` | saved Claude Code conversation transcripts, BM25-ranked |
| focus-picker | v1 (`$`) | `~/.config/tmux/scripts/focus-picker.py` | tmux panes, MRU-ordered (no ranking) |
| winswitch | v2 (`/`) | `~/.config/hypr/winswitch/src/query.rs` | open windows (Hyprland), grid layout — plus tmux/Claude Code metadata cross-referenced onto them |
| clipboard-picker | v2 (`/`) | `~/.config/hypr/clipboard-picker/src/picker.rs` | cliphist clipboard history, list layout |
| notification-picker | v2 (`/`) | same `picker.rs`, `src/bin/notification-picker.rs` | notifyd's retained notification history |

See [tmux.md](tmux.md) for the tmux bindings and [rust-tools.md](rust-tools.md)
for winswitch and the GTK pickers.

## v1 grammar (`$`) — window-search, claude-history, focus-picker

Unchanged by this revision; kept here in full for reference since v2 below
is best read as a diff against it.

```
"phrase"        exact quoted text — also the escape hatch
!token          negation prefix (window-search/claude-history only)
+$group[.sub]   add a display column (focus-picker only)
-$group[.sub]   remove a display column (focus-picker only)
$field:value    scope value to one field
bareword        everything else
```

- `$field:value` — `field` fuzzy-resolved (substring-containment) against
  the implementation's known field list, unioned across every match.
  window-search/claude-history score `value` (BM25, prefix-expanded);
  focus-picker substring-matches it. An unresolvable field degrades to a
  literal bare-word search over the whole `"$field:value"` text.
- `+$group[.sub]` / `-$group[.sub]` (focus-picker only) — column
  visibility, processed left-to-right against one running ordered set, so
  `-$group.sub` after a `+$group` un-shows just that one column and a
  later `+$group.sub` can re-show it. Never filters.
- `!token` / `!"phrase"` (window-search/claude-history only) — negation.
  `!` over the more conventional `-` specifically because these corpora
  are full of literal minus signs worth searching *for* (`-rf`, `--stat`).
- `"..."` — exact, whitespace-normalized text; also the universal escape
  hatch for `$`/`+$`/`-$`/`!`.
- Bare words — window-search/claude-history: prefix-expanded, BM25-scored,
  required. focus-picker: plain substring, required, unranked (MRU order
  otherwise).

Full detail — the punctuation-carrying "soft literal" bonus, the exact
`MATCH_MODE=all` semantics, why `!` beat `-` — lives in each script's own
comments (`window-search.py`, `claude-history`, `focus-picker.py`), not
duplicated a second time here now that v2 is the actively-developed one.

## v2 grammar (`/`) — winswitch, clipboard-picker, notification-picker

```
"phrase"           exact-whitespace / fuzzy-across-whitespace text — see Quoting
/+path             show a column (path = field, group, group/sub, or group/*)
/-path             hide a column, same path grammar
/action/args...    a data-manipulation action — see Actions
/path[:value]      filter — path = field, group, group/sub, or group/* ; bare group (no ":") = existence check
bareword           everything else — see Bare words
```

Every `/`-token is parsed by looking at what immediately follows the `/`,
in this order:

1. **`+` or `-`** → column visibility (`/+path`, `/-path`). No `:value`
   ever follows here — a visibility token is *only* a path.
2. **A known action verb** (currently just `sort`; see Actions) → an
   action, its own args slash-separated after the verb. Checked *before*
   field/group resolution: action verbs are a small, deliberately fixed
   vocabulary (fuzzy-matched the same way field names are, so `/sor/` is
   as valid as `/sort/`), and none of the current field/group names could
   ever collide with one.
3. **Anything else** → a filter: `path` optionally followed by `:value`.
   `path` is one or more `/`-separated segments (`title`, `tmux/title`,
   `claude/*`); a bare group with no `:` at all (`/tmux`, `/clau`) is an
   *existence* check, not a text search.

The token itself is still found by the same whitespace/quote-aware
tokenizer v1 uses (`tokenize_with_spans`) — only the character *inside*
the token that used to be `$`/`+$`/`-$`/`.` changed to `/`+`/`. A dotted
path is gone entirely: `$tmux.title:foo` is now `/tmux/title:foo`,
`$claude.*:foo` is now `/claude/*:foo`.

### `/path[:value]` — filtering

`path` is one segment (`title`) for a flat field, or two (`tmux/title`)
for a group's subfield. Each segment is fuzzy-resolved by subsequence
match against that level's known name list — `/tsk:foo` reaches
`workspace` (t,s,k appear in order), `/tmux/se:foo` reaches
`tmux/session` — and every match is unioned rather than only the first,
so an ambiguous segment searches every field it could mean.

- **Flat field** (`title`, `class`, `workspace`, `pid` for winswitch;
  `type`/`date` for clipboard-picker; `app`/`date` for
  notification-picker): `/field:value` scopes `value` to just that field,
  subsequence-matched.
- **Group** (winswitch only today — `tmux`, `claude`, cross-referencing an
  open terminal window against the live tmux server and any Claude Code
  session running in it; see `~/.config/hypr/winswitch/src/enrich.rs`):
  - `/group/sub:value` — explicit subfield.
  - `/group:value` — bare group, **defaults to its `title` subfield**, not
    "every subfield." A group's `title` is the one field expected to carry
    a human-meaningful summary (a tmux pane's title, a Claude Code
    conversation's AI-generated name).
  - `/group/*:value` — matches if *any* subfield of the group matches.
    `*` is one hand-parsed reserved segment, **not regex** — nothing in
    this DSL uses a real regex engine (see Design principles); a further
    pattern like `/group/*[0-9]` is out of scope for the same reason.
  - `/group` — bare, **no colon at all**: an *existence* filter, "does
    this window have any data in this group at all" — not a text search.
    Typing just `/clau` alone immediately narrows to claude-hosting
    windows before a colon or value is ever typed. Only meaningful for
    groups (every window always has *some* title); an unresolved or
    still-multi-segment-but-colonless fragment (`/zzz`, `/tmux/se`) is
    still mid-typing, inert (see Design principles), not an existence
    check.
- An **unresolvable field/group** is unmatchable (contributes nothing that
  can match, "narrows to nothing"), not a literal-text fallback — all
  three v2 corpora are small and unranked, so a stray filter reads as
  honest failure rather than a silently degraded search.
- winswitch's group data is gathered **asynchronously**, well after the
  grid is already shown (`enrich.rs` runs off-thread so a slow tmux server
  or a large transcript never delays the grid's first paint). A
  `/tmux/*`/`/claude/*` filter simply doesn't match *yet* on a
  freshly-opened grid and fills in live as enrichment completes — the same
  "absence, not a fallback" rule an unresolved field already had, just
  arriving on a delay. Because a terminal window can be split into several
  panes, "is claude running here" (`/claude`, `/claude/*`) is checked
  across **every visible pane**, not just the focused one; `tmux/title`
  and `tmux/window` stay tied to the *focused* pane specifically, since
  those two describe what's focused.

### `/+path` / `/-path` — column visibility

Now available in **all three** v2 pickers (v1's `+$`/`-$` stayed
focus-picker-only; v2 generalizes it), because all three now render
optional per-entry metadata that's worth hiding by default:

- **winswitch**: each grid cell's label. Default shown: `workspace` and
  `title` (today's existing hardcoded "#N Title" look) — `class`/`pid`
  and any `tmux`/`claude` field are hidden until added.
- **clipboard-picker / notification-picker**: nothing beyond the entry's
  own preview text (or thumbnail). Default shown: **no** extra columns at
  all — `type`/`date`/`app` only appear once you type `/+date` etc. This
  differs from winswitch's default on purpose: winswitch's two defaults
  (workspace, title) are exactly what the grid always showed before this
  DSL existed, so nothing regresses by default; the GTK list pickers never
  had extra columns before, so there's no existing baseline to preserve.

`path` follows the same field/group/sub/`*` grammar as filtering, minus
the `:value` part (a visibility token is a path and nothing else):

- `/+workspace` — show a flat field.
- `/+claude/title` — show one group subfield.
- `/+claude` — show a group's default (`title`) subfield, same
  bare-group-defaults-to-title rule filtering uses.
- `/+claude/*` — show *every* subfield of that group, each as its own
  column.
- `/-workspace`, `/-claude/*`, etc. — the exact mirror, removing whatever
  a `+` (individually or via `*`) added.

Tokens are processed **left to right** against one running ordered set —
`/+claude/* /-claude/path /+claude/path` ends with `claude/path` back
(removed, then re-added), order significant unlike the AND-of-requirements
semantics filtering has. Removing a column that was never shown, or whose
path doesn't resolve, is a silent no-op, not an error. Column-visibility
directives **never filter** — they only ever change what a matched entry
*displays*, a strictly orthogonal concern from which entries survive.

### Actions (`/action/args...`)

New in this revision: v2's first "do something to the result set" syntax,
distinct from filtering (narrows which entries survive) and visibility
(changes what a surviving entry shows). An action's args are always
`/`-separated, never colon-separated — that's the tell that distinguishes
`/sort/date/descending` (action) from `/tmux/title:foo` (filter): the verb
at the front is checked against the small fixed action vocabulary first,
and only falls through to field/group resolution if it isn't one.

Built now, as the base other actions will extend:

- **`/sort/field[/direction]`** — sort the surviving (post-filter) entries
  by `field` (same resolution as a filter's `path`: flat field, or
  `group`/`group/sub` for winswitch — a bare group defaults to `.title`,
  same as filtering; `group/*` is **not** valid here, since a sort key
  has to be one field, not a set). `direction` fuzzy-matches
  `ascending`/`descending`, defaulting to `ascending` if omitted. Only the
  **last** `/sort/` token in a query takes effect (replaces, not stacks —
  simplest predictable behaviour; multi-key sort is a natural but
  unbuilt extension if it's ever actually wanted). Absent entirely, the
  picker's own default order applies unchanged (MRU, cliphist recency,
  winswitch's focus-history order, ...) — sorting is opt-in.
- **`/reverse`** — reverses whatever order is currently in effect
  (default order, or a `/sort/` if also present). No args. Idempotent —
  any number of `/reverse` tokens in one query has the same effect as
  one, not a toggle, since toggling-by-count would be surprising to type
  against. Useful on its own specifically because it can flip a picker's
  *default* order (e.g. see the least-recently-used window first)
  without having to name a field at all.
- **Anticipated, not built**: `/limit/N` (cap the result count) is the
  obvious next one in the same shape — flagged here so the action
  vocabulary and dispatch mechanism are understood to accommodate it
  without a redesign, not implemented until it's actually wanted.

**Sort comparison, precisely** — this is the one place a naive
implementation gets a wrong answer on the very example that motivated it.
Every v2 field is stored and matched as a `String` (that's what makes
subsequence-fuzzy filtering and autocomplete simple and uniform), but
plain lexicographic string comparison is wrong for two field shapes v2
already has:

- **Plain integers** (`workspace`, `pid`): `"10"` sorts before `"2"`
  lexicographically. Wrong for a human reading a workspace/pid list in
  order.
- **Age buckets** (`date`, from `humanize_ago` — `"30s"`, `"5m"`, `"3h"`,
  `"2d"`): comparing the strings is nonsense across units (`"10m"` <
  `"2d"` lexicographically has no relationship to which is actually more
  recent), and even converting to seconds and comparing *that* isn't
  enough on its own — see the direction trap below.

The comparator (`compare_field_values` in each engine's query/picker
module) sniffs the shape of both values being compared and picks the
right rule: both parse as plain non-negative integers → numeric compare;
both match the `humanize_ago` bucket shape (`^\d+[smhd]$`) → convert to
seconds and compare *that*; otherwise → plain lexicographic string
compare (the correct behaviour already for `type`/`class`/`title`/`app`
and anything else that's genuinely just text).

**The direction trap**: `date`'s stored value is an *age* (seconds ago),
not an absolute timestamp — smaller age means *more recent*. A user
typing `/sort/date/descending` means "newest first" (the ordinary,
calendar sense of "descending date"), which is **ascending by age in
seconds** (smallest age first) — the literal opposite of what "descending"
would mean applied to the raw number. So for age-bucket-shaped values
specifically, the requested direction is inverted before it reaches the
numeric comparison: `ascending` (oldest first, chronologically) compares
by age *descending* (largest age first) internally, and `descending`
(newest first) compares by age *ascending* internally. Plain-integer and
text fields apply the requested direction literally, with no such
inversion — the trap is specific to values that represent "time since,"
not comparison in general.

### Quoting

Doubles, everywhere, as the **literal escape hatch** for every prefix
character this grammar reserves (`/`, `+`, `-`): checked first at each
token position, so `"+something"` always means those literal characters,
never a visibility directive. Beyond that, quoting means "let this span
whitespace" rather than "exact" — the same design v1's window-search/
claude-history/focus-picker do *not* share (their quoting means exact,
literal text; see the v1 section above and each script's own comments).
v2's tokenizer otherwise splits on every whitespace run, which would
normally make a multi-word field name or value impossible to type as one
unit (`/title:imperial rome` would become two separate tokens). Quoting —
`/title:"imperial rome"`, `/app:"discord canary"` — keeps the run as one
token, still matched by the *same* subsequence() fuzzy-match an unquoted
`/field:value` already uses, not a literal comparison: `/title:"imp rom"`
matches "Imperial Rome" the identical way `/title:imp` already
fuzzy-matches "Imperial", because subsequence() treats a literal space in
the needle as just another character to find in order.

This upgrade applies to bare (non-`/`) quoted text too in **winswitch**:
`"imp rom"` alone, quoted, subsequence-matches title+class; unquoted
`imp rom` still ANDs two independent substring tests the older way, order
not enforced. It does **not** apply the same way in
**clipboard-picker/notification-picker**, because their bare words were
never independent tokens to begin with — multiple free words there always
join into one space-separated phrase, matched as a single literal run
against `Entry::haystack` (predates this DSL work, left as-is — see
`picker.rs`'s module doc). Quoting a free word there still works as the
reserved-character escape hatch, but doesn't change *how* free text
matches.

### Bare words

No `/`, no quotes — the always-available default with no syntax to learn
(see Design principles). **winswitch**: substring test against
`title + " " + class`, required, unranked — subsequence instead if quoted
(see Quoting). **clipboard-picker / notification-picker**: every bare
word joins into one space-separated phrase, matched as one literal
substring against `Entry::haystack` (clipboard preview; app+summary+body
for notifications) — the strictest of the three, `hello world` requires
that exact contiguous run, not "hello" and "world" independently present.

## Autocompletion

Typing `/` alone should be enough to discover what exists — an empty
fragment is otherwise indistinguishable from "not typed yet." All three
v2 pickers grow a real GTK-native completion popup (not fzf-driven, since
these aren't fzf-backed) covering every stage of the grammar, not just the
field name:

1. **Top-level** (`/fragment`, nothing else typed yet): candidates are
   every flat field, group, and action verb that fuzzy-matches
   `fragment`, **plus** the two literal characters `+` and `-` as their
   own candidates. Accepting `+`/`-` inserts just that character (no
   trailing `:` or space) and immediately re-triggers completion one
   level down.
2. **After `+`/`-`** (`/+fragment`, `/-fragment`): candidates are fields
   and groups only — no action verbs (an action can't be shown/hidden),
   no further `+`/`-`. Accepting inserts the path segment with **no**
   trailing punctuation — a visibility token is complete the moment its
   path is (`/+claude` is already valid on its own, unlike a filter's
   `/claude:`).
3. **After a group + `/`** (`/tmux/fragment`, in any of the three
   contexts above): candidates are that group's subfields plus `*`.
4. **After an unambiguous field/group + `:`** (`/title:fragment`,
   filtering only): candidates are every distinct, non-empty value that
   field actually has across the current entries right now, fuzzy-
   narrowed by `fragment`, deduplicated and sorted — this is what answers
   `/workspace:` with the workspaces that actually exist this instant,
   not a hardcoded guess, and is the one stage genuinely scoped to these
   corpora being small (a couple dozen windows, a few hundred
   clipboard/notification entries at most).
5. **After `/sort/` + an unambiguous field** (`/sort/date/fragment`):
   candidates are `ascending`/`descending`, fuzzy-narrowed the same way.

Shared UI across all five stages, in all three pickers: a plain in-layout
`GtkListBox` under the search entry (not a `GtkPopover` — gtk-layer-
shell's layer surface has no xdg_popup positioner to anchor one to),
narrowed on every keystroke off the same signal that drives the
underlying filter. `Tab` accepts the highlighted suggestion; `Ctrl+j`/
`Ctrl+k` move the highlight (clamped, not wrapped); `Escape` dismisses
just the popup, never the picker itself, while it's showing. One real bug
worth remembering if this popup ever silently stops appearing again: a
`GtkListBox` built with `no-show-all` (so the picker's own one-time
startup `show_all()` doesn't prematurely reveal an empty popup) also
ignores a *later* `show_all()` meant to reveal it — the flag guards the
widget it's set on, not just descendants an ancestor's recursive call
reaches. Every row/label has to be shown explicitly, the list itself
revealed with a direct `.show()`.

## Fuzzy resolution, precisely

- **v1** (window-search/claude-history/focus-picker): field/group names —
  substring-containment. Bare words and `$field:` values — window-search/
  claude-history: prefix-expansion against the corpus vocabulary, BM25-
  scored; focus-picker: plain substring.
- **v2** (winswitch and the GTK pickers): every level — path segments,
  filter values, action verbs, sort direction — subsequence match
  (`subsequence("crit","alacritty")` is true: every character of the
  needle appears in the haystack in order, not necessarily contiguous).
  Chosen because every v2 corpus is tiny (a couple dozen windows; a few
  hundred clipboard/notification entries), so subsequence's looser feel
  costs nothing in precision at that scale. The same algorithm powers
  autocompletion's narrowing at every stage — one algorithm doing double
  duty for filtering and suggestion-ranking throughout v2. Bare words are
  plain substring in v2 (winswitch unquoted; both GTK pickers always) —
  see Bare words above for why subsequence isn't used there.

## Design principles

- **Never flash to zero results on a valid-so-far partial keystroke.** A
  token that's mid-typed (`/`, `/ti`, `/+`, `/tmux/`, `/sort/`, an
  unterminated `"phrase`) is inert — contributes no requirement — rather
  than literal-searched-for-as-typed.
- **...but a genuinely unresolvable, *complete* v1 token still degrades
  to a literal search** (`$zzz:foo` → literal search for `"zzz:foo"`),
  since a typo'd prefix in front of real search text is still a real
  search someone typed. v2 is the exception (see filtering above) — its
  small, unranked corpora make "matches nothing" the more honest answer.
- **Every picker keeps one plain-typing default with no special syntax at
  all.** Whatever `/field:value`/`$field:value` a picker grows, typing
  without any prefix character must always still search *something*
  sensible by default — clipboard contents, window title+class, pane
  scrollback, notification summary/body/app. This is what makes the DSL
  additive, never a wall a casual user has to learn first.
- **No real regex anywhere in this DSL.** Every fuzzy match is
  substring-containment, subsequence, or prefix-expansion. `/group/*` is
  one hand-parsed reserved segment, not a wildcard engine.
- **Column-visibility directives never filter.** `/+`/`/-` (v2) and
  `+$`/`-$` (v1, focus-picker) change what's *shown*, never what
  *matches* — orthogonal to filtering by construction.
- **Actions never filter or hide either** (v2). `/sort`/`/reverse`
  reorder what filtering already decided should survive; they never
  change which entries survive.
- **Quoting is the universal escape hatch**, checked before every other
  grammar form, so any reserved-character text a user actually wants to
  search for verbatim is always reachable.
- **Field/group name resolution is never plain prefix matching** — an
  abbreviation doesn't have to start at the beginning of the real name.
- **AND, not OR, across distinct filter tokens.** Every requirement a
  query expresses must all be satisfied by a surviving entry.
- **Selection follows the user, not the query — where there's no reason
  for it to follow something else.** clipboard-picker and
  notification-picker open with nothing selected; the first explicit
  navigation selects the top visible entry, and a selection a later
  keystroke filters out of view is cleared rather than left dangling.
  `Enter` with nothing selected still activates the top visible entry.
  winswitch's grid is the deliberate exception — it still auto-selects on
  open, because landing on the previously active window the instant a
  single Alt+Tab tap completes is the entire point of classic alt-tab
  behaviour.
