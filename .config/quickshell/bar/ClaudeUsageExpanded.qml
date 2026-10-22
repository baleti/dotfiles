import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
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

    // Emitted by focusHyprWindow() once a row's window has been focused --
    // Bar.qml owns closing the panel from this (it also has to clear
    // claudeUsagePinned, not just this component's own `expanded`; see the
    // comment there).
    signal picked()

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

    // Absolute local reset time for the hover hint, "Thu 22 Oct 18:30".
    function fmtResetAt(iso) {
        const d = iso ? new Date(iso) : null;
        if (!d || isNaN(d.getTime()))
            return "--";
        return Qt.formatDateTime(d, "ddd d MMM HH:mm");
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
        "frozen": Theme.cyan,
        "stopped": Theme.textDim,
    })
    function statusColor(status) {
        return root.statusColors[status] || Theme.textDim;
    }
    // "waiting" was abbreviated for a fixed-width status column that no
    // longer exists -- statusNaturalW below now sizes the column to the
    // widest label actually present, so it's kept short here only because
    // it's already established, not because a longer word would overflow.
    readonly property var statusLabels: ({
        "busy": qsTr("busy"),
        "waiting": qsTr("wait"),
        "idle": qsTr("idle"),
        "frozen": qsTr("frozen"),
        "stopped": qsTr("stopped"),
    })
    function statusLabel(status) {
        return root.statusLabels[status] || status || "?";
    }
    // an archived (past) conversation has no process status: it says "archive"
    function rowStatusLabel(r) { return r.archived ? qsTr("archive") : (r.tmuxRow ? qsTr("tmux") : root.statusLabel(r.status)); }
    function rowStatusColor(r) { return (r.archived || r.tmuxRow) ? Theme.textDim : root.statusColor(r.status); }

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

    // ---- keyboard row selection (routed in from Bar.qml's
    // root.Keys.onPressed via handleKey(), same shape as
    // CalendarExpanded.handleKey) -- Up/Down walk the visible rows
    // starting from the top, Space/Enter focuses the selected row's
    // window (identical to clicking the row). selActive gates the
    // highlight + left-side thumbnail so a freshly-opened panel shows
    // neither until the user actually starts navigating.
    property int selIndex: 0
    property bool selActive: false

    // 1-based position of `account` in ClaudeUsageSvc.accounts -- the bare
    // number the "acct" column shows (hover for the real name) and what
    // its column-sort compares on.
    function acctIndex(account) {
        for (let i = 0; i < ClaudeUsageSvc.accounts.length; i++)
            if (ClaudeUsageSvc.accounts[i].account === account)
                return i + 1;
        return 0;
    }

    // Sessions across every account -- the total pill on the
    // tally line (request 2026-09-05).
    readonly property int totalSessionCount: {
        let n = 0;
        for (const a of ClaudeUsageSvc.accounts)
            n += (ClaudeUsageSvc.sessions[a.account] || []).length;
        return n;
    }

    // ---- search box: shared picker query DSL (query-dsl.md / QueryDsl.qml)
    // -- same grammar as the app launcher and RSS reader, "/" to focus, same
    // import (not a port) per that doc's own "stays copy-pasted... add a new
    // consumer, add its row" convention. A flat list of rows (the single
    // merged table, all 3 accounts) rather than a variable column view, so
    // /ft /at /rt are inert (same call the RSS reader made for the same
    // reason) -- only /fv (bare text or field:value) and /s actually
    // do anything. Its /s, when present, override the table's own
    // column-click sort (root.sort).
    property string searchText: ""
    readonly property var searchTypeNames: [
        "title", "pid", "status", "tokens", "path", "account",
        "tmux-session", "tmux-window", "tmux-pane",
        "hypr-workspace", "hypr-monitor", "hypr-window",
    ]
    // `/fts term` is rewritten to /fv/fts, so "fts" must resolve as a filter
    // path - but it is a verb, not a type: kept out of completion and /s.
    readonly property var _filterTypeNames: root.searchTypeNames.concat(["fts"])
    // "/fts[/live|/archive] [term]": full-text search of the Claude conversations
    // (Recoll via `claude-history`, the same engine as alt-tab and the tmux
    // picker). Plain /fts covers running AND archived conversations, /fts/live
    // only the running ones, /fts/archive only past ones. For the live rows it
    // is sugar for "/fv/fts term", rewritten before the shared parser sees it.
    // /fts/archive switches the panel to archive rows from
    // `claude-history --sessions`, drops the columns that only make sense for a
    // running session, and Enter/click resumes in a new terminal window.
    // An archived row is also what plain /fts appends after the live matches.
    readonly property var _ftsTokenRe: /(^|\s)(!?)\/fts(?:\/([a-z,-]+))?(?=\s|$)(?:\s+("[^"]*"|(?!\/)\S+))?/g
    // /fts/<keys>: keys fuzzy-resolve against the scope names (query-dsl.md Keys), so
    // live, claude-live, archive, claude and tmux all work; no keys = every scope
    readonly property var ftsScopeNames: ["claude-live", "claude-archive", "tmux"]
    function _ftsScopeOf(keys) {
        if (!keys) return { live: true, archive: true, tmux: true };
        const r = QueryDsl.resolvePath(keys, root.ftsScopeNames);
        return { live: r.indexOf("claude-live") >= 0, archive: r.indexOf("claude-archive") >= 0, tmux: r.indexOf("tmux") >= 0 };
    }
    function _ftsTokens(text) {
        const out = [];
        root._ftsTokenRe.lastIndex = 0;
        let m;
        while ((m = root._ftsTokenRe.exec(text)) !== null)
            out.push({ neg: m[2] === "!", scope: root._ftsScopeOf(m[3]), arg: m[4] ? m[4].replace(/"/g, "") : "" });
        return out;
    }
    // null (no /fts) | { live, archive, tmux }: the union of every /fts token's scopes
    readonly property var ftsScopes: {
        const toks = root._ftsTokens(root.searchText);
        if (toks.length === 0) return null;
        const u = { live: false, archive: false, tmux: false };
        for (const t of toks) for (const k of ["live", "archive", "tmux"]) u[k] = u[k] || t.scope[k];
        return u;
    }
    // archive-only: the short columns (no status / tmux / workspace / pid)
    readonly property bool archiveMode: !!root.ftsScopes && root.ftsScopes.archive && !root.ftsScopes.live && !root.ftsScopes.tmux
    readonly property bool liveRowsIn: !root.ftsScopes || root.ftsScopes.live
    // the term the archive / tmux rows are fetched for ("" = newest, archive-only scope only)
    readonly property string archiveTerm: {
        const t = root._ftsTokens(root.searchText).find(x => !x.neg && x.arg);
        return t ? t.arg : "";
    }
    function _rewriteFts(text) {
        // the live rows are filtered by `/fv/fts term` (hit set from claude-history); a token whose scopes
        // exclude the live rows is dropped (archive / tmux rows come from the --sessions fetch below)
        return text.replace(root._ftsTokenRe, (all, lead, neg, scope, arg) =>
            !root._ftsScopeOf(scope).live ? lead : (arg ? lead + neg + "/fv/fts " + arg : lead));
    }
    property var archiveRows: []
    // sid -> { title, cwd, msgs, tokens, mtime }, kept by claude-fts-index (what supplies the msgs column of live rows)
    property var convMeta: ({})
    FileView {
        path: Quickshell.env("HOME") + "/.cache/indexes/claude/meta.json"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: { try { root.convMeta = JSON.parse(text()); } catch (e) {} }
    }
    onArchiveTermChanged: root._archiveRefresh()
    onFtsScopesChanged: root._archiveRefresh()
    function _archiveRefresh() {
        // archive-only lists even without a term; otherwise archived / tmux hits need a real term
        const sc = root.ftsScopes;
        const want = !!sc && (sc.archive || sc.tmux) && (root.archiveMode || root.archiveTerm !== "");
        if (!want) { root.archiveRows = []; return; }
        const csv = [sc.archive ? "archive" : "", sc.tmux ? "tmux" : ""].filter(x => x).join(",");
        const q = root._ftsTokens(root.searchText).filter(t => t.arg)
            .map(t => (t.neg ? "!" : "") + (/\s/.test(t.arg) ? '"' + t.arg + '"' : t.arg)).join(" ");
        archiveProc.command = [Quickshell.env("HOME") + "/bin/claude-history", "--sessions", q, "--scope", csv];
        archiveProc.running = false;
        archiveProc.running = true;
    }
    Process {
        id: archiveProc
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.archiveRows = JSON.parse(text).map(r => r.kind === "tmux" ? ({
                        // a tmux scrollback hit: shown with its tmux ids, status "tmux"
                        account: "", title: r.title, cwd: r.cwd, session_id: r.session_id, pane_id: r.pane_id,
                        context_tokens: null, msgs: "", updated_at_ms: (r.mtime || 0) * 1000,
                        status: "tmux", pid: 0, tmuxRow: true, score: r.score,
                        tmux_session: r.sess, tmux_window: r.win, tmux_pane: r.pane
                    }) : ({
                        account: r.account, title: r.title, cwd: r.cwd, session_id: r.session_id,
                        context_tokens: r.tokens, msgs: r.msgs, updated_at_ms: (r.mtime || 0) * 1000,
                        status: "", pid: 0, archived: true, score: r.score
                    }));
                } catch (e) {
                    root.archiveRows = [];
                }
            }
        }
    }
    Process { id: resumeProc }
    function resumeRow(row) {
        ClaudeUsageQueryHistory.record(root.searchText);
        resumeProc.exec([Quickshell.env("HOME") + "/bin/claude-history", "--resume-window", row.session_id]);
        root.picked();
    }
    readonly property var searchParsed: QueryDsl.parse(root._rewriteFts(root.searchText))

    // fts hits: lowercase term -> { sessionId: relevance % }, filled by one
    // query per distinct term (queue drained by ftsProc).
    property var ftsHits: ({})
    property var _ftsQueue: []
    property string _ftsCurrent: ""
    function _ftsTerms() {
        const out = [];
        for (const t of root.searchParsed.terms) {
            if (t.field === undefined || !t.value) continue;
            if (QueryDsl.resolvePath(t.field, root._filterTypeNames).indexOf("fts") < 0) continue;
            const v = String(t.value).toLowerCase();
            if (out.indexOf(v) < 0) out.push(v);
        }
        return out;
    }
    function _ftsRefresh() {
        const terms = root._ftsTerms();
        if (terms.length === 0) {
            if (root.searchText === "") root.ftsHits = ({});
            return;
        }
        root._ftsQueue = terms.filter(v => root.ftsHits[v] === undefined);
        root._ftsNext();
    }
    function _ftsNext() {
        if (ftsProc.running || root._ftsQueue.length === 0) return;
        root._ftsCurrent = root._ftsQueue[0];
        root._ftsQueue = root._ftsQueue.slice(1);
        ftsProc.command = [Quickshell.env("HOME") + "/bin/claude-history", "--fts", root._ftsCurrent];
        ftsProc.running = true;
    }
    onSearchParsedChanged: root._ftsRefresh()

    // Match preview (only while /fts is in the query): excerpts of the
    // highlighted row's conversation around the searched words.
    function _snipTerms() {
        if (root.archiveMode)
            return root.archiveTerm ? [root.archiveTerm] : [];
        return root._ftsTerms();
    }
    readonly property bool ftsActive: root._snipTerms().length > 0
    // Sized to the excerpts (at least 150), but never past half the panel's
    // height - the table's viewport gives up what the strip takes.
    readonly property real snippetH: Math.min(root.maxPanelHeight * 0.5, Math.max(150, snippetText.implicitHeight + 14))
    property string snippetHtml: ""
    property string _snipKey: ""
    function _snipRefresh() {
        const terms = root._snipTerms();
        const row = root.sortedProcs[root.selActive ? root.selIndex : 0];
        if (terms.length === 0 || !row || !row.session_id) {
            root._snipKey = ""; root.snippetHtml = "";
            return;
        }
        const key = row.session_id + "|" + terms.join(" ");
        if (key === root._snipKey) return;
        root._snipKey = key;
        snipProc.command = [Quickshell.env("HOME") + "/bin/claude-history", "--snippets", row.session_id, terms.join(" ")];
        snipProc.running = false;
        snipProc.running = true;
    }
    onSelIndexChanged: root._snipRefresh()
    onSelActiveChanged: root._snipRefresh()
    Process {
        id: snipProc
        stdout: StdioCollector {
            onStreamFinished: {
                const esc = t => t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
                const hit = "<b><font color=\"" + Theme.cyan + "\">";
                root.snippetHtml = text.split("\n").filter(l => l.length > 0)
                    .map(l => esc(l).replace(/\x01/g, hit).replace(/\x02/g, "</font></b>"))
                    .join("<br><br>");
            }
        }
    }
    Process {
        id: ftsProc
        stdout: StdioCollector {
            onStreamFinished: {
                const hits = {};
                for (const line of text.split("\n")) {
                    const m = line.split("\t");
                    if (m.length === 2) hits[m[0]] = parseFloat(m[1]);
                }
                const nh = Object.assign({}, root.ftsHits);
                nh[root._ftsCurrent] = hits;
                root.ftsHits = nh;
                root._ftsNext();
            }
        }
    }
    function _searchFieldVals(row, field, account) {
        switch (field) {
        case "title": return [row.title || ""];
        case "pid": return [String(row.pid)];
        case "status": return [row.archived ? "archive" : (row.tmuxRow ? "tmux" : (row.status || ""))];
        case "tokens": return [row.context_tokens !== null && row.context_tokens !== undefined ? String(row.context_tokens) : ""];
        case "path": return [root.shortCwd(row.cwd)];
        case "account": return [account];
        case "tmux-session": return [row.tmux_session || ""];
        case "tmux-window": return [row.tmux_window || ""];
        case "tmux-pane": return [row.tmux_pane || ""];
        case "hypr-workspace": return [row.hypr_workspace || ""];
        case "hypr-monitor": return [row.hypr_monitor || ""];
        case "hypr-window": return [row.hypr_address || ""];
        }
        return [];
    }
    function _searchMatches(row, term, account) {
        return QueryDsl.applyNeg(term, root._searchMatchesPos(row, term, account));
    }
    function _searchMatchesPos(row, term, account) {
        if (term.text !== undefined) {
            const hay = (row.title + " " + row.pid + " " + (row.status || "") + " "
                         + root.shortCwd(row.cwd) + " " + account).toLowerCase();
            return QueryDsl.substr(term.text, hay, term.quoted);
        }
        const fields = QueryDsl.resolvePath(term.field, root._filterTypeNames);
        if (fields.length === 0)
            return false; // unresolvable complete path -> narrows to nothing
        for (const f of fields) {
            if (f === "fts" && (row.archived || row.tmuxRow))
                return true; // already a hit: claude-history only returned matching archived rows
            if (f === "fts") {
                // BM25 hit set from claude-history, not QueryDsl.substr.
                const hits = root.ftsHits[String(term.value).toLowerCase()];
                if (hits && row.session_id && hits[row.session_id] !== undefined) return true;
                continue;
            }
            for (const v of root._searchFieldVals(row, f, account)) {
                if (QueryDsl.substr(term.value, String(v), term.quoted))
                    return true;
            }
        }
        return false;
    }
    function focusSearch() {
        // Moving focus into the search box is a mode switch away from row
        // navigation -- drop the keyboard selection state so its highlight
        // and the left-side thumbnail don't linger over the table.
        root.selActive = false;
        root.thumbKeyboardActive = false;
        searchInput.forceActiveFocus();
        searchInput.selectAll();
    }

    // ---- single merged process table across every account -------------
    // Every alive process across every account, tagged with which account
    // it's from -- what the one flat table is built from now, replacing
    // the old per-account Repeater-of-Repeaters shape.
    readonly property var allProcs: {
        const out = [];
        if (root.liveRowsIn)
            for (const a of ClaudeUsageSvc.accounts)
                for (const row of (ClaudeUsageSvc.sessions[a.account] || []))
                    out.push(Object.assign({ account: a.account, msgs: (root.convMeta[row.session_id] || {}).msgs }, row));
        // archived / tmux hits follow the live ones (or are all there is, in archive-only / tmux-only views)
        return root.ftsScopes ? out.concat(root.archiveRows) : out;
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
    // The search box's own /s, when present, overrides it (see
    // root.searchParsed).
    readonly property var sortedProcs: {
        const base = root.searchFilteredProcs;
        const s = root.searchParsed.sort;
        // Each key resolves to one or more fields (fuzzy keys expand, query-dsl.md "Keys");
        // a key that names nothing makes the *whole* /sort inert.
        const keys = s ? QueryDsl.resolveSortKeys(s.fields, root.searchTypeNames) : null;
        let arr;
        if (s && keys !== null) {
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
        } else if (root.archiveMode && !root.sort) {
            arr = base.slice(); // archive rows arrive best match (or newest) first
        } else if (root._ftsTerms().length > 0 && !root.sort) {
            // /fts active and nothing explicitly sorted: best BM25 match first
            const score = r => (r.archived || r.tmuxRow) ? (r.score || 0) : root._ftsTerms().reduce((acc, t) =>
                acc + ((root.ftsHits[t] || {})[r.session_id] || 0), 0);
            arr = base.slice().sort((a, b) => score(b) - score(a));
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
        return arr;
    }

    // Keep the keyboard selection in range as the daemon's row set (or a
    // search filter) shrinks under it.
    onSortedProcsChanged: {
        root._snipRefresh();
        if (root.selIndex > root.sortedProcs.length - 1)
            root.selIndex = Math.max(0, root.sortedProcs.length - 1);
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
        "account": "claude / claude2 / claude3 / claude4 / claude5 / claude6 / claude7 / claude8",
        "tmux-session": "tmux session id",
        "tmux-window": "tmux window id",
        "tmux-pane": "tmux pane id",
        "hypr-workspace": "hyprland workspace",
        "hypr-monitor": "hyprland monitor",
        "hypr-window": "hyprland window address",
        "fts": "full text of the Claude conversation (periodically indexed); /fts term",
    })
    readonly property var _acVerbs: ["/fv", "/s"]

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
            // A leading "!" negates the term (query-dsl.md "Negation"); it is
            // not part of the command, so the span starts after it.
            const bang = text[i] === "!" ? 1 : 0;
            const tok = text.slice(i + bang, j);
            i = j;
            if (tok.length > 1 && tok[0] === "/") {
                if (/^\/fts(\/[a-z,-]+)?$/.test(tok) || QueryDsl.canonVerb({ q: false, v: tok })) {
                    spans.push({ start: start + bang, end: start + bang + tok.length, valid: true });
                } else if (!root._isVerbPrefix(tok)) {
                    spans.push({ start: start + bang, end: start + bang + tok.length, valid: false });
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

    // The full Verb-stage vocabulary: the three verbs that do anything here
    // (`_acVerbs`) plus `/fv` and `/s` - the two that take a real path -
    // crossed with every type name ("fv/tokens", "s/tmux-session", ...), so
    // a fragment of the *type*, not just the verb, reaches a whole working
    // command. See query-dsl.md's
    // "Verb-stage depth".
    function _verbStageUniverse() {
        const bare = root._acVerbs.map(v => v.slice(1)).concat(["fts", "fts/claude", "fts/claude-live", "fts/claude-archive", "fts/tmux"]);
        const deep = [];
        for (const v of ["fv", "s"])
            for (const n of root.searchTypeNames)
                deep.push(v + "/" + n);
        return bare.concat(deep);
    }

    // A deep candidate lands the via form ("/fv/tokens "), matching this
    // panel's own steering everywhere else in _acCandidates.
    function _verbStageItem(prefix, v) {
        if (v.startsWith("fts"))
            return { text: prefix + "/" + v + " ", label: "/" + v, alias: "",
                     desc: v === "fts" ? "full text of the running and archived Claude conversations"
                         : v === "fts/tmux" ? "full text of tmux scrollback (panes without a Claude session)"
                         : v === "fts/claude" ? "full text, running and archived conversations"
                         : v === "fts/claude-live" ? "full text, running conversations only"
                         : "full text, past conversations only; Enter resumes one in a new window" };
        const slash = v.indexOf("/");
        if (slash < 0) {
            return { text: prefix + "/" + v + " ", label: "/" + v,
                     alias: QueryDsl.verbInfo["/" + v].long, desc: QueryDsl.verbInfo["/" + v].desc };
        }
        const verb = v.slice(0, slash), name = v.slice(slash + 1);
        return { text: `${prefix}/${verb}/${name}` + (verb === "fv" ? " " : ""), label: "/" + v,
                 alias: QueryDsl.verbInfo["/" + verb].long, desc: root.searchTypeDescs[name] || "" };
    }

    // Ctrl+Space AND-narrowing (query-dsl.md): true while a Verb-stage
    // popup is being narrowed by more than one space-separated fragment;
    // `acVerbMultiStart` freezes the char offset of that completion's
    // opening "/". See the Ctrl+Space key handler below.
    property bool acVerbMulti: false
    property int acVerbMultiStart: 0

    // Ctrl+Space AND-narrowing for the non-Verb popups (type-path, value,
    // sort direction): "//cla" + Tab + Ctrl+Space + "fts" keeps the
    // candidates matching both. `acArgMultiStart` freezes where the fragment
    // began; the first word is completed as usual (via the `tIn` re-entry
    // below) and the rest are ANDed against each candidate's label.
    property bool acArgMulti: false
    property int acArgMultiStart: 0

    function _acCandidates(tIn) {
        if (tIn === undefined && root.acArgMulti) {
            const full = root.searchText;
            if (root.acArgMultiStart <= full.length) {
                const frags = full.slice(root.acArgMultiStart).split(/\s+/).filter(f => f.length > 0);
                return root._acCandidates(full.slice(0, root.acArgMultiStart) + (frags.length > 0 ? frags[0] : ""))
                    .filter(it => frags.slice(1).every(f => String(it.label).indexOf(f) >= 0));
            }
            root.acArgMulti = false;
        }
        const t = tIn !== undefined ? tIn : root.searchText;
        // "//path" is the default-verb spelling of "/fv/path" (query-dsl.md
        // "Default verb"); match the stage regexes against the expanded form,
        // but keep building replacement text from `t` (only the tail differs).
        const tm = t.replace(/(^|\s)\/\/(?=[a-z,-]*(?:\s|$))/g, "$1/fv/");

        if (root.acVerbMulti) {
            if (root.acVerbMultiStart < t.length && t[root.acVerbMultiStart] === "/") {
                const frags = t.slice(root.acVerbMultiStart + 1).split(/\s+/).filter(f => f.length > 0);
                const prefix = t.slice(0, root.acVerbMultiStart);
                return root._verbStageUniverse()
                    .filter(v => frags.every(f => v.indexOf(f) >= 0))
                    .map(v => root._verbStageItem(prefix, v));
            }
            root.acVerbMulti = false; root.acArgMulti = false;
        }

        const fm = t.match(/(?:^|\s|!)\/fts\/([a-z,-]*)$/);
        if (fm) {
            const frag = fm[1].slice(fm[1].lastIndexOf(",") + 1);
            const head = t.slice(0, t.length - frag.length);
            return [["tmux", "tmux scrollback (all panes without a Claude session)"], ["claude", "running and archived conversations"], ["claude-live", "running conversations only"], ["claude-archive", "past conversations only; Enter resumes one in a new window"]]
                .filter(x => x[0].indexOf(frag) >= 0)
                .map(x => ({ text: head + x[0] + " ", label: x[0], alias: "", desc: x[1] }));
        }
        const ks = QueryDsl.keyStageCandidates(t, root.searchTypeNames, root.searchTypeDescs);
        if (ks !== null) return ks;
        const vm = t.match(/(?:^|\s|!)(\/[a-z-]*)$/);
        if (vm) {
            const frag = vm[1].slice(1);
            const prefix = t.slice(0, t.length - vm[1].length);
            return root._verbStageUniverse().filter(v => v.indexOf(frag) >= 0).map(v => root._verbStageItem(prefix, v));
        }

        // value stage:  "//<keys> <frag>"  /  "/fv/<keys> <frag>"
        const val = tm.match(/(?:^|\s)\/(?:fv|filter-value)\/([a-z,-]+)\s+([^\s]*)$/);
        if (val) {
            const field = val[1].toLowerCase();
            const frag = val[2].toLowerCase();
            const base = t.slice(0, t.length - frag.length);
            return root._fieldValueCandidates(field, frag).slice(0, 40)
                .map(v => ({ text: base + v, label: v, alias: "", desc: "" }));
        }

        return [];
    }
    property var acItems: []
    property int acSel: 0
    property bool acDismissed: false
    // A history popup (Ctrl+R) stays open even at zero current
    // candidates - unlike every other kind, where zero means "nothing to
    // complete" - same as zsh's own ctrl-r widget always showing its
    // popup (bug found 2026-09-14 testing winswitch's identical gap).
    readonly property bool acOpen: (acItems.length > 0 || acHistoryMode) && !acDismissed
    onAcItemsChanged: {
        acSel = 0;
        acDismissed = false;
        if (acItems.length === 0) { root.acVerbMulti = false; root.acArgMulti = false; }
    }
    // Keep the highlighted row in view as arrow keys move acSel past
    // the popup's fixed 7-row window -- acList is the ListView defined
    // below, in the same component so its id is visible here.
    onAcSelChanged: acList.positionViewAtIndex(acSel, ListView.Contain)

    function _applyAcItem(it) {
        if (!it) return;
        // choosing an entry of the Ctrl+R history popup ends it (query-dsl.md "Search-box
        // history"); close before the text changes, or the text-change recompute reopens it
        if (root.acHistoryMode) {
            root.acHistoryMode = false;
            root.acItems = [];
            
        }
        root.searchText = it.text;
        searchInput.text = it.text;
        searchInput.cursorPosition = searchInput.text.length;
    }
    function acAccept() {
        root._applyAcItem(root.acItems[root.acSel]);
    }
    function triggerCompletion() {
        root.acHistoryMode = false;
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

    // ---- search-box history (query-dsl.md's "Search-box history") --
    // Ctrl+R reuses the completion popup's own rendering/highlight/accept
    // machinery (acItems/acSel/acAccept/_applyAcItem all already just
    // read-and-replace `it.text` generically) rather than a second popup
    // component - acHistoryMode only changes what *computes* acItems.
    property bool acHistoryMode: false

    // The QML pickers' own approximation of fzf's default fuzzy algorithm
    // (deliberately not this DSL's plain substring rule - see the doc
    // section): ordered-subsequence match, same as fzf's core heuristic
    // without its scoring/highlighting.
    function _fuzzySubsequence(hay, needle) {
        let i = 0;
        for (let j = 0; j < hay.length && i < needle.length; j++)
            if (hay[j] === needle[i]) i++;
        return i === needle.length;
    }

    function _acHistoryCandidates() {
        const q = root.searchText.toLowerCase();
        const entries = ClaudeUsageQueryHistory.listMostRecentFirst();
        const matched = q.length === 0 ? entries
            : entries.filter(e => root._fuzzySubsequence(e.toLowerCase(), q));
        return matched.map(e => ({ text: e, label: e, alias: "", desc: "" }));
    }

    // Ctrl+R: opens unconditionally, even with zero history yet - same as
    // zsh's own ctrl-r widget, which shows its (empty) popup rather than
    // doing nothing the first time there's no history - so the binding is
    // never indistinguishable from unbound.
    function _triggerHistorySearch() {
        root.acHistoryMode = true;
        root.acSel = 0;
        root.acItems = root._acHistoryCandidates();
    }

    // Up/Down cycling: most-recent-first with draft-restore, scoped to
    // whenever the completion/history popup ISN'T open (query-dsl.md's
    // Up-arrow bullet) - Up/Down there stay popup-highlight movement (the
    // `&& root.acOpen` guard on their existing branches below); with the
    // popup closed they otherwise bubble to handleKey() and move the
    // process-row selection, so this intercepts them first instead.
    property string acHistDraft: ""
    property int acHistIndex: -1  // -1 = sitting on the draft, not cycling
    property bool _histCycling: false  // guards searchInput's onTextChanged
    // (below) from treating OUR OWN text-set as a fresh edit that should
    // cancel cycling

    function _setQueryTextForHistory(text) {
        root._histCycling = true;
        root.searchText = text;
        searchInput.text = text;
        searchInput.cursorPosition = searchInput.text.length;
        root._histCycling = false;
    }

    function _historyPrev() {
        const entries = ClaudeUsageQueryHistory.entries;  // oldest-first
        if (entries.length === 0) return;
        if (root.acHistIndex < 0) {
            root.acHistDraft = root.searchText;
            root.acHistIndex = entries.length;
        }
        if (root.acHistIndex > 0) {
            root.acHistIndex--;
            root._setQueryTextForHistory(entries[root.acHistIndex]);
        }
    }

    function _historyNext() {
        if (root.acHistIndex < 0) return;  // not cycling - nothing to do
        const entries = ClaudeUsageQueryHistory.entries;
        root.acHistIndex++;
        if (root.acHistIndex >= entries.length) {
            root.acHistIndex = -1;
            root._setQueryTextForHistory(root.acHistDraft);
        } else {
            root._setQueryTextForHistory(entries[root.acHistIndex]);
        }
    }

    // View-state resets on every panel open *and* close -- this Rectangle
    // instance is never destroyed (only its height collapses to 0, same
    // "sibling overlay" pattern as Media/CalendarExpanded), so without
    // this a sort or a manual column resize from one look at the panel
    // would silently still be there next time.
    onExpandedChanged: {
        root.sort = null;
        root.selIndex = 0;
        // First row starts pre-selected (highlighted) on open -- but
        // thumbKeyboardActive stays false, so the left-side thumbnail
        // still only appears once an actual Up/Down/Home/End press
        // (root.handleKey/_syncKeyboardThumb) asks for it (request
        // 2026-09-11: selected-by-default row, no thumbnail until a real
        // arrow press).
        root.selActive = root.expanded;
        root.thumbKeyboardActive = false;
        root.thumbReady = false;
        root.mouseMovedSinceOpen = false;
        root._hoverSettled = false;
        // no completion / Ctrl+R history popup survives a close: each open starts clean
        root.acHistoryMode = false;
        root.acItems = [];
        root.acVerbMulti = false;
        root.acArgMulti = false;
        if (root.expanded) {
            // the search box has focus from the start; one Escape closes the panel
            Qt.callLater(root.focusSearch);
            hoverSettleTimer.restart();
            // Preselect the row for whatever Hyprland window currently has
            // focus, if any of the visible rows map to it -- async, so it
            // lands a beat after the plain "first row" default just above;
            // _selectAddressIfPresent no-ops if the panel's since closed
            // again or nothing matches (request 2026-09-27).
            activeWindowProc.exec(["hyprctl", "-j", "activewindow"]);
        } else {
            hoverSettleTimer.stop();
        }
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
    // The typed `/s/key1,key2/dir` (when it resolves to one type per key) overrides the
    // header-click sort; its keys mark their column headers: the first with the arrow,
    // every further key with the arrow in the accent colour (secondary sort key,
    // query-dsl.md "Sort").
    readonly property var dslSort: {
        const s = root.searchParsed.sort;
        if (!s) return null;
        const keys = QueryDsl.resolveSortKeys(s.fields, root.searchTypeNames);
        return keys !== null ? { keys, asc: s.dir !== "desc" } : null;
    }
    readonly property var _colField: ({ acct: "account", status: "status", title: "title", tokens: "tokens", path: "path", pid: "pid",
        tmuxSession: "tmux-session", tmuxWindow: "tmux-window", tmuxPane: "tmux-pane", hyprWorkspace: "hypr-workspace" })
    // 0 = not a sort key, 1 = primary, 2 = secondary
    function sortRole(col) {
        if (root.dslSort) {
            const i = root.dslSort.keys.indexOf(root._colField[col]);
            return i < 0 ? 0 : (i === 0 ? 1 : 2);
        }
        return (root.sort && root.sort.col === col) ? 1 : 0;
    }
    function sortArrow(col) {
        const role = root.sortRole(col);
        if (role === 0) return "";
        const asc = root.dslSort ? root.dslSort.asc : root.sort.asc;
        return asc ? " ▲" : " ▼";
    }
    function sortColor(col) { return root.sortRole(col) === 2 ? Theme.cyan : Theme.muted; }
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
        // tmux is a *grouped* column visually, but each sub-column sorts
        // independently -- only these, never the group label itself (that
        // has no click action at all, see the header row below: "there
        // should be no action when user clicks on [tmux/hyprland]... only
        // subcolumns should be capable of sorting", 2026-09-02).
        case "tmuxSession": return (Number(a.tmux_session) || 0) - (Number(b.tmux_session) || 0);
        case "tmuxWindow": return (Number(a.tmux_window) || 0) - (Number(b.tmux_window) || 0);
        case "tmuxPane": return (Number(a.tmux_pane) || 0) - (Number(b.tmux_pane) || 0);
        case "active": return (a.updated_at_ms || 0) - (b.updated_at_ms || 0);
        case "hyprWorkspace": return (Number(a.hypr_workspace) || 0) - (Number(b.hypr_workspace) || 0);
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
    // The per-account session-tally pill row below the table (request
    // 2026-09-05: "add total tally...", boxed into pills 2026-09-05).
    readonly property int tallyLineH: 26
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
    // hyprland "wks" column below (originally a grouped workspace+monitor
    // pair; monitor dropped 2026-09-08).
    readonly property var colDefaults: ({
        acct: 30, status: root.statusNaturalW, title: 400, tokens: root.tokensNaturalW, last: 44,
        tmuxSession: root.tmuxSessionNaturalW, tmuxWindow: root.tmuxWindowNaturalW, tmuxPane: root.tmuxPaneNaturalW,
        hyprWorkspace: root.hyprWorkspaceNaturalW,
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
    readonly property real colMsgsW: 44
    // tmux is a *grouped* column -- one "tmux" super-header spanning these
    // 3, each shrink-to-fit to its actual current values alone (see
    // tmuxSessionNaturalW etc. below for why these 3, unlike
    // status/tokens/pid, don't also take their header label into the
    // Math.max - the label would nearly always be the wider of the two
    // and defeat the point).
    property real colTmuxSessionW: colDefaults.tmuxSession
    property real colTmuxWindowW: colDefaults.tmuxWindow
    property real colTmuxPaneW: colDefaults.tmuxPane
    // Derived, not resized directly -- follows its 3 sub-columns
    // automatically as they're dragged.
    readonly property real colTmuxGroupW: colTmuxSessionW + colTmuxWindowW + colTmuxPaneW + 2 * root.handleW
    // hyprland: which Hyprland window is currently showing this session's
    // tmux pane (see claude-usage-daemon.py's
    // hyprland_windows_by_tmux_session), if any -- a single "wks" column
    // right after tmux (originally grouped with a "monitor" column under
    // its own "hyprland" group header; both dropped 2026-09-08, monitor
    // wasn't worth the width and the group header was redundant once it
    // was the only sub-column left). The window's own Hyprland address
    // (what the keyboard-thumbnail/click-to-focus feature on this cell
    // keys off, see root.startThumbCapture) is kept on the row data
    // (modelData.hypr_address) but deliberately not rendered as its own
    // column: it's a long opaque hex string with no value as a glanceable
    // readout, unlike workspace. Labeled "wks" (hover for a "hyprland
    // workspace" hint, see the header below) -- narrow on purpose, values
    // here are almost always a single digit.
    property real colHyprWorkspaceW: colDefaults.hyprWorkspace
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
        + root.colHyprWorkspaceW + root.handleW + root.colPidW + root.handleW
        + root.colPathW + root.scrollbarGap + root.scrollbarW
    // Same fallback width the standalone-preview default (panelWidth: 320
    // above) already used -- reused here as the floor so a near-empty
    // panel (few/no live processes) doesn't shrink below something that
    // still comfortably fits the mode-line/search box/account name text.
    readonly property real minContentWidth: 320
    // Width the first-row account pills need side by side (each pill's own
    // implicitWidth + the RowLayout's 10px spacing), so the panel grows
    // enough not to crop them even when the table/no-process floor is
    // narrower. Repeater.itemAt() isn't reactive, so the pills push their
    // size here via recalcPillsWidth().
    property real pillsNaturalWidth: 0
    function recalcPillsWidth() {
        let w = 0;
        for (let i = 0; i < acctPillsRepeater.count; i++) {
            const it = acctPillsRepeater.itemAt(i);
            if (it) w = Math.max(w, it.implicitWidth);
        }
        root.pillsNaturalWidth = w;
    }
    readonly property real naturalContentWidth:
        Math.max((root.anyProcsVisible ? Math.max(root.tableNaturalWidth, root.minContentWidth) : root.minContentWidth),
                 root.pillsNaturalWidth) + 24

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

    // ---- content-driven natural widths: status/tkns/wks/sess/win/pane/pid --
    // These columns used to default to hand-picked flat numbers (some
    // sized for the header label, some for the values, whichever was
    // wider) -- request 2026-09-05: size each to whatever its own header
    // + actual current values need, same shrink-to-fit approach path
    // already used above, instead of a guessed constant (sess joined the
    // set 2026-09-10, having been missed the first time round). Values
    // render at fontSize-2 for status/tokens/pid, fontSize-3 (same as
    // every header) for tmux session/window/pane and hyprland workspace --
    // two FontMetrics to match.
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
        root._maxTextWidth(valueFontMetrics, root.allProcs.map(r => root.rowStatusLabel(r)))
    ) + 6
    readonly property real tokensNaturalW: Math.max(
        pathFontMetrics.advanceWidth(qsTr("tkns") + " ▲"),
        root._maxTextWidth(valueFontMetrics, root.allProcs.map(r => root.fmtTokens(r.context_tokens)))
    ) + 6
    readonly property real pidNaturalW: Math.max(
        pathFontMetrics.advanceWidth(qsTr("pid") + " ▲"),
        root._maxTextWidth(valueFontMetrics, root.allProcs.map(r => String(r.pid)))
    ) + 6
    // Content-only, unlike status/tkns/pid above -- those headers
    // ("status"/"tkns"/"pid") are comparable in length to their own
    // values, so the Math.max(header, value) pattern they use rarely
    // matters. tmux's ids are short (1-3 digit numbers, `tmux_session`
    // etc. is `#{session_id}` with its "$" stripped - see
    // claude-usage-daemon.py) but "sess"/"win"/"pane" + a reserved sort-
    // arrow slot are not, so that same pattern let the header label (not
    // the values) set the width every time - the column always read as
    // padded well past its actual digits (reported 2026-09-10, "sess"
    // worst of the three since its label is longest). Sizing off the
    // values alone means an active sort's " ▲"/" ▼" can, rarely, overflow
    // a very narrow column - the header Text below now has `elide` as the
    // safety net for that, same as the "title" header's.
    readonly property real tmuxSessionNaturalW: Math.max(root.colMinW,
        root._maxTextWidth(pathFontMetrics, root.allProcs.map(r => r.tmux_session || "")) + 6)
    readonly property real tmuxWindowNaturalW: Math.max(root.colMinW,
        root._maxTextWidth(pathFontMetrics, root.allProcs.map(r => r.tmux_window || "")) + 6)
    readonly property real tmuxPaneNaturalW: Math.max(root.colMinW,
        root._maxTextWidth(pathFontMetrics, root.allProcs.map(r => r.tmux_pane || "")) + 6)
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
    // Set while the keyboard selection is driving the thumbnail -- the only
    // way it gets driven now (see startThumbCapture's own comment for why
    // mouse hover no longer triggers it at all).
    property bool thumbKeyboardActive: false
    // Y (in root's own coordinate space) of the top of the row the
    // thumbnail is for -- the popup pins its own top here rather than
    // following the cursor (request: "on the left of the panel ... top
    // aligned to the top of any selected entry").
    property real thumbAnchorY: 0

    // Kick off an async capture of `address` into a fresh PNG (thumbProc's
    // onExited flips thumbReady once it lands). Keyboard-selection-only now
    // (see _syncKeyboardThumb) -- mouse hover used to drive this too (a
    // HoverHandler on each row calling this on every enter), removed
    // entirely 2026-09-28. Each call spawns a fresh thumb-capture process
    // (a fresh Wayland client), and Hyprland's DynamicPermissionManager --
    // despite an explicit allow-rule for this exact binary in
    // environment.lua -- started popping its interactive "Permission
    // request" dialog ("Unknown application") on real mouse hovering,
    // reliably enough to be disruptive, even after debouncing the
    // once-per-row-boundary-crossed burst a fast mouse sweep produces down
    // to one spawn per settled row (that debounce code is gone too -- it
    // cut the frequency but the dialog still showed up eventually on
    // ordinary hovering). Root cause not pinned down (suspected: some
    // per-spawn race in Hyprland's own permission resolution, not
    // reproducible via manual/scripted invocation of the exact same
    // binary+args -- see thumb-capture's own doc comment). Keyboard
    // Up/Down never showed it, presumably just because it produces far
    // fewer distinct spawns per minute than casually gliding the mouse
    // over rows -- so keyboard-only sidesteps the problem rather than
    // fixing it. The real fix would be turning thumb-capture into a
    // persistent resident process (bind the Hyprland permission once at
    // startup, like winswitch already does) instead of a fresh client per
    // request; revisit if keyboard-only turns out to not be enough.
    function startThumbCapture(address) {
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

    function focusHyprWindow(row) {
        if (row.archived) {
            root.resumeRow(row);
            return;
        }
        if (row.tmuxRow) {   // a scrollback hit: go to that tmux pane (focus its terminal)
            ClaudeUsageQueryHistory.record(root.searchText);
            resumeProc.exec([Quickshell.env("HOME") + "/bin/claude-history", "--focus-tmux", row.pane_id]);
            root.picked();
            return;
        }
        if (!row.hypr_address && !row.tmux_session)
            return;
        // query-dsl.md's "Search-box history": a real accept records the
        // query, same as fzf's own --history flag does for the tmux
        // pickers.
        ClaudeUsageQueryHistory.record(root.searchText);
        if (row.tmux_window)
            tmuxSelectProc.exec(["tmux", "select-window", "-t", "@" + row.tmux_window]);
        if (row.tmux_pane)
            tmuxSelectPaneProc.exec(["tmux", "select-pane", "-t", "%" + row.tmux_pane]);
        if (row.hypr_address) {
            const addr = row.hypr_address;
            const script = "local ws = hl.get_windows({})\n"
                + "for i, w in ipairs(ws) do\n"
                + "    if tostring(w.address) == \"" + addr + "\" then\n"
                + "        hl.dispatch(hl.dsp.focus({ window = w }))\n"
                + "        break\n"
                + "    end\n"
                + "end";
            focusProc.exec(["hyprctl", "repl", script]);
        } else {
            // No live Hyprland window for this session -- open a new
            // terminal attached to it on the current workspace, same
            // fallback notify-summon.sh's claude-stop: path uses for a
            // detached session. The tmux select-window/-pane calls above
            // already pointed the session at this row's window/pane, so
            // attach lands looking at the right one.
            spawnAttachProc.exec(["alacritty", "-e", "tmux", "attach", "-t", "$" + row.tmux_session]);
        }
        // Closes on pick (2026-09-27) -- picking a window here is a
        // one-shot "go there" action, not a hover-ish alt-tab list. Used to
        // deliberately stay open (reverted 2026-09-12, see git history) to
        // route around an ALT+Tab/mod+Tab-can't-switch-away issue, but that
        // was a winswitch-side focus-grab interaction since fixed by
        // winswitch's own socket2 rework, so nothing depends on staying
        // open anymore. Signal rather than `root.expanded = false` directly
        // -- Bar.qml also has to clear claudeUsagePinned, or CTRL+ALT+c's
        // pin-toggle desyncs from the now-false `expanded` and needs two
        // presses to reopen (reported 2026-09-27).
        root.picked();
    }

    // ---- keyboard row navigation --------------------------------------
    // The delegate Rectangle for the current selIndex. The Repeater
    // builds every row up front (not virtualised like a ListView), so
    // itemAt is always populated for an in-range index.
    function _selDelegate() {
        return (root.selIndex >= 0 && root.selIndex < root.sortedProcs.length)
            ? rowsRepeater.itemAt(root.selIndex) : null;
    }
    // Scroll the selected row fully into the fixed-height viewport.
    function _ensureSelVisible() {
        const item = root._selDelegate();
        if (!item)
            return;
        if (item.y < rowsFlick.contentY)
            rowsFlick.contentY = item.y;
        else if (item.y + item.height > rowsFlick.contentY + rowsFlick.height)
            rowsFlick.contentY = item.y + item.height - rowsFlick.height;
    }
    // Point the left-side thumbnail at the current keyboard selection:
    // capture that row's window (if it maps to one) and pin the popup's
    // top to the row's top -- the same thing hovering the "wks" cell
    // does, just driven by selIndex instead of the pointer.
    function _syncKeyboardThumb() {
        root._ensureSelVisible();
        const item = root._selDelegate();
        if (item)
            root.thumbAnchorY = item.mapToItem(root, 0, 0).y;
        const row = root.sortedProcs[root.selIndex];
        if (row && row.hypr_address) {
            root.thumbKeyboardActive = true;
            root.startThumbCapture(row.hypr_address);
        } else {
            root.thumbKeyboardActive = false;
        }
    }
    // Hold-to-repeat for list/popup navigation (Ctrl+J/K, arrows,
    // PageUp/Down): the held key re-fires its own step on a timer rather
    // than relying on whichever surface currently holds focus (this
    // panel, or searchInput inside it) forwarding Qt's own key-repeat,
    // which isn't guaranteed -- same reasoning as the CTRL+ALT+h/l
    // Hyprland-side repeat fix and the ClipboardPicker/NotificationPicker
    // DSL pickers' identical mechanism.
    property var _navRepeatFn: null
    Timer { id: navRepeatDelay; interval: 600; onTriggered: navRepeatTimer.start() }
    Timer { id: navRepeatTimer; interval: 40; repeat: true; onTriggered: if (root._navRepeatFn) root._navRepeatFn() }
    function _startNavRepeat(fn) {
        root._navRepeatFn = fn;
        fn();
        navRepeatDelay.restart();
    }
    function _stopNavRepeat() {
        navRepeatDelay.stop();
        navRepeatTimer.stop();
        root._navRepeatFn = null;
    }
    // Up/Down move the selection (first press lands on the top row);
    // Space/Enter focuses the selected row's window, identical to
    // clicking it. Escape and "/" are handled upstream in Bar.qml before
    // this is reached.
    function handleKey(event) {
        const n = root.sortedProcs.length;
        if (n === 0)
            return;
        // Ctrl+J/Ctrl+K alias Down/Up, same convention as every other
        // picker (AppLauncher/WinSwitch/RssReader) - needed here now that
        // plain Down/Up, while the search box has focus, are claimed for
        // history-cycling instead of bubbling up to this function (see
        // searchInput's own Keys.onPressed, which forwards Ctrl+J/Ctrl+K
        // here explicitly the same way it already forwards Enter).
        if (event.key === Qt.Key_Down || (event.key === Qt.Key_J && (event.modifiers & Qt.ControlModifier))) {
            if (!event.isAutoRepeat) root._startNavRepeat(() => {
                const n2 = root.sortedProcs.length;
                if (n2 === 0) return;
                root.selIndex = root.selActive ? Math.min(n2 - 1, root.selIndex + 1) : 0;
                root.selActive = true;
                root._syncKeyboardThumb();
                // query-dsl.md's "Search-box history": moving the
                // selection after typing counts as "acted on" too, not
                // just a full accept - record() no-ops on an empty query,
                // so this is harmless while the search box was never
                // touched.
                ClaudeUsageQueryHistory.record(root.searchText);
            });
            event.accepted = true;
        } else if (event.key === Qt.Key_Up || (event.key === Qt.Key_K && (event.modifiers & Qt.ControlModifier))) {
            if (!event.isAutoRepeat) root._startNavRepeat(() => {
                const n2 = root.sortedProcs.length;
                if (n2 === 0) return;
                root.selIndex = root.selActive ? Math.max(0, root.selIndex - 1) : 0;
                root.selActive = true;
                root._syncKeyboardThumb();
                ClaudeUsageQueryHistory.record(root.searchText);
            });
            event.accepted = true;
        } else if (event.key === Qt.Key_Home) {
            root.selIndex = 0;
            root.selActive = true;
            root._syncKeyboardThumb();
            event.accepted = true;
        } else if (event.key === Qt.Key_End) {
            root.selIndex = n - 1;
            root.selActive = true;
            root._syncKeyboardThumb();
            event.accepted = true;
        } else if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            const row = root.sortedProcs[root.selActive ? root.selIndex : 0];
            if (row)
                root.focusHyprWindow(row);
            event.accepted = true;
        }
    }

    // Called from activeWindowProc once `hyprctl -j activewindow` answers.
    // Guarded on root.expanded since the query is async and the panel may
    // have closed again (or reopened past this row set) by the time it
    // lands; a non-match (address blank, or no row of this session table
    // maps to it) just leaves the plain first-row default from
    // onExpandedChanged in place.
    function _selectAddressIfPresent(addr) {
        if (!root.expanded || !addr)
            return;
        const idx = root.sortedProcs.findIndex(r => r.hypr_address === addr);
        if (idx >= 0) {
            root.selIndex = idx;
            root.selActive = true;
            root._ensureSelVisible();
        }
    }

    Process {
        id: activeWindowProc
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root._selectAddressIfPresent(JSON.parse(text).address || "");
                } catch (e) {
                    // Not running inside a live Hyprland session, or
                    // hyprctl's output shape changed -- keep the plain
                    // first-row default.
                }
            }
        }
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
    Process { id: spawnAttachProc }

    // Single table now -- one header block, not one per (formerly
    // foldable) account group. The process list itself no longer
    // truncates with a "+N more" line (request 2026-09-05: "remove ...
    // at the bottom, scroller size should be enough of an indication") --
    // it's a fixed-height scrollable viewport instead, holding every row
    // in root.sortedProcs, so this is now just "how tall should that
    // viewport be" rather than "how many rows fit before truncating".
    // One line (+ the Column's own spacing) per account currently showing
    // an error (see the error Repeater below) -- omitted from
    // fixedOverhead until 2026-09-17, when a real 429 on the "claude"
    // account showed the actual bug: that Repeater's line wasn't budgeted
    // for at all, so its extra height silently grew content past
    // maxPanelHeight and pushed the tally pill below root's clipped
    // bounds (cut off at the bottom) instead of shrinking the table to
    // make room for it.
    readonly property int errorLineCount: ClaudeUsageSvc.accounts.filter(a => !!a.error).length
    readonly property real errorLineH: valueFontMetrics.height + content.spacing

    readonly property real processAreaBudget: {
        // pillsFlow.height: the account-pills row, which wraps onto several
        // lines with many accounts (a fixed 20 here let the wrapped extra
        // lines push the tally below the clipped bottom, 2026-10-19). 24: root's own implicitHeight
        // padding (content.implicitHeight + 24). 16: safety margin.
        // groupHeaderH: the table's own header block (tmux/hyprland row +
        // column-header row). tallyLineH: the total-sessions line below
        // the table. errorLineCount * errorLineH: one line per account
        // currently showing an error.
        const fixedOverhead = Math.max(20, pillsFlow.height) + 14 + 24 + 16 + root.searchBoxH + root.groupHeaderH + root.tallyLineH
            + root.errorLineCount * root.errorLineH
            + (root.ftsActive ? root.snippetH + content.spacing : 0);
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
        Flow {
            id: pillsFlow
            width: parent.width
            spacing: 10

            // The mode-line ("polling every 2m..." + "updated N ago") used
            // to sit here with Layout.fillWidth, sharing this row with the
            // account pills -- routinely lost the width fight and got
            // elided down to "polling every ..." (reported 2026-09-11), so
            // it's gone outright rather than fixed.
            // (Now a Flow: with 7 accounts + codex the pills wrap onto
            // several lines instead of widening the panel.)
            Repeater {
                id: acctPillsRepeater
                model: ClaudeUsageSvc.codex ? ClaudeUsageSvc.accounts.concat([ClaudeUsageSvc.codex]) : ClaudeUsageSvc.accounts
                onItemAdded: root.recalcPillsWidth()
                onItemRemoved: root.recalcPillsWidth()

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
                    implicitWidth: acctSummary.implicitWidth + 16
                    implicitHeight: acctSummary.implicitHeight + 6
                    onImplicitWidthChanged: root.recalcPillsWidth()
                    radius: Math.min(height / 2, 12)
                    color: Theme.bgAlpha
                    border.color: Theme.border
                    border.width: 1

                    Row {
                        id: acctSummary
                        anchors.centerIn: parent
                        spacing: 4

                        // Provider logo (same tinted-PNG recipe as
                        // ClaudeUsagePill), then the account number for
                        // the Claude accounts; codex is just its logo.
                        Item {
                            id: acctLogo
                            readonly property bool isCodex: acctSummaryPill.modelData.account === "codex"
                            anchors.verticalCenter: parent.verticalCenter
                            width: isCodex ? 22 : 13
                            height: isCodex ? 22 : 13
                            Image {
                                id: acctLogoSrc
                                anchors.fill: parent
                                source: acctLogo.isCodex ? "assets/openai-logo.png" : "assets/claude-logo.png"
                                sourceSize: Qt.size(64, 64)
                                smooth: true
                                visible: false
                            }
                            MultiEffect {
                                anchors.fill: parent
                                source: acctLogoSrc
                                colorization: 1
                                colorizationColor: acctLogo.isCodex ? Theme.text : Theme.orange
                            }
                        }
                        Text {
                            id: acctSummaryName
                            visible: !acctLogo.isCodex
                            anchors.verticalCenter: parent.verticalCenter
                            text: String(root.acctIndex(acctSummaryPill.modelData.account))
                            color: Theme.text
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 1
                            font.bold: true
                            rightPadding: 4
                        }
                        // Session and weekly limits each on their own
                        // line (request 2026-10-12: with 4 accounts they
                        // no longer fit side by side on one line).
                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 1

                            Row {
                                id: acctSummarySession
                                visible: typeof acctSummaryPill.modelData.session_pct === "number"
                                spacing: 4
                                Text {
                                    anchors.baseline: acctSessionPct.baseline
                                    text: "session"
                                    color: Theme.textDim
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSize - 3
                                }
                                Text {
                                    id: acctSessionPct
                                    opacity: acctSummaryPill.modelData.stale ? 0.55 : 1
                                    text: qsTr("%1%").arg(Math.round(acctSummaryPill.modelData.session_pct))
                                    color: Theme.rampColor(acctSummaryPill.modelData.session_pct / 100)
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSize - 2
                                }
                                Text {
                                    anchors.baseline: acctSessionPct.baseline
                                    text: root.tick >= 0 ? root.fmtResets(acctSummaryPill.modelData.session_resets_at) : ""
                                    color: Theme.textDim
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSize - 3
                                }
                            }
                            Row {
                                id: acctSummaryWeekly
                                visible: typeof acctSummaryPill.modelData.weekly_pct === "number"
                                spacing: 4
                                Text {
                                    anchors.baseline: acctWeeklyPct.baseline
                                    text: "weekly"
                                    color: Theme.textDim
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSize - 3
                                }
                                Text {
                                    id: acctWeeklyPct
                                    opacity: acctSummaryPill.modelData.stale ? 0.55 : 1
                                    text: qsTr("%1%").arg(Math.round(acctSummaryPill.modelData.weekly_pct))
                                    color: Theme.rampColor(acctSummaryPill.modelData.weekly_pct / 100)
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSize - 2
                                }
                                Text {
                                    anchors.baseline: acctWeeklyPct.baseline
                                    text: root.tick >= 0 ? root.fmtResets(acctSummaryPill.modelData.weekly_resets_at) : ""
                                    color: Theme.textDim
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSize - 3
                                }
                            }
                        }
                    }

                    // Hover: exact date/time both limits reset, via the
                    // shared cursor-following hint.
                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        function hintFor() {
                            const m = acctSummaryPill.modelData;
                            const lines = [];
                            if (typeof m.session_pct === "number")
                                lines.push(qsTr("session resets %1").arg(root.fmtResetAt(m.session_resets_at)));
                            if (typeof m.weekly_pct === "number")
                                lines.push(qsTr("weekly resets %1").arg(root.fmtResetAt(m.weekly_resets_at)));
                            return lines.join("\n");
                        }
                        onEntered: {
                            root.showHint(hintFor());
                            root.moveHint(acctSummaryPill.mapToItem(root, mouseX, mouseY));
                        }
                        onPositionChanged: mouse => root.moveHint(acctSummaryPill.mapToItem(root, mouse.x, mouse.y))
                        onExited: root.hideHint()
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
                // Qt's default TextInput selection is a hardcoded style
                // blue, unrelated to this wallpaper-generated theme --
                // reported 2026-09-06 (Ctrl+A here still highlighted in
                // that stock blue while everything else in the panel
                // already tracks the theme). Same wallpaper-derived
                // accent + low-alpha-tint idiom already used for the
                // process-row hover highlight and the autocomplete
                // popup's selected row (Theme.cyan at partial alpha over
                // the box's own background) rather than a solid fill,
                // so the selected text itself stays legible without
                // needing a separate selectedTextColor.
                selectionColor: Qt.rgba(Theme.cyan.r, Theme.cyan.g, Theme.cyan.b, 0.35)
                selectedTextColor: Theme.text
                // Any further typing past a shown popup closes it, same as
                // a shell/IDE -- Tab recomputes it fresh for wherever the
                // cursor is now (root.triggerCompletion). Also fires
                // (harmlessly, on an already-empty acItems) when accepting
                // a completion sets this text itself.
                onTextChanged: {
                    // A real edit cancels an in-progress Up/Down history
                    // cycle (query-dsl.md: editing invalidates the cycle
                    // the same way it does in a real shell) - but not when
                    // WE just set the text ourselves while cycling.
                    if (!root._histCycling) root.acHistIndex = -1;
                    // Once the popup is already open, keep recomputing
                    // candidates from the new text instead of clearing --
                    // narrows the list as you type (e.g. `/fv/` + Tab shows
                    // every field, typing `p` narrows to path/pid/...)
                    // rather than closing and forcing another Tab press.
                    // `wasOpen` is read before reassigning searchText/
                    // acItems, since root.acOpen depends on both.
                    const wasOpen = root.acOpen;
                    root.searchText = text;
                    root.acItems = wasOpen
                        ? (root.acHistoryMode ? root._acHistoryCandidates() : root._acCandidates())
                        : [];
                }

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
                DslHighlight { input: searchInput; spans: searchInput.text.length ? root._commandSpans(searchInput.text) : [] }

                // First Escape while searching closes the autocomplete
                // popup if one's open. With no popup, one Escape both
                // clears a non-empty query AND blurs the search box
                // (root.forceActiveFocus() moves focus off searchInput
                // back onto this whole panel) -- not two separate presses
                // (request 2026-09-05: "make pressing escape both remove
                // focus and clear its input"). The panel itself stays
                // open; that needs a further Escape, which -- now that
                // this one is accepted and the box no longer holds focus
                // -- bubbles up to Bar.qml's root.Keys.onPressed.
                // zsh-autosuggestions (query-dsl.md "Search-box history"): greyed-out
                // rest of the newest history entry starting with the text; Right, End
                // or Ctrl+F at the end of the text takes it.
                readonly property string ghost:
                    (cursorPosition === text.length && !(root.acOpen)) ? ClaudeUsageQueryHistory.suggest(text) : ""
                Text {
                    visible: searchInput.ghost.length > 0
                    // cursorRectangle (cursor is at the end whenever the ghost
                    // shows) notifies on change; positionToRectangle() doesn't,
                    // so the ghost kept the previous keystroke's x and overlapped.
                    x: searchInput.cursorRectangle.x + searchInput.cursorRectangle.width
                    y: searchInput.cursorRectangle.y
                    text: searchInput.ghost
                    color: Theme.muted
                    font: searchInput.font
                }
                Keys.onPressed: event => {
                    if (searchInput.ghost.length > 0 && !((event.modifiers & Qt.ShiftModifier))
                            && ((event.key === Qt.Key_Right && !(event.modifiers & ~Qt.KeypadModifier))
                                || event.key === Qt.Key_End
                                || (event.key === Qt.Key_F && (event.modifiers & Qt.ControlModifier)))) {
                        searchInput.insert(searchInput.text.length, searchInput.ghost);
                        event.accepted = true;
                        return;
                    }
                    if (event.key === Qt.Key_Escape) {
                        if (root.acOpen) {
                            root.acDismissed = true;
                            root.acVerbMulti = false; root.acArgMulti = false;
                        } else {
                            // No popup: Escape closes the panel (the query is
                            // reset by onExpandedChanged on the next open).
                            searchInput.text = "";
                            root.picked();
                        }
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Tab) {
                        if (root.acOpen) {
                            // Tab confirms the highlighted suggestion (query-dsl.md);
                            // Shift+Tab steps the highlight back.
                            if (event.modifiers & Qt.ShiftModifier)
                                root.acSel = (root.acSel - 1 + root.acItems.length) % root.acItems.length;
                            else
                                root.acAccept();
                        } else {
                            root.triggerCompletion();
                        }
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Space && !root.acOpen && (event.modifiers & Qt.ControlModifier)) {
                        // Ctrl+Space also opens completion, same as Tab
                        // (query-dsl.md Autocompletion section) -
                        // ClipboardPicker.qml/NotificationPicker.qml's
                        // reference implementation, ported here.
                        root.triggerCompletion();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Space && root.acOpen && (event.modifiers & Qt.ControlModifier)) {
                        // AND-narrows instead of accepting (query-dsl.md) -
                        // see AppLauncher.qml's identical handler for the
                        // full rationale.
                        const vm = searchInput.text.match(/(?:^|\s|!)(\/[a-z-]*)$/);
                        if (vm || root.acVerbMulti) {
                            if (!root.acVerbMulti) {
                                root.acVerbMulti = true;
                                root.acVerbMultiStart = searchInput.text.length - vm[1].length;
                            }
                            searchInput.insert(searchInput.cursorPosition, " ");
                        } else if (root.acArgMulti || root.acOpen) {
                            if (!root.acArgMulti) {
                                root.acArgMulti = true;
                                root.acArgMultiStart = searchInput.text.search(/[^\s:\/]*$/);
                            }
                            searchInput.insert(searchInput.cursorPosition, " ");
                        }
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Space && root.acOpen) {
                        root.acAccept();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_R && (event.modifiers & Qt.ControlModifier)) {
                        // query-dsl.md's "Search-box history": always
                        // (re)opens, even with an empty history file yet.
                        root._triggerHistorySearch();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Down && root.acOpen) {
                        if (!event.isAutoRepeat) root._startNavRepeat(() => { root.acSel = Math.min(root.acItems.length - 1, root.acSel + 1); });
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Up && root.acOpen) {
                        if (!event.isAutoRepeat) root._startNavRepeat(() => { root.acSel = Math.max(0, root.acSel - 1); });
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Down) {
                        // Popup closed: history-cycle instead of letting
                        // this bubble to handleKey() and move the
                        // process-row selection (query-dsl.md's Up-arrow
                        // bullet - Up/Down are claimed for history here,
                        // same trade the other QML pickers make); row
                        // navigation moves to Ctrl+J/Ctrl+K below instead.
                        if (root.acHistIndex >= 0) root._historyNext();
                        else { searchInput.focus = false; root.forceActiveFocus(); } // query-dsl.md "Focus between search box and results"
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Up) {
                        root._historyPrev();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_J && (event.modifiers & Qt.ControlModifier)) {
                        if (root.acOpen) {
                            if (!event.isAutoRepeat) root._startNavRepeat(() => { root.acSel = Math.min(root.acItems.length - 1, root.acSel + 1); });
                        } else if (root.acHistIndex >= 0) root._historyNext(); // Ctrl+J == Down (query-dsl.md "Search-box history")
                        else { searchInput.focus = false; root.forceActiveFocus(); }
                        event.accepted = true;
                    } else if (event.key === Qt.Key_K && (event.modifiers & Qt.ControlModifier)) {
                        if (root.acOpen) {
                            if (!event.isAutoRepeat) root._startNavRepeat(() => { root.acSel = Math.max(0, root.acSel - 1); });
                        } else root._historyPrev(); // Ctrl+K == Up
                        event.accepted = true;
                    } else if (event.key === Qt.Key_PageDown && root.acOpen) {
                        if (!event.isAutoRepeat) root._startNavRepeat(() => { root.acSel = Math.min(root.acItems.length - 1, root.acSel + 7); });
                        event.accepted = true;
                    } else if (event.key === Qt.Key_PageUp && root.acOpen) {
                        if (!event.isAutoRepeat) root._startNavRepeat(() => { root.acSel = Math.max(0, root.acSel - 7); });
                        event.accepted = true;
                    } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !root.acOpen) {
                        // TextInput would otherwise just swallow Return/Enter
                        // as a no-op "accepted" edit key -- forward it to the
                        // same row-select handling handleKey already gives
                        // Space/Enter when focus sits on the panel itself, so
                        // "search box focused by default" (2026-09-11) doesn't
                        // also disable Enter-to-open-selected-row.
                        root.handleKey(event);
                    }
                }
                // Native key-repeat here delivers a flood of RELEASE events
                // flagged isAutoRepeat=true (confirmed live 2026-10-04, see
                // AppLauncher.qml's identical comment) -- only a genuine
                // key-up should actually stop it.
                Keys.onReleased: event => { if (!event.isAutoRepeat) root._stopNavRepeat(); }
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

            // ListView instead of a plain Column+Repeater so entries past
            // the 7-row window are reachable -- wheel-scrollable, and
            // Up/Down (root.onAcSelChanged above) keeps the selection in
            // view via positionViewAtIndex.
            ListView {
                id: acList
                anchors.fill: parent
                anchors.margins: 4
                anchors.rightMargin: 10
                clip: true
                model: root.acItems
                currentIndex: root.acSel
                boundsBehavior: Flickable.StopAtBounds
                delegate: Rectangle {
                    id: acRow
                    required property var modelData
                    required property int index
                    readonly property bool cur: index === root.acSel
                    width: acList.width
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

            // Hand-rolled vertical scrollbar (no QtQuick.Controls anywhere
            // in this project, see bar/CalendarExpanded.qml's identical
            // pattern) - visible only once acItems overflows the 7-row
            // window, thumb size/position proportional to how much of the
            // list is in view.
            Rectangle {
                id: acScrollBar
                visible: acList.contentHeight > acList.height + 1
                anchors.top: acList.top
                anchors.right: parent.right
                anchors.rightMargin: 3
                width: 4
                height: acList.height
                radius: 2
                color: Qt.rgba(1, 1, 1, 0.06)

                readonly property real thumbH: Math.max(10, acList.visibleArea.heightRatio * height)
                readonly property real travel: Math.max(1, height - thumbH)
                readonly property real maxContentY: Math.max(0, acList.contentHeight - acList.height)

                function scrollToThumbTop(ty: real): void {
                    const clamped = Math.max(0, Math.min(acScrollBar.travel, ty));
                    acList.contentY = (clamped / acScrollBar.travel) * acScrollBar.maxContentY;
                }

                Rectangle {
                    width: parent.width
                    radius: 2
                    height: acScrollBar.thumbH
                    y: Math.min(acScrollBar.travel, acList.visibleArea.yPosition * acScrollBar.height)
                    color: acSbArea.pressed ? Theme.text
                        : (acSbArea.containsMouse ? Theme.textDim : Qt.rgba(1, 1, 1, 0.28))
                }

                MouseArea {
                    id: acSbArea
                    anchors.fill: parent
                    anchors.leftMargin: -8
                    anchors.topMargin: -2
                    anchors.bottomMargin: -2
                    hoverEnabled: true
                    preventStealing: true
                    property real grabOffset: 0

                    onPressed: mouse => {
                        const ty = mouse.y + anchors.topMargin;
                        const thumbY = Math.min(acScrollBar.travel, acList.visibleArea.yPosition * acScrollBar.height);
                        if (ty >= thumbY && ty <= thumbY + acScrollBar.thumbH) {
                            grabOffset = ty - thumbY;
                        } else {
                            grabOffset = acScrollBar.thumbH / 2;
                            acScrollBar.scrollToThumbTop(ty - grabOffset);
                        }
                    }
                    onPositionChanged: mouse => {
                        if (pressed)
                            acScrollBar.scrollToThumbTop(mouse.y + anchors.topMargin - grabOffset);
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

            // Group-header row: blank over every plain column, "tmux"
            // label (underlined) spanning its own sub-columns below --
            // same shape as the old per-account version, just rendered
            // once now. Hyprland used to get the same grouped-label
            // treatment over workspace+monitor, but the monitor
            // sub-column was dropped and "wks" alone reads fine as a
            // plain column with no group label above it (request
            // 2026-09-08).
            RowLayout {
                width: content.width
                spacing: 0

                Item { Layout.preferredWidth: root.colAcctW }
                Item { Layout.preferredWidth: root.handleW }
                Item { visible: !root.archiveMode; Layout.preferredWidth: root.colStatusW }
                Item { visible: !root.archiveMode; Layout.preferredWidth: root.handleW }
                Item { Layout.preferredWidth: root.colTitleW }
                Item { Layout.preferredWidth: root.handleW }
                Item { Layout.preferredWidth: root.colMsgsW }
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
                    visible: !root.archiveMode
                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: 1
                        color: Theme.border
                    }
                }
                Item { visible: !root.archiveMode; Layout.preferredWidth: root.handleW }
                Item { visible: !root.archiveMode; Layout.preferredWidth: root.colHyprWorkspaceW }
                Item { visible: !root.archiveMode; Layout.preferredWidth: root.handleW }
                Item { visible: !root.archiveMode; Layout.preferredWidth: root.colPidW }
                Item { visible: !root.archiveMode; Layout.preferredWidth: root.handleW }
                Item { Layout.preferredWidth: root.colPathW }
                Item { Layout.fillWidth: true }
            }

            // Column headers. Four of these are abbreviated with a
            // cursor-following hover hint for the full word (request
            // 2026-09-05) -- "tkns" (tokens), "sess" (tmux session), "win"
            // (tmux window), "wks" (-> "hyprland workspace", renamed from
            // the old bare "#" which used a static hint the cursor itself
            // occluded). "pane"/"pid"/"path"/etc. are short enough already
            // and stay unabbreviated.
            RowLayout {
                width: content.width
                spacing: 0

                Text {
                    text: qsTr("acct") + root.sortArrow("acct")
                    color: root.sortColor("acct")
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
                    color: root.sortColor("status")
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                    Layout.preferredWidth: root.colStatusW
                    visible: !root.archiveMode
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.toggleSort("status")
                    }
                }
                ColumnResizeHandle {
                    Layout.preferredWidth: root.handleW
                    visible: !root.archiveMode
                    Layout.fillHeight: true
                    targetWidth: root.colStatusW
                    onWidthChangeRequested: w => root.colStatusW = w
                }
                Text {
                    text: qsTr("title") + root.sortArrow("title")
                    color: root.sortColor("title")
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
                    id: msgsHeader
                    text: qsTr("msgs")
                    color: Theme.muted
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                    horizontalAlignment: Text.AlignRight
                    Layout.preferredWidth: root.colMsgsW
                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: {
                            root.showHint(qsTr("messages"));
                            root.moveHint(msgsHeader.mapToItem(root, mouseX, mouseY));
                        }
                        onPositionChanged: mouse => root.moveHint(msgsHeader.mapToItem(root, mouse.x, mouse.y))
                        onExited: root.hideHint()
                    }
                }
                Item { Layout.preferredWidth: root.handleW }
                Text {
                    id: tokensHeader
                    text: qsTr("tkns") + root.sortArrow("tokens")
                    color: root.sortColor("tokens")
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
                    color: root.sortColor("active")
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
                    color: root.sortColor("tmuxSession")
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                    elide: Text.ElideRight
                    Layout.preferredWidth: root.colTmuxSessionW
                    visible: !root.archiveMode
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
                    visible: !root.archiveMode
                    Layout.fillHeight: true
                    targetWidth: root.colTmuxSessionW
                    onWidthChangeRequested: w => root.colTmuxSessionW = w
                }
                Text {
                    id: winHeader
                    text: qsTr("win") + root.sortArrow("tmuxWindow")
                    color: root.sortColor("tmuxWindow")
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                    elide: Text.ElideRight
                    Layout.preferredWidth: root.colTmuxWindowW
                    visible: !root.archiveMode
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
                    visible: !root.archiveMode
                    Layout.fillHeight: true
                    targetWidth: root.colTmuxWindowW
                    onWidthChangeRequested: w => root.colTmuxWindowW = w
                }
                Text {
                    text: qsTr("pane") + root.sortArrow("tmuxPane")
                    color: root.sortColor("tmuxPane")
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                    elide: Text.ElideRight
                    Layout.preferredWidth: root.colTmuxPaneW
                    visible: !root.archiveMode
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.toggleSort("tmuxPane")
                    }
                }
                ColumnResizeHandle {
                    Layout.preferredWidth: root.handleW
                    visible: !root.archiveMode
                    Layout.fillHeight: true
                    targetWidth: root.colTmuxPaneW
                    onWidthChangeRequested: w => root.colTmuxPaneW = w
                }
                Text {
                    id: wksHeader
                    text: qsTr("wks") + root.sortArrow("hyprWorkspace")
                    color: root.sortColor("hyprWorkspace")
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                    Layout.preferredWidth: root.colHyprWorkspaceW
                    visible: !root.archiveMode
                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: {
                            root.showHint(qsTr("hyprland workspace"));
                            root.moveHint(wksHeader.mapToItem(root, mouseX, mouseY));
                        }
                        onPositionChanged: mouse => root.moveHint(wksHeader.mapToItem(root, mouse.x, mouse.y))
                        onExited: root.hideHint()
                        onClicked: root.toggleSort("hyprWorkspace")
                    }
                }
                ColumnResizeHandle {
                    Layout.preferredWidth: root.handleW
                    visible: !root.archiveMode
                    Layout.fillHeight: true
                    targetWidth: root.colHyprWorkspaceW
                    onWidthChangeRequested: w => root.colHyprWorkspaceW = w
                }
                Text {
                    text: qsTr("pid") + root.sortArrow("pid")
                    color: root.sortColor("pid")
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                    Layout.preferredWidth: root.colPidW
                    visible: !root.archiveMode
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.toggleSort("pid")
                    }
                }
                ColumnResizeHandle {
                    Layout.preferredWidth: root.handleW
                    visible: !root.archiveMode
                    Layout.fillHeight: true
                    targetWidth: root.colPidW
                    onWidthChangeRequested: w => root.colPidW = w
                }
                Text {
                    text: qsTr("path") + root.sortArrow("path")
                    color: root.sortColor("path")
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
                id: rowsRepeater
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
                    required property int index
                    width: rowsColumn.width
                    implicitHeight: procRowLayout.implicitHeight
                    height: implicitHeight
                    radius: 3
                    // One highlight now, one selection state -- mouse hover
                    // moves root.selIndex/selActive exactly like Up/Down
                    // does (see procRowHover below), so there's no separate
                    // lighter "just pointed at" tint anymore to reconcile
                    // against the keyboard one (request 2026-09-28: "moving
                    // mouse should modify it, same as up down keys").
                    color: (root.selActive && procRow.index === root.selIndex)
                        ? Qt.rgba(Theme.cyan.r, Theme.cyan.g, Theme.cyan.b, 0.22)
                        : "transparent"

                    // Moves the selection cursor to this row on hover, same
                    // selIndex/selActive Up/Down sets in handleKey -- but
                    // deliberately does NOT call _syncKeyboardThumb/
                    // startThumbCapture (request: "only up down keys should
                    // trigger preview pane"). Thumbnail capture spawns a
                    // fresh thumb-capture process per call, and routing
                    // mouse hover into that (first as a direct call, then
                    // even after debouncing) is what made Hyprland's
                    // permission dialog show up reliably on real hovering,
                    // removed 2026-09-28 -- see startThumbCapture's own
                    // comment. A HoverHandler (rather than a plain
                    // MouseArea) is still needed here so this keeps
                    // reporting hovered while the cursor is over the "acct"
                    // cell's own child MouseArea.
                    HoverHandler {
                        id: procRowHover
                        onHoveredChanged: {
                            if (!hovered || !root.mouseMovedSinceOpen)
                                return;
                            root.selIndex = procRow.index;
                            root.selActive = true;
                        }
                    }

                    // Click anywhere on the row focuses that session's
                    // window (request: "clicking anywhere in any row
                    // switches focus ... not just on its value in workspace
                    // column"). Sits below the RowLayout, so the "acct"
                    // cell's own MouseArea (hover tooltip) still gets its
                    // own area first; every other cell falls through here.
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: (procRow.modelData.hypr_address || procRow.modelData.tmux_session) ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: root.focusHyprWindow(procRow.modelData)
                    }

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
                                cursorShape: (procRow.modelData.hypr_address || procRow.modelData.tmux_session) ? Qt.PointingHandCursor : Qt.ArrowCursor
                                onEntered: {
                                    root.showHint(modelData.account);
                                    root.moveHint(acctCell.mapToItem(root, mouseX, mouseY));
                                }
                                onPositionChanged: mouse => root.moveHint(acctCell.mapToItem(root, mouse.x, mouse.y))
                                onExited: root.hideHint()
                                // This cell's MouseArea would otherwise
                                // swallow the click before it reached the
                                // row-level handler above.
                                onClicked: root.focusHyprWindow(procRow.modelData)
                            }
                        }
                        Item { Layout.preferredWidth: root.handleW }
                        Text {
                            text: root.rowStatusLabel(modelData)
                            color: root.rowStatusColor(modelData)
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                            Layout.preferredWidth: root.colStatusW
                            visible: !root.archiveMode
                        }
                        Item { visible: !root.archiveMode; Layout.preferredWidth: root.handleW }
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
                            text: String(modelData.msgs || "")
                            color: Theme.muted
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 3
                            horizontalAlignment: Text.AlignRight
                            Layout.preferredWidth: root.colMsgsW
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
                            visible: !root.archiveMode
                        }
                        Item { visible: !root.archiveMode; Layout.preferredWidth: root.handleW }
                        Text {
                            text: modelData.tmux_window || ""
                            color: Theme.muted
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 3
                            Layout.preferredWidth: root.colTmuxWindowW
                            visible: !root.archiveMode
                        }
                        Item { visible: !root.archiveMode; Layout.preferredWidth: root.handleW }
                        Text {
                            text: modelData.tmux_pane || ""
                            color: Theme.muted
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 3
                            Layout.preferredWidth: root.colTmuxPaneW
                            visible: !root.archiveMode
                        }
                        Item { visible: !root.archiveMode; Layout.preferredWidth: root.handleW }
                        // hyprland cell: which real window is showing this
                        // session, if any (see root.startThumbCapture's own
                        // comment for why it's address-keyed rather than
                        // title/appId-matched). Just the "wks" column now
                        // (monitor dropped, request 2026-09-08). Click
                        // (focus) is handled at row level -- see the row
                        // MouseArea above; thumbnail preview only fires on
                        // Up/Down (procRowHover moves the selection cursor
                        // on hover too, but not the thumbnail) -- so this
                        // is a plain text cell.
                        Item {
                            id: hyprCell
                            Layout.preferredWidth: root.colHyprWorkspaceW
                            visible: !root.archiveMode
                            Layout.fillHeight: true

                            Text {
                                anchors.fill: parent
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
                            }
                        }
                        Item { visible: !root.archiveMode; Layout.preferredWidth: root.handleW }
                        Text {
                            text: String(modelData.pid)
                            color: Theme.muted
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                            Layout.preferredWidth: root.colPidW
                            visible: !root.archiveMode
                        }
                        Item { visible: !root.archiveMode; Layout.preferredWidth: root.handleW }
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

        // /fts match preview for the highlighted row.
        Rectangle {
            width: content.width
            height: root.snippetH
            visible: root.ftsActive
            color: Theme.bgAlpha
            border.color: Theme.border
            border.width: 1
            radius: 4
            clip: true
            Text {
                id: snippetText
                anchors.fill: parent
                anchors.margins: 6
                textFormat: Text.RichText
                wrapMode: Text.Wrap
                elide: Text.ElideRight
                color: Theme.muted
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 2
                text: root.snippetHtml.length > 0 ? root.snippetHtml : qsTr("no excerpts")
            }
        }

        // Session tally -- just the total across every account (request
        // 2026-09-11: drop the per-account "1 N / 2 N / 3 N" pills and the
        // "sessions" label, keep only the Σ total pill this row started
        // as before 2026-09-05's per-account breakdown was added).
        RowLayout {
            width: content.width
            spacing: 6
            visible: root.anyProcsVisible

            Rectangle {
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: tallyTotalText.implicitWidth + 16
                implicitHeight: tallyTotalText.implicitHeight + 6
                radius: height / 2
                color: Theme.bgAlpha
                border.color: Theme.border
                border.width: 1

                Text {
                    id: tallyTotalText
                    anchors.centerIn: parent
                    text: qsTr("Σ %1").arg(root.totalSessionCount)
                    color: Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 1
                    font.bold: true
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

    // The hover/keyboard thumbnail is rendered by Bar.qml, NOT here: it's
    // meant to sit just outside this panel's left edge (request: "out of
    // the panel aligned to the left border"), and this Rectangle has
    // clip:true (its content can exceed the monitor-capped height), which
    // would swallow anything drawn past its bounds. Bar.qml binds to the
    // thumb* properties above and to thumbAnchorY (a Y in this panel's own
    // coordinate space, top of the hovered/selected row) for placement.

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
