using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;

namespace SearchApp
{
    public partial class AppRoot
    {
        public class CompState { public bool Open, Path; public List<Cand> Cands = new List<Cand>(); public int Sel, Start; public int? Multi; public string Q; }
        public class HistState { public bool Open, Picked; public int Sel; public List<string> M = new List<string>(); }
        public CompState CP = new CompState(); public HistState HP = new HistState();
        Border dropBox; ScrollViewer dropSv; StackPanel dropSp;

        Border EnsureDrop()
        {
            if (dropBox != null) return dropBox;
            dropSp = new StackPanel();
            dropSv = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Hidden, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Content = dropSp, Focusable = false };
            dropBox = new Border { CornerRadius = new CornerRadius(6), BorderThickness = new Thickness(1), Child = dropSv, Visibility = Visibility.Collapsed, Focusable = false, ClipToBounds = true };
            dropBox.Effect = new DropShadowEffect { BlurRadius = 24, ShadowDepth = 8, Direction = 270, Opacity = .45, Color = Colors.Black };
            Overlay.Children.Add(dropBox); Overlay.IsHitTestVisible = true;
            return dropBox;
        }
        void DropShow(bool show)
        {
            var b = EnsureDrop();
            if (show)
            {
                b.Background = Th.Bg; b.BorderBrush = Th.Border;
                Canvas.SetLeft(b, 12); Canvas.SetTop(b, 44); b.Width = Math.Max(100, TitleLine.ActualWidth);
                b.MaxHeight = Math.Max(100, ActualHeight * 0.5);
            }
            b.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        }
        FrameworkElement DropRow(string v, string l, bool on, bool bold, Action click)
        {
            var g = new Grid { Background = on ? Th.Sel : Brushes.Transparent };
            var sp = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(10, 3, 10, 3) };
            sp.Children.Add(new TextBlock { Text = v, FontFamily = Fonts.Family, FontSize = 12, FontWeight = FontWeights.Bold, Foreground = Th.Accent, Margin = new Thickness(0, 0, 14, 0), TextTrimming = TextTrimming.CharacterEllipsis });
            if (!string.IsNullOrEmpty(l)) sp.Children.Add(new TextBlock { Text = l, FontFamily = Fonts.Family, FontSize = 11, Foreground = Th.Dim, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis });
            g.Children.Add(sp);
            if (on) g.Children.Add(new Border { Width = 3, Background = Th.Accent, HorizontalAlignment = HorizontalAlignment.Left });
            if (click != null) g.PreviewMouseLeftButtonDown += (s, e) => { e.Handled = true; click(); };
            return g;
        }

        // ---- history popup (Ctrl+R / F4) ----
        public void HpOpen() { if (CP.Open) CpClose(); HP.Open = true; HP.Sel = 0; HP.Picked = false; LoadHist(); HpDraw(); }
        public void HpClose() { HP.Open = false; DropShow(false); }
        public void HpDraw()
        {
            EnsureDrop(); HP.M = Dsl.HistMatches(Q.Text, hist); HP.Sel = Math.Min(HP.Sel, Math.Max(0, HP.M.Count - 1));
            dropSp.Children.Clear(); DropShow(true);
            if (HP.M.Count == 0) { dropSp.Children.Add(DropRow("", "no earlier searches", false, false, null)); return; }
            for (int i = 0; i < HP.M.Count; i++) { int ix = i; dropSp.Children.Add(DropRow(HP.M[i], null, HP.Picked && i == HP.Sel, true, () => { HP.Sel = ix; HP.Picked = true; HpAccept(); })); }
        }
        public void HpAccept()
        {
            string s = HP.Sel < HP.M.Count ? HP.M[HP.Sel] : null;
            if (s != null && HP.Picked) { Q.SetText(s); q = s; Send(s); }
            HpClose();
        }

        // ---- completion popup (Tab / Ctrl+Space) ----
        public void CpClose() { CP.Open = false; CP.Multi = null; DropShow(false); }
        public void CpDraw()
        {
            EnsureDrop(); dropSp.Children.Clear(); DropShow(true);
            int n = Math.Min(400, CP.Cands.Count); FrameworkElement onRow = null;
            for (int i = 0; i < n; i++)
            {
                int ix = i; var r = DropRow(CP.Cands[i].V.TrimEnd(), CP.Cands[i].L, i == CP.Sel, true, () => { CP.Sel = ix; CpAccept(); });
                if (i == CP.Sel) onRow = r; dropSp.Children.Add(r);
            }
            if (onRow != null) { dropSv.UpdateLayout(); onRow.BringIntoView(); }
        }
        void CpApply(int start, string rep)
        {
            string t = Q.Text.Substring(0, Math.Min(start, Q.Text.Length)) + rep;
            Q.SetText(t); q = t; lastInput = DateTime.UtcNow; debounce.Stop(); debounce.Start();
        }
        public void CpAccept() { if (CP.Sel >= CP.Cands.Count) { CpClose(); return; } var c = CP.Cands[CP.Sel]; CpApply(CP.Start, c.V); CpClose(); }
        static List<Cand> PathCands(KeyValuePair<long, List<string>> j)
        {
            return j.Value.Select(p => new Cand((System.Text.RegularExpressions.Regex.IsMatch(p, @"\s") ? "\"" + p + "\"" : p) + " ", j.Key + " folders")).ToList();
        }
        public async void CpStart()
        {
            string qq = Q.Text; int ps; string pfrag;
            if (Dsl.PathFragment(qq, out ps, out pfrag))
            {
                try { var j = await Api.Paths(pfrag, CancellationToken.None); CP.Start = ps; CP.Cands = PathCands(j); CP.Path = true; } catch { return; }
            }
            else { var c = new List<Cand>(); CP.Start = Dsl.Completions(qq, facets, hist, c); CP.Cands = c; CP.Path = false; }
            if (CP.Cands.Count == 0) return;
            if (CP.Cands.Count == 1 && !CP.Path) { CpApply(CP.Start, CP.Cands[0].V); return; }
            if (HP.Open) HpClose();
            CP.Sel = 0; CP.Open = true; CP.Multi = null; CP.Q = qq; CpDraw();
        }
        async void CpNarrow()
        {
            if (!CP.Open) return; string qq = Q.Text;
            if (CP.Path)
            {
                int ps; string pf; if (!Dsl.PathFragment(qq, out ps, out pf)) { CpClose(); return; }
                try
                {
                    var j = await Api.Paths(pf, CancellationToken.None); if (!CP.Open) return;
                    CP.Start = ps; CP.Cands = PathCands(j); if (CP.Cands.Count == 0) { CpClose(); return; }
                    CP.Sel = 0; CpDraw();
                }
                catch { }
                return;
            }
            var c = new List<Cand>(); int st = Dsl.CompletionsMulti(qq, CP.Multi, facets, hist, c);
            if (c.Count == 0) { CpClose(); return; }
            CP.Start = st; CP.Cands = c; CP.Sel = 0; CpDraw();
        }
        void ClosePopups() { if (CP.Open) CpClose(); if (HP.Open) HpClose(); }
    }
}
