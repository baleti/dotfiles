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

        static void Log(Exception e)
        {
            try
            {
                string d = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SearchApp"); Directory.CreateDirectory(d);
                File.AppendAllText(Path.Combine(d, "error.log"), DateTime.Now.ToString("s") + " " + e + "\r\n");
            }
            catch { }
        }

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
            System.Threading.Tasks.Task.Run(() => { Opener.CleanTemp(); Updater.CleanOld(); });
            var cfg = Config.Load();
            string query = args.Length > 0 ? string.Join(" ", args) : cfg.LastQuery;
            bool restored = args.Length == 0 && !string.IsNullOrEmpty(query);
            var th = new Theme(Theme.WindowsLight());
            var app = new Application();
            app.DispatcherUnhandledException += (s, e) => { Log(e.Exception); e.Handled = true; };
            AppDomain.CurrentDomain.UnhandledException += (s, e) => Log(e.ExceptionObject as Exception);
            return app.Run(new MainWindow(cfg, th, query, restored));
        }
    }
}
