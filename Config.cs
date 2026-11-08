using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Web.Script.Serialization;

namespace SearchApp
{
    public class WinState { public double x = double.NaN, y = double.NaN, w = 1300, h = 800; public bool max; }

    public class Config
    {
        public string Server = "http://127.0.0.1:8795";
        public List<string[]> PathMap = new List<string[]>();
        public double Thumb = 16;
        public Dictionary<string, double> Cw = new Dictionary<string, double>();
        public WinState Window = new WinState();
        public string LastQuery = ""; public bool ShowOwner = true;
        public List<string> DangerousExt = new List<string>("exe bat cmd com ps1 psm1 vbs vbe js jse wsf wsh msi msp scr hta jar lnk reg cpl dll".Split(' '));

        public static string Dir
        {
            get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "SearchApp"); }
        }
        public static string FilePath { get { return Path.Combine(Dir, "config.json"); } }

        public static Config Load(string path = null)
        {
            var c = new Config();
            try
            {
                path = path ?? FilePath;
                if (!File.Exists(path)) return c;
                var js = new JavaScriptSerializer();
                var d = js.DeserializeObject(File.ReadAllText(path)) as Dictionary<string, object>;
                if (d == null) return c;
                object v;
                if (d.TryGetValue("server", out v) && v is string && ((string)v).Length > 0) c.Server = ((string)v).TrimEnd('/');
                if (d.TryGetValue("pathMap", out v) && v is object[])
                    foreach (var e in (object[])v) { var a = e as object[]; if (a != null && a.Length == 2) c.PathMap.Add(new[] { Convert.ToString(a[0]), Convert.ToString(a[1]) }); }
                if (d.TryGetValue("thumb", out v)) c.Thumb = Math.Min(800, Math.Max(16, Convert.ToDouble(v)));
                if (d.TryGetValue("cw", out v) && v is Dictionary<string, object>)
                    foreach (var kv in (Dictionary<string, object>)v) c.Cw[kv.Key] = Convert.ToDouble(kv.Value);
                if (c.Cw.ContainsKey("name") && c.Cw.ContainsKey("path") && c.Cw["name"] > 0 && c.Cw["path"] > 0) c.Cw.Remove("path");
                if (d.TryGetValue("window", out v) && v is Dictionary<string, object>)
                {
                    var w = (Dictionary<string, object>)v; object o;
                    if (w.TryGetValue("x", out o)) c.Window.x = Convert.ToDouble(o);
                    if (w.TryGetValue("y", out o)) c.Window.y = Convert.ToDouble(o);
                    if (w.TryGetValue("w", out o)) c.Window.w = Convert.ToDouble(o);
                    if (w.TryGetValue("h", out o)) c.Window.h = Convert.ToDouble(o);
                    if (w.TryGetValue("max", out o)) c.Window.max = Convert.ToBoolean(o);
                }
                if (d.TryGetValue("showOwner", out v) && v is bool) c.ShowOwner = (bool)v;
                if (d.TryGetValue("lastQuery", out v) && v is string) c.LastQuery = (string)v;
                if (d.TryGetValue("dangerousExt", out v) && v is object[]) c.DangerousExt = ((object[])v).Select(x => Convert.ToString(x).ToLowerInvariant().TrimStart('.')).ToList();
            }
            catch { }
            return c;
        }

        public bool NoSave;
        public void Save(string path = null)
        {
            if (NoSave) return;
            try
            {
                path = path ?? FilePath;
                Directory.CreateDirectory(Path.GetDirectoryName(path));
                var d = new Dictionary<string, object>();
                d["server"] = Server;
                d["pathMap"] = PathMap.Select(p => (object)new object[] { p[0], p[1] }).ToArray();
                d["thumb"] = Math.Round(Thumb);
                d["cw"] = Cw.ToDictionary(k => k.Key, k => (object)k.Value);
                var w = new Dictionary<string, object>();
                if (!double.IsNaN(Window.x)) { w["x"] = Window.x; w["y"] = Window.y; }
                w["w"] = Window.w; w["h"] = Window.h; w["max"] = Window.max;
                d["window"] = w;
                d["lastQuery"] = LastQuery; d["showOwner"] = ShowOwner;
                d["dangerousExt"] = DangerousExt.Select(x => (object)x).ToArray();
                string tmp = path + ".tmp";
                File.WriteAllText(tmp, new JavaScriptSerializer().Serialize(d));
                if (File.Exists(path)) File.Delete(path);
                File.Move(tmp, path);
            }
            catch { }
        }

        /// <summary>Windows path for a server path, or null if it is not under a mapped prefix.</summary>
        public string MapToWindows(string serverPath)
        {
            if (serverPath == null) return null;
            foreach (var m in PathMap)
                if (serverPath.StartsWith(m[0], StringComparison.Ordinal))
                    return m[1] + serverPath.Substring(m[0].Length).Replace('/', '\\');
            return null;
        }
    }
}
