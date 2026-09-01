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
    // groupRowBudgets below still has to truncate with a "+N more" line
    // rather than ever actually fitting everything unconditionally.
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

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.AllButtons
        onWheel: wheel => wheel.accepted = true
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

    // Per-account collapse state, keyed by account name -- missing/absent
    // means expanded (so a brand new account name defaults open).
    property var groupExpanded: ({})
    function isGroupExpanded(name) {
        return root.groupExpanded[name] !== false;
    }
    function toggleGroup(name) {
        const next = Object.assign({}, root.groupExpanded);
        next[name] = !root.isGroupExpanded(name);
        root.groupExpanded = next;
    }

    // Per-account process-table sort, keyed by account name -> {col, asc}.
    // Independent per account -- each has its own header row, so clicking
    // claude's "pid" header doesn't touch claude2/claude3's ordering.
    property var groupSort: ({})

    // ---- search box: shared picker query DSL (query-dsl.md / QueryDsl.qml)
    // -- same grammar as the app launcher and RSS reader, "/" to focus, same
    // import (not a port) per that doc's own "stays copy-pasted... add a new
    // consumer, add its row" convention. A flat list of rows across all 3
    // account groups here rather than a variable column view, so /ft /at
    // /rt are inert (same call the RSS reader made for the same reason) --
    // only /fv (bare text or field:value) and /s /rv actually do anything.
    // Global across every account's table at once: while searching, its
    // /s /rv (if present) override that account's own column-click sort
    // (root.groupSort) for every group, not just one.
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

    // All three view-state pieces reset on every panel open *and* close
    // -- this Rectangle instance is never destroyed (only its height
    // collapses to 0, same "sibling overlay" pattern as Media/
    // CalendarExpanded), so without this a fold, a sort, or a manual
    // column resize from one look at the panel would silently still be
    // there next time. First version only reset groupSort, leaving fold
    // state to persist (reasoned, at the time, that persisting collapse
    // felt like the more useful default) -- reported as inconsistent with
    // the intended "clean slate every open" behavior, so all three reset
    // together now.
    onExpandedChanged: {
        root.groupExpanded = ({});
        root.groupSort = ({});
        // root.searchText alone doesn't clear the box -- searchInput.text
        // only flows one way into it (onTextChanged), so the TextInput's
        // own text needs setting directly too (reported 2026-09-01: box
        // still had the last query on reopen).
        searchInput.text = "";
        root.searchText = "";
        root.resetColumnWidths();
    }

    function toggleSort(account, col) {
        const cur = root.groupSort[account];
        const next = Object.assign({}, root.groupSort);
        next[account] = (cur && cur.col === col) ? { col: col, asc: !cur.asc } : { col: col, asc: true };
        root.groupSort = next;
    }
    function sortArrow(account, col) {
        const s = root.groupSort[account];
        return (s && s.col === col) ? (s.asc ? " ▲" : " ▼") : "";
    }
    // undefined/null (context_tokens can be either for a session with no
    // recorded usage yet) sorts as lower than any real number, in both
    // directions -- "no data" reads more sensibly grouped at one end than
    // scattered wherever 0 would fall.
    function compareForSort(a, b, col) {
        switch (col) {
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

    // How many process rows each *expanded* account group gets to show,
    // derived from the real remaining vertical budget rather than a fixed
    // count -- so one account open alone gets to show many more than when
    // all 3 are open together. The header/row heights below are rendered-
    // size estimates (not measured live -- doing that without a two-pass
    // layout would mean each group's budget depending on its siblings'
    // actual process counts, which themselves depend on their own budget:
    // circular), calibrated against real screenshots rather than guessed
    // once and left alone -- an earlier, more conservative pass (rowH 20,
    // groupHeaderH 78, a 20px safety margin) reliably left 10-20% of
    // maxPanelHeight unused before truncating with "+N more", reported
    // "it still is using only about 80-90%". Tightened here; `root.clip:
    // true` is the actual backstop against a rare 1-2px partial last row
    // now that the margin's thinner, not a promise of zero clipping.
    // Both nudged down 1px from 18/84 to reflect acctCol's spacing
    // tightening (2 -> 1) above.
    readonly property int rowH: 17
    readonly property int groupHeaderH: 78
    readonly property int collapsedH: 18
    // Search box Rectangle (22px) + the one extra `content` Column
    // spacing gap (10px) it added between the mode-line and the first
    // account group -- wasn't part of the fixedOverhead estimate below
    // when that box was added, so every group's row budget stayed
    // computed as if it didn't exist, silently overshooting by ~32px
    // (about 2 rows) and clipping the last 2-3 lines of the last group
    // (reported 2026-09-02).
    readonly property int searchBoxH: 32

    // Shared column widths -- the process-list header row and every data
    // row below it bind to these same values so the two stay aligned
    // without hardcoding the same number twice. Mutable (not readonly):
    // each column's own resize handle (see ColumnResizeHandle usages
    // below) drags these directly, and resetColumnWidths() below restores
    // colDefaults on every panel open/close, same as groupExpanded/
    // groupSort -- a manual resize isn't meant to quietly outlive the
    // look at the panel that made it, any more than a fold or a sort is.
    // title raised again (140 -> 280) alongside Bar.qml's
    // claudeUsagePanelWidth bump (760 -> 920) -- "make the panel wider to
    // give more space to make the title column wider" 2026-09-01.
    // title widened / last narrowed alongside the panel's own 30% width
    // bump (Bar.qml's claudeUsagePanelWidth, 920 -> 1196) -- "make last
    // narrower and title wider" 2026-09-01, same request that added the
    // hyprland group (workspace/monitor, "#"/"monitor" headers) below.
    readonly property var colDefaults: ({
        status: 52, title: 400, tokens: 60, last: 44,
        tmuxSession: 54, tmuxWindow: 50, tmuxPane: 40,
        hyprWorkspace: 28, hyprMonitor: 56,
        pid: 68, path: 100,
    })
    // Sized for the "status" header label (6 chars) plus its clickable
    // sort-arrow suffix (" ▲"/" ▼"), not the shorter idle/busy/wait values
    // it holds -- the header row hit the exact same "wider label
    // overflows a value-sized column" bug the status *value* column had
    // before "waiting" got abbreviated to "wait".
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
    readonly property real tableNaturalWidth: root.colStatusW + root.handleW
        + root.colTitleW + root.handleW + root.colTokensW + root.handleW
        + root.colLastW + root.handleW + root.colTmuxGroupW + root.handleW
        + root.colHyprGroupW + root.handleW + root.colPidW + root.handleW
        + root.colPathW
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

    readonly property int expandedGroupCount: {
        let n = 0;
        for (const a of ClaudeUsageSvc.accounts)
            if (root.isGroupExpanded(a.account))
                n++;
        return n;
    }
    readonly property real processAreaBudget: {
        const collapsedCount = ClaudeUsageSvc.accounts.length - root.expandedGroupCount;
        // 40: mode-line text (~14px) + the content Column's own spacing
        // gaps between its visible top-level children (~30px, varies
        // slightly with how many groups are visible). 24: root's own
        // implicitHeight padding (content.implicitHeight + 24). 16: safety
        // margin -- was cut to 4 from an original 20 to reclaim wasted
        // height, but 4 proved too thin in practice: the last "+N more"
        // line was visibly clipped (reported 2026-08-31). 16 is a
        // middle ground between the two.
        const fixedOverhead = 40 + 24 + 16 + root.searchBoxH
            + root.expandedGroupCount * root.groupHeaderH
            + collapsedCount * root.collapsedH;
        return Math.max(0, root.maxPanelHeight - fixedOverhead);
    }
    // Water-filling row allocation across expanded groups, keyed by
    // account name -> row count. An equal per-group split (the original
    // version of this) wastes height whenever some group has fewer real
    // processes than its equal share: that leftover just sat unused
    // instead of flowing to a group that actually has more to show,
    // which is what made the whole panel visibly shrink on folding a
    // group even while another one still had a "+N more" waiting to grow
    // into the freed space (reported 2026-08-31). Processing
    // smallest-total-first and handing each group only what it can use,
    // with every leftover row rolling forward to the remaining groups,
    // means the panel only shrinks when there's genuinely nothing left
    // to show anywhere, not from an uneven split.
    readonly property var groupRowBudgets: {
        const totalRows = Math.max(0, Math.floor(root.processAreaBudget / root.rowH));
        const items = [];
        for (const a of ClaudeUsageSvc.accounts) {
            if (root.isGroupExpanded(a.account)) {
                items.push({ account: a.account, total: (ClaudeUsageSvc.sessions[a.account] || []).length });
            }
        }
        items.sort((x, y) => x.total - y.total);

        let remaining = totalRows;
        const budgets = {};
        for (let i = 0; i < items.length; i++) {
            const groupsLeft = items.length - i;
            const fairShare = Math.max(1, Math.floor(remaining / groupsLeft));
            const give = Math.min(items[i].total, fairShare, remaining);
            budgets[items[i].account] = give;
            remaining -= give;
        }
        return budgets;
    }
    function rowBudgetFor(account) {
        return root.groupRowBudgets[account] || 0;
    }

    Column {
        id: content
        x: 12
        y: 12
        width: parent.width - 24
        spacing: 10

        Text {
            width: parent.width
            text: root.tick >= 0 ? root.modeLine() + " -- " + qsTr("updated %1 ago").arg(root.fmtAgo(ClaudeUsageSvc.updatedAt)) : ""
            color: Theme.textDim
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 2
            elide: Text.ElideRight
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
                // popup if one's open; otherwise clears the query and
                // stays focused (a non-empty query is the common case
                // worth a dedicated undo step). Escape on an already-empty
                // box with no popup open isn't accepted here, so it
                // bubbles up to Bar.qml's root.Keys.onPressed, which is
                // what actually closes the whole panel -- no explicit
                // refocus plumbing needed, that's just normal Qt Quick
                // key-event bubbling.
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Escape) {
                        if (root.acOpen) {
                            root.acDismissed = true;
                            event.accepted = true;
                        } else if (searchInput.text.length > 0) {
                            searchInput.text = "";
                            event.accepted = true;
                        }
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

        Repeater {
            model: ClaudeUsageSvc.accounts

            delegate: Column {
                id: acctCol
                width: content.width
                // 2 -> 1: reclaims a little vertical space across the ~20
                // rows/headers each account block can have, compounding
                // into a real amount -- reported "there is a lot of empty
                // space above" the tmux header, asking for the whole
                // table to sit one line higher.
                spacing: 1

                required property var modelData
                readonly property bool hasSession: typeof modelData.session_pct === "number"
                readonly property bool hasWeekly: typeof modelData.weekly_pct === "number"
                readonly property bool groupOpen: root.isGroupExpanded(modelData.account)
                // Every alive process for this account, most-recently-active
                // first (claude-usage-daemon.py's list_sessions()) -- 20-40
                // of these routinely exist per account here, almost all idle
                // resumed shells, so visibleProcs below is what actually
                // renders; procs.length (the real total) drives "+N more".
                readonly property var procs: ClaudeUsageSvc.sessions[modelData.account] || []
                // Search box (root.searchParsed) narrows procs before either
                // sort applies -- an empty query matches everything (terms
                // is []), so this is a no-op until something's typed.
                readonly property var searchFilteredProcs: {
                    root.searchParsed; // dependency
                    const terms = root.searchParsed.terms;
                    if (terms.length === 0)
                        return procs;
                    return procs.filter(p => terms.every(t => root._searchMatches(p, t, modelData.account)));
                }
                // Column-header-click sort, this account's own (see
                // root.groupSort) -- falls back to the daemon's own
                // most-recent-first order when nothing's been clicked. The
                // search box's own /s /rv, when present, override this for
                // every group at once (see root.searchParsed's own comment).
                readonly property var sortSpec: root.groupSort[modelData.account]
                readonly property var sortedProcs: {
                    const base = searchFilteredProcs;
                    const s = root.searchParsed.sort;
                    let arr;
                    if (s) {
                        const fields = QueryDsl.resolvePath(s.field, root.searchTypeNames);
                        const f = fields.length === 1 ? fields[0] : (fields[0] || "title");
                        arr = base.slice().sort((a, b) => {
                            const av = String(root._searchFieldVals(a, f, modelData.account)[0] || "").toLowerCase();
                            const bv = String(root._searchFieldVals(b, f, modelData.account)[0] || "").toLowerCase();
                            const c = av < bv ? -1 : (av > bv ? 1 : 0);
                            return s.dir === "desc" ? -c : c;
                        });
                    } else if (sortSpec) {
                        arr = base.slice().sort((a, b) => root.compareForSort(a, b, sortSpec.col));
                        if (!sortSpec.asc)
                            arr.reverse();
                    } else {
                        arr = base;
                    }
                    return root.searchParsed.reverse ? arr.slice().reverse() : arr;
                }
                readonly property int rowBudget: root.rowBudgetFor(modelData.account)
                readonly property var visibleProcs: groupOpen ? sortedProcs.slice(0, rowBudget) : []
                readonly property int hiddenProcCount: groupOpen ? Math.max(0, searchFilteredProcs.length - rowBudget) : 0

                Item {
                    id: heading
                    width: headingRow.width
                    height: headingRow.height

                    Row {
                        id: headingRow
                        spacing: 6

                        Text {
                            // Folded (collapsed): points right. Unfolded
                            // (expanded): points down. Plain Unicode
                            // triangles, not a Nerd Font glyph -- no
                            // icon-font dependency needed for two shapes
                            // this simple.
                            text: acctCol.groupOpen ? "▾" : "▸"
                            color: Theme.textDim
                            font.pixelSize: Theme.fontSize + 2
                            anchors.verticalCenter: nameText.verticalCenter
                        }
                        Text {
                            id: nameText
                            text: acctCol.modelData.account || ""
                            color: Theme.text
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize
                            font.bold: true
                        }
                    }

                    // MouseArea deliberately lives on this wrapping Item,
                    // not inside headingRow itself -- a MouseArea with
                    // anchors.fill: parent whose parent is the Row it's
                    // also a child of creates a layout cycle (the Row's
                    // own size depends on its children, one of which then
                    // depends back on the Row's size), which silently
                    // collapsed this whole heading to zero size the first
                    // time this was written that way.
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.toggleGroup(acctCol.modelData.account)
                    }
                }

                // A stale reading still shows its (dimmed) numbers below --
                // this is just the "why" note, not a replacement for them.
                // Only a genuinely never-fetched account has no numbers to
                // dim, in which case this is the only line shown.
                Text {
                    visible: parent.groupOpen && !!modelData.error
                    width: parent.width
                    text: parent.hasSession || parent.hasWeekly
                        ? qsTr("%1 -- showing last known values").arg(modelData.error)
                        : qsTr("error: %1").arg(modelData.error)
                    color: Theme.red
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                    elide: Text.ElideRight
                }

                RowLayout {
                    visible: parent.groupOpen && parent.hasSession
                    opacity: modelData.stale ? 0.55 : 1
                    width: parent.width
                    spacing: 10

                    Text {
                        text: qsTr("session %1%").arg(Math.round(modelData.session_pct))
                        color: Theme.rampColor(modelData.session_pct / 100)
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 1
                    }
                    Text {
                        text: root.tick >= 0 ? root.fmtResets(modelData.session_resets_at) : ""
                        color: Theme.textDim
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 2
                    }
                    Item { Layout.fillWidth: true }
                }

                RowLayout {
                    visible: parent.groupOpen && parent.hasWeekly
                    opacity: modelData.stale ? 0.55 : 1
                    width: parent.width
                    spacing: 10

                    Text {
                        text: qsTr("weekly %1%").arg(Math.round(modelData.weekly_pct))
                        color: Theme.rampColor(modelData.weekly_pct / 100)
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 1
                    }
                    Text {
                        text: root.tick >= 0 ? root.fmtResets(modelData.weekly_resets_at) : ""
                        color: Theme.textDim
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 2
                    }
                    Item { Layout.fillWidth: true }
                }

                // Both header rows below sit inside their own Column,
                // shifted up 16px (roughly one header line) via a
                // transform -- a plain visual offset, not a layout change
                // (acctCol still reserves this block's normal height, so
                // nothing below it shifts to compensate). Deliberately
                // overlaps the bottom of the "weekly" line above; asked
                // for explicitly ("it's okay because they are away from
                // each other" -- horizontally, weekly's text is short and
                // left-aligned while the header row's content starts
                // further right, so the overlap in practice doesn't
                // collide with actual glyphs).
                Column {
                    spacing: 1
                    transform: Translate { y: -16 }

                // Group-header row, once per group -- blank over every
                // plain column, one "tmux" label (underlined, to read as
                // a group heading for the session/window/pane sub-columns
                // below it rather than a 4th independent column) spanning
                // the 3 tmux sub-columns. Same column widths as the two
                // rows below it (root.col*W, gaps all root.handleW) so all
                // three stay aligned; clicking the "tmux" label sorts by
                // the group as a whole (session, then window, then pane --
                // see root.compareForSort), the 3 sub-columns don't get
                // their own individual sort. Gaps here are plain Items,
                // not ColumnResizeHandles -- dragging happens on the
                // column-header row below; this row just has to match its
                // widths.
                RowLayout {
                    visible: acctCol.groupOpen && acctCol.procs.length > 0
                    width: content.width
                    spacing: 0

                    Item { Layout.preferredWidth: root.colStatusW }
                    Item { Layout.preferredWidth: root.handleW }
                    Item { Layout.preferredWidth: root.colTitleW }
                    Item { Layout.preferredWidth: root.handleW }
                    Item { Layout.preferredWidth: root.colTokensW }
                    Item { Layout.preferredWidth: root.handleW }
                    Item { Layout.preferredWidth: root.colLastW }
                    Item { Layout.preferredWidth: root.handleW }
                    // Group labels themselves are plain, non-interactive
                    // text -- no MouseArea, no cursor change, no sort.
                    // Only the sub-columns below (session/window/pane,
                    // #/monitor) sort anything, each independently
                    // (request 2026-09-02: "there should be no action
                    // when user clicks on [the group labels]").
                    Text {
                        text: qsTr("tmux")
                        color: Theme.muted
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 3
                        horizontalAlignment: Text.AlignHCenter
                        Layout.preferredWidth: root.colTmuxGroupW
                        // A full-width rule spanning the whole group (all
                        // 3 sub-columns), not font.underline (tried
                        // first) -- that only underlines the "tmux" glyphs
                        // themselves, much narrower than the session/
                        // window/pane span it's meant to mark as one
                        // group. A child of the Text, not a RowLayout
                        // sibling, so it doesn't add its own row -- Items
                        // don't inflate the size of the Text they're
                        // parented to.
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

                // Column headers, once per group -- shares its widths with
                // the data row below via root.col*W so the two stay
                // aligned without repeating "pid"/"tok" on every single
                // row. Status/title/tokens/last/pid/path are each
                // individually clickable: sorts this account's table by
                // that column, a second click on the same one flips
                // ascending/descending (root.toggleSort), and a ▲/▼ marks
                // whichever column is currently driving the order (the
                // tmux group's own arrow lives on its label in the row
                // above, not here -- session/window/pane are plain labels,
                // not separately sortable). Sort state resets on every
                // panel open/close (root.onExpandedChanged), so it never
                // silently persists into an unrelated later look at the
                // panel.
                //
                // Every gap between two columns is a ColumnResizeHandle
                // (hover -> resize cursor, drag -> adjusts the column
                // immediately to its left; see that component's own
                // comment for why it reports the drag via a signal rather
                // than writing the bound property directly). All 9
                // columns are independent fixed widths now, not one
                // fillWidth column auto-absorbing spare space -- with
                // manual resize available there's no need for that
                // anymore, and a trailing filler after "path" soaks up any
                // genuine leftover row width instead. Resizes reset on
                // every panel open/close along with fold state and sort
                // (root.onExpandedChanged / root.resetColumnWidths()).
                RowLayout {
                    visible: acctCol.groupOpen && acctCol.procs.length > 0
                    width: content.width
                    spacing: 0

                    Text {
                        text: qsTr("status") + root.sortArrow(modelData.account, "status")
                        color: Theme.muted
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 3
                        Layout.preferredWidth: root.colStatusW
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.toggleSort(modelData.account, "status")
                        }
                    }
                    ColumnResizeHandle {
                        Layout.preferredWidth: root.handleW
                        Layout.fillHeight: true
                        targetWidth: root.colStatusW
                        onWidthChangeRequested: w => root.colStatusW = w
                    }
                    Text {
                        text: qsTr("title") + root.sortArrow(modelData.account, "title")
                        color: Theme.muted
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 3
                        elide: Text.ElideRight
                        Layout.preferredWidth: root.colTitleW
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.toggleSort(modelData.account, "title")
                        }
                    }
                    ColumnResizeHandle {
                        Layout.preferredWidth: root.handleW
                        Layout.fillHeight: true
                        targetWidth: root.colTitleW
                        onWidthChangeRequested: w => root.colTitleW = w
                    }
                    Text {
                        text: qsTr("tokens") + root.sortArrow(modelData.account, "tokens")
                        color: Theme.muted
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 3
                        Layout.preferredWidth: root.colTokensW
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.toggleSort(modelData.account, "tokens")
                        }
                    }
                    ColumnResizeHandle {
                        Layout.preferredWidth: root.handleW
                        Layout.fillHeight: true
                        targetWidth: root.colTokensW
                        onWidthChangeRequested: w => root.colTokensW = w
                    }
                    Text {
                        text: qsTr("last") + root.sortArrow(modelData.account, "active")
                        color: Theme.muted
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 3
                        horizontalAlignment: Text.AlignRight
                        Layout.preferredWidth: root.colLastW
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.toggleSort(modelData.account, "active")
                        }
                    }
                    ColumnResizeHandle {
                        Layout.preferredWidth: root.handleW
                        Layout.fillHeight: true
                        targetWidth: root.colLastW
                        onWidthChangeRequested: w => root.colLastW = w
                    }
                    Text {
                        text: qsTr("session") + root.sortArrow(modelData.account, "tmuxSession")
                        color: Theme.muted
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 3
                        Layout.preferredWidth: root.colTmuxSessionW
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.toggleSort(modelData.account, "tmuxSession")
                        }
                    }
                    ColumnResizeHandle {
                        Layout.preferredWidth: root.handleW
                        Layout.fillHeight: true
                        targetWidth: root.colTmuxSessionW
                        onWidthChangeRequested: w => root.colTmuxSessionW = w
                    }
                    Text {
                        text: qsTr("window") + root.sortArrow(modelData.account, "tmuxWindow")
                        color: Theme.muted
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 3
                        Layout.preferredWidth: root.colTmuxWindowW
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.toggleSort(modelData.account, "tmuxWindow")
                        }
                    }
                    ColumnResizeHandle {
                        Layout.preferredWidth: root.handleW
                        Layout.fillHeight: true
                        targetWidth: root.colTmuxWindowW
                        onWidthChangeRequested: w => root.colTmuxWindowW = w
                    }
                    Text {
                        text: qsTr("pane") + root.sortArrow(modelData.account, "tmuxPane")
                        color: Theme.muted
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 3
                        Layout.preferredWidth: root.colTmuxPaneW
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.toggleSort(modelData.account, "tmuxPane")
                        }
                    }
                    ColumnResizeHandle {
                        Layout.preferredWidth: root.handleW
                        Layout.fillHeight: true
                        targetWidth: root.colTmuxPaneW
                        onWidthChangeRequested: w => root.colTmuxPaneW = w
                    }
                    Text {
                        // Labeled "#" not "workspace" -- values are almost
                        // always a single digit, so the full word wasted
                        // most of colHyprWorkspaceW; a hover hint (below)
                        // keeps it identifiable without spending the
                        // width permanently (request 2026-09-02).
                        id: hyprWorkspaceHeader
                        text: qsTr("#") + root.sortArrow(modelData.account, "hyprWorkspace")
                        color: Theme.muted
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 3
                        Layout.preferredWidth: root.colHyprWorkspaceW
                        property bool hovering: false
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onEntered: hyprWorkspaceHeader.hovering = true
                            onExited: hyprWorkspaceHeader.hovering = false
                            onClicked: root.toggleSort(modelData.account, "hyprWorkspace")
                        }
                        Rectangle {
                            visible: hyprWorkspaceHeader.hovering
                            anchors.top: parent.bottom
                            anchors.topMargin: 2
                            anchors.left: parent.left
                            z: 50
                            width: hintText.implicitWidth + 8
                            height: hintText.implicitHeight + 4
                            radius: 3
                            color: Theme.bg
                            border.color: Theme.border
                            border.width: 1
                            Text {
                                id: hintText
                                anchors.centerIn: parent
                                text: qsTr("workspace")
                                color: Theme.text
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 3
                            }
                        }
                    }
                    ColumnResizeHandle {
                        Layout.preferredWidth: root.handleW
                        Layout.fillHeight: true
                        targetWidth: root.colHyprWorkspaceW
                        onWidthChangeRequested: w => root.colHyprWorkspaceW = w
                    }
                    Text {
                        text: qsTr("monitor") + root.sortArrow(modelData.account, "hyprMonitor")
                        color: Theme.muted
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 3
                        Layout.preferredWidth: root.colHyprMonitorW
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.toggleSort(modelData.account, "hyprMonitor")
                        }
                    }
                    ColumnResizeHandle {
                        Layout.preferredWidth: root.handleW
                        Layout.fillHeight: true
                        targetWidth: root.colHyprMonitorW
                        onWidthChangeRequested: w => root.colHyprMonitorW = w
                    }
                    Text {
                        text: qsTr("pid") + root.sortArrow(modelData.account, "pid")
                        color: Theme.muted
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 3
                        Layout.preferredWidth: root.colPidW
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.toggleSort(modelData.account, "pid")
                        }
                    }
                    ColumnResizeHandle {
                        Layout.preferredWidth: root.handleW
                        Layout.fillHeight: true
                        targetWidth: root.colPidW
                        onWidthChangeRequested: w => root.colPidW = w
                    }
                    Text {
                        text: qsTr("path") + root.sortArrow(modelData.account, "path")
                        color: Theme.muted
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 3
                        elide: Text.ElideRight
                        Layout.preferredWidth: root.colPathW
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.toggleSort(modelData.account, "path")
                        }
                    }
                    Item { Layout.fillWidth: true }
                }
                } // end header-shift Column

                // Same -16px shift as the header block above, so the data
                // rows immediately follow the (visually-shifted) headers
                // instead of leaving the 16px gap the header shift alone
                // would open up between them -- reported 2026-09-01.
                Column {
                    spacing: 1
                    transform: Translate { y: -16 }

                Repeater {
                    model: acctCol.visibleProcs

                    delegate: RowLayout {
                        required property var modelData
                        width: content.width
                        spacing: 0

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
                        // cycle this file's heading block already ran into
                        // once (see that block's own comment).
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
                                    // this panel's own monitor right now --
                                    // "highlight the workspace number if
                                    // it's the one this panel was invoked
                                    // from" 2026-09-02.
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

                // Real remaining count, not a vague "more" -- rowBudget is
                // a fit-estimate (see groupRowBudgets' own comment), so
                // this can be slightly off if a row rendered shorter/
                // taller than assumed, but it's always derived from
                // procs.length, the true total the daemon sent, never
                // silently dropped.
                Text {
                    visible: acctCol.hiddenProcCount > 0
                    text: qsTr("+%1 more").arg(acctCol.hiddenProcCount)
                    color: Theme.muted
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                    topPadding: 1
                }
                } // end rows-shift Column
            }
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
}
