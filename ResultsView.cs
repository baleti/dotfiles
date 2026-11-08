using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;

namespace SearchApp
{
    public static class Const { public const int Page = 200; public const double Grid = 220, Gap = 10, CellTxt = 72, MinW = 40, Bar = 10; }

    /// <summary>Column widths shared by the header and the rows (the page's --cols variable).</summary>
    public class ColModel
    {
        public double Thumb = 16; public bool HasScore;
        public Dictionary<string, double> CW = new Dictionary<string, double>();
        public double[] X = new double[7], W = new double[7];
        public static readonly string[] Keys = { "name", "path", "size", "pages", "date" };
        static readonly Dictionary<string, double> Def = new Dictionary<string, double> { { "size", 76 }, { "pages", 44 }, { "date", 116 } };
        public bool Fixed(string k) { double v; return CW.TryGetValue(k, out v) && v > 0; }
        public void Layout(double width)
        {
            W[0] = 6 + Thumb + 12;
            W[3] = Fixed("size") ? CW["size"] : Def["size"]; W[4] = Fixed("pages") ? CW["pages"] : Def["pages"]; W[5] = Fixed("date") ? CW["date"] : Def["date"];
            W[6] = HasScore ? 44 : 0;
            bool nf = Fixed("name"), pf = Fixed("path");
            double free = width - W[0] - W[3] - W[4] - W[5] - W[6];
            if (nf) { W[1] = CW["name"]; free -= W[1]; }
            if (pf) { W[2] = CW["path"]; free -= W[2]; }
            if (!nf && !pf)
            {
                double n = free * 30 / 70, p = free * 40 / 70;
                if (n < 60) { n = 60; p = Math.Max(60, free - 60); } else if (p < 60) { p = 60; n = Math.Max(60, free - 60); }
                W[1] = n; W[2] = p;
            }
            else if (!nf) W[1] = Math.Max(60, free);
            else if (!pf) W[2] = Math.Max(60, free);
            double x = 0; for (int i = 0; i < 7; i++) { X[i] = x; x += W[i]; }
        }
    }

    public struct Geom { public bool Grid, Bar; public int Cols; public double T, Stride, W, H, Content, CellH; }

    public class ResultsView : FrameworkElement
    {
        public Func<int, Hit> GetHit; public long Total; public int Sel = -1; public List<string> Terms = new List<string>();
        public bool ShowNone; public ColModel Cols; public Theme Th; public ThumbCache Thumbs; public double Off;
        public event Action<int, int> NeedRange;     // first, last visible (+overscan)
        public event Action<int, int> RowClick;      // index, click count
        public event Action<int, Point> RowRightClick;
        public event Action<int> DragOut;
        public event Action<double> ZoomWheel;
        public event Action ViewChanged;
        readonly TextCache tc = new TextCache();
        bool barHot, barDrag; double dragDy; int downIdx = -1; Point downPt; bool dragFired;

        public ResultsView() { Focusable = true; FocusVisualStyle = null; ClipToBounds = true; SnapsToDevicePixels = true; }

        public void ThemeChanged() { tc.Clear(); InvalidateVisual(); }
        public bool IsGrid { get { return Cols.Thumb >= Const.Grid; } }

        public Geom Compute()
        {
            var g = ComputeFor(ActualWidth, ActualHeight, false);
            if (g.Content > g.H + 0.5) g = ComputeFor(ActualWidth, ActualHeight, true);
            return g;
        }
        Geom ComputeFor(double wFull, double h, bool bar)
        {
            var g = new Geom { Bar = bar, H = h, W = Math.Max(0, wFull - (bar ? Const.Bar : 0)) };
            if (IsGrid)
            {
                g.Grid = true;
                g.Cols = Math.Max(1, (int)Math.Floor((g.W + Const.Gap) / (Cols.Thumb + Const.Gap)));
                g.T = Math.Max(16, Math.Floor((g.W - Const.Gap * (g.Cols - 1)) / g.Cols));
                g.Stride = g.T + Const.CellTxt + Const.Gap; g.CellH = g.T + Const.CellTxt;
                long rows = (Total + g.Cols - 1) / g.Cols; g.Content = Math.Max(0, rows * g.Stride - Const.Gap);
            }
            else { g.Cols = 1; g.Stride = Math.Max(Cols.Thumb + 4, 20); g.CellH = g.Stride; g.Content = Total * g.Stride; }
            return g;
        }
        public double MaxOff(Geom g) { return Math.Max(0, g.Content - g.H); }
        public void SetOff(double v) { var g = Compute(); v = Math.Max(0, Math.Min(v, MaxOff(g))); if (Math.Abs(v - Off) < 0.01) return; Off = v; InvalidateVisual(); if (ViewChanged != null) ViewChanged(); }
        public void EnsureVisible(int i)
        {
            var g = Compute(); int row = i / g.Cols; double top = row * g.Stride, bot = top + (g.Grid ? g.CellH : g.Stride);
            if (top < Off) SetOff(top); else if (bot > Off + g.H) SetOff(bot - g.H);
        }
        public int IndexAt(Point p, Geom g)
        {
            if (p.X >= g.W || p.Y < 0) return -1;
            double y = p.Y + Off;
            int row = (int)Math.Floor(y / g.Stride);
            if (!g.Grid) return row >= 0 && row < Total ? row : -1;
            double yin = y - row * g.Stride; if (yin > g.CellH) return -1;
            int col = (int)Math.Floor(p.X / (g.T + Const.Gap)); if (col >= g.Cols) return -1;
            if (p.X - col * (g.T + Const.Gap) > g.T) return -1;
            long i = (long)row * g.Cols + col; return i < Total ? (int)i : -1;
        }

        protected override void OnRenderSizeChanged(SizeChangedInfo i) { base.OnRenderSizeChanged(i); SetOffClamp(); if (ViewChanged != null) ViewChanged(); }
        void SetOffClamp() { var g = Compute(); Off = Math.Max(0, Math.Min(Off, MaxOff(g))); }
        protected override void OnDpiChanged(DpiScale o, DpiScale n) { Txt.Ppd = n.PixelsPerDip; tc.Clear(); InvalidateVisual(); }

        string Nm(string text, double w, bool sel, FormattedText ft) { return null; }

        protected override void OnRender(DrawingContext dc)
        {
            try { Txt.Ppd = VisualTreeHelper.GetDpi(this).PixelsPerDip; } catch { }
            var g = Compute(); SetOffClamp();
            double W = ActualWidth;
            dc.DrawRectangle(Brushes.Transparent, null, new Rect(0, 0, W, ActualHeight));
            if (Total <= 0)
            {
                if (ShowNone) dc.DrawText(tc.Get("none", () => Txt.Make("no matches", 13, Th.Dim)), new Point(6, 20));
                return;
            }
            int firstRow = Math.Max(0, (int)Math.Floor(Off / g.Stride) - 2), lastRow = (int)Math.Ceiling((Off + g.H) / g.Stride) + 2;
            long ia = (long)firstRow * g.Cols, ib = Math.Min(Total, (long)lastRow * g.Cols);
            if (NeedRange != null) NeedRange((int)ia, (int)Math.Max(ia, ib - 1));
            double dpi = Txt.Ppd;
            Cols.Layout(g.W);
            if (g.Grid) RenderGrid(dc, g, (int)ia, (int)ib, dpi); else RenderList(dc, g, (int)ia, (int)ib, dpi);
            if (g.Bar) DrawBar(dc, g);
        }

        FormattedText NameFt(string base_, double size, double w, bool sel, string kind)
        {
            string key = kind + "|" + (sel ? 1 : 0) + "|" + (int)w + "|" + string.Join("\u0001", Terms) + "|" + base_;
            return tc.Get(key, () =>
            {
                var ft = Txt.Make(base_, size, sel ? Th.Text : Th.TextSoft, false, w);
                int pos = 0;
                foreach (var s in Dsl.HlName(base_, Terms)) { if (s.Value && s.Key.Length > 0) ft.SetFontWeight(FontWeights.Bold, pos, s.Key.Length); pos += s.Key.Length; }
                return ft;
            });
        }
        FormattedText Plain(string s, double size, Brush b, double w, string kind)
        {
            return tc.Get(kind + "|" + size + "|" + (int)w + "|" + s, () => Txt.Make(s, size, b, false, w));
        }

        void DrawThumb(DrawingContext dc, Hit h, Rect box, double dpi)
        {
            ImageSource im = h == null ? null : Thumbs.Get(h, Math.Max(box.Width, box.Height) * dpi);
            if (im == null) { dc.DrawRoundedRectangle(Th.Placeholder, null, box, 4, 4); return; }
            double iw = im.Width, ih = im.Height; if (iw <= 0 || ih <= 0) return;
            double s = Math.Min(box.Width / iw, box.Height / ih);
            double w = iw * s, hh = ih * s;
            dc.DrawImage(im, new Rect(box.X + (box.Width - w) / 2, box.Y + (box.Height - hh) / 2, w, hh));
        }

        void RenderList(DrawingContext dc, Geom g, int ia, int ib, double dpi)
        {
            double th = Cols.Thumb; var c = Cols; bool score = c.HasScore;
            RenderOptions.SetBitmapScalingMode(this, BitmapScalingMode.HighQuality);
            for (int i = ia; i < ib; i++)
            {
                double y = Math.Round(i * g.Stride - Off); var h = GetHit(i); bool sel = i == Sel;
                if (y + g.Stride < 0 || y > g.H) continue;
                if (sel)
                {
                    dc.DrawRoundedRectangle(Th.Sel, null, new Rect(0, y, g.W, g.Stride), 6, 6);
                    dc.DrawRoundedRectangle(Th.Accent, null, new Rect(0, y, 3, g.Stride), 1, 1);
                }
                DrawThumb(dc, h, new Rect(6, y + Math.Round((g.Stride - th) / 2), th, th), dpi);
                if (h == null) continue;
                var sd = Dsl.SplitDir(h.Path);
                var f = NameFt(sd[1], 11, c.W[1] - 8, sel, "n"); dc.DrawText(f, new Point(c.X[1], y + (g.Stride - f.Height) / 2));
                f = Plain(sd[0], 11, Th.Dim, c.W[2] - 8, "p"); dc.DrawText(f, new Point(c.X[2], y + (g.Stride - f.Height) / 2));
                if (h.HasSize) { f = Plain(Dsl.HSize(h.Size), 11, Th.Dim, c.W[3] - 8, "s"); dc.DrawText(f, new Point(c.X[3], y + (g.Stride - f.Height) / 2)); }
                if (h.Pages >= 0) { f = Plain(h.Pages.ToString(), 11, Th.Dim, c.W[4] - 8, "g"); dc.DrawText(f, new Point(c.X[4], y + (g.Stride - f.Height) / 2)); }
                if (!string.IsNullOrEmpty(h.Mtime)) { f = Plain(Dsl.STime(h.Mtime), 11, Th.Dim, c.W[5] - 8, "d"); dc.DrawText(f, new Point(c.X[5], y + (g.Stride - f.Height) / 2)); }
                if (score && h.HasScore) { f = Plain(h.Score.ToString("0.00", System.Globalization.CultureInfo.InvariantCulture), 12, Th.Accent, c.W[6], "c"); dc.DrawText(f, new Point(c.X[6], y + (g.Stride - f.Height) / 2)); }
            }
        }

        void RenderGrid(DrawingContext dc, Geom g, int ia, int ib, double dpi)
        {
            RenderOptions.SetBitmapScalingMode(this, BitmapScalingMode.HighQuality);
            for (int i = ia; i < ib; i++)
            {
                int row = i / g.Cols, col = i % g.Cols;
                double x = col * (g.T + Const.Gap), y = Math.Round(row * g.Stride - Off);
                if (y + g.CellH < 0 || y > g.H) continue;
                var h = GetHit(i); bool sel = i == Sel; var box = new Rect(x, y, g.T, g.T);
                DrawThumb(dc, h, box, dpi);
                if (sel) dc.DrawRoundedRectangle(null, Ui.P(Th.Accent, 2), new Rect(x - 3, y - 3, g.T + 6, g.T + 6), 6, 6);
                if (h == null) continue;
                if (h.HasScore) { var sf = Plain(h.Score.ToString("0.00", System.Globalization.CultureInfo.InvariantCulture), 10, Th.Accent, g.T, "c10"); dc.DrawText(sf, new Point(x + g.T - sf.WidthIncludingTrailingWhitespace - 2, y + 2)); }
                var sd = Dsl.SplitDir(h.Path);
                double ty = y + g.T + 4;
                var f = NameFt(sd[1], 12, g.T, sel, "gn"); dc.DrawText(f, new Point(x, ty + (14.4 - f.Height) / 2)); ty += 14.4;
                f = Plain("path: " + sd[0], 10, Th.Dim, g.T, "gp"); dc.DrawText(f, new Point(x, ty + (13 - f.Height) / 2)); ty += 13;
                var parts = new List<string>();
                if (h.HasSize) parts.Add("size: " + Dsl.HSize(h.Size));
                if (!string.IsNullOrEmpty(h.Mtime)) parts.Add("date modified: " + Dsl.STime(h.Mtime));
                if (h.Pages >= 0) parts.Add("pages: " + h.Pages);
                string meta = string.Join(" · ", parts);
                string key = "gm|" + (int)g.T + "|" + meta;
                var mf = tc.Get(key, () => { var t = Txt.Make(meta, 10, Th.Dim, false, g.T); t.MaxLineCount = 3; t.LineHeight = 13; return t; });
                dc.DrawText(mf, new Point(x, ty));
            }
        }

        // ---- scrollbar ----
        Rect ThumbRect(Geom g)
        {
            double th = Math.Max(36, g.H * g.H / g.Content), max = MaxOff(g), top = max <= 0 ? 0 : Off / max * (g.H - th);
            return new Rect(g.W + 2, top, Const.Bar - 4, th);
        }
        void DrawBar(DrawingContext dc, Geom g)
        {
            var r = ThumbRect(g);
            dc.DrawRoundedRectangle(barHot || barDrag ? Ui.Alpha(Th.AccentC, .6) : Ui.Alpha(Th.DimC, .28), null, r, 3, 3);
        }

        // ---- mouse ----
        protected override void OnMouseWheel(MouseWheelEventArgs e)
        {
            double dy = -e.Delta * (100.0 / 120.0);
            if ((Keyboard.Modifiers & ModifierKeys.Control) != 0) { if (ZoomWheel != null) ZoomWheel(dy); e.Handled = true; return; }
            var g = Compute(); double boost = Math.Min(6, Math.Max(1, g.Stride / 60));
            SetOff(Off + (!g.Grid && boost > 1.05 ? dy * boost : dy));
            e.Handled = true;
        }
        protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
        {
            Focus(); var p = e.GetPosition(this); var g = Compute();
            if (g.Bar && p.X >= g.W)
            {
                var r = ThumbRect(g);
                if (p.Y >= r.Top && p.Y <= r.Bottom) { barDrag = true; dragDy = p.Y - r.Top; CaptureMouse(); }
                else SetOff(Off + (p.Y < r.Top ? -g.H : g.H) * 0.9);
                InvalidateVisual(); e.Handled = true; return;
            }
            int i = IndexAt(p, g); downIdx = i; downPt = p; dragFired = false;
            if (i >= 0) { if (RowClick != null) RowClick(i, e.ClickCount); CaptureMouse(); }
            e.Handled = true;
        }
        protected override void OnMouseMove(MouseEventArgs e)
        {
            var p = e.GetPosition(this); var g = Compute();
            if (barDrag)
            {
                double th = Math.Max(36, g.H * g.H / g.Content), track = g.H - th;
                if (track > 0) SetOff((p.Y - dragDy) / track * MaxOff(g));
                return;
            }
            bool hot = g.Bar && p.X >= g.W; if (hot != barHot) { barHot = hot; InvalidateVisual(); }
            if (downIdx >= 0 && e.LeftButton == MouseButtonState.Pressed && !dragFired &&
                (Math.Abs(p.X - downPt.X) > SystemParameters.MinimumHorizontalDragDistance || Math.Abs(p.Y - downPt.Y) > SystemParameters.MinimumVerticalDragDistance))
            {
                dragFired = true; int idx = downIdx; downIdx = -1; ReleaseMouseCapture();
                if (DragOut != null) DragOut(idx);
            }
        }
        protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e) { barDrag = false; downIdx = -1; if (IsMouseCaptured) ReleaseMouseCapture(); InvalidateVisual(); }
        protected override void OnMouseLeave(MouseEventArgs e) { if (barHot) { barHot = false; InvalidateVisual(); } }
        protected override void OnMouseRightButtonDown(MouseButtonEventArgs e)
        {
            Focus(); var p = e.GetPosition(this); int i = IndexAt(p, Compute());
            if (i >= 0 && RowRightClick != null) RowRightClick(i, p);
            e.Handled = true;
        }

        /// <summary>Screen-independent rectangle (relative to this view) of an item, for menus.</summary>
        public Rect ItemRect(int i)
        {
            var g = Compute(); int row = i / g.Cols, col = i % g.Cols;
            return g.Grid ? new Rect(col * (g.T + Const.Gap), row * g.Stride - Off, g.T, g.CellH) : new Rect(0, row * g.Stride - Off, g.W, g.Stride);
        }
    }

    public class HeaderView : FrameworkElement
    {
        public ColModel Cols; public Theme Th; public string Query = ""; public double RightPad;
        public event Action<string> SortClick; public event Action WidthsChanged; public event Action Resized;
        int hot = -1, drag = -1, downCell = -1; double x0, startW, spare; bool moved; readonly TextCache tc = new TextCache();
        static readonly string[] Labels = { "NAME", "PATH", "SIZE", "#P", "MODIFIED", "SCORE" };
        public HeaderView() { SnapsToDevicePixels = true; ClipToBounds = true; }
        public void ThemeChanged() { tc.Clear(); InvalidateVisual(); }
        public double ColW(string k) { return Cols.W[1 + Array.IndexOf(ColModel.Keys, k)]; }

        int CellAt(double x) { for (int i = 1; i <= (Cols.HasScore ? 6 : 5); i++) if (x >= Cols.X[i] && x < Cols.X[i] + Cols.W[i]) return i; return -1; }
        int GripAt(double x) { for (int i = 1; i <= 5; i++) { double r = Cols.X[i] + Cols.W[i]; if (x >= r - 6 && x <= r + 6) return i; } return -1; }

        protected override void OnRender(DrawingContext dc)
        {
            try { Txt.Ppd = VisualTreeHelper.GetDpi(this).PixelsPerDip; } catch { }
            dc.DrawRectangle(Brushes.Transparent, null, new Rect(0, 0, ActualWidth, ActualHeight));
            Cols.Layout(Math.Max(0, ActualWidth - RightPad));
            var si = Dsl.SortInfo(Query); string pc = si.Explicit ? Dsl.ColOfKey(si.Key) : null;
            int n = Cols.HasScore ? 6 : 5;
            for (int i = 1; i <= n; i++)
            {
                string k = i <= 5 ? ColModel.Keys[i - 1] : "score";
                bool arrow = si.Explicit && i <= 5 && (pc == k || si.Keys.Skip(1).Any(x => Dsl.ColOfKey(x) == k));
                string label = Labels[i - 1] + (arrow ? (si.Desc ? " ▼" : " ▲") : "");
                Brush b = pc == k ? Th.Accent : (arrow ? Th.Text : Th.Dim);
                string key = label + "|" + (pc == k ? "p" : arrow ? "s" : "d") + "|" + (int)Cols.W[i];
                var ft = tc.Get(key, () => Txt.Make(label, 10, b, false, Cols.W[i]));
                dc.DrawText(ft, new Point(Cols.X[i], ActualHeight - ft.Height - 2));
            }
            int g = drag >= 0 ? drag : hot;
            if (g >= 1 && g <= 5) { double r = Cols.X[g] + Cols.W[g]; dc.DrawRoundedRectangle(Th.Accent, null, new Rect(r - 1, 2, 2, ActualHeight - 3), 1, 1); }
        }

        public void RaiseSort(string k) { if (SortClick != null) SortClick(k); }
        protected override void OnMouseMove(MouseEventArgs e)
        {
            var p = e.GetPosition(this);
            if (drag >= 0)
            {
                string k = ColModel.Keys[drag - 1]; moved = true;
                double v = Math.Round(Math.Max(Const.MinW, Math.Min(startW + p.X - x0, startW + spare)));
                Cols.CW[k] = v;
                if (k == "name") Cols.CW.Remove("path"); else if (k == "path") Cols.CW.Remove("name");
                InvalidateVisual(); if (Resized != null) Resized(); return;
            }
            int g = GripAt(p.X); Cursor = g > 0 ? Cursors.SizeWE : Cursors.Hand;
            if (g != hot) { hot = g; InvalidateVisual(); }
        }
        protected override void OnMouseLeave(MouseEventArgs e) { if (drag < 0 && hot != -1) { hot = -1; InvalidateVisual(); } }
        protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
        {
            var p = e.GetPosition(this); int g = GripAt(p.X);
            if (g > 0)
            {
                string k = ColModel.Keys[g - 1];
                if (e.ClickCount == 2) { Cols.CW.Remove(k); InvalidateVisual(); if (Resized != null) Resized(); if (WidthsChanged != null) WidthsChanged(); e.Handled = true; return; }
                drag = g; x0 = p.X; startW = Cols.W[g]; moved = false;
                var absorb = (k == "name" || k == "path") ? new[] { k == "name" ? "path" : "name" } : new[] { "name", "path" }.Where(c => !Cols.Fixed(c)).ToArray();
                spare = absorb.Sum(c => Math.Max(0, Cols.W[1 + Array.IndexOf(ColModel.Keys, c)] - 60));
                CaptureMouse(); e.Handled = true; return;
            }
            downCell = CellAt(p.X); e.Handled = true;
        }
        protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
        {
            var p = e.GetPosition(this);
            if (drag >= 0) { drag = -1; ReleaseMouseCapture(); InvalidateVisual(); if (WidthsChanged != null) WidthsChanged(); return; }
            int c = CellAt(p.X);
            if (c > 0 && c == downCell && c <= 5 && SortClick != null) SortClick(ColModel.Keys[c - 1]);
            downCell = -1;
        }
    }
}
