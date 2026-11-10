using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace SearchApp
{
    public enum OpenKind { Url, Local, Download, Refuse }

    public class OpenPlan { public OpenKind Kind; public string Target; public override string ToString() { return Kind + (Target != null ? " " + Target : ""); } }

    /// <summary>Decides how a result is opened and performs it. With Dry set nothing is launched, the action is only logged.</summary>
    public class Opener
    {
        public static bool Dry; public static readonly List<string> Log = new List<string>();
        readonly Config cfg; readonly Api api;
        public Opener(Config c, Api a) { cfg = c; api = a; }

        public static string TempRoot { get { return Path.Combine(Path.GetTempPath(), "SearchApp"); } }

        public OpenPlan Plan(Hit h, Func<string, bool> exists = null)
        {
            exists = exists ?? File.Exists;
            if (!h.FileOk)
            {
                if (h.Path.StartsWith("http://") || h.Path.StartsWith("https://")) { int i = h.Path.IndexOf('#'); return new OpenPlan { Kind = OpenKind.Url, Target = i >= 0 ? h.Path.Substring(0, i) : h.Path }; }
                return new OpenPlan { Kind = OpenKind.Refuse };
            }
            string m = cfg.MapToWindows(h.Path);
            if (m != null && exists(m)) return new OpenPlan { Kind = OpenKind.Local, Target = m };
            string mir = MirrorToWindows(h.Path, exists);
            if (mir != null) return new OpenPlan { Kind = OpenKind.Local, Target = mir };
            return new OpenPlan { Kind = OpenKind.Download, Target = CopyPath(h) };
        }

        /// <summary>A backup-mirror path (/mnt/host1-backups/office/ksr/&lt;project-slug&gt;/&lt;m|q|c&gt;/&lt;rest&gt;) is a copy of a file on the
        /// mapped drive: find the original at &lt;drive&gt;:\PROJECTS\&lt;number&gt;*\&lt;rest&gt; so it opens / shows in place instead of being downloaded.</summary>
        public string MirrorToWindows(string serverPath, Func<string, bool> exists)
        {
            var mt = System.Text.RegularExpressions.Regex.Match(serverPath ?? "", @"^/mnt/host1-backups/office/ksr/([^/]+)/([a-z])/(.+)$");
            if (!mt.Success) return null;
            string root = null;
            foreach (var pm in cfg.PathMap) if (pm[0] == "/mnt/ksr/" + mt.Groups[2].Value + "/") root = pm[1];
            if (root == null) return null;
            string slug = mt.Groups[1].Value, num = slug.Contains("-") ? slug.Substring(0, slug.IndexOf('-')) : slug;
            if (num.Length == 0) return null;
            string rest = mt.Groups[3].Value.Replace('/', '\\');
            try
            {
                foreach (var d in Directory.GetDirectories(root + "PROJECTS", num + "*"))
                {
                    string cand = Path.Combine(d, rest);
                    if (exists(cand)) return cand;
                }
            }
            catch { }
            return null;
        }

        public static string SafeName(string path)
        {
            string name = path.Substring(path.LastIndexOf('/') + 1);
            foreach (char c in Path.GetInvalidFileNameChars()) name = name.Replace(c, '_');
            name = name.Trim().TrimEnd('.', ' ');
            return name.Length == 0 ? "file" : (name.Length > 150 ? name.Substring(0, 120) + Path.GetExtension(name) : name);
        }
        public string CopyPath(Hit h)
        {
            using (var sha = SHA1.Create())
            {
                string hex = string.Concat(sha.ComputeHash(Encoding.UTF8.GetBytes(h.Path)).Select(b => b.ToString("x2"))).Substring(0, 10);
                return Path.Combine(TempRoot, hex, SafeName(h.Path));
            }
        }

        /// <summary>Path of a local file for the result: the original through the drive map, else a downloaded copy.</summary>
        public async Task<string> Localize(Hit h, Action<long, long> progress, CancellationToken ct)
        {
            var plan = Plan(h);
            if (plan.Kind == OpenKind.Local) return plan.Target;
            if (plan.Kind != OpenKind.Download) return null;
            string dest = plan.Target;
            try { if (File.Exists(dest) && (!h.HasSize || new FileInfo(dest).Length == (long)h.Size)) return dest; } catch { }
            await api.Download(h.Path, dest, progress, ct);
            return dest;
        }

        public static bool IsDangerous(Config c, string path)
        {
            string ext = Path.GetExtension(path ?? "").TrimStart('.').ToLowerInvariant();
            return ext.Length > 0 && c.DangerousExt.Contains(ext);
        }

        public static void Shell(string target)
        {
            if (Dry) { Log.Add("shell " + target); return; }
            Process.Start(new ProcessStartInfo(target) { UseShellExecute = true });
        }
        public static void OpenWith(string file)
        {
            if (Dry) { Log.Add("openwith " + file); return; }
            Process.Start(new ProcessStartInfo("rundll32.exe", "shell32.dll,OpenAs_RunDLL " + file) { UseShellExecute = false });
        }
        [System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
        static extern int SHParseDisplayName(string name, IntPtr bind, out IntPtr pidl, uint attrs, out uint outAttrs);
        [System.Runtime.InteropServices.DllImport("shell32.dll")]
        static extern int SHOpenFolderAndSelectItems(IntPtr pidlFolder, uint cidl, IntPtr[] apidl, uint flags);
        [System.Runtime.InteropServices.DllImport("shell32.dll")]
        static extern void ILFree(IntPtr pidl);

        /// <summary>Opens the file's folder in Explorer with the file selected. Goes through the shell API (it brings the
        /// window to the front, which a plain "explorer.exe /select" started from a background app often does not),
        /// falling back to the command line.</summary>
        public static void ShowInFolder(string file)
        {
            file = file.Replace('/', '\\');
            if (Dry) { Log.Add("explorer /select " + file); return; }
            try
            {
                IntPtr pidl; uint attrs;
                if (SHParseDisplayName(Path.GetFullPath(file), IntPtr.Zero, out pidl, 0, out attrs) == 0 && pidl != IntPtr.Zero)
                {
                    try { if (SHOpenFolderAndSelectItems(pidl, 0, null, 0) == 0) return; }
                    finally { ILFree(pidl); }
                }
            }
            catch { }
            Process.Start(new ProcessStartInfo("explorer.exe", "/select,\"" + file + "\"") { UseShellExecute = false });
        }

        /// <summary>Delete downloaded copies older than 7 days (only inside our own temp folder).</summary>
        public static void CleanTemp()
        {
            try
            {
                if (!Directory.Exists(TempRoot)) return;
                foreach (var d in Directory.GetDirectories(TempRoot))
                    try { if (DateTime.UtcNow - Directory.GetLastWriteTimeUtc(d) > TimeSpan.FromDays(7)) Directory.Delete(d, true); } catch { }
            }
            catch { }
        }
    }
}
