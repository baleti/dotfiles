using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace SearchApp
{
    public class Hit
    {
        public string Remote, Path, Mtime, Thumb;
        public double Size = -1, Score = double.NaN; public int Pages = -1;
        public bool Ready, Pending, FileOk;
        public bool HasSize { get { return Size >= 0; } }
        public bool HasScore { get { return !double.IsNaN(Score); } }
        public string Key { get { return Remote + "|" + Size + "|" + Mtime + "|" + Thumb + "|" + Score + "|" + Pages; } }
    }

    public class Stats { public double Size; public string DMin, DMax; public bool Approx; public List<KeyValuePair<string, long>> Kinds = new List<KeyValuePair<string, long>>(); }

    public class QueryResult
    {
        public long Count; public List<Hit> Results = new List<Hit>(); public List<string> Errors = new List<string>(); public Stats Stats; public bool Stale;
    }

    public class VerInfo { public long Ver = -1; public Palette Theme; }

    public class Snippet { public int Page; public string Text; public List<int[]> Ranges = new List<int[]>(); }

    public class ServerSettings
    {
        public string DefaultExclude = ""; public bool BackupRestic, BackupBtrfs, FtsRvt = true, FtsDwg = true;
    }

    public class Api
    {
        public string Base;
        readonly HttpClient http;
        readonly HttpClient bigHttp;
        public static readonly JavaScriptSerializer Js = new JavaScriptSerializer { MaxJsonLength = int.MaxValue, RecursionLimit = 64 };

        public Api(string baseUrl)
        {
            Base = baseUrl.TrimEnd('/');
            ServicePointManager.Expect100Continue = false;
            ServicePointManager.DefaultConnectionLimit = 16;
            http = Make(30); bigHttp = Make(0);
        }
        HttpClient Make(int timeoutSec)
        {
            var h = new HttpClient(new HttpClientHandler { AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate });
            h.Timeout = timeoutSec > 0 ? TimeSpan.FromSeconds(timeoutSec) : Timeout.InfiniteTimeSpan;
            h.DefaultRequestHeaders.Add("X-Requested-With", "search-web");
            return h;
        }

        public static string Enc(string s) { return Uri.EscapeDataString(s ?? ""); }
        public string Url(string path, params string[] kv)
        {
            var sb = new StringBuilder(Base).Append(path);
            for (int i = 0; i + 1 < kv.Length; i += 2) sb.Append(i == 0 ? '?' : '&').Append(kv[i]).Append('=').Append(Enc(kv[i + 1]));
            return sb.ToString();
        }
        public string FileUrl(string serverPath, bool dl = false) { return Url("/api/file", "path", serverPath) + (dl ? "&dl=1" : ""); }
        public string AbsUrl(string rel) { return rel.StartsWith("http") ? rel : Base + rel; }

        async Task<HttpResponseMessage> Send(Func<HttpRequestMessage> make, CancellationToken ct, HttpClient c = null, HttpCompletionOption opt = HttpCompletionOption.ResponseContentRead)
        {
            c = c ?? http;
            for (int attempt = 0; ; attempt++)
            {
                var r = await c.SendAsync(make(), opt, ct).ConfigureAwait(false);
                if ((int)r.StatusCode == 429 && attempt < 3) { r.Dispose(); await Task.Delay(300 * (attempt + 1), ct).ConfigureAwait(false); continue; }
                return r;
            }
        }
        async Task<object> GetJson(string url, CancellationToken ct)
        {
            using (var r = await Send(() => new HttpRequestMessage(HttpMethod.Get, url), ct).ConfigureAwait(false))
            {
                if (!r.IsSuccessStatusCode) throw new HttpRequestException(((int)r.StatusCode).ToString());
                string s = await r.Content.ReadAsStringAsync().ConfigureAwait(false);
                return Js.DeserializeObject(s);
            }
        }
        async Task<object> PostJson(string url, object body, CancellationToken ct)
        {
            string payload = Js.Serialize(body);
            using (var r = await Send(() => new HttpRequestMessage(HttpMethod.Post, url) { Content = new StringContent(payload, Encoding.UTF8, "application/json") }, ct).ConfigureAwait(false))
            {
                if (!r.IsSuccessStatusCode) throw new HttpRequestException(((int)r.StatusCode).ToString());
                return Js.DeserializeObject(await r.Content.ReadAsStringAsync().ConfigureAwait(false));
            }
        }

        // ---- tolerant JSON readers ----
        static Dictionary<string, object> D(object o) { return o as Dictionary<string, object>; }
        static object G(Dictionary<string, object> d, string k) { object v; return d != null && d.TryGetValue(k, out v) ? v : null; }
        static string Str(object o) { return o as string; }
        static double Num(object o, double def) { if (o == null || o is string || o is bool) return def; try { return Convert.ToDouble(o, System.Globalization.CultureInfo.InvariantCulture); } catch { return def; } }
        static bool Bool(object o) { return o is bool && (bool)o; }
        static List<object> Arr(object o) { var a = o as object[]; if (a != null) return new List<object>(a); var l = o as System.Collections.ArrayList; if (l != null) return l.Cast<object>().ToList(); return new List<object>(); }

        public static Hit ParseHit(object o)
        {
            var d = D(o); var h = new Hit();
            h.Remote = Str(G(d, "remote")) ?? ""; h.Path = Str(G(d, "path")) ?? h.Remote; h.Mtime = Str(G(d, "mtime")); h.Thumb = Str(G(d, "thumb")) ?? "";
            h.Size = Num(G(d, "size"), -1); h.Score = Num(G(d, "score"), double.NaN); h.Pages = (int)Num(G(d, "pages"), -1);
            h.Ready = Bool(G(d, "ready")); h.Pending = Bool(G(d, "pending")); h.FileOk = Bool(G(d, "fileok"));
            return h;
        }
        public static QueryResult ParseQuery(object o)
        {
            var d = D(o); var q = new QueryResult();
            q.Count = (long)Num(G(d, "count"), 0); q.Stale = Bool(G(d, "stale"));
            foreach (var x in Arr(G(d, "results"))) q.Results.Add(ParseHit(x));
            foreach (var x in Arr(G(d, "errors"))) q.Errors.Add(Convert.ToString(x));
            var s = D(G(d, "stats"));
            if (s != null)
            {
                q.Stats = new Stats { Size = Num(G(s, "size"), 0), DMin = Str(G(s, "dmin")), DMax = Str(G(s, "dmax")), Approx = Bool(G(s, "approx")) };
                foreach (var k in Arr(G(s, "kinds"))) { var a = Arr(k); if (a.Count >= 2) q.Stats.Kinds.Add(new KeyValuePair<string, long>(Convert.ToString(a[0]), (long)Num(a[1], 0))); }
            }
            return q;
        }

        public async Task<QueryResult> Query(string q, int offset, int top, string cid, int seq, CancellationToken ct)
        {
            var j = await GetJson(Url("/api/query", "q", q, "offset", offset.ToString(), "top", top.ToString(), "cid", cid, "seq", seq.ToString()), ct).ConfigureAwait(false);
            return ParseQuery(j);
        }
        public async Task<VerInfo> Ver(CancellationToken ct)
        {
            var d = D(await GetJson(Url("/api/ver"), ct).ConfigureAwait(false)); var v = new VerInfo();
            v.Ver = (long)Num(G(d, "ver"), -1);
            var t = D(G(d, "theme"));
            if (t != null && Str(G(t, "bg")) != null)
                v.Theme = new Palette { Bg = Str(G(t, "bg")), Text = Str(G(t, "text")), Dim = Str(G(t, "dim")), Border = Str(G(t, "border")), Accent = Str(G(t, "accent")), Error = Str(G(t, "error")) };
            return v;
        }
        public async Task<Facets> GetFacets(CancellationToken ct)
        {
            var d = D(await GetJson(Url("/api/facets"), ct).ConfigureAwait(false)); var f = new Facets();
            foreach (var x in Arr(G(d, "dates"))) f.Dates.Add(Convert.ToString(x));
            foreach (var x in Arr(G(d, "mimes"))) f.Mimes.Add(Convert.ToString(x));
            foreach (var x in Arr(G(d, "exts"))) f.Exts.Add(Convert.ToString(x));
            foreach (var x in Arr(G(d, "attrs")))
            {
                var a = Arr(x); if (a.Count < 2) continue;
                var at = new Attr { Name = Convert.ToString(a[0]), Count = (long)Num(a[1], 0) };
                if (a.Count > 2) foreach (var v in Arr(a[2])) at.Values.Add(Convert.ToString(v));
                f.Attrs.Add(at);
            }
            foreach (var x in Arr(G(d, "tags"))) { var a = Arr(x); if (a.Count >= 2) f.ExtraTags.Add(new[] { Convert.ToString(a[0]), Convert.ToString(a[1]) }); }
            return f;
        }
        public async Task<KeyValuePair<long, List<string>>> Paths(string frag, CancellationToken ct)
        {
            var d = D(await GetJson(Url("/api/paths", "q", frag, "offset", "0", "top", "200"), ct).ConfigureAwait(false));
            return new KeyValuePair<long, List<string>>((long)Num(G(d, "total"), 0), Arr(G(d, "items")).Select(Convert.ToString).ToList());
        }
        public async Task<List<Snippet>> Snippets(string remote, string q, CancellationToken ct)
        {
            var d = D(await GetJson(Url("/api/snippets", "remote", remote, "q", q), ct).ConfigureAwait(false)); var l = new List<Snippet>();
            foreach (var x in Arr(G(d, "snippets")))
            {
                var s = D(x); var sn = new Snippet { Page = (int)Num(G(s, "page"), 0), Text = Str(G(s, "text")) ?? "" };
                foreach (var r in Arr(G(s, "ranges"))) { var a = Arr(r); if (a.Count >= 2) sn.Ranges.Add(new[] { (int)Num(a[0], 0), (int)Num(a[1], 0) }); }
                l.Add(sn);
            }
            return l;
        }
        /// <summary>History, newest first.</summary>
        public async Task<List<string>> History(CancellationToken ct)
        {
            var d = D(await GetJson(Url("/api/history"), ct).ConfigureAwait(false));
            var l = Arr(G(d, "items")).Select(Convert.ToString).ToList(); l.Reverse(); return l;
        }
        public Task PostHistory(string q) { return PostJson(Url("/api/history"), new Dictionary<string, object> { { "q", q } }, CancellationToken.None); }

        static ServerSettings ParseSettings(object o)
        {
            var s = D(G(D(o), "settings")); var r = new ServerSettings();
            if (s == null) return r;
            r.DefaultExclude = Str(G(s, "default_exclude")) ?? "";
            r.BackupRestic = Bool(G(s, "show_backup_restic")); r.BackupBtrfs = Bool(G(s, "show_backup_btrfs"));
            object v; r.FtsRvt = !s.TryGetValue("show_fts_rvt", out v) || Bool(v); r.FtsDwg = !s.TryGetValue("show_fts_dwg", out v) || Bool(v);
            return r;
        }
        public async Task<ServerSettings> GetSettings(CancellationToken ct) { return ParseSettings(await GetJson(Url("/api/settings"), ct).ConfigureAwait(false)); }
        public async Task<ServerSettings> PostSettings(Dictionary<string, object> patch) { return ParseSettings(await PostJson(Url("/api/settings"), patch, CancellationToken.None).ConfigureAwait(false)); }

        public async Task<byte[]> GetBytes(string relOrAbs, CancellationToken ct)
        {
            using (var r = await Send(() => new HttpRequestMessage(HttpMethod.Get, AbsUrl(relOrAbs)), ct).ConfigureAwait(false))
            {
                if (!r.IsSuccessStatusCode) throw new HttpRequestException(((int)r.StatusCode).ToString());
                return await r.Content.ReadAsByteArrayAsync().ConfigureAwait(false);
            }
        }

        /// <summary>Stream a file to disk. progress(bytesDone, total or -1).</summary>
        public async Task Download(string serverPath, string dest, Action<long, long> progress, CancellationToken ct)
        {
            string tmp = dest + ".part";
            using (var r = await Send(() => new HttpRequestMessage(HttpMethod.Get, FileUrl(serverPath, true)), ct, bigHttp, HttpCompletionOption.ResponseHeadersRead).ConfigureAwait(false))
            {
                if (!r.IsSuccessStatusCode) throw new HttpRequestException(((int)r.StatusCode).ToString());
                long total = r.Content.Headers.ContentLength ?? -1, done = 0;
                Directory.CreateDirectory(Path.GetDirectoryName(dest));
                using (var s = await r.Content.ReadAsStreamAsync().ConfigureAwait(false))
                using (var f = new FileStream(tmp, FileMode.Create, FileAccess.Write, FileShare.None, 81920, true))
                {
                    var buf = new byte[81920]; int n;
                    while ((n = await s.ReadAsync(buf, 0, buf.Length, ct).ConfigureAwait(false)) > 0)
                    { await f.WriteAsync(buf, 0, n, ct).ConfigureAwait(false); done += n; if (progress != null) progress(done, total); }
                }
            }
            if (File.Exists(dest)) File.Delete(dest);
            File.Move(tmp, dest);
        }
    }
}
