using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace SearchApp
{
    /// <summary>--shot: render the UI offscreen to a PNG (no window is ever shown).</summary>
    public static class Shot
    {
        public static void Pump(int ms, Func<bool> until = null)
        {
            var frame = new DispatcherFrame(); var end = DateTime.UtcNow.AddMilliseconds(ms);
            var t = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(15) };
            t.Tick += (s, e) => { if (DateTime.UtcNow >= end || (until != null && until())) { t.Stop(); frame.Continue = false; } };
            t.Start(); Dispatcher.PushFrame(frame);
        }

        static string Arg(List<string> a, string name, string def = null) { int i = a.IndexOf(name); return i >= 0 && i + 1 < a.Count ? a[i + 1] : def; }

        public static int Run(string[] args)
        {
            var a = args.ToList(); string outPng = Arg(a, "--shot"); if (outPng == null) return 2;
            System.Threading.SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(Dispatcher.CurrentDispatcher));
            var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            var cfg = new Config { NoSave = true }; string server = Arg(a, "--server"); if (server != null) cfg.Server = server;
            string thumb = Arg(a, "--thumb"); if (thumb != null) cfg.Thumb = double.Parse(thumb, System.Globalization.CultureInfo.InvariantCulture);
            string[] sz = Arg(a, "--size", "1300x800").Split('x'); double W = double.Parse(sz[0]), H = double.Parse(sz[1]);
            bool light = a.Contains("--light");
            var th = new Theme(light);
            var root = new AppRoot(cfg, th, null);
            root.Width = W; root.Height = H;
            if (a.Contains("--debug-text")) { root.Q.DebugShowText = true; root.Q.ApplyTheme(); }
            string q = Arg(a, "--query", "");
            root.Measure(new Size(W, H)); root.Arrange(new Rect(0, 0, W, H)); root.UpdateLayout();
            var ft = Fonts.EnsureAsync(root.Api);
            Pump(5000, () => ft.IsCompleted); if (Fonts.Loaded) Fonts.Apply();
            var init = root.InitialAsync(q);
            Pump(25000, () => init.IsCompleted && !root.busy);
            root.UpdateLayout();
            Pump(a.Contains("--wait") ? int.Parse(Arg(a, "--wait")) : 1800);
            string sel = Arg(a, "--select"); if (sel != null) { root.Select(int.Parse(sel)); }
            string pre = Arg(a, "--do");
            if (pre != null) root.ShotAction(pre);
            Pump(400);
            root.UpdateLayout();
            double scale = double.Parse(Arg(a, "--scale", "1"), System.Globalization.CultureInfo.InvariantCulture);
            var rtb = new RenderTargetBitmap((int)(W * scale), (int)(H * scale), 96 * scale, 96 * scale, PixelFormats.Pbgra32);
            var dv = new DrawingVisual(); using (var dc = dv.RenderOpen()) dc.DrawRectangle(th.Bg, null, new Rect(0, 0, W, H));
            rtb.Render(dv); rtb.Render(root);
            var enc = new PngBitmapEncoder(); enc.Frames.Add(BitmapFrame.Create(rtb));
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outPng)));
            using (var f = File.Create(outPng)) enc.Save(f);
            string log = Arg(a, "--out"); if (log != null) File.WriteAllText(log, "shot ok " + outPng + "\nstatus: " + root.StatusText + "\nfont loaded: " + Fonts.Loaded + "\nthumb requests: " + root.Thumbs.Requests + "\n");
            return 0;
        }
    }
}
