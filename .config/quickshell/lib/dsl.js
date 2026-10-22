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
