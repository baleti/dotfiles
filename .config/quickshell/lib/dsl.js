.pragma library
// The query DSL's pure primitives, shared by every QML consumer (launcher, rss reader, usage panel,
// alt-tab, the clipboard family). ~/.config/dsl/dsl.py is the Python twin; ~/.config/dsl/tests.json
// is the conformance suite both (and the Rust/Kotlin ports) must pass. Semantics: query-dsl.md.

// "Keys": a comma list; per key the name equal to it wins alone, else every name containing it;
// unioned, in `known` order. Case-insensitive; empty keys skipped.
function resolveNames(keys, known) {
    var hit = {};
    var parts = String(keys).toLowerCase().split(",");
    for (var i = 0; i < parts.length; i++) {
        var key = parts[i];
        if (key.length === 0) continue;
        var exact = known.filter(function (n) { return n.toLowerCase() === key; });
        var m = exact.length > 0 ? exact : known.filter(function (n) { return n.toLowerCase().indexOf(key) >= 0; });
        for (var j = 0; j < m.length; j++) hit[m[j]] = true;
    }
    return known.filter(function (n) { return hit[n]; });
}

// The ordered sort keys a `/s/key,key` chain resolves to: per key the exact name alone or - for a
// fuzzy key - every name containing it, alphabetically (`pa` = pages,path); duplicates dropped.
// null when any key names nothing (the whole /s is inert).
function resolveSortKeys(keys, known) {
    var out = [];
    for (var i = 0; i < keys.length; i++) {
        var r = resolveNames(keys[i], known).slice().sort();
        if (r.length === 0) return null;
        for (var j = 0; j < r.length; j++) if (out.indexOf(r[j]) < 0) out.push(r[j]);
    }
    return out;
}

// A direction word: any non-empty prefix of ascending / descending -> "asc" / "desc", else null.
function parseDirection(word) {
    var t = String(word).toLowerCase();
    if (t.length === 0) return null;
    if ("ascending".indexOf(t) === 0) return "asc";
    if ("descending".indexOf(t) === 0) return "desc";
    return null;
}

// `/verb/keys[/dir]` or `//keys` -> { verb, keys, dir, bad } or null when the token names no verb.
// verbs: { spelling: canonical } (the empty spelling "" is the default verb of `//keys`);
// maxParts: { canonical: n } (default 2; /s takes 3, an argument-less verb 1). keys/dir are null
// when absent; bad = more parts than the verb allows.
function splitCmd(text, verbs, maxParts) {
    if (text.charAt(0) !== "/") return null;
    var parts = text.slice(1).split("/");
    var verb;
    if (parts[0] === "") verb = parts.length >= 2 ? (verbs[""] || null) : null;
    else verb = verbs.hasOwnProperty(parts[0]) ? verbs[parts[0]] : null;
    if (verb === null) return null;
    var max = (maxParts && maxParts[verb] !== undefined) ? maxParts[verb] : 2;
    return { verb: verb, keys: parts.length >= 2 ? parts[1] : null,
             dir: parts.length === 3 ? parts[2] : null, bad: parts.length > max };
}

// Substring index of `needle` in `hay` (case-insensitive); with `exact` (a quoted term) the match
// must stand alone: no letter/digit/underscore directly before or after it. -1 when absent.
function substrIdx(needle, hay, exact) {
    var n = String(needle).toLowerCase(), h = String(hay).toLowerCase();
    var i = h.indexOf(n);
    if (!exact || n.length === 0) return i;
    var w = /[a-z0-9_]/;
    var lead = w.test(n.charAt(0)), trail = w.test(n.charAt(n.length - 1));
    while (i >= 0) {
        if (!(lead && w.test(h.charAt(i - 1))) && !(trail && w.test(h.charAt(i + n.length)))) return i;
        i = h.indexOf(n, i + 1);
    }
    return -1;
}
function substr(needle, hay, exact) { return substrIdx(needle, hay, exact) >= 0; }

// Sort comparison (query-dsl.md "Sort comparison, precisely"): plain integers numerically, age
// buckets (30s/5m/3h/2d) by seconds with the direction inverted (the direction trap), else
// lexicographic case-insensitive; `dir` ("asc"/"desc") applied here.
function _tryInt(s) { return /^\d+$/.test(s) ? parseInt(s, 10) : null; }
function _tryAgeSeconds(s) {
    var m = /^(\d+)([smhd])$/.exec(s);
    if (!m) return null;
    return parseInt(m[1], 10) * ({ s: 1, m: 60, h: 3600, d: 86400 }[m[2]]);
}
function compareFieldValues(a, b, dir) {
    var as = String(a), bs = String(b);
    var ai = _tryInt(as), bi = _tryInt(bs);
    if (ai !== null && bi !== null) return dir === "desc" ? bi - ai : ai - bi;
    var aa = _tryAgeSeconds(as), ba = _tryAgeSeconds(bs);
    if (aa !== null && ba !== null) return dir === "desc" ? aa - ba : ba - aa;
    var al = as.toLowerCase(), bl = bs.toLowerCase();
    var c = al < bl ? -1 : (al > bl ? 1 : 0);
    return dir === "desc" ? -c : c;
}

// Tokenizer: whitespace-split, a quoted run ("..." or '...') kept whole with the quote characters
// dropped, a leading "!" carried as `neg` (not part of the token). `'` opens a quote only at the
// start of a token, so apostrophes inside words stay text. Token: { start (index of its first
// character, the opening quote included, never the "!"), text, leadQuote (it began with a quote - a
// literal, never a command, even unterminated), quoted (a quote was closed: the exact-match flag),
// neg }. An unterminated quote runs to the end of the input (still being typed).
function tokenize(query) {
    var tokens = [];
    var cur = "", start = -1, leadQuote = false, inQuotes = false, qc = "", quoted = false, neg = false;
    for (var i = 0; i < query.length; i++) {
        var c = query.charAt(i);
        if (c === "!" && start < 0 && !neg) { neg = true; continue; }
        var opens = c === '"' || (c === "'" && start < 0);
        if (inQuotes ? c === qc : opens) {
            if (start < 0) leadQuote = true;
            if (!inQuotes) qc = c;
            else quoted = true;
            inQuotes = !inQuotes;
            if (start < 0) start = i;
            continue;
        }
        if (/\s/.test(c) && !inQuotes) {
            if (start >= 0) {
                tokens.push({ start: start, text: cur, leadQuote: leadQuote, quoted: quoted, neg: neg });
                cur = ""; start = -1; leadQuote = false; quoted = false;
            }
            neg = false;
            continue;
        }
        if (start < 0) start = i;
        cur += c;
    }
    if (start >= 0) tokens.push({ start: start, text: cur, leadQuote: leadQuote, quoted: quoted, neg: neg });
    return tokens;
}

// ---- /group (/g): folds the (already filtered) rows into collapsible sections. Mirror of dsl.py's
// parse_group / group_value / group_layout / group_visible; spec: query-dsl.md "/group".
var GROUP_VERBS = ["g", "group"];
var GROUP_BUCKETS = ["pf", "parent-folder", "day", "week", "month", "year"];
var _DATE_BUCKETS = ["day", "week", "month", "year"];

// The default bucketing family of a type, by its name: size / age / date / path / value.
function groupKind(name) {
    var n = String(name).toLowerCase();
    if (n.indexOf("size") >= 0) return "size";
    if (n === "age" || /-age$/.test(n)) return "age";
    if (n === "dm" || ["date", "modified", "created", "mtime", "time", "when", "deadline", "scheduled"].some(function (w) { return n.indexOf(w) >= 0; })) return "date";
    if (n.indexOf("path") >= 0) return "path";
    return "value";
}

// `/g/keys[/part...]` -> { specs: [{name, bucket, level}], dir } or null (not a group token, or inert).
// aliases: { shortKey: typeName } (optional).
function parseGroup(text, known, aliases) {
    var parts = text.split("/");
    if (parts.length < 3 || parts[0] !== "" || GROUP_VERBS.indexOf(parts[1]) < 0 || parts[2].replace(/,/g, "") === "") return null;
    var bucket = null, level = null, direction = null, i;
    for (i = 3; i < parts.length; i++) {
        var p = parts[i], low = p.toLowerCase();
        if (GROUP_BUCKETS.indexOf(low) >= 0) {
            if (bucket !== null) return null;
            bucket = low === "parent-folder" ? "pf" : low;
        } else if (/^\d+$/.test(p)) {
            if (level !== null || parseInt(p, 10) < 1) return null;
            level = parseInt(p, 10);
        } else if (parseDirection(p) !== null && direction === null) {
            direction = parseDirection(p);
        } else return null;
    }
    var names = [], aliasPf = {}, keys = parts[2].split(",");
    for (i = 0; i < keys.length; i++) {
        if (keys[i] === "") continue;
        var kl = keys[i].toLowerCase(), r;
        if (kl === "pf" || kl === "parent-folder") {
            r = (resolveSortKeys(["path"], known) || []).filter(function (n) { return groupKind(n) === "path"; }).slice(0, 1);
            for (var a = 0; a < r.length; a++) aliasPf[r[a]] = true;
        } else if (aliases && aliases.hasOwnProperty(kl) && known.indexOf(aliases[kl]) >= 0) {
            r = [aliases[kl]];
        } else r = resolveSortKeys([keys[i]], known);
        if (!r || r.length === 0) return null;
        for (var j = 0; j < r.length; j++) if (names.indexOf(r[j]) < 0) names.push(r[j]);
    }
    var specs = [], hasBucket = false, hasPf = false;
    names.forEach(function (n) {
        var kind = groupKind(n), b;
        if ((aliasPf[n] || bucket === "pf") && kind === "path") b = "pf";
        else if (_DATE_BUCKETS.indexOf(bucket) >= 0 && kind === "date") b = bucket;
        else b = ({ date: "day", size: "size", age: "age", path: "pf" })[kind] || "value";
        if (b === bucket) hasBucket = true;
        if (b === "pf") hasPf = true;
        specs.push({ name: n, bucket: b, level: level || 1 });
    });
    if (bucket !== null && !hasBucket) return null;
    if (level !== null && !hasPf) return null;
    return { specs: specs, dir: direction };
}

function _daysFromCivil(y, m, d) {
    if (m <= 2) y -= 1;
    var era = Math.floor(y / 400);
    var yoe = y - era * 400;
    var doy = Math.floor((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1;
    var doe = yoe * 365 + Math.floor(yoe / 4) - Math.floor(yoe / 100) + doy;
    return era * 146097 + doe - 719468;
}
function _civilFromDays(z) {
    z += 719468;
    var era = Math.floor(z / 146097);
    var doe = z - era * 146097;
    var yoe = Math.floor((doe - Math.floor(doe / 1460) + Math.floor(doe / 36524) - Math.floor(doe / 146096)) / 365);
    var y = yoe + era * 400;
    var doy = doe - (365 * yoe + Math.floor(yoe / 4) - Math.floor(yoe / 100));
    var mp = Math.floor((5 * doy + 2) / 153);
    var d = doy - Math.floor((153 * mp + 2) / 5) + 1;
    var m = mp + (mp < 10 ? 3 : -9);
    return [y + (m <= 2 ? 1 : 0), m, d];
}
function _pad(n, w) { var s = String(n); while (s.length < w) s = "0" + s; return s; }
function _ymd(raw) {
    var s = String(raw).trim(), m = /^(\d{4})-(\d{2})-(\d{2})/.exec(s);
    if (m) return [parseInt(m[1], 10), parseInt(m[2], 10), parseInt(m[3], 10)];
    if (/^\d{9,11}(\.\d+)?$/.test(s)) {
        var t = new Date(parseFloat(s) * 1000);
        return [t.getFullYear(), t.getMonth() + 1, t.getDate()];
    }
    return null;
}
var _MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
var _SIZE_EDGES = [[1 << 10, "< 1 KB"], [10 << 10, "1 - 10 KB"], [100 << 10, "10 - 100 KB"], [1 << 20, "100 KB - 1 MB"],
                   [10 << 20, "1 - 10 MB"], [100 << 20, "10 - 100 MB"], [1073741824, "100 MB - 1 GB"], [10737418240, "1 - 10 GB"]];
var _AGE_EDGES = [[3600, "Last hour"], [86400, "Last day"], [7 * 86400, "Last week"], [30 * 86400, "Last month"]];
function _sizeBytes(raw) {
    var m = /^\s*(\d+(?:\.\d+)?)\s*([kmgt]?)i?b?\s*$/.exec(String(raw).toLowerCase());
    if (!m) return null;
    return parseFloat(m[1]) * ({ "": 1, k: 1024, m: 1048576, g: 1073741824, t: 1099511627776 })[m[2]];
}

// [sortKey, label] of the group `raw` falls in under `spec`; today = "YYYY-MM-DD". Empty/unparseable ->
// key "" (the "(none)" group, always laid out last).
function groupValue(spec, raw, today) {
    raw = (raw === null || raw === undefined) ? "" : String(raw);
    var b = spec.bucket, i, none = ["", "(none)"];
    if (b === "pf") {
        var dirs = raw.replace(/\/+$/, "").split("/").slice(0, -1);
        if (raw === "" || dirs.length === 0) return none;
        var keep = dirs.slice(0, Math.max(1, dirs.length - (spec.level - 1)));
        var label = keep.join("/") || "/";
        return [label, label];
    }
    if (_DATE_BUCKETS.indexOf(b) >= 0) {
        var ymd = _ymd(raw);
        if (!ymd) return none;
        var t = _ymd(today), dn = _daysFromCivil(ymd[0], ymd[1], ymd[2]), tn = _daysFromCivil(t[0], t[1], t[2]);
        var key;
        if (b === "day") {
            key = _pad(ymd[0], 4) + "-" + _pad(ymd[1], 2) + "-" + _pad(ymd[2], 2);
            return [key, dn === tn ? "Today" : dn === tn - 1 ? "Yesterday" : key];
        }
        if (b === "week") {
            var ws = dn - (((dn + 3) % 7) + 7) % 7, tws = tn - (((tn + 3) % 7) + 7) % 7, c = _civilFromDays(ws);
            key = _pad(c[0], 4) + "-" + _pad(c[1], 2) + "-" + _pad(c[2], 2);
            return [key, ws === tws ? "This week" : ws === tws - 7 ? "Last week" : "Week of " + key];
        }
        if (b === "month") {
            key = _pad(ymd[0], 4) + "-" + _pad(ymd[1], 2);
            return [key, (ymd[0] === t[0] && ymd[1] === t[1]) ? "This month" : _MONTHS[ymd[1] - 1] + " " + ymd[0]];
        }
        key = _pad(ymd[0], 4);
        return [key, ymd[0] === t[0] ? "This year" : key];
    }
    if (b === "size") {
        var n = _sizeBytes(raw);
        if (n === null) return none;
        for (i = 0; i < _SIZE_EDGES.length; i++) if (n < _SIZE_EDGES[i][0]) return [String(i), _SIZE_EDGES[i][1]];
        return [String(_SIZE_EDGES.length), "10 GB or more"];
    }
    if (b === "age") {
        var m = /^(\d+)([smhd])$/.exec(raw);
        if (!m) return none;
        var sec = parseInt(m[1], 10) * ({ s: 1, m: 60, h: 3600, d: 86400 })[m[2]];
        for (i = 0; i < _AGE_EDGES.length; i++) if (sec < _AGE_EDGES[i][0]) return [String(i), _AGE_EDGES[i][1]];
        return [String(_AGE_EDGES.length), "Older"];
    }
    return raw !== "" ? [raw, raw] : none;
}

// Rows (already filtered and ordered) -> flat layout: ["h", depth, id, label, count] headers and
// ["r", index] rows. Groups ordered by key per parsed.dir (age buckets newest-first when desc; "(none)"
// last), rows keep their incoming order. get(row, name) -> raw value. id = labels joined by U+001F.
function groupLayout(rows, parsed, get, today) {
    var specs = parsed.specs, direction = parsed.dir, out = [];
    function order(list, spec) {
        var full = list.filter(function (g) { return g[0] !== ""; });
        var none = list.filter(function (g) { return g[0] === ""; });
        if (direction === null) return full.concat(none);   // no explicit dir: groups follow the order their rows already have
        full.sort(function (a, b) {
            if (spec.bucket === "value") return compareFieldValues(a[0], b[0], direction);
            var c = a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0;
            return ((direction === "desc") !== (spec.bucket === "age")) ? -c : c;
        });
        return full.concat(none);
    }
    function build(idxs, depth, prefix) {
        var spec = specs[depth], groups = {}, list = [];
        idxs.forEach(function (i) {
            var kl = groupValue(spec, get(rows[i], spec.name), today);
            if (!groups.hasOwnProperty(kl[0])) { groups[kl[0]] = [kl[0], kl[1], []]; list.push(groups[kl[0]]); }
            groups[kl[0]][2].push(i);
        });
        order(list, spec).forEach(function (g) {
            var gid = prefix ? prefix + "\u001f" + g[1] : g[1];
            out.push(["h", depth, gid, g[1], g[2].length]);
            if (depth + 1 < specs.length) build(g[2], depth + 1, gid);
            else g[2].forEach(function (i) { out.push(["r", i]); });
        });
    }
    var all = [];
    for (var i = 0; i < rows.length; i++) all.push(i);
    build(all, 0, "");
    return out;
}

// The layout minus everything inside a collapsed header (the header stays). collapsed: { id: true }.
function groupVisible(layout, collapsed) {
    var out = [], hideDepth = -1;
    layout.forEach(function (e) {
        if (e[0] === "h") {
            if (hideDepth >= 0 && e[1] > hideDepth) return;
            hideDepth = collapsed[e[2]] ? e[1] : -1;
            out.push(e);
        } else if (hideDepth < 0) out.push(e);
    });
    return out;
}

function _ownsNext(tok) {
    var t = tok.replace(/^!+/, "");
    if (t.indexOf("//") === 0 && t.length > 2) return true;
    var p = t.split("/");
    return p.length === 3 && p[0] === "" && (p[1] === "fv" || p[1] === "filter-value") && p[2] !== "";
}

// Pipeline hook: pull the /g command out of a token list -> { rest, parsed }. Position-independent, last
// valid /g wins, a token owned as another command's value is never read as /g, an inert /g is dropped.
// Filters and sorts pass through untouched, so grouping always works on the filtered result.
function extractGroup(tokens, known, aliases, ownsNext) {
    var owns = ownsNext || _ownsNext, rest = [], parsed = null, i = 0;
    while (i < tokens.length) {
        var t = tokens[i++];
        if (owns(t)) {
            rest.push(t);
            if (i < tokens.length) rest.push(tokens[i++]);
            continue;
        }
        var bare = t.split("/");
        if (bare.length >= 2 && bare[0] === "" && GROUP_VERBS.indexOf(bare[1]) >= 0 && t.charAt(0) !== "!") {
            var p = parseGroup(t, known, aliases);
            if (p) parsed = p;
            continue;
        }
        rest.push(t);
    }
    return { rest: rest, parsed: parsed };
}

function todayIso() {
    var d = new Date();
    return _pad(d.getFullYear(), 4) + "-" + _pad(d.getMonth() + 1, 2) + "-" + _pad(d.getDate(), 2);
}

// What the QML pickers show for a /g: rows (already filtered and sorted) + the parsed command -> 
// { items, rows }. items: the display sequence - { kind: "group", depth, id, label, count, folded } headers and
// { kind: "row", row, v } rows (v = the row's position in `rows`); rows: the rows outside folded groups, in
// display order - the sequence selection and navigation walk. collapsed: { id: true }.
function groupDisplay(rows, parsed, get, collapsed, today) {
    var layout = groupLayout(rows, parsed, get, today || todayIso());
    var vis = groupVisible(layout, collapsed || {});
    var items = [], out = [];
    vis.forEach(function (e) {
        if (e[0] === "h") items.push({ kind: "group", depth: e[1], id: e[2], label: e[3], count: e[4], folded: !!(collapsed && collapsed[e[2]]) });
        else { items.push({ kind: "row", row: rows[e[1]], v: out.length }); out.push(rows[e[1]]); }
    });
    return { items: items, rows: out };
}

// The group id the row at position v of display.rows sits under (innermost), or "".
function groupOfRow(display, v) {
    var id = "";
    for (var i = 0; i < display.items.length; i++) {
        var it = display.items[i];
        if (it.kind === "group") id = it.id;
        else if (it.v === v) return id;
    }
    return "";
}

// The ListView model for a grouped picker: `prefix` rows (completion rows etc., ungrouped) followed by the
// display of groupDisplay(). Row entries are the row objects themselves; headers are { grp: true, depth, id,
// label, count, folded }. vOf[i] is the logical position (in prefix.concat(display.rows)) of model entry i,
// -1 for a header.
function groupModel(prefix, display) {
    var model = prefix.slice(), vOf = [], i;
    for (i = 0; i < prefix.length; i++) vOf.push(i);
    display.items.forEach(function (it) {
        if (it.kind === "group") {
            model.push({ grp: true, depth: it.depth, id: it.id, label: it.label, count: it.count, folded: it.folded });
            vOf.push(-1);
        } else {
            model.push(it.row);
            vOf.push(prefix.length + it.v);
        }
    });
    return { model: model, vOf: vOf };
}
