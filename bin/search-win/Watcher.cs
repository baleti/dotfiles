using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using Microsoft.Win32;

namespace SearchApp
{
    /// <summary>
    /// SearchApp.exe --watch: a headless background watcher (no window) for the drives the file catalog indexes.
    /// Like Everything's change monitoring it listens to the file system's own change notifications (ReadDirectoryChangesW
    /// through FileSystemWatcher, which also works over SMB) and appends one JSON line per change to
    /// %LOCALAPPDATA%\SearchApp\changes\&lt;start time&gt;.jsonl. The Linux side reads that file over ssh and applies the changes to
    /// the catalog, so new, changed, moved and deleted files show up in searches within seconds.
    /// Line format (paths in the WSL form /mnt/m/...): {"op":"put","p":..,"s":size|null,"m":mtime,"k":"file|dir|link"},
    /// {"op":"delprefix","p":..}, {"overflow":1} (events may have been lost), {"hb":1} every 30 s.
    /// Roots come from "watch" in config.json (Windows folders, drive letters only).
    /// </summary>
    public class Watcher
    {
        struct Pend { public DateTime At; public bool Walk; public int Tries; }
        readonly List<string> roots; readonly string dir; readonly object sync = new object();
        readonly Dictionary<string, FileSystemWatcher> watchers = new Dictionary<string, FileSystemWatcher>(StringComparer.OrdinalIgnoreCase);
        readonly ConcurrentDictionary<string, Pend> due = new ConcurrentDictionary<string, Pend>(StringComparer.OrdinalIgnoreCase);
        StreamWriter cur; long curBytes; DateTime lastHb = DateTime.UtcNow; int emitted;
        public static string BaseDir { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SearchApp"); } }
        static string LogPath { get { return Path.Combine(BaseDir, "watcher.log"); } }

        public Watcher(List<string> roots) { this.roots = roots; dir = Path.Combine(BaseDir, "changes"); }

        static void Log(string s) { try { Directory.CreateDirectory(BaseDir); var fi = new FileInfo(LogPath); if (fi.Exists && fi.Length > 500000) File.Delete(LogPath); File.AppendAllText(LogPath, DateTime.Now.ToString("s") + " " + s + "\r\n"); } catch { } }

        // ---- entry points ----
        public static int Run(string[] args)
        {
            var cfg = Config.Load();
            if (args.Contains("--watch-stop")) { try { EventWaitHandle.OpenExisting("Local\\SearchAppWatcherStop").Set(); } catch { } return 0; }
            if (args.Contains("--install-watcher") || args.Contains("--uninstall-watcher"))
            {
                try
                {
                    using (var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true))
                    {
                        if (args.Contains("--install-watcher")) k.SetValue("SearchAppWatcher", "\"" + System.Diagnostics.Process.GetCurrentProcess().MainModule.FileName + "\" --watch");
                        else k.DeleteValue("SearchAppWatcher", false);
                    }
                    return 0;
                }
                catch (Exception e) { Log("install failed " + e.Message); return 1; }
            }
            bool created;
            using (var mutex = new Mutex(true, "Local\\SearchAppWatcher", out created))
            {
                if (!created) return 0;                       // already running
                var stop = new EventWaitHandle(false, EventResetMode.ManualReset, "Local\\SearchAppWatcherStop");
                if (cfg.Watch.Count == 0) { Log("no \"watch\" folders in config.json, nothing to do"); return 2; }
                var w = new Watcher(cfg.Watch);
                w.Start();
                stop.WaitOne();
                w.Stop();
                return 0;
            }
        }

        // ---- output ----
        void OpenFile()
        {
            Directory.CreateDirectory(dir);
            string name = DateTime.UtcNow.ToString("yyyyMMddHHmmss") + "-" + System.Diagnostics.Process.GetCurrentProcess().Id + ".jsonl";
            if (cur != null) cur.Dispose();
            cur = new StreamWriter(new FileStream(Path.Combine(dir, name), FileMode.Create, FileAccess.Write, FileShare.ReadWrite), new UTF8Encoding(false)) { NewLine = "\n", AutoFlush = true };
            curBytes = 0;
            try   // keep the newest 3 files and anything younger than two days
            {
                var old = Directory.GetFiles(dir, "*.jsonl").OrderByDescending(f => f).Skip(3).Where(f => DateTime.UtcNow - File.GetLastWriteTimeUtc(f) > TimeSpan.FromDays(2));
                foreach (var f in old) try { File.Delete(f); } catch { }
            }
            catch { }
        }
        void Emit(string line)
        {
            lock (sync)
            {
                if (cur == null || curBytes > 30000000) OpenFile();
                cur.WriteLine(line); curBytes += line.Length + 1; emitted++;
            }
        }
        static string J(string s)
        {
            var sb = new StringBuilder("\"");
            foreach (char c in s) { if (c == '"' || c == '\\') sb.Append('\\').Append(c); else if (c < ' ') sb.Append("\\u").Append(((int)c).ToString("x4")); else sb.Append(c); }
            return sb.Append('"').ToString();
        }
        public static string ToWsl(string win)
        {
            if (win.Length < 3 || win[1] != ':') return null;
            return "/mnt/" + char.ToLowerInvariant(win[0]) + win.Substring(2).Replace('\\', '/').TrimEnd('/');
        }
        static long Epoch(DateTime utc) { return new DateTimeOffset(DateTime.SpecifyKind(utc, DateTimeKind.Utc)).ToUnixTimeSeconds(); }
        void Put(string winPath, long? size, DateTime mtimeUtc, string kind)
        {
            string p = ToWsl(winPath); if (p == null) return;
            Emit("{\"op\":\"put\",\"p\":" + J(p) + ",\"s\":" + (size.HasValue ? size.Value.ToString() : "null") + ",\"m\":" + Epoch(mtimeUtc) + ",\"k\":\"" + kind + "\"}");
        }
        void Del(string winPath) { string p = ToWsl(winPath); if (p != null) Emit("{\"op\":\"delprefix\",\"p\":" + J(p) + "}"); }

        // ---- watching ----
        Timer tick;
        public void Start()
        {
            Log("watcher started, roots: " + roots.Count);
            lock (sync) OpenFile();
            Emit("{\"hb\":1}");
            Ensure(false);
            tick = new Timer(_ => { try { Tick(); } catch (Exception e) { Log("tick failed " + e); } }, null, 500, 500);
        }
        public void Stop() { if (tick != null) tick.Dispose(); foreach (var w in watchers.Values) w.Dispose(); lock (sync) { if (cur != null) cur.Dispose(); } Log("watcher stopped"); }

        DateTime lastEnsure = DateTime.UtcNow;
        void Ensure(bool gap)
        {
            foreach (var r in roots)
            {
                if (watchers.ContainsKey(r)) continue;
                try
                {
                    if (!Directory.Exists(r)) continue;
                    var w = new FileSystemWatcher(r) { IncludeSubdirectories = true, InternalBufferSize = 65536, NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.LastWrite | NotifyFilters.Size };
                    w.Created += (s, e) => Queue(e.FullPath, true);
                    w.Changed += (s, e) => Queue(e.FullPath, false);
                    w.Deleted += (s, e) => { Pend o; due.TryRemove(e.FullPath, out o); Del(e.FullPath); };
                    w.Renamed += (s, e) => { Del(e.OldFullPath); Queue(e.FullPath, true); };
                    string root = r;
                    w.Error += (s, e) =>
                    {
                        Log("watcher error on " + root + ": " + e.GetException().Message);
                        Emit("{\"overflow\":1}");
                        lock (watchers) { FileSystemWatcher x; if (watchers.TryGetValue(root, out x)) { x.Dispose(); watchers.Remove(root); } }   // recreated by Ensure()
                    };
                    w.EnableRaisingEvents = true;
                    watchers[r] = w;
                    if (gap) Emit("{\"overflow\":1}");           // the root was away: changes may have been missed
                    Log("watching " + r);
                }
                catch (Exception e) { Log("cannot watch " + r + ": " + e.Message); }
            }
        }

        void Queue(string path, bool walk)
        {
            string n = Path.GetFileName(path);
            if (path.IndexOf("$RECYCLE.BIN", StringComparison.OrdinalIgnoreCase) >= 0 || path.IndexOf("System Volume Information", StringComparison.OrdinalIgnoreCase) >= 0 || n.StartsWith("~$")) return;
            due.AddOrUpdate(path, new Pend { At = DateTime.UtcNow, Walk = walk }, (k, o) => new Pend { At = o.At, Walk = o.Walk || walk, Tries = o.Tries });
        }

        void Tick()
        {
            var now = DateTime.UtcNow;
            if ((now - lastHb).TotalSeconds >= 30) { lastHb = now; Emit("{\"hb\":1}"); }
            if ((now - lastEnsure).TotalSeconds >= 30) { lastEnsure = now; lock (watchers) Ensure(true); }
            foreach (var kv in due.ToArray())
            {
                if ((now - kv.Value.At).TotalMilliseconds < 1200) continue;       // wait until the file stops changing
                Pend p; if (!due.TryRemove(kv.Key, out p)) continue;
                Resolve(kv.Key, p);
            }
        }

        void Resolve(string path, Pend p)
        {
            try
            {
                FileAttributes a = File.GetAttributes(path);
                if ((a & FileAttributes.Directory) != 0)
                {
                    var di = new DirectoryInfo(path); Put(path, null, di.LastWriteTimeUtc, "dir");
                    if (p.Walk) Walk(path);
                }
                else
                {
                    var fi = new FileInfo(path);
                    if ((a & FileAttributes.ReparsePoint) != 0) Put(path, 0, fi.LastWriteTimeUtc, "link"); else Put(path, fi.Length, fi.LastWriteTimeUtc, "file");
                }
            }
            catch (FileNotFoundException) { Del(path); }
            catch (DirectoryNotFoundException) { Del(path); }
            catch (Exception)   // locked or not readable yet: try again a few times
            {
                if (p.Tries < 3) due[path] = new Pend { At = DateTime.UtcNow.AddSeconds(5), Walk = p.Walk, Tries = p.Tries + 1 };
            }
        }

        /// <summary>A folder that appeared (moved or copied in): list everything below it, since no event is sent for the contents of a move.</summary>
        void Walk(string root)
        {
            var stack = new Stack<string>(); stack.Push(root); int n = 0;
            while (stack.Count > 0 && n < 200000)
            {
                string d = stack.Pop(); string[] es;
                try { es = Directory.GetFileSystemEntries(d); } catch { continue; }
                foreach (var e in es)
                {
                    try
                    {
                        var a = File.GetAttributes(e);
                        if ((a & FileAttributes.Directory) != 0) { Put(e, null, Directory.GetLastWriteTimeUtc(e), "dir"); if ((a & FileAttributes.ReparsePoint) == 0) stack.Push(e); }
                        else if ((a & FileAttributes.ReparsePoint) != 0) Put(e, 0, File.GetLastWriteTimeUtc(e), "link");
                        else { var fi = new FileInfo(e); Put(e, fi.Length, fi.LastWriteTimeUtc, "file"); }
                        n++;
                    }
                    catch { }
                }
            }
        }
    }
}
