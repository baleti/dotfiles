using System;
using System.Collections.Generic;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Threading;

namespace SearchApp
{
    /// <summary>File owner (NTFS / SMB) read on demand for the rows on screen, through the drive map. The server does not provide owners.</summary>
    public class OwnerCache
    {
        class Entry { public string Owner; public bool Loading; public long Wanted; }
        readonly Config cfg; readonly Dispatcher disp;
        readonly Dictionary<string, Entry> d = new Dictionary<string, Entry>();
        readonly SemaphoreSlim gate = new SemaphoreSlim(4);
        public event Action Loaded;
        public OwnerCache(Config c, Dispatcher disp) { cfg = c; this.disp = disp; }
        public void Clear() { d.Clear(); }

        /// <summary>Owner text, "" when unknown (not a Windows file), null while loading.</summary>
        public string Get(Hit h)
        {
            string p = cfg.MapToWindows(h.Path);
            if (p == null || !h.FileOk) return "";
            Entry e; if (!d.TryGetValue(p, out e)) { if (d.Count > 20000) d.Clear(); d[p] = e = new Entry(); }
            e.Wanted = Environment.TickCount;
            if (e.Owner != null) return e.Owner;
            if (!e.Loading) { e.Loading = true; Load(p, e); }
            return null;
        }

        async void Load(string p, Entry e)
        {
            string owner = null; bool skipped = false;
            await gate.WaitAsync().ConfigureAwait(false);
            try
            {
                if (Environment.TickCount - e.Wanted > 1500) skipped = true;
                else owner = await Task.Run(() => Read(p)).ConfigureAwait(false);
            }
            finally { gate.Release(); }
            disp.BeginInvoke(new Action(() => { e.Loading = false; if (skipped) return; e.Owner = owner ?? ""; if (Loaded != null) Loaded(); }));
        }

        public static string Read(string path)
        {
            try
            {
                var sec = new FileInfo(path).GetAccessControl(AccessControlSections.Owner);
                var sid = sec.GetOwner(typeof(SecurityIdentifier));
                try { string n = sid.Translate(typeof(NTAccount)).Value; int i = n.LastIndexOf('\\'); return i >= 0 ? n.Substring(i + 1) : n; } catch { return sid.Value; }
            }
            catch { return ""; }
        }
    }
}
