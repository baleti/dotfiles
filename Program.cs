using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;

namespace SearchApp
{
    static class Program
    {
        [DllImport("shell32.dll", SetLastError = true)]
        static extern void SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string appId);

        [STAThread]
        static int Main(string[] args)
        {
            if (args.Length > 0 && args[0] == "--selftest")
            {
                string outPath = null; var rest = args.Skip(1).ToList();
                int i = rest.IndexOf("--out"); if (i >= 0 && i + 1 < rest.Count) { outPath = rest[i + 1]; rest.RemoveRange(i, 2); }
                var sw = new StringWriter(); int rc;
                try { rc = Selftest.Run(rest.ToArray(), sw); } catch (Exception e) { sw.WriteLine("EXCEPTION " + e); rc = 2; }
                if (outPath != null) File.WriteAllText(outPath, sw.ToString()); else Console.Write(sw.ToString());
                return rc;
            }
            if (args.Contains("--shot"))
            {
                try { return Shot.Run(args); }
                catch (Exception e) { int i = Array.IndexOf(args, "--out"); if (i >= 0 && i + 1 < args.Length) File.WriteAllText(args[i + 1], "EXCEPTION " + e); return 3; }
            }
            try { SetCurrentProcessExplicitAppUserModelID("Local.SearchApp"); } catch { }
            var cfg = Config.Load();
            string query = args.Length > 0 ? string.Join(" ", args) : "";
            var th = new Theme(Theme.WindowsLight());
            var app = new Application();
            return app.Run(new MainWindow(cfg, th, query));
        }
    }
}
