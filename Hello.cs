using System; using System.Windows; using System.Windows.Controls;
namespace SearchApp { static class P { [STAThread] static int Main(string[] a) {
  if (a.Length > 0 && a[0] == "--selftest") { Console.WriteLine("selftest ok, clr " + Environment.Version); return 0; }
  var app = new Application(); var w = new Window { Title = "Search files", Width = 600, Height = 300, Content = new TextBlock { Text = "hello from WPF code-only" } }; return app.Run(w); } } }
