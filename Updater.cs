using System;
using System.Diagnostics;
using System.IO;

namespace SearchApp
{
    /// <summary>Notices that SearchApp.exe on disk was replaced while this copy keeps running (deploy renames the running exe aside).</summary>
    public static class Updater
    {
        static readonly string exe = Process.GetCurrentProcess().MainModule.FileName;
        static readonly long startStamp = Stamp();
        public static bool Pending;
        static long Stamp() { try { var f = new FileInfo(Path.Combine(Path.GetDirectoryName(exe), "SearchApp.exe")); return f.Exists ? f.LastWriteTimeUtc.Ticks ^ f.Length : 0; } catch { return 0; } }
        /// <summary>True when the pending state changed.</summary>
        public static bool Check()
        {
            if (Pending) return false;
            // our own file was renamed away (name differs from SearchApp.exe) or the file at the normal path changed
            bool renamed = !string.Equals(Path.GetFileName(exe), "SearchApp.exe", StringComparison.OrdinalIgnoreCase) && File.Exists(Path.Combine(Path.GetDirectoryName(exe), "SearchApp.exe"));
            if (renamed || (Stamp() != 0 && Stamp() != startStamp)) { Pending = true; return true; }
            return false;
        }
        public static void CleanOld()
        {
            try { foreach (var f in Directory.GetFiles(Path.GetDirectoryName(exe), "SearchApp.old-*.exe")) { try { File.Delete(f); } catch { } } } catch { }
        }
    }
}
