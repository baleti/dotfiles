using System;
using System.IO;
using System.Linq;
using System.Windows;

namespace SearchApp
{
    static class Program
    {
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
            var app = new Application();
            return app.Run(new Window { Title = "Search files" });
        }
    }
}
