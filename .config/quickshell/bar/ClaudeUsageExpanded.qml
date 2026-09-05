import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "../theme"
import "../services"
import "../launcher" // QueryDsl -- shared picker DSL, see query-dsl.md

// Detail panel for ClaudeUsagePill: session%/weekly% (+ reset time) for
// each of the 3 Claude Code accounts on this machine, plus the poller's
// current adaptive-interval tier so it's obvious why a number looks stale.
// Same sibling-overlay / collapses-to-0-height-when-closed shape as
// MediaExpanded/CalendarExpanded, click/CTRL+ALT+c-toggled only -- no
// hover-open. Takes real keyboard focus on open the same way media/
// calendar do (Bar.qml wires onExpandedChanged the same way, and
// root.Keys.onPressed there handles Escape while this is the open panel)
// -- originally left out of that machinery since nothing here needed
// arrow-key nav, reversed once Escape-to-close was requested, since that
// needs the same real focus grab the other panels use.
Rectangle {
    id: root

    property bool expanded: false
    // Set from Bar.qml (root.screen, this bar instance's own monitor) --
    // used only to find that monitor's own currently-active workspace
    // (root.activeWorkspaceName), to highlight a matching row in the
    // hyprland column group's "#" column.
    property var screen: null
    readonly property string activeWorkspaceName: {
        const ws = root.screen
            ? Hyprland.workspaces.values.find(w => w.active && w.monitor && w.monitor.name === root.screen.name)
            : null;
        return ws ? ws.name : "";
    }
    property real panelWidth: 320
    // Set from Bar.qml (root.maxPanelHeight, screen-height-derived, same
    // as CalendarExpanded); this fallback only matters for a standalone
    // preview. "As tall as the monitor allows" per-request -- no fixed
    // small cap -- but real per-account process counts (20-40 alive here)
    // routinely exceed even that combined across all 3, so
    // root.processAreaBudget below still has to truncate with a "+N more"
    // line rather than ever actually fitting everything unconditionally.
    property real maxPanelHeight: 700

    width: panelWidth
    implicitHeight: expanded ? Math.min(content.implicitHeight + 24, root.maxPanelHeight) : 0
    height: implicitHeight
    visible: height > 0
    clip: true
    radius: Theme.rounding
    color: Theme.bgAlpha
    border.color: Theme.border
    border.width: 1

    readonly property bool hovered: mouseArea.containsMouse

    // A HoverHandler/MouseArea's "hovered" flips true the instant the panel
    // appears under a cursor that never actually moved (no real move event
    // needed -- just geometry containment on creation), which made the
    // process-row hover highlight below light up a row on every open purely
    // from wherever the mouse happened to be sitting. Gate that highlight on
    // an explicit "the mouse has genuinely moved since this open" flag
    // instead.
    //
    // Turns out positionChanged isn't the clean "only real input" signal
    // that first looked like -- reopening the panel (height 0 -> N under a
    // cursor that never moved) *does* fire a synthetic one too, just like
    // containsMouse, because Qt re-delivers hover to an existing MouseArea
    // whenever its geometry changes under the pointer (a fresh initial
    // creation doesn't go through that path, which is why a true first-ever
    // open never showed this -- only reopening did, reported 2026-09-05).
    // So a bare "flag true on the first positionChanged" reintroduces the
    // exact bug on every reopen.
    //
    // Fix: a short one-shot settle timer (no repeating poll -- negligible
    // CPU) ignores every positionChanged for the first settleMs after open,
    // long enough for that synthetic reopen event to fire and be dropped.
    // The moment the timer fires, it snapshots the current hover position
    // as the reference -- from then on, ANY positionChanged whose position
    // differs from that reference (even the very first one) counts as real
    // movement, so genuine motion right after the settle window is
    // detected immediately (no more requiring a second move like the
    // previous baseline-diffing version did, reported as "have to really
    // move the mouse").
    property bool mouseMovedSinceOpen: false
    property bool _hoverSettled: false
    property point _hoverRefPos: Qt.point(0, 0)
    readonly property int hoverSettleMs: 200

    Timer {
        id: hoverSettleTimer
        interval: root.hoverSettleMs
        repeat: false
        onTriggered: {
            root._hoverRefPos = Qt.point(mouseArea.mouseX, mouseArea.mouseY);
            root._hoverSettled = true;
        }
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.AllButtons
        onWheel: wheel => wheel.accepted = true
    }

    // Watches mouseX/mouseY directly (their own elemental change signals)
    // rather than MouseArea's composite positionChanged -- reported still
    // insensitive to a real first move even after positionChanged was
    // made maximally eager (flagging on its very first firing, no
    // baseline/second-event requirement at all), which points at
    // positionChanged itself not reliably firing promptly here rather than
    // at any counting/threshold logic. mouseX/mouseYChanged are the more
    // primitive per-property notifications underneath it and should track
    // every real pointer update Qt actually receives.
    function _checkMouseMoved() {
        if (!root._hoverSettled)
            return;
        if (mouseArea.mouseX !== root._hoverRefPos.x || mouseArea.mouseY !== root._hoverRefPos.y)
            root.mouseMovedSinceOpen = true;
    }
    Connections {
        target: mouseArea
        function onMouseXChanged() { root._checkMouseMoved(); }
        function onMouseYChanged() { root._checkMouseMoved(); }
    }

    // Coarse "bigUnit smallUnit" for a duration in seconds, e.g. "5m",
    // "2h 14m", "1d 3h", "2w 4d", "3mo 1w", "1y 2mo" -- shared by the
    // per-limit reset countdown, the backoff/staleness lines, and the
    // process list's "last active" column. Months/years are approximated
    // (30d/365d) since this is a coarse "roughly how long" readout, not a
    // calendar computation -- some sessions here go back weeks, so hours-
    // only (the original version of this) rolled over into meaningless
    // "410h" instead of "17d 2h".
    function fmtDuration(totalS) {
        const s = Math.max(0, Math.round(totalS));
        if (s < 60)
            return qsTr("%1s").arg(s);
        if (s < 3600)
            return qsTr("%1m").arg(Math.floor(s / 60));
        if (s < 86400) {
            const h = Math.floor(s / 3600);
            const m = Math.floor((s % 3600) / 60);
            return qsTr("%1h %2m").arg(h).arg(m);
        }
        if (s < 7 * 86400) {
            const d = Math.floor(s / 86400);
            const h = Math.floor((s % 86400) / 3600);
            return qsTr("%1d %2h").arg(d).arg(h);
        }
        if (s < 30 * 86400) {
            const w = Math.floor(s / (7 * 86400));
            const d = Math.floor((s % (7 * 86400)) / 86400);
            return qsTr("%1w %2d").arg(w).arg(d);
        }
        if (s < 365 * 86400) {
            const mo = Math.floor(s / (30 * 86400));
            const w = Math.floor((s % (30 * 86400)) / (7 * 86400));
            return qsTr("%1mo %2w").arg(mo).arg(w);
        }
        const y = Math.floor(s / (365 * 86400));
        const mo = Math.floor((s % (365 * 86400)) / (30 * 86400));
        return qsTr("%1y %2mo").arg(y).arg(mo);
    }

    // "resets in Xd Yh" -- ISO8601 in. null (an account whose tier wasn't
    // returned, e.g. it's disabled) reads as "--", not "resets in NaN".
    function fmtResets(iso) {
        if (!iso)
            return "--";
        const target = new Date(iso).getTime();
        if (isNaN(target))
            return "--";
        const deltaS = Math.round((target - Date.now()) / 1000);
        return deltaS <= 0 ? qsTr("resetting") : qsTr("resets in %1").arg(root.fmtDuration(deltaS));
    }

    // Raw "12s" / "4m" / "2d 3h" -- no "ago" baked in, so this doubles as
    // both the mode-line staleness readout (which adds its own " ago") and
    // the process list's "last active" column (which doesn't).
    function fmtAgo(iso) {
        if (!iso)
            return qsTr("never");
        const t = new Date(iso).getTime();
        if (isNaN(t))
            return qsTr("never");
        return root.fmtDuration((Date.now() - t) / 1000);
    }

    readonly property string homeDir: Quickshell.env("HOME") || ""

    // "/home/user1/foo" -> "~/foo" (or "~" for the home dir itself); left
    // as-is otherwise. Paired with Text.ElideLeft at the call site so a
    // long path still shows its most identifying (rightmost) part.
    function shortCwd(cwd) {
        if (!cwd)
            return "";
        if (cwd === root.homeDir)
            return "~";
        if (root.homeDir && cwd.startsWith(root.homeDir + "/"))
            return "~" + cwd.slice(root.homeDir.length);
        return cwd;
    }

    // 274308 -> "274k", 850 -> "850", null/undefined -> "--". Context
    // tokens routinely run into the hundreds of thousands here, so this
    // stays readable at a glance instead of a long raw digit string.
    function fmtTokens(n) {
        if (typeof n !== "number")
            return "--";
        if (n < 1000)
            return String(n);
        return (n / 1000).toFixed(n < 10000 ? 1 : 0) + "k";
    }

    function fmtAgoMs(ms) {
        return ms ? root.fmtAgo(new Date(ms).toISOString()) : qsTr("never");
    }

    // No dynamically-discoverable "context window before auto-compact"
    // figure exists anywhere reachable here -- checked the /usage
    // endpoint's response (session/weekly rate-limit percentages only, no
    // per-turn context size), each sessions/<pid>.json (no such field),
    // and real transcripts' own "usage" objects (input/cache/output token
    // counts only, no window-size or compact-threshold value alongside
    // them). Static fallback per request 2026-09-02: assume 1,000,000.
    readonly property real maxContextTokens: 1000000
    // Same theme-derived ramp session/weekly % already use (Theme.cyan-
    // to-red, wallpaper-recolored) -- calm/cool low, vivid/red near the
    // assumed compaction point, so a context that's getting full reads at
    // a glance the same way a rate limit nearing 100% does.
    function tokenColor(n) {
        if (typeof n !== "number")
            return Theme.textDim;
        return Theme.rampColor(Theme.norm(n, 0, root.maxContextTokens));
    }

    readonly property var statusColors: ({
        "busy": Theme.red,
        "waiting": Theme.orange,
        "idle": Theme.muted,
    })
    function statusColor(status) {
        return root.statusColors[status] || Theme.textDim;
    }
    // "waiting" is visibly wider than "busy"/"idle" -- abbreviated so the
    // fixed-width status column in each single-line process row doesn't
    // have it run into the pid field right after it with no gap (a real
    // bug the first version of this row layout had).
    readonly property var statusLabels: ({
        "busy": qsTr("busy"),
        "waiting": qsTr("wait"),
        "idle": qsTr("idle"),
    })
    function statusLabel(status) {
        return root.statusLabels[status] || status || "?";
    }

    readonly property var pollModeLabels: ({
        "locked": qsTr("polling hourly (locked/screen off)"),
        "active": qsTr("polling every 2m (active)"),
        "idle": qsTr("polling every 5m (idle)"),
    })

    // Backoff isn't a fixed label like the other 3 tiers -- it's a live
    // countdown to when polling resumes, computed from updated_at (when
    // this backoff started) + poll_interval_s (how long it runs), same
    // pair every other mode uses for its own bookkeeping.
    function modeLine() {
        if (ClaudeUsageSvc.pollMode === "backoff") {
            const resumeMs = new Date(ClaudeUsageSvc.updatedAt).getTime() + ClaudeUsageSvc.pollIntervalS * 1000;
            const deltaS = Math.round((resumeMs - Date.now()) / 1000);
            return qsTr("rate limited (429) -- retrying in %1").arg(root.fmtDuration(Math.max(0, deltaS)));
        }
        return root.pollModeLabels[ClaudeUsageSvc.pollMode] || qsTr("Claude usage");
    }

    // Re-render the relative-time strings once a second while open -- they
    // read off Date.now()/live deltas, which QML has no binding source for
    // on its own.
    Timer {
        interval: 1000
        running: root.expanded
        repeat: true
        onTriggered: root.tick = root.tick + 1
    }
    property int tick: 0

    // Single flat table across every account (request 2026-09-05: "instead
    // of 3 separate tables grouped by account, let's have a single table")
    // with an "acct" column identifying which account each row came from
    // -- no more per-account fold state, and one sort applies to the whole
    // table instead of one independent sort per account.
    property var sort: null

    // 1-based position of `account` in ClaudeUsageSvc.accounts -- the bare
    // number the "acct" column shows (hover for the real name) and what
    // its column-sort compares on.
    function acctIndex(account) {
        for (let i = 0; i < ClaudeUsageSvc.accounts.length; i++)
            if (ClaudeUsageSvc.accounts[i].account === account)
                return i + 1;
        return 0;
    }

    // Conversation count + summed context tokens for one account -- the
    // per-account tally line below the table (request 2026-09-05).
    function acctTotals(account) {
        let count = 0, tokens = 0;
        for (const row of (ClaudeUsageSvc.sessions[account] || [])) {
            count++;
            if (typeof row.context_tokens === "number")
                tokens += row.context_tokens;
        }
        return { count: count, tokens: tokens };
    }

    // ---- search box: shared picker query DSL (query-dsl.md / QueryDsl.qml)
    // -- same grammar as the app launcher and RSS reader, "/" to focus, same
    // import (not a port) per that doc's own "stays copy-pasted... add a new
    // consumer, add its row" convention. A flat list of rows (the single
    // merged table, all 3 accounts) rather than a variable column view, so
    // /ft /at /rt are inert (same call the RSS reader made for the same
    // reason) -- only /fv (bare text or field:value) and /s /rv actually
    // do anything. Its /s /rv, when present, override the table's own
    // column-click sort (root.sort).
    property string searchText: ""
    readonly property var searchTypeNames: [
        "title", "pid", "status", "tokens", "path", "account",
        "tmux.session", "tmux.window", "tmux.pane",
        "hypr.workspace", "hypr.monitor", "hypr.window",
    ]
    readonly property var searchParsed: QueryDsl.parse(root.searchText)
    function _searchFieldVals(row, field, account) {
        switch (field) {
        case "title": return [row.title || ""];
        case "pid": return [String(row.pid)];
        case "status": return [row.status || ""];
        case "tokens": return [row.context_tokens !== null && row.context_tokens !== undefined ? String(row.context_tokens) : ""];
        case "path": return [root.shortCwd(row.cwd)];
        case "account": return [account];
        case "tmux.session": return [row.tmux_session || ""];
        case "tmux.window": return [row.tmux_window || ""];
        case "tmux.pane": return [row.tmux_pane || ""];
        case "hypr.workspace": return [row.hypr_workspace || ""];
        case "hypr.monitor": return [row.hypr_monitor || ""];
        case "hypr.window": return [row.hypr_address || ""];
        }
        return [];
    }
    function _searchMatches(row, term, account) {
        if (term.text !== undefined) {
            const hay = (row.title + " " + row.pid + " " + (row.status || "") + " "
                         + root.shortCwd(row.cwd) + " " + account).toLowerCase();
            return hay.indexOf(term.text) >= 0;
        }
        const fields = QueryDsl.resolvePath(term.field, root.searchTypeNames);
        if (fields.length === 0)
            return false; // unresolvable complete path -> narrows to nothing
        for (const f of fields) {
            for (const v of root._searchFieldVals(row, f, account)) {
                if (String(v).toLowerCase().indexOf(term.value) >= 0)
                    return true;
            }
        }
        return false;
    }
    function focusSearch() {
        searchInput.forceActiveFocus();
        searchInput.selectAll();
    }

    // ---- single merged process table across every account -------------
    // Every alive process across every account, tagged with which account
    // it's from -- what the one flat table is built from now, replacing
    // the old per-account Repeater-of-Repeaters shape.
    readonly property var allProcs: {
        const out = [];
        for (const a of ClaudeUsageSvc.accounts)
            for (const row of (ClaudeUsageSvc.sessions[a.account] || []))
                out.push(Object.assign({ account: a.account }, row));
        return out;
    }
    readonly property var searchFilteredProcs: {
        root.searchParsed; // dependency
        const terms = root.searchParsed.terms;
        if (terms.length === 0)
            return root.allProcs;
        return root.allProcs.filter(p => terms.every(t => root._searchMatches(p, t, p.account)));
    }
    // Column-header-click sort (root.sort) falls back to a global
    // most-recent-first sort by age when nothing's been clicked, so rows
    // from all 3 accounts interleave by actual recency instead of sitting
    // in account-then-recency-within-account blocks (reported 2026-09-05:
    // merging the 3 tables into one still showed every account-1 row
    // before any account-2/3 row -- each account alone had enough
    // sessions to fill the row budget on its own, since the un-sorted
    // fallback used to just be root.allProcs's own concatenation order).
    // The search box's own /s /rv, when present, overrides it (see
    // root.searchParsed).
    readonly property var sortedProcs: {
        const base = root.searchFilteredProcs;
        const s = root.searchParsed.sort;
        // Each chain segment must resolve to exactly one field
        // (query-dsl.md "/sort"); any segment that doesn't makes the
        // *whole* /sort inert, not just that key.
        const sortFields = s ? s.fields.map(p => QueryDsl.resolvePath(p, root.searchTypeNames)) : null;
        let arr;
        if (s && sortFields.every(fl => fl.length === 1)) {
            const keys = sortFields.map(fl => fl[0]);
            arr = base.slice().sort((a, b) => {
                for (const f of keys) {
                    const av = root._searchFieldVals(a, f, a.account)[0] || "";
                    const bv = root._searchFieldVals(b, f, b.account)[0] || "";
                    // Shared comparator (QueryDsl.compareFieldValues):
                    // numeric-sniffs plain ints (tokens/pid) so "100" sorts
                    // after "2" instead of before it, same rule the
                    // column-header click sort (root.compareForSort)
                    // already applies.
                    const c = QueryDsl.compareFieldValues(av, bv, s.dir);
                    if (c !== 0) return c;
                }
                return 0;
            });
        } else if (root.sort) {
            arr = base.slice().sort((a, b) => root.compareForSort(a, b, root.sort.col));
            if (!root.sort.asc)
                arr.reverse();
        } else {
            // Default: most-recently-active first, i.e. descending age --
            // compareForSort's "active" case is ascending (oldest first),
            // so swap the comparator args rather than sort-then-reverse.
            arr = base.slice().sort((a, b) => root.compareForSort(b, a, "active"));
        }
        return root.searchParsed.reverse ? arr.slice().reverse() : arr;
    }

    // ---- cursor-following hover hint (header abbreviations, acct cells) ----
    // Shared by every abbreviated column header (wks/sess/win/tkns) and the
    // "acct" column's per-row value -- follows the cursor like the
    // hyprland-column thumbnail below rather than sitting at a fixed spot
    // next to the header, which the cursor itself ended up occluding
    // (reported 2026-09-05).
    property string hintText: ""
    property point hintPos: Qt.point(0, 0)
    function showHint(text) {
        root.hintText = text;
    }
    function moveHint(rootPos) {
        root.hintPos = Qt.point(rootPos.x + 12, rootPos.y + 16);
    }
    function hideHint() {
        root.hintText = "";
    }

    // ---- search box autocomplete (Tab-triggered, marginalia-style) ----
    // Ported from rssreader/RssReader.qml's identical block (itself
    // mirroring launcher/AppLauncher.qml) -- ~/.config/docs/query-dsl.md
    // says every DSL consumer gets this, and this one didn't yet (gap
    // reported 2026-09-02). /ft /at /rt excluded from _acVerbs same as
    // the RSS reader: this is a fixed set of columns per row, not a
    // variable column view, so those verbs are inert here too.
    readonly property var searchTypeDescs: ({
        "title": "process/tmux pane title",
        "pid": "process id",
        "status": "busy / wait / idle",
        "tokens": "context tokens used",
        "path": "working directory",
        "account": "claude / claude2 / claude3",
        "tmux.session": "tmux session id",
        "tmux.window": "tmux window id",
        "tmux.pane": "tmux pane id",
        "hypr.workspace": "hyprland workspace",
        "hypr.monitor": "hyprland monitor",
        "hypr.window": "hyprland window address",
    })
    readonly property var _acVerbs: ["/fv", "/s", "/rv"]

    function _isVerbPrefix(v) {
        if (v.length <= 1) return false;
        const forms = QueryDsl.shortVerbs.concat(Object.keys(QueryDsl.verbAliases));
        return forms.some(f => f.startsWith(v));
    }

    // Every `/`-led token in `text` that's unambiguously a command attempt
    // - {start, end, valid} for each. Same as AppLauncher.qml/RssReader.qml's
    // identical copies (query.rs::command_spans).
    function _commandSpans(text) {
        const spans = [];
        let i = 0;
        while (i < text.length) {
            while (i < text.length && text[i] === " ") i++;
            if (i >= text.length) break;
            const start = i;
            if (text[i] === '"') {
                const end = text.indexOf('"', i + 1);
                i = end < 0 ? text.length : end + 1;
                continue;
            }
            let j = i;
            while (j < text.length && text[j] !== " ") j++;
            const tok = text.slice(i, j);
            i = j;
            if (tok.length > 1 && tok[0] === "/") {
                if (QueryDsl.canonVerb({ q: false, v: tok })) {
                    spans.push({ start, end: start + tok.length, valid: true });
                } else if (!root._isVerbPrefix(tok)) {
                    spans.push({ start, end: start + tok.length, valid: false });
                }
            }
        }
        return spans;
    }

    // Distinct non-empty values a resolved field has across every visible
    // process right now, substring-narrowed by `frag`, sorted.
    function _fieldValueCandidates(field, frag) {
        const fields = QueryDsl.resolvePath(field, root.searchTypeNames);
        if (fields.length !== 1)
            return [];
        const f = fields[0], seen = ({}), out = [];
        for (const a of ClaudeUsageSvc.accounts) {
            const account = a.account;
            for (const row of (ClaudeUsageSvc.sessions[account] || [])) {
                for (const raw of root._searchFieldVals(row, f, account)) {
                    const s = String(raw).trim();
                    const key = s.toLowerCase();
                    if (!s || seen[key] || (frag && key.indexOf(frag) < 0))
                        continue;
                    seen[key] = true;
                    out.push(s);
                }
            }
        }
        return out.sort();
    }

    function _acCandidates() {
        const t = root.searchText;

        const vm = t.match(/(?:^|\s)(\/[a-z-]*)$/);
        if (vm) {
            const frag = vm[1].slice(1);
            return root._acVerbs.filter(v => v.indexOf(frag) >= 0).map(v => ({
                text: v + " ", label: v,
                alias: QueryDsl.verbInfo[v].long, desc: QueryDsl.verbInfo[v].desc
            }));
        }

        const val = t.match(/(?:^|\s)\/(?:fv|filter-value)(?:\/([a-z.]+)\s+([^\s:]*)|\s+([a-z.]+):([^\s:]*))$/);
        if (val) {
            const field = (val[1] || val[3]).toLowerCase();
            const frag = (val[2] !== undefined ? val[2] : val[4]).toLowerCase();
            const base = t.slice(0, t.length - frag.length);
            return root._fieldValueCandidates(field, frag).slice(0, 40)
                .map(v => ({ text: base + v, label: v, alias: "", desc: "" }));
        }

        const dir = t.match(/(?:^|\s)\/(?:s|sort)(?:\/[a-z.]+|\s+[a-z.]+)\s+([a-z]*)$/);
        if (dir) {
            const frag = dir[1].toLowerCase();
            const base = t.slice(0, t.length - frag.length);
            return ["ascending", "descending"].filter(d => d.indexOf(frag) === 0)
                .map(d => ({ text: base + d, label: d, alias: "", desc: "" }));
        }

        const vp = t.match(/(?:^|\s)\/(fv|filter-value|s|sort)\/([a-z.]*)$/);
        if (vp) {
            const frag = vp[2];
            const base = t.slice(0, t.length - frag.length);
            return root.searchTypeNames.filter(n => n.indexOf(frag) >= 0).map(n => ({
                text: base + n + " ", label: n, alias: "", desc: root.searchTypeDescs[n] || ""
            }));
        }

        const pm = t.match(/(?:^|\s)\/(fv|filter-value|s|sort)\s+([a-z.]*)$/);
        if (pm && pm[2].indexOf(":") < 0) {
            const frag = pm[2];
            const head = t.slice(0, t.length - frag.length).replace(/\s+$/, "/");
            return root.searchTypeNames.filter(n => n.indexOf(frag) >= 0).map(n => ({
                text: head + n + " ", label: n, alias: "", desc: root.searchTypeDescs[n] || ""
            }));
        }

        return [];
    }
    property var acItems: []
    property int acSel: 0
    property bool acDismissed: false
    readonly property bool acOpen: acItems.length > 0 && !acDismissed
    onAcItemsChanged: { acSel = 0; acDismissed = false; }

    function _applyAcItem(it) {
        if (!it) return;
        root.searchText = it.text;
        searchInput.text = it.text;
        searchInput.cursorPosition = searchInput.text.length;
    }
    function acAccept() {
        root._applyAcItem(root.acItems[root.acSel]);
    }
    function triggerCompletion() {
        const items = root._acCandidates();
        if (items.length === 0) return false;
        if (items.length === 1) {
            root._applyAcItem(items[0]);
            return true;
        }
        root.acSel = 0;
        root.acItems = items;
        return true;
    }

    // View-state resets on every panel open *and* close -- this Rectangle
    // instance is never destroyed (only its height collapses to 0, same
    // "sibling overlay" pattern as Media/CalendarExpanded), so without
    // this a sort or a manual column resize from one look at the panel
    // would silently still be there next time.
    onExpandedChanged: {
        root.sort = null;
        root.mouseMovedSinceOpen = false;
        root._hoverSettled = false;
        if (root.expanded)
            hoverSettleTimer.restart();
        else
            hoverSettleTimer.stop();
        // root.searchText alone doesn't clear the box -- searchInput.text
        // only flows one way into it (onTextChanged), so the TextInput's
        // own text needs setting directly too (reported 2026-09-01: box
        // still had the last query on reopen).
        searchInput.text = "";
        root.searchText = "";
        root.resetColumnWidths();
    }

    function toggleSort(col) {
        root.sort = (root.sort && root.sort.col === col)
            ? { col: col, asc: !root.sort.asc }
            : { col: col, asc: true };
    }
    function sortArrow(col) {
        return (root.sort && root.sort.col === col) ? (root.sort.asc ? " ▲" : " ▼") : "";
    }
    // undefined/null (context_tokens can be either for a session with no
    // recorded usage yet) sorts as lower than any real number, in both
    // directions -- "no data" reads more sensibly grouped at one end than
    // scattered wherever 0 would fall.
    function compareForSort(a, b, col) {
        switch (col) {
        case "acct": return root.acctIndex(a.account) - root.acctIndex(b.account);
        case "status": return (a.status || "").localeCompare(b.status || "");
        case "title": return (a.title || "").localeCompare(b.title || "");
        case "pid": return (a.pid || 0) - (b.pid || 0);
        case "tokens": return (a.context_tokens ?? -1) - (b.context_tokens ?? -1);
        case "path": return root.shortCwd(a.cwd).localeCompare(root.shortCwd(b.cwd));
        // tmux/hyprland are *grouped* columns visually, but each
        // sub-column sorts independently -- only these, never the group
        // label itself (that has no click action at all, see the header
        // row below: "there should be no action when user clicks on
        // [tmux/hyprland]... only subcolumns should be capable of
        // sorting", 2026-09-02).
        case "tmuxSession": return (Number(a.tmux_session) || 0) - (Number(b.tmux_session) || 0);
        case "tmuxWindow": return (Number(a.tmux_window) || 0) - (Number(b.tmux_window) || 0);
        case "tmuxPane": return (Number(a.tmux_pane) || 0) - (Number(b.tmux_pane) || 0);
        case "active": return (a.updated_at_ms || 0) - (b.updated_at_ms || 0);
        case "hyprWorkspace": return (Number(a.hypr_workspace) || 0) - (Number(b.hypr_workspace) || 0);
        case "hyprMonitor": return (a.hypr_monitor || "").localeCompare(b.hypr_monitor || "");
        default: return 0;
        }
    }

    // Row/header height estimates (not measured live), calibrated against
    // real screenshots rather than guessed once and left alone -- used to
    // size the scrollable row-viewport (root.processAreaBudget) and the
    // scrollbar thumb. `root.clip: true` on the viewport is the actual
    // backstop against a rare 1-2px partial last row, not a promise of
    // zero clipping.
    readonly property int rowH: 17
    readonly property int groupHeaderH: 45
    // The per-account totals line below the table (request 2026-09-05:
    // "add total tally of each account conversations, tokens").
    readonly property int tallyLineH: 18
    // Search box Rectangle (22px) + the one extra `content` Column
    // spacing gap (10px) it added between the mode-line and the table
    // below it -- wasn't part of the fixedOverhead estimate when that box
    // was added, so the row budget stayed computed as if it didn't exist,
    // silently overshooting and clipping the last 2-3 lines (reported
    // 2026-09-02).
    readonly property int searchBoxH: 32
    // Width of the row-viewport's own scrollbar (request 2026-09-05:
    // "scrollable... with a scroller on the right"), plus the small gap
    // between it and the last data column.
    readonly property real scrollbarW: 6
    readonly property real scrollbarGap: 4

    // Shared column widths -- the process-list header row and every data
    // row below it bind to these same values so the two stay aligned
    // without hardcoding the same number twice. Mutable (not readonly):
    // each column's own resize handle (see ColumnResizeHandle usages
    // below) drags these directly, and resetColumnWidths() below restores
    // colDefaults on every panel open/close, same as root.sort -- a manual
    // resize isn't meant to quietly outlive the look at the panel that
    // made it, any more than a sort is.
    // title raised again (140 -> 280) alongside Bar.qml's
    // claudeUsagePanelWidth bump (760 -> 920) -- "make the panel wider to
    // give more space to make the title column wider" 2026-09-01.
    // title widened / last narrowed alongside the panel's own 30% width
    // bump (Bar.qml's claudeUsagePanelWidth, 920 -> 1196) -- "make last
    // narrower and title wider" 2026-09-01, same request that added the
    // hyprland group (workspace/monitor, "#"/"monitor" headers) below.
    readonly property var colDefaults: ({
        acct: 30, status: root.statusNaturalW, title: 400, tokens: root.tokensNaturalW, last: 44,
        tmuxSession: 54, tmuxWindow: root.tmuxWindowNaturalW, tmuxPane: root.tmuxPaneNaturalW,
        hyprWorkspace: root.hyprWorkspaceNaturalW, hyprMonitor: 56,
        pid: root.pidNaturalW, path: 100,
    })
    // New "acct" column (request 2026-09-05, single-table merge) -- just a
    // bare "1"/"2"/"3" (root.acctIndex), so narrow like "#"/"wks" below;
    // hover shows the real account name via the shared cursor-following
    // hint (root.showHint) instead of spending width on the full name.
    property real colAcctW: colDefaults.acct
    // Whichever is wider of the "status" header (label + its clickable
    // sort-arrow suffix) and the actual idle/busy/wait values currently
    // shown (root.statusNaturalW) -- used to be a flat 52 sized for the
    // header alone, tightened to shrink-to-fit per-column (request
    // 2026-09-05: "make status... narrower... resize dynamically based
    // on displayed contents").
    property real colStatusW: colDefaults.status
    // Title (tmux's own pane_title, e.g. "Reddit API automation for
    // unixporn posts") used to be the one column with Layout.fillWidth,
    // absorbing whatever width the panel had spare -- path had that job
    // first, on the reasoning that it was the least critical column to
    // keep fully visible, but path is almost always just "~" in this
    // environment, so giving *it* the stretch just wasted the panel's
    // extra width as blank space while titles sat elided (reported "title
    // column is too short"). Now that every column can be dragged to a
    // manual width (ColumnResizeHandle below), there's no need for any
    // one column to auto-absorb leftover space -- all 9 are plain fixed
    // widths, defaults tuned so title (140) starts noticeably roomier
    // than path (100), and a trailing filler after the last column
    // (path) soaks up genuine leftover space instead of stretching a
    // specific column into it.
    property real colTitleW: colDefaults.title
    property real colPidW: colDefaults.pid
    property real colTokensW: colDefaults.tokens
    // "last" itself is short, but values like "2mo 1w" aren't.
    property real colLastW: colDefaults.last
    // tmux is a *grouped* column -- one "tmux" super-header spanning these
    // 3, sized off their own header labels ("session"/"window"/"pane",
    // the widest of which is "session" at 7 chars) rather than the
    // (shorter, numeric) session/window/pane ids they actually hold.
    property real colTmuxSessionW: colDefaults.tmuxSession
    property real colTmuxWindowW: colDefaults.tmuxWindow
    property real colTmuxPaneW: colDefaults.tmuxPane
    // Derived, not resized directly -- follows its 3 sub-columns
    // automatically as they're dragged.
    readonly property real colTmuxGroupW: colTmuxSessionW + colTmuxWindowW + colTmuxPaneW + 2 * root.handleW
    // hyprland is a *grouped* column like tmux, right after it: which
    // Hyprland window is currently showing this session's tmux pane (see
    // claude-usage-daemon.py's hyprland_windows_by_tmux_session), if any.
    // Only workspace/monitor are actually shown as columns -- the window's
    // own Hyprland address (what the hover-thumbnail/click-to-focus
    // feature on this group keys off, see root.hyprHoverEntered) is kept
    // on the row data (modelData.hypr_address) but deliberately not
    // rendered as its own column: it's a long opaque hex string with no
    // value as a glanceable readout, unlike workspace/monitor. "workspace"
    // is labeled just "#" (hover for a "workspace" hint, see the header
    // below) -- narrow on purpose, values here are almost always a single
    // digit.
    property real colHyprWorkspaceW: colDefaults.hyprWorkspace
    property real colHyprMonitorW: colDefaults.hyprMonitor
    readonly property real colHyprGroupW: colHyprWorkspaceW + colHyprMonitorW + root.handleW
    // Sized off the actual longest visible path, not a flat default --
    // "almost always just '~' in this environment" (colDefaults' own
    // comment) meant colDefaults.path (100) was already generous for the
    // common case, but a genuinely longer cwd used to get truncated even
    // when the panel had plenty of spare width to just show it (request
    // 2026-09-02: "shouldn't have to be truncated if it doesn't have to").
    // Still capped (pathNaturalCapW) and still has `elide` as the real
    // fallback -- a single pathological cwd shouldn't be able to blow the
    // panel width out on its own; that's what "may be truncated later if
    // space gets more scarce" describes.
    readonly property real pathNaturalCapW: 300
    readonly property real pathNaturalW: Math.max(colDefaults.path,
        Math.min(root.pathNaturalCapW, root.pathContentMaxW + 6))
    property real colPathW: root.pathNaturalW
    // Width of each drag-resize handle between columns (see
    // ColumnResizeHandle.qml) -- also the RowLayout spacing everywhere a
    // handle isn't interactive (the group-header row, data rows), so
    // every row's columns line up regardless of which row it is.
    readonly property real handleW: 8
    readonly property real colMinW: 24

    function resetColumnWidths() {
        root.colAcctW = root.colDefaults.acct;
        root.colStatusW = root.colDefaults.status;
        root.colTitleW = root.colDefaults.title;
        root.colTokensW = root.colDefaults.tokens;
        root.colLastW = root.colDefaults.last;
        root.colTmuxSessionW = root.colDefaults.tmuxSession;
        root.colTmuxWindowW = root.colDefaults.tmuxWindow;
        root.colTmuxPaneW = root.colDefaults.tmuxPane;
        root.colHyprWorkspaceW = root.colDefaults.hyprWorkspace;
        root.colHyprMonitorW = root.colDefaults.hyprMonitor;
        root.colPidW = root.colDefaults.pid;
        root.colPathW = root.pathNaturalW;
    }

    // ---- dynamic panel width: shrink-to-fit between a min and a max ----
    // panelWidth used to be a flat constant (Bar.qml's claudeUsagePanelWidth,
    // 1196) regardless of what was actually inside -- wasted space with few/
    // no processes, and no way to grow past it for a genuinely wide table.
    // Bar.qml now clamps between minPanelWidth and its own 1196 ceiling
    // around this natural figure instead (request 2026-09-02: "current
    // width... was meant to be only a maximum, add a reasonable minimum").
    //
    // No process table needs rendering at all if no account has any
    // sessions right now -- just the mode-line/search box/account-name
    // lines, which need far less width than the full 12-column table.
    readonly property bool anyProcsVisible: {
        for (const a of ClaudeUsageSvc.accounts)
            if ((ClaudeUsageSvc.sessions[a.account] || []).length > 0)
                return true;
        return false;
    }
    // Sum of every column + the handle gap between each pair -- the exact
    // width the process table's header/data rows actually need to render
    // without their trailing filler Item eating any slack (or, if this
    // exceeds Bar.qml's max, without something being cut off beyond what
    // that filler removal already implies).
    readonly property real tableNaturalWidth: root.colAcctW + root.handleW + root.colStatusW + root.handleW
        + root.colTitleW + root.handleW + root.colTokensW + root.handleW
        + root.colLastW + root.handleW + root.colTmuxGroupW + root.handleW
        + root.colHyprGroupW + root.handleW + root.colPidW + root.handleW
        + root.colPathW + root.scrollbarGap + root.scrollbarW
    // Same fallback width the standalone-preview default (panelWidth: 320
    // above) already used -- reused here as the floor so a near-empty
    // panel (few/no live processes) doesn't shrink below something that
    // still comfortably fits the mode-line/search box/account name text.
    readonly property real minContentWidth: 320
    readonly property real naturalContentWidth:
        (root.anyProcsVisible ? Math.max(root.tableNaturalWidth, root.minContentWidth) : root.minContentWidth) + 24

    // Measures path text the same font the "path" column's own Text uses
    // (Theme.fontFamily @ fontSize-3), for pathNaturalW above. Across
    // every session, not just currently-visible rows -- simpler than
    // duplicating each account's own search/sort/row-budget slicing here,
    // and "+N more" rows tend to share similar cwd patterns anyway.
    FontMetrics {
        id: pathFontMetrics
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize - 3
    }
    readonly property real pathContentMaxW: {
        let m = 0;
        for (const a of ClaudeUsageSvc.accounts) {
            for (const row of (ClaudeUsageSvc.sessions[a.account] || [])) {
                const w = pathFontMetrics.advanceWidth(root.shortCwd(row.cwd));
                if (w > m) m = w;
            }
        }
        return m;
    }

    // ---- content-driven natural widths: status/tkns/wks/win/pane/pid ----
    // These 6 columns used to default to hand-picked flat numbers (some
    // sized for the header label, some for the values, whichever was
    // wider) -- request 2026-09-05: size each to whatever its own header
    // + actual current values need, same shrink-to-fit approach path
    // already used above, instead of a guessed constant. Values render at
    // fontSize-2 for status/tokens/pid, fontSize-3 (same as every header)
    // for tmux window/pane and hyprland workspace -- two FontMetrics to
    // match.
    FontMetrics {
        id: valueFontMetrics
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize - 2
    }
    function _maxTextWidth(fm, texts) {
        let m = 0;
        for (const t of texts) {
            const w = fm.advanceWidth(t);
            if (w > m) m = w;
        }
        return m;
    }
    // +6: a little breathing room past the exact glyph width, same margin
    // pathNaturalW's own "+ 6" above uses.
    readonly property real statusNaturalW: Math.max(
        pathFontMetrics.advanceWidth(qsTr("status") + " ▲"),
        root._maxTextWidth(valueFontMetrics, root.allProcs.map(r => root.statusLabel(r.status)))
    ) + 6
    readonly property real tokensNaturalW: Math.max(
        pathFontMetrics.advanceWidth(qsTr("tkns") + " ▲"),
        root._maxTextWidth(valueFontMetrics, root.allProcs.map(r => root.fmtTokens(r.context_tokens)))
    ) + 6
    readonly property real pidNaturalW: Math.max(
        pathFontMetrics.advanceWidth(qsTr("pid") + " ▲"),
        root._maxTextWidth(valueFontMetrics, root.allProcs.map(r => String(r.pid)))
    ) + 6
    readonly property real tmuxWindowNaturalW: Math.max(
        pathFontMetrics.advanceWidth(qsTr("win") + " ▲"),
        root._maxTextWidth(pathFontMetrics, root.allProcs.map(r => r.tmux_window || ""))
    ) + 6
    readonly property real tmuxPaneNaturalW: Math.max(
        pathFontMetrics.advanceWidth(qsTr("pane") + " ▲"),
        root._maxTextWidth(pathFontMetrics, root.allProcs.map(r => r.tmux_pane || ""))
    ) + 6
    readonly property real hyprWorkspaceNaturalW: Math.max(
        pathFontMetrics.advanceWidth(qsTr("wks") + " ▲"),
        root._maxTextWidth(pathFontMetrics, root.allProcs.map(r => r.hypr_workspace || ""))
    ) + 6

    // ---- hyprland-column hover-thumbnail + click-to-focus ------------
    //
    // Only live over the hyprland group's own 3 sub-columns (workspace/
    // monitor/window), not the whole row -- asked for explicitly, so
    // hovering the title/tokens/etc of a row that happens to also have a
    // resolved window doesn't pop a thumbnail up unexpectedly.
    //
    // Capture goes through a standalone helper binary (thumb-capture,
    // ~/.config/claude-usage/thumb-capture/) instead of Quickshell's own
    // built-in ScreencopyView/ToplevelManager (Quickshell.Wayland) -- that
    // one only identifies windows by appId/title via the generic
    // wlr-foreign-toplevel-list protocol, which can't disambiguate this
    // machine's many identically-titled "Alacritty" windows (confirmed
    // live 2026-09-01: 34 windows, one distinct title, "Alacritty", among
    // them all). Hyprland's own hyprland-toplevel-export-v1 protocol
    // captures by exact window *address* instead, which
    // hyprland_windows_by_tmux_session already resolves per row -- no
    // ambiguity. thumb-capture is its own crate (not a dependency on or
    // subcommand of ~/.config/hypr/winswitch, which implements the same
    // protocol for its own alt-tab grid) -- see that binary's own doc
    // comment for why duplicating the ~400 lines of capture code was
    // preferred over coupling to winswitch's build.
    //
    // Click-to-focus does NOT go through thumb-capture or Quickshell at
    // all -- it's the same `hyprctl repl` Lua dispatch
    // ~/.config/hypr/winswitch/src/hyprctl.rs::focus_window() uses
    // (`hyprctl dispatch focuswindow address:...` doesn't work on this
    // Hyprland install; it's on the Lua config system, under which
    // `hyprctl dispatch` isn't valid syntax -- has to go through
    // `hl.dispatch(hl.dsp.focus(...))` via `hyprctl repl` instead). Also
    // re-points the tmux client at the exact session/window/pane this row
    // is for (not just "some window of the right session") -- clicking a
    // row should land you looking at *that* pane, not whatever the
    // terminal last happened to be showing.
    readonly property string thumbBin: Quickshell.env("HOME") + "/.config/claude-usage/thumb-capture/target/release/thumb-capture"
    readonly property string thumbDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/claude-usage-thumbs"
    property int thumbSeq: 0
    property string thumbAddress: ""   // which window the current capture/display is for
    property string thumbImagePath: ""
    property bool thumbReady: false
    property bool thumbHovering: false
    property point thumbPos: Qt.point(0, 0)

    function hyprHoverEntered(address) {
        root.thumbHovering = true;
        if (!address) {
            root.thumbReady = false;
            return;
        }
        if (root.thumbAddress === address && root.thumbReady)
            return; // already have a current thumbnail for this exact window
        root.thumbAddress = address;
        root.thumbReady = false;
        root.thumbSeq += 1;
        const outPath = root.thumbDir + "/" + root.thumbSeq + ".png";
        root._pendingOutPath = outPath;
        root._pendingAddress = address;
        thumbProc.exec([root.thumbBin, address, outPath]);
    }
    property string _pendingOutPath: ""
    property string _pendingAddress: ""
    function hyprHoverMoved(rootPos) {
        // A little below-right of the cursor, not centered on it, so the
        // cursor itself isn't hidden under the image it's pointing at.
        root.thumbPos = Qt.point(rootPos.x + 14, rootPos.y + 14);
    }
    function hyprHoverExited() {
        root.thumbHovering = false;
    }

    function focusHyprWindow(row) {
        if (!row.hypr_address)
            return;
        if (row.tmux_window)
            tmuxSelectProc.exec(["tmux", "select-window", "-t", "@" + row.tmux_window]);
        if (row.tmux_pane)
            tmuxSelectPaneProc.exec(["tmux", "select-pane", "-t", "%" + row.tmux_pane]);
        const addr = row.hypr_address;
        const script = "local ws = hl.get_windows({})\n"
            + "for i, w in ipairs(ws) do\n"
            + "    if tostring(w.address) == \"" + addr + "\" then\n"
            + "        hl.dispatch(hl.dsp.focus({ window = w }))\n"
            + "        break\n"
            + "    end\n"
            + "end";
        focusProc.exec(["hyprctl", "repl", script]);
    }

    Process {
        id: mkdirProc
    }
    Component.onCompleted: mkdirProc.exec(["mkdir", "-p", root.thumbDir])

    Process {
        id: thumbProc
        onExited: (exitCode, exitStatus) => {
            if (exitCode === 0 && root.thumbAddress === root._pendingAddress) {
                root.thumbImagePath = root._pendingOutPath;
                root.thumbReady = true;
            }
        }
    }
    Process { id: focusProc }
    Process { id: tmuxSelectProc }
    Process { id: tmuxSelectPaneProc }

    // Single table now -- one header block, not one per (formerly
    // foldable) account group. The process list itself no longer
    // truncates with a "+N more" line (request 2026-09-05: "remove ...
    // at the bottom, scroller size should be enough of an indication") --
    // it's a fixed-height scrollable viewport instead, holding every row
    // in root.sortedProcs, so this is now just "how tall should that
    // viewport be" rather than "how many rows fit before truncating".
    readonly property real processAreaBudget: {
        // 20: the mode-line/summary row. 24: root's own implicitHeight
        // padding (content.implicitHeight + 24). 16: safety margin.
        // groupHeaderH: the table's own header block (tmux/hyprland row +
        // column-header row). tallyLineH: the per-account totals line
        // below the table.
        const fixedOverhead = 20 + 24 + 16 + root.searchBoxH + root.groupHeaderH + root.tallyLineH;
        return Math.max(0, root.maxPanelHeight - fixedOverhead);
    }

    Column {
        id: content
        x: 12
        y: 12
        width: parent.width - 24
        spacing: 10

        // Mode-line text + the combined session/weekly summary share one
        // row now (request 2026-09-05: "put the line ... on the first
        // line, the same line as 'polling every 2m'... aligned to the
        // right") -- mode-line gets Layout.fillWidth + elide so it yields
        // space to the summary instead of the two fighting over width.
        // Account names shortened to their bare acctIndex (1/2/3) to help
        // fit, and each percentage's "resets in..." is back to being
        // printed inline (it was hover-only for one revision, reported
        // "bring back resets in... we had before").
        RowLayout {
            width: parent.width
            spacing: 10

            Text {
                Layout.fillWidth: true
                text: root.tick >= 0 ? root.modeLine() + " -- " + qsTr("updated %1 ago").arg(root.fmtAgo(ClaudeUsageSvc.updatedAt)) : ""
                color: Theme.textDim
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 2
                elide: Text.ElideRight
            }

            Repeater {
                model: ClaudeUsageSvc.accounts

                // Pill/chip background around each account's numbers
                // (request 2026-09-06: "reads better" -- with 3 accounts'
                // worth of numbers now sharing one line, a rounded border
                // per account visually separates them at a glance instead
                // of relying purely on the "/" and the gap between
                // groups). radius: height/2 for a true pill (fully
                // rounded ends), not Theme.rounding's flatter default --
                // this chip is much shorter than the controls that
                // constant was tuned for.
                Rectangle {
                    id: acctSummaryPill
                    required property var modelData
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: acctSummary.implicitWidth + 16
                    implicitHeight: acctSummary.implicitHeight + 6
                    radius: height / 2
                    color: Theme.bgAlpha
                    border.color: Theme.border
                    border.width: 1

                    Row {
                        id: acctSummary
                        anchors.centerIn: parent
                        spacing: 4

                        Text {
                            id: acctSummaryName
                            text: String(root.acctIndex(acctSummaryPill.modelData.account))
                            color: Theme.text
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 1
                            font.bold: true
                        }
                        Text {
                            id: acctSummarySession
                            visible: typeof acctSummaryPill.modelData.session_pct === "number"
                            // Baseline, not verticalCenter -- these run at
                            // fontSize-2/-3 next to the bold fontSize-1
                            // number, and centering different glyph sizes on
                            // each other leaves their baselines at different
                            // heights (reported 2026-09-05: "1 2 3 and the
                            // rest of the line seem misaligned"). Sitting
                            // every piece on the number's baseline lines the
                            // text up the way it reads as aligned.
                            anchors.baseline: acctSummaryName.baseline
                            opacity: acctSummaryPill.modelData.stale ? 0.55 : 1
                            text: qsTr("%1%").arg(Math.round(acctSummaryPill.modelData.session_pct))
                            color: Theme.rampColor(acctSummaryPill.modelData.session_pct / 100)
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                        }
                        Text {
                            visible: acctSummarySession.visible
                            anchors.baseline: acctSummaryName.baseline
                            text: root.tick >= 0 ? root.fmtResets(acctSummaryPill.modelData.session_resets_at) : ""
                            color: Theme.textDim
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 3
                        }
                        Text {
                            visible: acctSummarySession.visible && acctSummaryWeekly.visible
                            anchors.baseline: acctSummaryName.baseline
                            text: "/"
                            color: Theme.textDim
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                        }
                        Text {
                            id: acctSummaryWeekly
                            visible: typeof acctSummaryPill.modelData.weekly_pct === "number"
                            anchors.baseline: acctSummaryName.baseline
                            opacity: acctSummaryPill.modelData.stale ? 0.55 : 1
                            text: qsTr("%1%").arg(Math.round(acctSummaryPill.modelData.weekly_pct))
                            color: Theme.rampColor(acctSummaryPill.modelData.weekly_pct / 100)
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                        }
                        Text {
                            visible: acctSummaryWeekly.visible
                            anchors.baseline: acctSummaryName.baseline
                            text: root.tick >= 0 ? root.fmtResets(acctSummaryPill.modelData.weekly_resets_at) : ""
                            color: Theme.textDim
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 3
                        }
                    }
                }
            }
        }

        // A stale reading still shows its (dimmed) numbers above -- this
        // is just the "why" note, not a replacement for them. Only a
        // genuinely never-fetched account has no numbers to dim, in which
        // case this is the only line shown. One line per erroring account,
        // prefixed with its name now that there's no per-account heading
        // to sit under (request 2026-09-05).
        Repeater {
            model: ClaudeUsageSvc.accounts

            Text {
                required property var modelData
                visible: !!modelData.error
                width: content.width
                text: (typeof modelData.session_pct === "number" || typeof modelData.weekly_pct === "number")
                    ? qsTr("%1: %2 -- showing last known values").arg(modelData.account).arg(modelData.error)
                    : qsTr("%1: error: %2").arg(modelData.account).arg(modelData.error)
                color: Theme.red
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 2
                elide: Text.ElideRight
            }
        }

        // Search box: shared picker query DSL (see root.searchParsed's own
        // comment). Always present (not shown-on-demand) -- "/" just moves
        // real keyboard focus into it, same convention as the RSS reader
        // and app launcher's own search boxes.
        Rectangle {
            id: searchBox
            width: parent.width
            height: 22
            radius: 4
            color: Theme.bg
            border.color: searchInput.activeFocus ? Theme.cyan : Theme.border
            border.width: 1

            TextInput {
                id: searchInput
                anchors.fill: parent
                anchors.leftMargin: 6
                anchors.rightMargin: 6
                verticalAlignment: TextInput.AlignVCenter
                color: Theme.text
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 2
                clip: true
                // Any further typing past a shown popup closes it, same as
                // a shell/IDE -- Tab recomputes it fresh for wherever the
                // cursor is now (root.triggerCompletion). Also fires
                // (harmlessly, on an already-empty acItems) when accepting
                // a completion sets this text itself.
                onTextChanged: { root.searchText = text; root.acItems = []; }

                Text {
                    visible: searchInput.text.length === 0 && !searchInput.activeFocus
                    text: qsTr("/ to search")
                    color: Theme.muted
                    font: searchInput.font
                    anchors.verticalCenter: parent.verticalCenter
                }

                // Inline command-validity coloring (query-dsl.md): an
                // underline under each `/command` token -- see
                // AppLauncher.qml/RssReader.qml's identical copies for why
                // (no per-range text styling on TextInput, and
                // positionToRectangle stays correct under scrolling where a
                // manual TextMetrics measurement wouldn't).
                Repeater {
                    model: searchInput.text.length ? root._commandSpans(searchInput.text) : []
                    Rectangle {
                        required property var modelData
                        x: searchInput.positionToRectangle(modelData.start).x
                        y: searchInput.positionToRectangle(modelData.start).y
                           + searchInput.positionToRectangle(modelData.start).height - 2
                        width: Math.max(1, searchInput.positionToRectangle(modelData.end).x - x)
                        height: 2
                        radius: 1
                        color: modelData.valid ? Theme.cyan : Theme.red
                    }
                }

                // First Escape while searching closes the autocomplete
                // popup if one's open; next closes it further by clearing
                // a non-empty query (a common case worth a dedicated undo
                // step); with both of those already clear, an Escape now
                // just blurs the search box (root.forceActiveFocus() moves
                // focus off searchInput back onto this whole panel) rather
                // than closing the panel outright -- the panel should stay
                // open, focus just leaves the box (request 2026-09-05).
                // *That* Escape is accepted here too, so it never reaches
                // Bar.qml's root.Keys.onPressed; only a further Escape,
                // pressed once the search box no longer holds focus,
                // bubbles all the way up and actually closes the panel.
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Escape) {
                        if (root.acOpen) {
                            root.acDismissed = true;
                        } else if (searchInput.text.length > 0) {
                            searchInput.text = "";
                        } else {
                            root.forceActiveFocus();
                        }
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Tab) {
                        if (root.acOpen) { root.acAccept(); event.accepted = true; }
                        else if (root.triggerCompletion()) { event.accepted = true; }
                    } else if (event.key === Qt.Key_Down && root.acOpen) {
                        root.acSel = Math.min(root.acItems.length - 1, root.acSel + 1);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Up && root.acOpen) {
                        root.acSel = Math.max(0, root.acSel - 1);
                        event.accepted = true;
                    }
                }
            }
        }

        // Autocomplete popup (marginalia-style, see launcher/AppLauncher.qml
        // and rssreader/RssReader.qml's identical copies): label, long-form
        // alias, one-line description. Tab-triggered only (root.acItems is
        // never recomputed just from typing) -- a popup that popped open on
        // every keystroke was obtrusive and could steal focus at the wrong
        // moment, same reasoning as the other two consumers.
        Rectangle {
            id: ac
            visible: root.acOpen
            z: 50
            x: searchBox.x
            y: searchBox.y + searchBox.height + 4
            width: Math.min(360, content.width)
            height: visible ? Math.min(root.acItems.length, 7) * 24 + 8 : 0
            radius: Theme.rounding - 4
            color: Theme.bgAlpha
            border.color: Theme.cyan
            border.width: 1
            clip: true

            Column {
                anchors.fill: parent
                padding: 4

                Repeater {
                    model: root.acItems
                    Rectangle {
                        id: acRow
                        required property var modelData
                        required property int index
                        readonly property bool cur: index === root.acSel
                        width: ac.width - 8
                        height: 24
                        radius: Theme.rounding - 5
                        color: cur ? Qt.rgba(Theme.cyan.r, Theme.cyan.g, Theme.cyan.b, 0.18) : "transparent"

                        Row {
                            anchors.verticalCenter: parent.verticalCenter
                            x: 10
                            spacing: 8

                            Text {
                                id: acLabel
                                text: acRow.modelData.label
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 2
                                color: acRow.cur ? Theme.cyan : Theme.text
                            }
                            Text {
                                visible: !!acRow.modelData.alias
                                anchors.baseline: acLabel.baseline
                                text: "(" + acRow.modelData.alias + ")"
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 3
                                color: Theme.muted
                            }
                            Text {
                                anchors.baseline: acLabel.baseline
                                text: acRow.modelData.desc
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 3
                                color: Theme.textDim
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { root.acSel = acRow.index; root.acAccept(); }
                        }
                    }
                }
            }
        }

        // Single header block for the merged table (request 2026-09-05:
        // "instead of 3 separate tables grouped by account, let's have a
        // single table") -- one "acct" column (root.acctIndex, hover for
        // the real name) identifies which account each row is from,
        // replacing the old per-account heading + header-row-per-group
        // shape entirely. Column headers are individually clickable
        // (root.toggleSort/sortArrow), one sort for the whole table now
        // instead of one independent sort per account.
        Column {
            width: content.width
            spacing: 1
            visible: root.anyProcsVisible

            // Group-header row: blank over every plain column, "tmux" and
            // "hyprland" labels (underlined) spanning their own
            // sub-columns below -- same shape as the old per-account
            // version, just rendered once now.
            RowLayout {
                width: content.width
                spacing: 0

                Item { Layout.preferredWidth: root.colAcctW }
                Item { Layout.preferredWidth: root.handleW }
                Item { Layout.preferredWidth: root.colStatusW }
                Item { Layout.preferredWidth: root.handleW }
                Item { Layout.preferredWidth: root.colTitleW }
                Item { Layout.preferredWidth: root.handleW }
                Item { Layout.preferredWidth: root.colTokensW }
                Item { Layout.preferredWidth: root.handleW }
                Item { Layout.preferredWidth: root.colLastW }
                Item { Layout.preferredWidth: root.handleW }
                Text {
                    text: qsTr("tmux")
                    color: Theme.muted
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                    horizontalAlignment: Text.AlignHCenter
                    Layout.preferredWidth: root.colTmuxGroupW
                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: 1
                        color: Theme.border
                    }
                }
                Item { Layout.preferredWidth: root.handleW }
                Text {
                    text: qsTr("hyprland")
                    color: Theme.muted
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                    horizontalAlignment: Text.AlignHCenter
                    Layout.preferredWidth: root.colHyprGroupW
                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: 1
                        color: Theme.border
                    }
                }
                Item { Layout.preferredWidth: root.handleW }
                Item { Layout.preferredWidth: root.colPidW }
                Item { Layout.preferredWidth: root.handleW }
                Item { Layout.preferredWidth: root.colPathW }
                Item { Layout.fillWidth: true }
            }

            // Column headers. Four of these are abbreviated with a
            // cursor-following hover hint for the full word (request
            // 2026-09-05) -- "tkns" (tokens), "sess" (tmux session), "win"
            // (tmux window), "wks" (hyprland workspace, renamed from the
            // old bare "#" which used a static hint the cursor itself
            // occluded). "pane"/"monitor"/"pid"/"path"/etc. are short
            // enough already and stay unabbreviated.
            RowLayout {
                width: content.width
                spacing: 0

                Text {
                    text: qsTr("acct") + root.sortArrow("acct")
                    color: Theme.muted
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                    Layout.preferredWidth: root.colAcctW
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.toggleSort("acct")
                    }
                }
                ColumnResizeHandle {
                    Layout.preferredWidth: root.handleW
                    Layout.fillHeight: true
                    targetWidth: root.colAcctW
                    onWidthChangeRequested: w => root.colAcctW = w
                }
                Text {
                    text: qsTr("status") + root.sortArrow("status")
                    color: Theme.muted
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                    Layout.preferredWidth: root.colStatusW
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.toggleSort("status")
                    }
                }
                ColumnResizeHandle {
                    Layout.preferredWidth: root.handleW
                    Layout.fillHeight: true
                    targetWidth: root.colStatusW
                    onWidthChangeRequested: w => root.colStatusW = w
                }
                Text {
                    text: qsTr("title") + root.sortArrow("title")
                    color: Theme.muted
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                    elide: Text.ElideRight
                    Layout.preferredWidth: root.colTitleW
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.toggleSort("title")
                    }
                }
                ColumnResizeHandle {
                    Layout.preferredWidth: root.handleW
                    Layout.fillHeight: true
                    targetWidth: root.colTitleW
                    onWidthChangeRequested: w => root.colTitleW = w
                }
                Text {
                    id: tokensHeader
                    text: qsTr("tkns") + root.sortArrow("tokens")
                    color: Theme.muted
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                    Layout.preferredWidth: root.colTokensW
                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: {
                            root.showHint(qsTr("tokens"));
                            root.moveHint(tokensHeader.mapToItem(root, mouseX, mouseY));
                        }
                        onPositionChanged: mouse => root.moveHint(tokensHeader.mapToItem(root, mouse.x, mouse.y))
                        onExited: root.hideHint()
                        onClicked: root.toggleSort("tokens")
                    }
                }
                ColumnResizeHandle {
                    Layout.preferredWidth: root.handleW
                    Layout.fillHeight: true
                    targetWidth: root.colTokensW
                    onWidthChangeRequested: w => root.colTokensW = w
                }
                Text {
                    text: qsTr("age") + root.sortArrow("active")
                    color: Theme.muted
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                    horizontalAlignment: Text.AlignRight
                    Layout.preferredWidth: root.colLastW
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.toggleSort("active")
                    }
                }
                ColumnResizeHandle {
                    Layout.preferredWidth: root.handleW
                    Layout.fillHeight: true
                    targetWidth: root.colLastW
                    onWidthChangeRequested: w => root.colLastW = w
                }
                Text {
                    id: sessHeader
                    text: qsTr("sess") + root.sortArrow("tmuxSession")
                    color: Theme.muted
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                    Layout.preferredWidth: root.colTmuxSessionW
                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: {
                            root.showHint(qsTr("session"));
                            root.moveHint(sessHeader.mapToItem(root, mouseX, mouseY));
                        }
                        onPositionChanged: mouse => root.moveHint(sessHeader.mapToItem(root, mouse.x, mouse.y))
                        onExited: root.hideHint()
                        onClicked: root.toggleSort("tmuxSession")
                    }
                }
                ColumnResizeHandle {
                    Layout.preferredWidth: root.handleW
                    Layout.fillHeight: true
                    targetWidth: root.colTmuxSessionW
                    onWidthChangeRequested: w => root.colTmuxSessionW = w
                }
                Text {
                    id: winHeader
                    text: qsTr("win") + root.sortArrow("tmuxWindow")
                    color: Theme.muted
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                    Layout.preferredWidth: root.colTmuxWindowW
                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: {
                            root.showHint(qsTr("window"));
                            root.moveHint(winHeader.mapToItem(root, mouseX, mouseY));
                        }
                        onPositionChanged: mouse => root.moveHint(winHeader.mapToItem(root, mouse.x, mouse.y))
                        onExited: root.hideHint()
                        onClicked: root.toggleSort("tmuxWindow")
                    }
                }
                ColumnResizeHandle {
                    Layout.preferredWidth: root.handleW
                    Layout.fillHeight: true
                    targetWidth: root.colTmuxWindowW
                    onWidthChangeRequested: w => root.colTmuxWindowW = w
                }
                Text {
                    text: qsTr("pane") + root.sortArrow("tmuxPane")
                    color: Theme.muted
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                    Layout.preferredWidth: root.colTmuxPaneW
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.toggleSort("tmuxPane")
                    }
                }
                ColumnResizeHandle {
                    Layout.preferredWidth: root.handleW
                    Layout.fillHeight: true
                    targetWidth: root.colTmuxPaneW
                    onWidthChangeRequested: w => root.colTmuxPaneW = w
                }
                Text {
                    id: wksHeader
                    text: qsTr("wks") + root.sortArrow("hyprWorkspace")
                    color: Theme.muted
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                    Layout.preferredWidth: root.colHyprWorkspaceW
                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: {
                            root.showHint(qsTr("workspace"));
                            root.moveHint(wksHeader.mapToItem(root, mouseX, mouseY));
                        }
                        onPositionChanged: mouse => root.moveHint(wksHeader.mapToItem(root, mouse.x, mouse.y))
                        onExited: root.hideHint()
                        onClicked: root.toggleSort("hyprWorkspace")
                    }
                }
                ColumnResizeHandle {
                    Layout.preferredWidth: root.handleW
                    Layout.fillHeight: true
                    targetWidth: root.colHyprWorkspaceW
                    onWidthChangeRequested: w => root.colHyprWorkspaceW = w
                }
                Text {
                    text: qsTr("monitor") + root.sortArrow("hyprMonitor")
                    color: Theme.muted
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                    Layout.preferredWidth: root.colHyprMonitorW
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.toggleSort("hyprMonitor")
                    }
                }
                ColumnResizeHandle {
                    Layout.preferredWidth: root.handleW
                    Layout.fillHeight: true
                    targetWidth: root.colHyprMonitorW
                    onWidthChangeRequested: w => root.colHyprMonitorW = w
                }
                Text {
                    text: qsTr("pid") + root.sortArrow("pid")
                    color: Theme.muted
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                    Layout.preferredWidth: root.colPidW
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.toggleSort("pid")
                    }
                }
                ColumnResizeHandle {
                    Layout.preferredWidth: root.handleW
                    Layout.fillHeight: true
                    targetWidth: root.colPidW
                    onWidthChangeRequested: w => root.colPidW = w
                }
                Text {
                    text: qsTr("path") + root.sortArrow("path")
                    color: Theme.muted
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                    elide: Text.ElideRight
                    Layout.preferredWidth: root.colPathW
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.toggleSort("path")
                    }
                }
                Item { Layout.fillWidth: true }
            }
        }

        // Scrollable row viewport (request 2026-09-05: "make the table
        // scrollable with a scroller on the right and react to... mouse
        // wheel") -- fixed height (root.processAreaBudget), holding every
        // row in root.sortedProcs rather than a pre-sliced
        // root.visibleProcs, so scrolling actually reaches every row
        // instead of just the ones that used to fit before truncating
        // with "+N more" (removed: "scroller size should be enough of an
        // indication").
        Item {
            id: tableViewport
            width: content.width
            height: root.processAreaBudget
            clip: true
            visible: root.anyProcsVisible

            Flickable {
                id: rowsFlick
                anchors.fill: parent
                anchors.rightMargin: root.scrollbarGap + root.scrollbarW
                contentWidth: width
                contentHeight: rowsColumn.height
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick

                // Explicit rather than relying on Flickable's own implicit
                // wheel handling -- directly requested ("react to...
                // mousewheel"), so make it deterministic instead of
                // hoping the platform default covers it. Doesn't steal
                // clicks/hover from the row delegates below (a
                // WheelHandler only intercepts wheel events, unlike an
                // overlapping MouseArea, which would have broken the
                // per-row hover highlight and every cell's own hover
                // tooltip).
                WheelHandler {
                    onWheel: event => {
                        rowsFlick.contentY = Math.max(0, Math.min(
                            Math.max(0, rowsFlick.contentHeight - rowsFlick.height),
                            rowsFlick.contentY - event.angleDelta.y / 2));
                    }
                }

                Column {
                    id: rowsColumn
                    width: rowsFlick.width
                    spacing: 1

            Repeater {
                model: root.sortedProcs

                // Wrapping Rectangle purely for the hover highlight -- the
                // row content is the RowLayout inside it. Uses a
                // HoverHandler (not a row-spanning MouseArea) because the
                // hyprland cell (and now the acct cell too) already has
                // its own child MouseArea with hoverEnabled: a passive
                // HoverHandler on this ancestor still reports `hovered`
                // while the cursor is over that child, where a parent
                // MouseArea's containsMouse would drop to false. Highlight
                // tint is the wallpaper-theme primary at low alpha, same
                // token/approach as the autocomplete popup's selected row.
                // Gated on root.mouseMovedSinceOpen too -- HoverHandler
                // reports hovered=true on creation if the cursor already
                // happens to be sitting over the row, so without the gate
                // whatever row was under the mouse would light up on
                // every panel open even with zero mouse movement.
                delegate: Rectangle {
                    id: procRow
                    required property var modelData
                    width: rowsColumn.width
                    implicitHeight: procRowLayout.implicitHeight
                    height: implicitHeight
                    radius: 3
                    color: root.mouseMovedSinceOpen && procRowHover.hovered
                        ? Qt.rgba(Theme.cyan.r, Theme.cyan.g, Theme.cyan.b, 0.15)
                        : "transparent"

                    HoverHandler { id: procRowHover }

                    RowLayout {
                        id: procRowLayout
                        anchors.left: parent.left
                        anchors.right: parent.right
                        spacing: 0

                        // "acct" column (request 2026-09-05): a bare
                        // 1/2/3 (root.acctIndex) identifying which
                        // account this row is from, hover for the real
                        // name via the shared cursor-following hint.
                        Text {
                            id: acctCell
                            text: String(root.acctIndex(modelData.account))
                            color: Theme.text
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                            Layout.preferredWidth: root.colAcctW
                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                onEntered: {
                                    root.showHint(modelData.account);
                                    root.moveHint(acctCell.mapToItem(root, mouseX, mouseY));
                                }
                                onPositionChanged: mouse => root.moveHint(acctCell.mapToItem(root, mouse.x, mouse.y))
                                onExited: root.hideHint()
                            }
                        }
                        Item { Layout.preferredWidth: root.handleW }
                        Text {
                            text: root.statusLabel(modelData.status)
                            color: root.statusColor(modelData.status)
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                            Layout.preferredWidth: root.colStatusW
                        }
                        Item { Layout.preferredWidth: root.handleW }
                        Text {
                            text: modelData.title || "--"
                            color: Theme.text
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                            elide: Text.ElideRight
                            Layout.preferredWidth: root.colTitleW
                        }
                        Item { Layout.preferredWidth: root.handleW }
                        Text {
                            text: root.fmtTokens(modelData.context_tokens)
                            color: root.tokenColor(modelData.context_tokens)
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                            Layout.preferredWidth: root.colTokensW
                        }
                        Item { Layout.preferredWidth: root.handleW }
                        Text {
                            text: root.tick >= 0 ? root.fmtAgoMs(modelData.updated_at_ms) : ""
                            color: Theme.muted
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 3
                            horizontalAlignment: Text.AlignRight
                            Layout.preferredWidth: root.colLastW
                        }
                        Item { Layout.preferredWidth: root.handleW }
                        Text {
                            text: modelData.tmux_session || ""
                            color: Theme.muted
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 3
                            Layout.preferredWidth: root.colTmuxSessionW
                        }
                        Item { Layout.preferredWidth: root.handleW }
                        Text {
                            text: modelData.tmux_window || ""
                            color: Theme.muted
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 3
                            Layout.preferredWidth: root.colTmuxWindowW
                        }
                        Item { Layout.preferredWidth: root.handleW }
                        Text {
                            text: modelData.tmux_pane || ""
                            color: Theme.muted
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 3
                            Layout.preferredWidth: root.colTmuxPaneW
                        }
                        Item { Layout.preferredWidth: root.handleW }
                        // hyprland group cell: which real window is showing
                        // this session, if any (see root.hyprHoverEntered's
                        // own comment for why it's address-keyed rather
                        // than title/appId-matched). One MouseArea over all
                        // 3 sub-columns (not the whole row -- asked for
                        // explicitly), inside a fixed-size Item (Layout.
                        // preferredWidth, not implicit-from-children) so
                        // adding it doesn't hit the sizing/MouseArea layout
                        // cycle this file's old heading block once ran
                        // into (see git history for that comment).
                        Item {
                            id: hyprCell
                            Layout.preferredWidth: root.colHyprGroupW
                            Layout.fillHeight: true

                            RowLayout {
                                anchors.fill: parent
                                spacing: 0
                                Text {
                                    text: modelData.hypr_workspace || ""
                                    // Wallpaper-theme primary color (same
                                    // token Workspaces.qml's own active-
                                    // workspace pill uses), only when this
                                    // is the workspace actually active on
                                    // this panel's own monitor right now.
                                    color: modelData.hypr_workspace && modelData.hypr_workspace === root.activeWorkspaceName
                                        ? Theme.cyan : Theme.muted
                                    font.bold: modelData.hypr_workspace && modelData.hypr_workspace === root.activeWorkspaceName
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSize - 3
                                    Layout.preferredWidth: root.colHyprWorkspaceW
                                }
                                Item { Layout.preferredWidth: root.handleW }
                                Text {
                                    text: modelData.hypr_monitor || ""
                                    color: Theme.muted
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSize - 3
                                    Layout.preferredWidth: root.colHyprMonitorW
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: modelData.hypr_address ? Qt.PointingHandCursor : Qt.ArrowCursor
                                onEntered: root.hyprHoverEntered(modelData.hypr_address)
                                onPositionChanged: mouse => root.hyprHoverMoved(hyprCell.mapToItem(root, mouse.x, mouse.y))
                                onExited: root.hyprHoverExited()
                                onClicked: root.focusHyprWindow(modelData)
                            }
                        }
                        Item { Layout.preferredWidth: root.handleW }
                        Text {
                            text: String(modelData.pid)
                            color: Theme.muted
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                            Layout.preferredWidth: root.colPidW
                        }
                        Item { Layout.preferredWidth: root.handleW }
                        Text {
                            text: root.shortCwd(modelData.cwd)
                            color: Theme.muted
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 3
                            elide: Text.ElideRight
                            Layout.preferredWidth: root.colPathW
                        }
                        Item { Layout.fillWidth: true }
                    }
                }
            }
            } // end rowsColumn
            } // end rowsFlick

            // Scrollbar track + thumb, right edge of the viewport --
            // thumb size communicates how much is hidden (request
            // 2026-09-05: "scroller size should be enough of an
            // indication") in place of the old "+N more" text. Only shown
            // once there's actually more content than the viewport can
            // hold; a thumb spanning the full track would be redundant.
            Rectangle {
                id: scrollTrack
                anchors.top: parent.top
                anchors.right: parent.right
                width: root.scrollbarW
                height: parent.height
                radius: root.scrollbarW / 2
                color: Theme.bg
                visible: rowsFlick.contentHeight > rowsFlick.height

                Rectangle {
                    width: parent.width
                    radius: parent.radius
                    color: Theme.muted
                    y: rowsFlick.contentHeight > 0
                        ? (rowsFlick.contentY / rowsFlick.contentHeight) * scrollTrack.height
                        : 0
                    height: rowsFlick.contentHeight > 0
                        ? Math.max(16, (rowsFlick.height / rowsFlick.contentHeight) * scrollTrack.height)
                        : scrollTrack.height
                }
            }
        }

        // Per-account totals -- conversation count + summed context
        // tokens (request 2026-09-05: "add total tally of each account
        // conversations, tokens at the bottom"). Same account-index
        // labeling as the top summary line (root.acctIndex), across
        // every session the daemon reports, not just the ones currently
        // scrolled into view.
        RowLayout {
            width: content.width
            spacing: 14
            visible: root.anyProcsVisible

            Repeater {
                model: ClaudeUsageSvc.accounts

                Row {
                    id: tallyRow
                    required property var modelData
                    readonly property var totals: root.acctTotals(modelData.account)
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 4

                    Text {
                        text: String(root.acctIndex(tallyRow.modelData.account))
                        color: Theme.text
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 2
                        font.bold: true
                    }
                    Text {
                        text: qsTr("%1 convos, %2 tokens").arg(tallyRow.totals.count).arg(root.fmtTokens(tallyRow.totals.tokens))
                        color: Theme.textDim
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 3
                    }
                }
            }
            Item { Layout.fillWidth: true }
        }

        Text {
            visible: !ClaudeUsageSvc.hasData
            width: parent.width
            text: qsTr("waiting for claude-usage-daemon...")
            color: Theme.muted
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 1
        }
    }

    // Hover-thumbnail popup: a purely visual cue that follows the cursor
    // while hovering a row's hyprland-group cell (root.hyprHoverEntered/
    // Moved/Exited below) -- not a click target itself, clicking is on the
    // row (see focusHyprWindow), asked for explicitly. Positioned in
    // root's own coordinate space (root.thumbPos, set via mapToItem from
    // whichever row's MouseArea is hovered) so it can sit "below the
    // cursor" regardless of which account group/row that is.
    Rectangle {
        id: thumbPopup
        visible: root.thumbHovering && root.thumbReady
        x: Math.min(root.thumbPos.x, root.width - width - 4)
        y: Math.min(root.thumbPos.y, root.height - height - 4)
        z: 100
        width: thumbImg.implicitWidth > 0 ? Math.min(280, thumbImg.implicitWidth) + 4 : 4
        height: thumbImg.implicitHeight > 0 ? (width - 4) * (thumbImg.implicitHeight / thumbImg.implicitWidth) + 4 : 4
        color: Theme.bg
        border.color: Theme.cyan
        border.width: 1
        radius: 3

        Image {
            id: thumbImg
            anchors.fill: parent
            anchors.margins: 2
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            cache: false
            source: root.thumbReady ? "file://" + root.thumbImagePath : ""
        }
    }

    // Generic cursor-following hover hint -- header abbreviations
    // (wks/sess/win/tkns) and each row's "acct" cell (root.showHint/
    // moveHint/hideHint). Same follow-the-cursor shape as thumbPopup above
    // rather than a fixed spot next to the header, which the cursor itself
    // ended up sitting on top of and hiding (reported 2026-09-05).
    Rectangle {
        id: hintPopup
        visible: root.hintText.length > 0
        x: Math.min(root.hintPos.x, root.width - width - 4)
        y: Math.min(root.hintPos.y, root.height - height - 4)
        z: 100
        width: hintPopupText.implicitWidth + 8
        height: hintPopupText.implicitHeight + 4
        radius: 3
        color: Theme.bg
        border.color: Theme.border
        border.width: 1
        Text {
            id: hintPopupText
            anchors.centerIn: parent
            text: root.hintText
            color: Theme.text
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 3
        }
    }
}
