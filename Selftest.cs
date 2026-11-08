using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace SearchApp
{
    /// <summary>--selftest: golden comparison of the ported logic (offline) plus optional live API checks.</summary>
    public static class Selftest
    {
        static object[] L(IEnumerable<object> e) { return e.ToArray(); }
        static string Ser(object o) { return Api.Js.Serialize(o); }
        static double N(object o) { return Convert.ToDouble(o, System.Globalization.CultureInfo.InvariantCulture); }
        static string S(object o) { return o as string; }
        static Dictionary<string, object> Dict(params object[] kv) { var d = new Dictionary<string, object>(); for (int i = 0; i < kv.Length; i += 2) d[(string)kv[i]] = kv[i + 1]; return d; }

        static object[] CandsOut(int start, List<Cand> c) { return new object[] { start, L(c.Select(x => (object)new object[] { x.V, x.L })) }; }

        public static int Run(string[] a, TextWriter o)
        {
            string golden = null; bool live = false; string server = "http://127.0.0.1:8795";
            for (int i = 0; i < a.Length; i++) { if (a[i] == "--golden" && i + 1 < a.Length) golden = a[++i]; else if (a[i] == "--live") live = true; else if (a[i] == "--server" && i + 1 < a.Length) server = a[++i]; }
            int fails = 0;
            if (golden != null) fails += Golden(golden, o);
            else o.WriteLine("(no --golden file given, offline logic tests skipped)");
            if (live) fails += Live(server, o);
            o.WriteLine(fails == 0 ? "SELFTEST OK" : "SELFTEST FAILED: " + fails);
            return fails == 0 ? 0 : 1;
        }

        static int Golden(string path, TextWriter o)
        {
            var root = (Dictionary<string, object>)Api.Js.DeserializeObject(File.ReadAllText(path));
            var fac = (Dictionary<string, object>)root["facets"];
            var facets = new Facets();
            foreach (var x in (object[])fac["dates"]) facets.Dates.Add((string)x);
            foreach (var x in (object[])fac["mimes"]) facets.Mimes.Add((string)x);
            foreach (var x in (object[])fac["exts"]) facets.Exts.Add((string)x);
            var hist = ((object[])root["hist"]).Select(x => (string)x).ToList();
            var recs = (object[])root["recs"];
            int fails = 0, n = 0; var perFn = new Dictionary<string, int>();
            foreach (Dictionary<string, object> r in recs)
            {
                string fn = (string)r["fn"]; var args = (object[])r["args"]; object exp = r["out"], got;
                try { got = Eval(fn, args, facets, hist); } catch (Exception e) { got = "EXCEPTION " + e.GetType().Name + " " + e.Message; }
                n++;
                string es = Ser(exp), gs = Ser(got);
                if (es != gs)
                {
                    fails++; int c; perFn.TryGetValue(fn, out c); perFn[fn] = c + 1;
                    if (c < 4) o.WriteLine("DIFF " + fn + " " + Ser(args) + "\n  js : " + es + "\n  cs : " + gs);
                }
            }
            o.WriteLine("golden: " + n + " records, " + fails + " diffs" + (fails > 0 ? " (" + string.Join(", ", perFn.Select(k => k.Key + "=" + k.Value)) + ")" : ""));
            return fails;
        }

        static object Eval(string fn, object[] a, Facets facets, List<string> hist)
        {
            switch (fn)
            {
                case "cmdSpans": return L(Dsl.CmdSpans(S(a[0])).Select(x => (object)new object[] { x[0], x[1] }));
                case "queryTerms": return L(Dsl.QueryTerms(S(a[0])).Select(x => (object)x));
                case "sortInfo":
                    {
                        var s = Dsl.SortInfo(S(a[0]));
                        if (!s.Explicit) return Dict("explicit", false, "key", null, "desc", true);
                        return Dict("explicit", true, "key", s.Key, "keys", L(s.Keys.Select(x => (object)x)), "desc", s.Desc);
                    }
                case "colOfKey": return Dsl.ColOfKey(S(a[0]));
                case "normQ": return Dsl.NormQ(S(a[0]));
                case "isContent": return Dsl.IsContent(S(a[0]));
                case "pathFragment": { int st; string fr; return Dsl.PathFragment(S(a[0]), out st, out fr) ? (object)new object[] { st, fr } : null; }
                case "completions": { var c = new List<Cand>(); int st = Dsl.Completions(S(a[0]), facets, hist, c); return CandsOut(st, c); }
                case "completionsMulti":
                    {
                        var c = new List<Cand>(); int? ms = a[1] == null ? (int?)null : (int)N(a[1]);
                        int st = Dsl.CompletionsMulti(S(a[0]), ms, facets, hist, c); return CandsOut(st, c);
                    }
                case "histMatches": return L(Dsl.HistMatches(S(a[0]), hist).Select(x => (object)x));
                case "hlSegs":
                    {
                        var terms = ((object[])a[1]).Select(x => (string)x).ToList();
                        return L(Dsl.HlName(S(a[0]), terms).Select(x => (object)new object[] { x.Key, x.Value }));
                    }
                case "setSortQ": return Dsl.SetSort(S(a[0]), S(a[1]));
                case "hsize": return Dsl.HSize(N(a[0]));
                case "digits": return Dsl.Digits((long)N(a[0]));
                case "stime": return Dsl.STime(S(a[0]));
                case "splitDir": return L(Dsl.SplitDir(S(a[0])).Select(x => (object)x));
                case "fuzzy": return Dsl.Fuzzy(S(a[0]), S(a[1]));
                case "lightFrom":
                    {
                        var t = (Dictionary<string, object>)a[0];
                        var p = ThemeMath.LightFrom(new Palette { Bg = S(t["bg"]), Accent = S(t["accent"]) });
                        return Dict("bg", p.Bg, "text", p.Text, "dim", p.Dim, "border", p.Border, "accent", p.Accent, "error", p.Error);
                    }
            }
            return "UNKNOWN FN " + fn;
        }

        // ---- live checks against the real server (read-only; settings are toggled and restored) ----
        static int Live(string server, TextWriter o)
        {
            int fails = 0; var api = new Api(server); var ct = CancellationToken.None;
            Action<string, bool, string> chk = (name, ok, info) => { o.WriteLine((ok ? "ok   " : "FAIL ") + name + (info != null ? "  " + info : "")); if (!ok) fails++; };
            try
            {
                var v = api.Ver(ct).Result;
                chk("ver", v.Ver >= 0 && v.Theme != null, "ver=" + v.Ver + " accent=" + (v.Theme == null ? "?" : v.Theme.Accent));
                var q0 = api.Query("sample minutes", 0, 200, "selftest", 1, ct).Result;
                chk("query page0", q0.Count > 0 && q0.Results.Count > 0, "count=" + q0.Count + " got=" + q0.Results.Count);
                if (q0.Results.Count > 0) { var h = q0.Results[0]; chk("hit fields", h.Path != null && h.Remote != null, h.Path + " size=" + h.Size + " mtime=" + h.Mtime + " thumb=" + h.Thumb + " fileok=" + h.FileOk + " pages=" + h.Pages); }
                chk("stats", q0.Stats != null && q0.Stats.Kinds.Count > 0, q0.Stats == null ? "null" : Dsl.HSize(q0.Stats.Size) + " " + q0.Stats.DMin + ".." + q0.Stats.DMax);
                if (q0.Count > 200)
                {
                    var q1 = api.Query("sample minutes", 200, 200, "selftest", 2, ct).Result;
                    chk("query page1", q1.Results.Count > 0 && q1.Results[0].Remote != q0.Results[0].Remote, "got=" + q1.Results.Count);
                }
                var qe = api.Query("/fts", 0, 10, "selftest", 3, ct).Result;
                chk("error text", qe.Errors.Count > 0, string.Join("; ", qe.Errors));
                var th = q0.Results.FirstOrDefault(x => !string.IsNullOrEmpty(x.Thumb));
                if (th != null) { var b = api.GetBytes(th.Thumb, ct).Result; chk("thumb bytes", b.Length > 100, b.Length + " bytes"); }
                var f = api.GetFacets(ct).Result; chk("facets", f.Dates.Count > 0 && f.Exts.Count > 0, f.Dates.Count + " dates " + f.Exts.Count + " exts");
                var pp = api.Paths("docs", ct).Result; chk("paths", pp.Key > 0, "total=" + pp.Key);
                var hs = api.History(ct).Result; chk("history", hs.Count > 0, hs.Count + " items, newest=" + (hs.Count > 0 ? hs[0] : ""));
                var st = api.GetSettings(ct).Result; chk("settings get", st.DefaultExclude != null, st.DefaultExclude);
                bool orig = st.FtsDwg;
                var st2 = api.PostSettings(new Dictionary<string, object> { { "show_fts_dwg", !orig } }).Result;
                bool flipped = st2.FtsDwg == !orig;
                var st3 = api.PostSettings(new Dictionary<string, object> { { "show_fts_dwg", orig } }).Result;
                chk("settings toggle+restore", flipped && st3.FtsDwg == orig, "orig=" + orig);
                var fts = api.Query("/fts minutes", 0, 5, "selftest", 4, ct).Result;
                if (fts.Results.Count > 0)
                {
                    var sn = api.Snippets(fts.Results[0].Remote, "/fts minutes", ct).Result;
                    chk("snippets", sn.Count >= 0, sn.Count + " passages");
                }
                else chk("fts query", fts.Errors.Count > 0, "0 results; " + string.Join(";", fts.Errors));
            }
            catch (Exception e) { chk("live exception", false, e.GetBaseException().GetType().Name + ": " + e.GetBaseException().Message); }
            return fails;
        }
    }
}
