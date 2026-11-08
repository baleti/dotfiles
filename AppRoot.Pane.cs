using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace SearchApp
{
    /// <summary>The /fts and /chroma preview pane: matching passages of the selected file.</summary>
    public partial class AppRoot
    {
        Border paneBox; ScrollViewer paneSv; StackPanel paneSp;
        readonly Dictionary<string, List<Snippet>> snips = new Dictionary<string, List<Snippet>>();
        DispatcherTimer paneT;

        void BuildPane()
        {
            paneSp = new StackPanel();
            paneSv = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Hidden, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Content = paneSp };
            paneBox = new Border { Width = 340 + 13, Margin = new Thickness(12, 0, 0, 0), Padding = new Thickness(12, 0, 0, 0), BorderThickness = new Thickness(1, 0, 0, 0), Child = paneSv, Visibility = Visibility.Collapsed };
            Grid.SetColumn(paneBox, 1); MainGrid.Children.Add(paneBox);
            paneBox.MouseWheel += (s, e) => { paneSv.ScrollToVerticalOffset(paneSv.VerticalOffset - e.Delta * 100.0 / 120); e.Handled = true; };
        }
        void PaneFont() { PaneUpdate(); }
        void PaneTheme() { if (paneBox == null) return; paneBox.BorderBrush = Th.Border; PaneUpdate(); }
        void ClearSnips() { snips.Clear(); }
        void PaneSoon()
        {
            if (paneT == null) { paneT = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(120) }; paneT.Tick += (s, e) => { paneT.Stop(); PaneUpdate(); }; }
            paneT.Stop(); paneT.Start();
        }
        TextBlock PaneText(string t, double size, Brush b, bool bold = false, double mb = 0)
        {
            return new TextBlock { Text = t, FontFamily = Fonts.Family, FontSize = size, Foreground = b, FontWeight = bold ? FontWeights.Bold : FontWeights.Normal, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, mb) };
        }
        public async void PaneUpdate()
        {
            if (paneBox == null) return;
            bool on = Dsl.IsContent(sent) && total > 0;
            paneBox.Visibility = on ? Visibility.Visible : Visibility.Collapsed; paneBox.BorderBrush = Th.Border;
            Hdr.Margin = new Thickness(12, 0, 12 + (on ? 353 : 0), 0);
            if (!on) return;
            var r = Current; paneSp.Children.Clear();
            if (r == null) return;
            string key = r.Remote + "|" + sent;
            paneSp.Children.Add(PaneText(Dsl.SplitDir(r.Path)[1], 13, Th.Text, true, 2));
            paneSp.Children.Add(PaneText(r.Path, 10, Th.Dim, false, 8));
            List<Snippet> c; bool have = snips.TryGetValue(key, out c);
            if (!have)
            {
                snips[key] = null; string qq = sent;
                paneSp.Children.Add(PaneText("loading…", 10, Th.Dim));
                try { var j = await Api.Snippets(r.Remote, qq, CancellationToken.None); snips[key] = j; if (Current == r) PaneUpdate(); }
                catch { snips.Remove(key); }
                return;
            }
            if (c == null) { paneSp.Children.Add(PaneText("loading…", 10, Th.Dim)); return; }
            if (c.Count == 0) { paneSp.Children.Add(PaneText("no passages", 10, Th.Dim)); return; }
            foreach (var x in c)
            {
                var tb = new TextBlock { FontFamily = Fonts.Family, FontSize = 12, Foreground = Th.Text, TextWrapping = TextWrapping.Wrap, LineHeight = 16.2, LineStackingStrategy = LineStackingStrategy.BlockLineHeight, Margin = new Thickness(0, 0, 0, 8) };
                if (x.Page > 0) tb.Inlines.Add(new Run("p." + x.Page + "  ") { Foreground = Th.Dim, FontSize = 10 });
                string t = x.Text ?? ""; int pos = 0;
                foreach (var rg in x.Ranges.OrderBy(a => a[0]))
                {
                    if (rg[0] < pos || rg[1] > t.Length) continue;
                    tb.Inlines.Add(new Run(t.Substring(pos, rg[0] - pos)));
                    tb.Inlines.Add(new Run(t.Substring(rg[0], rg[1] - rg[0])) { FontWeight = FontWeights.Bold, Foreground = Th.Accent });
                    pos = rg[1];
                }
                tb.Inlines.Add(new Run(t.Substring(pos)));
                paneSp.Children.Add(tb);
            }
        }
    }
}
