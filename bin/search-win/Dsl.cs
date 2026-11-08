using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace SearchApp
{
    public struct Cand { public string V, L; public Cand(string v, string l) { V = v; L = l; } }

    public class Attr { public string Name; public long Count; public List<string> Values = new List<string>(); }

    public class Facets
    {
        public List<string> Dates = new List<string>(), Mimes = new List<string>(), Exts = new List<string>();
        /// <summary>Document attributes from the server: name, number of files, common values.</summary>
        public List<Attr> Attrs = new List<Attr>();
        /// <summary>Further tags the server knows (for example //pages): name, description.</summary>
        public List<string[]> ExtraTags = new List<string[]>();
    }

    /// <summary>Port of the query-language helpers of the web page (cmdSpans, queryTerms, completions, ...).</summary>
    public static class Dsl
    {
        public static readonly string[] SortFields = { "name", "path", "size", "date-modified", "extension", "depth", "pages" };
        public static readonly string[][] Cols = {
            new[]{"name","NAME","name"}, new[]{"path","PATH","path"}, new[]{"size","SIZE","size"},
            new[]{"pages","#P","pages"}, new[]{"date","MODIFIED","date-modified"} };
        static readonly HashSet<string> Verbs = new HashSet<string>(("fts full-text-search chroma semantic clip face s sort g group show-dotfiles hide-dotfiles show-backup hide-backup show-backup-restic hide-backup-restic show-backup-btrfs hide-backup-btrfs show-fts-rvt hide-fts-rvt show-fts-dwg hide-fts-dwg").Split(' '));
        static readonly HashSet<string> Tags = new HashSet<string>("name path size dm mime ext file".Split(' '));
        /// <summary>Attribute and extra tag names from the server: a //word that is a part of one of them is a command too.</summary>
        public static List<string> AttrNames = new List<string>();
        static bool IsTag(string t) { return Tags.Contains(t) || (t.Length > 0 && AttrNames.Any(a => a.Contains(t))); }
        static readonly Regex ContentRx = new Regex(@"(^|\s)/(fts|chroma|full-text-search|semantic)(/\S*)?(\s|$)");
        static readonly Regex TokRx = new Regex("\"[^\"]*\"|\\S+");

        public static bool IsContent(string q) { return q != null && ContentRx.IsMatch(q); }

        public static string Digits(long n)
        {
            string s = n.ToString(System.Globalization.CultureInfo.InvariantCulture);
            bool neg = s.StartsWith("-"); if (neg) s = s.Substring(1);
            var sb = new StringBuilder();
            for (int i = 0; i < s.Length; i++) { if (i > 0 && (s.Length - i) % 3 == 0) sb.Append(','); sb.Append(s[i]); }
            return (neg ? "-" : "") + sb;
        }

        public static string HSize(double b)
        {
            string[] u = { "B", "KiB", "MiB", "GiB", "TiB" };
            int i = 0; double v = b;
            while (v >= 1024 && i < 4) { v /= 1024; i++; }
            return i > 0 ? JsFixed1(v) + " " + u[i] : Digits0(b) + " B";
        }
        static string Digits0(double b) { return ((long)b).ToString(System.Globalization.CultureInfo.InvariantCulture); }
        // JS toFixed(1) rounds half away from zero on the decimal expansion; Math.Round away-from-zero is close enough, mirror it.
        static string JsFixed1(double v)
        {
            return (Math.Floor(v * 10 + 0.5 + 1e-9) / 10).ToString("0.0", System.Globalization.CultureInfo.InvariantCulture);
        }

        public static string STime(string t)
        {
            t = t ?? "";
            int i = t.IndexOf('T');
            if (i >= 0) t = t.Substring(0, i) + " " + t.Substring(i + 1);
            return t.Length > 16 ? t.Substring(0, 16) : t;
        }

        public static string[] SplitDir(string p)
        {
            int i = p.LastIndexOf('/');
            if (i < 0) return new[] { "", p };
            if (i == 0) return new[] { "/", p.Substring(1) };
            return new[] { p.Substring(0, i), p.Substring(i + 1) };
        }

        public static string NormQ(string q) { return string.Join(" ", TokRx.Matches(q ?? "").Cast<Match>().Select(m => m.Value)); }

        public static List<int[]> CmdSpans(string q)
        {
            int i = 0; bool own = false; var outl = new List<int[]>();
            while (i < q.Length)
            {
                if (q[i] == ' ') { i++; continue; }
                int st = i; if (q[i] == '!') { i++; st = i; }
                if (i < q.Length && q[i] == '"') { int e = q.IndexOf('"', i + 1); i = e < 0 ? q.Length : e + 1; own = false; continue; }
                while (i < q.Length && q[i] != ' ') i++;
                string tok = q.Substring(st, i - st);
                if (own) { own = false; continue; }
                if (tok.StartsWith("//")) { if (IsTag(tok.Substring(2).Split('/')[0])) { outl.Add(new[] { st, i }); own = true; } }
                else if (tok.Length > 0 && tok[0] == '/') { if (Verbs.Contains(tok.Substring(1).Split('/')[0])) outl.Add(new[] { st, i }); }
            }
            return outl;
        }

        static readonly Regex FtsRx = new Regex(@"^/(fts|full-text-search|chroma|semantic)$");
        static readonly Regex ShowHideRx = new Regex(@"^/(show|hide)-");
        static readonly Regex SortTokRx = new Regex(@"^/(s|sort|g|group)/");

        public static List<string> QueryTerms(string q)
        {
            var outl = new List<string>(); bool skip = false;
            foreach (Match mm in TokRx.Matches(q ?? ""))
            {
                string tok = mm.Value;
                if (FtsRx.IsMatch(tok) || ShowHideRx.IsMatch(tok)) continue;
                if (tok[0] == '!') { string n = tok.Substring(1); if (n.StartsWith("//") || n == "/clip" || n == "/face") skip = true; continue; }
                if (SortTokRx.IsMatch(tok)) continue;
                if (tok == "/clip" || tok == "/face" || tok.StartsWith("//")) { skip = true; continue; }
                if (skip) { skip = false; continue; }
                string t = tok.Replace("\"", "").ToLowerInvariant();
                if (tok[0] != '"' && t.Contains("||")) outl.AddRange(t.Split(new[] { "||" }, StringSplitOptions.None).Where(x => x.Length > 0));
                else if (t.Length > 0) outl.Add(t);
            }
            return outl;
        }

        /// <summary>Segments of a name: (text, bold). Port of hlName.</summary>
        public static List<KeyValuePair<string, bool>> HlName(string text, List<string> terms)
        {
            string low = text.ToLowerInvariant(); var rg = new List<int[]>();
            foreach (var t in terms) { if (t.Length == 0) continue; int f = 0, i; while ((i = low.IndexOf(t, f, StringComparison.Ordinal)) >= 0) { rg.Add(new[] { i, i + t.Length }); f = i + t.Length; } }
            rg = rg.OrderBy(x => x[0]).ToList();   // stable
            int pos = 0; var res = new List<KeyValuePair<string, bool>>();
            foreach (var r in rg)
            {
                if (r[1] <= pos) continue; int s2 = Math.Max(r[0], pos);
                if (s2 > pos) res.Add(new KeyValuePair<string, bool>(text.Substring(pos, s2 - pos), false));
                res.Add(new KeyValuePair<string, bool>(text.Substring(s2, r[1] - s2), true)); pos = r[1];
            }
            if (pos < text.Length) res.Add(new KeyValuePair<string, bool>(text.Substring(pos), false));
            return res;
        }

        public class SortInf { public bool Explicit; public string Key; public string[] Keys; public bool Desc = true; }
        static readonly Regex SortRx = new Regex(@"(^|\s)/(?:s|sort)/(\S+)");
        public static SortInf SortInfo(string q)
        {
            var m = SortRx.Match(q ?? "");
            if (!m.Success) return new SortInf();
            var parts = m.Groups[2].Value.Split('/'); bool desc = true;
            foreach (var p in parts.Skip(1)) { if (p == "asc") desc = false; else if (p == "desc") desc = true; }
            var keys = parts[0].Split(',');
            return new SortInf { Explicit = true, Key = keys[0], Keys = keys, Desc = desc };
        }

        public static string ColOfKey(string k)
        {
            if (string.IsNullOrEmpty(k)) return null;
            foreach (var c in Cols) if (c[2].StartsWith(k, StringComparison.Ordinal) || (k == "date" && c[0] == "date")) return c[0];
            return null;
        }

        /// <summary>The query after a header click (setSort).</summary>
        public static string SetSort(string q, string colKey)
        {
            var si = SortInfo(q); string pc = si.Explicit ? ColOfKey(si.Key) : null;
            bool desc = !(si.Explicit && pc == colKey && si.Desc);
            string field = Cols.First(c => c[0] == colKey)[2];
            string rest = Regex.Replace(q, @"(^|\s)/(?:s|sort)/\S+", " ");
            rest = Regex.Replace(rest, @"\s+", " ").Trim();
            return (rest.Length > 0 ? rest + " " : "") + "/s/" + field + (desc ? "" : "/asc");
        }

        // ---- completion ----
        static readonly string[][] VerbList = {
            new[]{"/fts ","full-text search over every content index: /fts beta design //mime pdf"},new[]{"/chroma ","files whose text is closest in meaning (semantic): /chroma clash tolerances for BIM"},new[]{"/clip ","photos matching what they show (CLIP text): /clip brick"},new[]{"/face ","photos showing a registered person: /face daniel"},new[]{"/s/","(/sort) order the results by a field, e.g. /s/size/desc"},new[]{"/sort/","(/s) order the results by a field, e.g. /sort/size/desc"},new[]{"/g/","(/group) fold the results into sections, e.g. /g/dm/week or /g/pf/2"},new[]{"/group/","(/g) fold the results into sections, e.g. /group/dm/week"},new[]{"/show-dotfiles ","include names starting with a dot (this search only)"},new[]{"/hide-dotfiles ","leave out names starting with a dot (this search only)"},new[]{"/show-backup ","include restic backups and btrfs snapshots (this search only)"},new[]{"/hide-backup ","leave out restic backups and btrfs snapshots"},new[]{"/show-backup-restic ","include restic backups only"},new[]{"/hide-backup-restic ","leave out restic backups"},new[]{"/show-backup-btrfs ","include btrfs snapshots only"},new[]{"/hide-backup-btrfs ","leave out btrfs snapshots"},new[]{"/show-fts-rvt ","content searches (/fts, /chroma) include Revit files: rvt rfa rte rft"},new[]{"/hide-fts-rvt ","content searches leave out Revit files"},new[]{"/show-fts-dwg ","content searches include AutoCAD drawings"},new[]{"/hide-fts-dwg ","content searches leave out AutoCAD drawings"}};
        static readonly string[][] TagList = {
            new[]{"name","file name contains"},new[]{"path","folder path contains"},new[]{"size","file size, e.g. >5M or <200K"},new[]{"dm","date modified, pick a month"},new[]{"mime","file kind: image, pdf, text, code, ..."},new[]{"ext","file extension, e.g. .pdf or .csv"},new[]{"file","file-name search mode"}};

        public static List<Cand> ValuesFor(string tag, Facets f)
        {
            var o = new List<Cand>();
            if (tag == "dm") foreach (var d in f.Dates) o.Add(new Cand(d, "modified in this month"));
            else if (tag == "ext" || tag == "extension") foreach (var e in f.Exts) o.Add(new Cand("." + e, "file extension"));
            else if (tag == "mime") foreach (var m in f.Mimes) o.Add(new Cand(m, "file kind"));
            else if (tag == "size")
            {
                string[][] s = { new[]{"<100K","smaller than 100 KiB"},new[]{">100K","larger than 100 KiB"},new[]{"<1M","smaller than 1 MiB"},new[]{">1M","larger than 1 MiB"},new[]{"<10M","smaller than 10 MiB"},new[]{">10M","larger than 10 MiB"},new[]{"<100M","smaller than 100 MiB"},new[]{">100M","larger than 100 MiB"},new[]{"<1G","smaller than 1 GiB"},new[]{">1G","larger than 1 GiB"},new[]{"<10G","smaller than 10 GiB"},new[]{">10G","larger than 10 GiB"}};
                foreach (var x in s) o.Add(new Cand(x[0], x[1]));
            }
            else if (tag == "pages")
                foreach (var v in new[] { ">10", ">50", ">100", ">300", "<5" }) o.Add(new Cand(v, (v[0] == '>' ? "more than " : "fewer than ") + v.Substring(1) + " pages (counted PDFs)"));
            else if (tag.Length > 0 && f.Attrs.Count > 0)
            {
                var seen = new HashSet<string>();
                foreach (var a in f.Attrs) if (a.Name.Contains(tag)) foreach (var v in a.Values) if (seen.Add(v) && v.IndexOf('"') < 0) o.Add(new Cand(v.Any(IsWs) ? "\"" + v + "\"" : v, a.Name));
            }
            return o;
        }

        static bool IsWs(char c) { return char.IsWhiteSpace(c); }
        static bool Includes(string hay, string needle) { return hay.IndexOf(needle, StringComparison.Ordinal) >= 0; }
        static string Last(IList<string> a) { return a[a.Count - 1]; }

        public static int Completions(string q, Facets facets, IList<string> hist, List<Cand> outl)
        {
            // start = index after the last whitespace that is followed only by non-space up to the end
            int start = 0;
            { int j = q.Length; while (j > 0 && !IsWs(q[j - 1])) j--; if (j > 0) start = j; }
            if (start < q.Length && q[start] == '!') start++;
            string frag = q.Substring(start);
            var words = q.Substring(0, start).Trim().Split((char[])null, StringSplitOptions.RemoveEmptyEntries);
            string prev = words.Length > 0 ? words[words.Length - 1] : "";
            if (prev.Length > 0 && prev[0] == '!') prev = prev.Substring(1);
            outl.Clear();
            if (frag.Length > 0 && frag[0] == '/' && !frag.StartsWith("//") && !Includes(frag, " ") && !prev.StartsWith("//"))
            {
                foreach (var vl in VerbList) if (vl[0].StartsWith(frag, StringComparison.Ordinal) && !Includes(frag.Substring(1), "/")) outl.Add(new Cand(vl[0], vl[1]));
                if (!Includes(frag.Substring(1), "/"))
                {
                    foreach (var n in SortFields) { string v = "/s/" + n; if (v.StartsWith(frag, StringComparison.Ordinal)) outl.Add(new Cand(v, "(/sort) sort field")); }
                    foreach (var n in SortFields.Concat(new[] { "pf" })) { string v = "/g/" + n; if (v.StartsWith(frag, StringComparison.Ordinal)) outl.Add(new Cand(v, "(/group) group by")); }
                }
            }
            string chain = null, head = "";
            foreach (var p in new[] { "/group/", "/g/" }) if (frag.StartsWith(p, StringComparison.Ordinal)) { chain = frag.Substring(p.Length); head = p; }
            if (chain != null)
            {
                int i = chain.IndexOf('/');
                if (i >= 0)
                {
                    string tail = chain.Substring(i + 1);
                    var tp = tail.Split('/').Select(t => t.ToLowerInvariant()).ToList();
                    string last = Last(tp); var before = tp.Take(tp.Count - 1).ToList();
                    string bas = frag.Substring(0, frag.Length - last.Length);
                    Func<string, bool> isS = t => t == "s" || t == "sort";
                    if (before.Count > 0 && isS(Last(before)))
                    { foreach (var n in SortFields.Concat(new[] { "count" })) if (Includes(n, last)) outl.Add(new Cand(bas + n, "order sections by")); }
                    else if (before.Count >= 2 && isS(before[before.Count - 2]))
                    { foreach (var wf in new[] { new[] { "asc", "smallest / oldest first" }, new[] { "desc", "biggest / newest first (default)" } }) if (wf[0].StartsWith(last, StringComparison.Ordinal)) outl.Add(new Cand(bas + wf[0] + " ", wf[1])); }
                    else
                    {
                        bool sorted = before.Any(isS);
                        string[][] ws = { new[]{"pf","parent folder (1 = immediate, then /2 ...)"},new[]{"parent-folder","same as pf"},new[]{"day","by day"},new[]{"week","by week"},new[]{"month","by month"},new[]{"year","by year"},new[]{"asc","oldest / smallest / A first"},new[]{"desc","newest / biggest first"},new[]{"s","order the sections themselves: s/<field>[/asc|desc]"},new[]{"collapse","start with every section folded"}};
                        foreach (var wl in ws)
                        {
                            string w = wl[0];
                            if (w == "s" && sorted) continue;
                            if (w.StartsWith(last, StringComparison.Ordinal) && !before.Contains(w)) outl.Add(new Cand(bas + w + (w == "s" ? "/" : " "), wl[1]));
                        }
                    }
                }
                else
                {
                    int c = chain.LastIndexOf(',') + 1; string f = chain.Substring(c).ToLowerInvariant();
                    foreach (var n in SortFields.Concat(new[] { "pf" })) if (Includes(n, f)) outl.Add(new Cand(head + chain.Substring(0, c) + n, "group by"));
                }
                return start;
            }
            foreach (var p in new[] { "/sort/", "/s/" }) if (frag.StartsWith(p, StringComparison.Ordinal))
                {
                    string ch = frag.Substring(p.Length); int i = ch.IndexOf('/');
                    if (i >= 0)
                    {
                        string keys = ch.Substring(0, i), d = ch.Substring(i + 1).ToLowerInvariant();
                        foreach (var wf in new[] { new[] { "asc", "ascending" }, new[] { "desc", "descending" } }) if (wf[1].StartsWith(d, StringComparison.Ordinal)) outl.Add(new Cand(p + keys + "/" + wf[0] + " ", "sort direction"));
                    }
                    else
                    {
                        int c = ch.LastIndexOf(',') + 1; string f = ch.Substring(c).ToLowerInvariant();
                        foreach (var n in SortFields) if (Includes(n, f)) outl.Add(new Cand(p + ch.Substring(0, c) + n, "sort field"));
                    }
                    return start;
                }
            if (frag.StartsWith("//"))
            {
                string body = frag.Substring(2);
                var exact = TagList.FirstOrDefault(t => t[0] == body);
                bool known = exact != null || facets.ExtraTags.Any(t => t[0] == body) || facets.Attrs.Any(a => a.Name == body);
                if (known)
                {
                    var vals = ValuesFor(body, facets);
                    if (vals.Count > 0) { foreach (var v in vals) outl.Add(new Cand("//" + body + " " + v.V + " ", v.L)); return start; }
                }
                foreach (var t in TagList) if (t[0].StartsWith(body, StringComparison.Ordinal)) outl.Add(new Cand("//" + t[0] + " ", t[1]));
                foreach (var t in facets.ExtraTags) if (t[0].StartsWith(body, StringComparison.Ordinal)) outl.Add(new Cand("//" + t[0] + " ", t[1]));
                foreach (var a in facets.Attrs)
                    if (a.Name.Contains(body) && !TagList.Any(t => t[0] == a.Name)) outl.Add(new Cand("//" + a.Name + " ", "document attribute, " + Digits(a.Count) + " files (matches every attribute containing this)"));
            }
            else if (prev.StartsWith("//") && ValuesFor(prev.Substring(2), facets).Count > 0)
            {
                string f = frag.ToLowerInvariant();
                foreach (var v in ValuesFor(prev.Substring(2), facets)) if (Includes(v.V.ToLowerInvariant(), f)) outl.Add(new Cand(v.V + " ", v.L));
            }
            else if (prev == "/clip")
            {
                string f = frag.ToLowerInvariant(); var seen = new HashSet<string>();
                foreach (var h in hist)
                {
                    var m2 = Regex.Match(h, @"^\s*/clip\s+(.*)$");
                    if (m2.Success) { string t = m2.Groups[1].Value.Trim(); if (t.Length > 0 && Includes(t.ToLowerInvariant(), f) && seen.Add(t)) outl.Add(new Cand(t + " ", "earlier /clip search")); }
                }
            }
            return start;
        }

        /// <summary>Ctrl+Space AND-narrowing.</summary>
        public static int CompletionsMulti(string q, int? ms, Facets facets, IList<string> hist, List<Cand> outl)
        {
            if (ms == null || ms.Value > q.Length) return Completions(q, facets, hist, outl);
            var w = q.Substring(ms.Value).Trim().Split((char[])null, StringSplitOptions.RemoveEmptyEntries).ToList();
            string first = w.Count > 0 ? w[0] : ""; if (w.Count > 0) w.RemoveAt(0);
            var rest = w.Select(x => x.ToLowerInvariant()).ToList();
            int st = Completions(q.Substring(0, ms.Value) + first, facets, hist, outl);
            outl.RemoveAll(c => !rest.All(x => Includes(c.V.ToLowerInvariant(), x)));
            return st;
        }

        /// <summary>//path folder fragment: returns false or (start, fragment).</summary>
        public static bool PathFragment(string q, out int start, out string frag)
        {
            start = 0; frag = null;
            int i = q.LastIndexOf("//path", StringComparison.Ordinal); if (i < 0) return false;
            string after = q.Substring(i + 6);
            if (after.Length > 0 && !IsWs(after[0])) return false;
            start = i + 6 + (after.Length - after.TrimStart().Length);
            frag = q.Substring(start);
            if (Includes(frag, "//") || frag.Any(IsWs)) return false;
            return true;
        }

        public static bool Fuzzy(string hay, string needle)
        {
            int i = 0; hay = hay.ToLowerInvariant();
            foreach (char c in needle.ToLowerInvariant()) { i = hay.IndexOf(c, i); if (i < 0) return false; i++; }
            return true;
        }

        public static List<string> HistMatches(string input, IList<string> hist)
        {
            string n = NormQ(input);
            if (n.Length == 0) return hist.Take(10).ToList();
            string low = n.ToLowerInvariant();
            var o = hist.Where(h => Includes(h.ToLowerInvariant(), low)).Take(10).ToList();
            foreach (var h in hist) { if (o.Count >= 10) break; if (!o.Contains(h) && Fuzzy(h, n)) o.Add(h); }
            return o;
        }
    }
}
