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
            string golden = null, term = "report", narrow = "minutes"; bool live = false, ui = false; string server = "http://127.0.0.1:8795";
            for (int i = 0; i < a.Length; i++) { if (a[i] == "--golden" && i + 1 < a.Length) golden = a[++i]; else if (a[i] == "--live") live = true; else if (a[i] == "--ui") ui = true; else if (a[i] == "--term" && i + 1 < a.Length) term = a[++i]; else if (a[i] == "--narrow" && i + 1 < a.Length) narrow = a[++i]; else if (a[i] == "--server" && i + 1 < a.Length) server = a[++i]; }
            int fails = 0;
            if (golden != null) fails += Golden(golden, o);
            else o.WriteLine("(no --golden file given, offline logic tests skipped)");
            if (live) fails += Live(server, o, term, narrow);
            fails += Plans(o);
            if (ui) fails += Ui(server, o, term, narrow);
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

        // ---- open decisions (nothing is launched) ----
        static int Plans(TextWriter o)
        {
            int fails = 0;
            var cfg = new Config(); cfg.PathMap.Add(new[] { "/mnt/share/m/", "M:\\" }); cfg.PathMap.Add(new[] { "/mnt/share/q/", "Q:\\" });
            var op = new Opener(cfg, new Api("http://127.0.0.1:1"));
            Func<string, bool, Hit> H = (p, ok) => new Hit { Path = p, Remote = p, FileOk = ok };
            Action<string, OpenPlan, string> chk = (n, pl, want) => { bool ok = pl.ToString() == want; o.WriteLine((ok ? "ok   " : "FAIL ") + "plan " + n + "  " + pl); if (!ok) fails++; };
            chk("mapped exists", op.Plan(H("/mnt/share/m/A B/x.eml", true), p => true), "Local M:\\A B\\x.eml");
            var dl = op.Plan(H("/srv/docs/y.pdf", true), p => false);
            chk("unmapped", new OpenPlan { Kind = dl.Kind, Target = null }, "Download");
            o.WriteLine("     copy path " + dl.Target);
            var dl2 = op.Plan(H("/mnt/share/q/gone.pdf", true), p => false); chk("mapped but missing", new OpenPlan { Kind = dl2.Kind }, "Download");
            chk("url", op.Plan(H("https://host.example/dms/view.aspx?ID=1&latest=true#/a/b", false)), "Url https://host.example/dms/view.aspx?ID=1&latest=true");
            chk("refuse", op.Plan(H("/etc/x", false)), "Refuse");
            bool d1 = Opener.IsDangerous(cfg, "/a/b.EXE"), d2 = Opener.IsDangerous(cfg, "/a/b.eml");
            o.WriteLine((d1 && !d2 ? "ok   " : "FAIL ") + "dangerous ext check"); if (!(d1 && !d2)) fails++;
            var real = Config.Load(); string rm = real.MapToWindows("/mnt/share/m/PROJECTS/a/b.eml");
            o.WriteLine("     real config: server=" + real.Server + " maps=" + real.PathMap.Count + " sample=" + rm);
            {
                var f = new Facets(); f.Attrs.Add(new Attr { Name = "owner", Count = 1441, Values = { "Anna Smith" } }); f.Attrs.Add(new Attr { Name = "owner-org", Count = 640, Values = { "Acme" } }); f.Attrs.Add(new Attr { Name = "status", Count = 5, Values = { "locked" } });
                f.ExtraTags.Add(new[] { "pages", "PDF page count" });
                var c = new List<Cand>(); var none = new List<string>();
                Dsl.Completions("x //ow", f, none, c); bool a1 = c.Count == 2 && c[0].V == "//owner " && c[1].V == "//owner-org ";
                Dsl.Completions("x //pa", f, none, c); bool a2 = c.Any(x => x.V == "//pages ") && c.Any(x => x.V == "//path ");
                Dsl.Completions("x //owner ", f, none, c); bool a3 = c.Count == 2 && c[0].V == "\"Anna Smith\" ";
                Dsl.Completions("x //status ", f, none, c); bool a4 = c.Count == 1 && c[0].V == "locked ";
                Dsl.Completions("x //", f, none, c); bool a5 = c.Count == 7 + 1 + 3;
                Dsl.AttrNames = new List<string> { "owner", "status" }; bool a6 = Dsl.CmdSpans("a //own x").Count == 1; Dsl.AttrNames = new List<string>();
                bool ok = a1 && a2 && a3 && a4 && a5 && a6; o.WriteLine((ok ? "ok   " : "FAIL ") + "attribute completions " + a1 + a2 + a3 + a4 + a5 + a6); if (!ok) fails++;
            }
            string own = OwnerCache.Read(System.Reflection.Assembly.GetExecutingAssembly().Location);
            o.WriteLine((own.Length > 0 ? "ok   " : "FAIL ") + "owner of the exe: " + own); if (own.Length == 0) fails++;
            Opener.Dry = true; Opener.Shell("M:\\x.eml"); Opener.OpenWith("M:\\x.eml"); Opener.Dry = false;
            o.WriteLine("     dry log: " + string.Join(" | ", Opener.Log));
            return fails;
        }

        // ---- offscreen UI checks against the real server ----
        static int Ui(string server, TextWriter o, string term, string narrow)
        {
            int fails = 0;
            Action<string, bool, string> chk = (name, ok, info) => { o.WriteLine((ok ? "ok   " : "FAIL ") + name + (info != null ? "  " + info : "")); if (!ok) fails++; };
            try
            {
                System.Threading.SynchronizationContext.SetSynchronizationContext(new System.Windows.Threading.DispatcherSynchronizationContext(System.Windows.Threading.Dispatcher.CurrentDispatcher));
                var app = new System.Windows.Application { ShutdownMode = System.Windows.ShutdownMode.OnExplicitShutdown };
                var cfg = new Config { NoSave = true, Server = server };
                var root = new AppRoot(cfg, new Theme(false), null); root.Width = 1200; root.Height = 700;
                root.Measure(new System.Windows.Size(1200, 700)); root.Arrange(new System.Windows.Rect(0, 0, 1200, 700)); root.UpdateLayout();
                var init = root.InitialAsync(term);
                Shot.Pump(30000, () => init.IsCompleted && !root.busy);
                chk("ui initial query", root.total > 1000 && root.Hit(0) != null, "total=" + root.total);
                // scroll to the very end: the last page must get fetched on demand
                var g = root.List.Compute(); root.List.SetOff(root.List.MaxOff(g)); root.List.InvalidateVisual(); root.UpdateLayout();
                Shot.Pump(15000, () => root.Hit((int)root.total - 1) != null);
                chk("ui paging to last row", root.Hit((int)root.total - 1) != null, "pages loaded=" + root.pages.Count);
                // zoom to grid mode and back
                root.SetThumb(320); root.UpdateLayout(); chk("ui grid mode", root.List.IsGrid && root.Hdr.Visibility != System.Windows.Visibility.Visible, "thumb=" + root.Cols.Thumb);
                root.SetThumb(16); root.UpdateLayout(); chk("ui list mode", !root.List.IsGrid && root.Hdr.Visibility == System.Windows.Visibility.Visible, null);
                // stale handling: two quick queries, the later one must win
                root.Q.SetText(term + " " + narrow); root.q = term + " " + narrow; root.Send("zzzzqqqq9"); root.Send(term + " " + narrow);
                Shot.Pump(30000, () => !root.busy);
                chk("ui stale response ignored", root.sent == term + " " + narrow && root.total > 0 && root.total < 1000, "total=" + root.total);
                // header sort rewrites the query
                root.Hdr.RaiseSort("size"); Shot.Pump(90000, () => !root.busy && root.Hit(0) != null && root.sent.Contains("/s/size"));
                o.WriteLine("     debug: sent=" + root.sent + " busy=" + root.busy + " total=" + root.total + " errs=" + string.Join(";", root.errors) + " h0=" + (root.Hit(0) == null ? "null" : root.Hit(0).Path));
                chk("ui sort desc", root.Q.Text.EndsWith("/s/size") && root.Hit(1) != null && root.Hit(0).Size >= root.Hit(1).Size, root.Q.Text + " first=" + (root.Hit(0) != null ? root.Hit(0).Size.ToString() : "?"));
                root.Hdr.RaiseSort("size"); Shot.Pump(90000, () => !root.busy && root.sent.EndsWith("/asc"));
                chk("ui sort asc", root.Q.Text.EndsWith("/s/size/asc") && root.Hit(0) != null && root.Hit(1) != null && root.Hit(0).Size <= root.Hit(1).Size, root.Q.Text);
                try
                {
                    var win = new MainWindow(new Config { NoSave = true, Server = server }, new Theme(false), "x");
                    new System.Windows.Interop.WindowInteropHelper(win).EnsureHandle();
                    chk("ui main window constructs (not shown)", win.Root != null, null);
                    win.Close();
                }
                catch (Exception e) { chk("ui main window", false, e.ToString()); }
                Shot.Pump(2500);
                chk("ui thumbnails requested", root.Thumbs.Requests > 0, "requests=" + root.Thumbs.Requests);
            }
            catch (Exception e) { chk("ui exception", false, e.ToString()); }
            return fails;
        }

        // ---- live checks against the real server (read-only; settings are toggled and restored) ----
        static int Live(string server, TextWriter o, string term, string narrow)
        {
            int fails = 0; var api = new Api(server); var ct = CancellationToken.None; string cid = "st" + Guid.NewGuid().ToString("N").Substring(0, 8);
            Action<string, bool, string> chk = (name, ok, info) => { o.WriteLine((ok ? "ok   " : "FAIL ") + name + (info != null ? "  " + info : "")); if (!ok) fails++; };
            try
            {
                var v = api.Ver(ct).Result;
                chk("ver", v.Ver >= 0 && v.Theme != null, "ver=" + v.Ver + " accent=" + (v.Theme == null ? "?" : v.Theme.Accent));
                var q0 = api.Query(term + " " + narrow, 0, 200, cid, 1, ct).Result;
                chk("query page0", q0.Count > 0 && q0.Results.Count > 0, "count=" + q0.Count + " got=" + q0.Results.Count);
                if (q0.Results.Count > 0) { var h = q0.Results[0]; chk("hit fields", h.Path != null && h.Remote != null, h.Path + " size=" + h.Size + " mtime=" + h.Mtime + " thumb=" + h.Thumb + " fileok=" + h.FileOk + " pages=" + h.Pages); }
                chk("stats", q0.Stats != null && q0.Stats.Kinds.Count > 0, q0.Stats == null ? "null" : Dsl.HSize(q0.Stats.Size) + " " + q0.Stats.DMin + ".." + q0.Stats.DMax);
                if (q0.Count > 200)
                {
                    var q1 = api.Query(term + " " + narrow, 200, 200, cid, 2, ct).Result;
                    chk("query page1", q1.Results.Count > 0 && q1.Results[0].Remote != q0.Results[0].Remote, "got=" + q1.Results.Count);
                }
                var qe = api.Query("/fts", 0, 10, cid, 3, ct).Result;
                chk("error text", qe.Errors.Count > 0, string.Join("; ", qe.Errors));
                var th = q0.Results.FirstOrDefault(x => !string.IsNullOrEmpty(x.Thumb));
                if (th != null) { var b = api.GetBytes(th.Thumb, ct).Result; chk("thumb bytes", b.Length > 100, b.Length + " bytes"); }
                var f = api.GetFacets(ct).Result; chk("facets", f.Dates.Count > 0 && f.Exts.Count > 0, f.Dates.Count + " dates " + f.Exts.Count + " exts");
                var pp = api.Paths(term, ct).Result; chk("paths", pp.Key > 0, "total=" + pp.Key);
                var hs = api.History(ct).Result; chk("history", hs.Count > 0, hs.Count + " items, newest=" + (hs.Count > 0 ? hs[0] : ""));
                var st = api.GetSettings(ct).Result; chk("settings get", st.DefaultExclude != null, st.DefaultExclude);
                bool orig = st.FtsDwg;
                var st2 = api.PostSettings(new Dictionary<string, object> { { "show_fts_dwg", !orig } }).Result;
                bool flipped = st2.FtsDwg == !orig;
                var st3 = api.PostSettings(new Dictionary<string, object> { { "show_fts_dwg", orig } }).Result;
                chk("settings toggle+restore", flipped && st3.FtsDwg == orig, "orig=" + orig);
                var fts = api.Query("/fts minutes", 0, 5, cid, 4, ct).Result;
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
