using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;

namespace SearchApp
{
    /// <summary>Narrow, compact tab strip (hidden with a single tab). Click selects, x / middle click closes, + opens a tab.</summary>
    public class TabStrip : FrameworkElement
    {
        public Theme Th; public List<string> Titles = new List<string>(); public int Cur;
        public Action<int> Select, Close; public Action New;
        const double W = 104, H = 22, Gap = 4;
        int hot = -1; bool hotX;
        public TabStrip(Theme th) { Th = th; Height = 28; Cursor = Cursors.Arrow; Background = null; }
        Brush Background;
        Rect R(int i) { return new Rect(i * (W + Gap), 3, W, H); }
        Rect Plus() { return new Rect(Titles.Count * (W + Gap), 3, H, H); }
        int At(Point p, out bool x)
        {
            x = false;
            for (int i = 0; i < Titles.Count; i++) { var r = R(i); if (r.Contains(p)) { x = p.X > r.Right - 20; return i; } }
            return Plus().Contains(p) ? -2 : -1;
        }
        protected override Size MeasureOverride(Size a) { return new Size(0, Titles.Count > 1 ? 28 : 0); }
        protected override void OnMouseMove(MouseEventArgs e) { bool x; int i = At(e.GetPosition(this), out x); if (i != hot || x != hotX) { hot = i; hotX = x; InvalidateVisual(); } }
        protected override void OnMouseLeave(MouseEventArgs e) { hot = -1; InvalidateVisual(); }
        protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
        {
            bool x; int i = At(e.GetPosition(this), out x);
            if (i == -2) { if (New != null) New(); }
            else if (i >= 0) { if (x) { if (Close != null) Close(i); } else if (Select != null) Select(i); }
            e.Handled = true;
        }
        protected override void OnMouseDown(MouseButtonEventArgs e)
        {
            if (e.ChangedButton == MouseButton.Middle) { bool x; int i = At(e.GetPosition(this), out x); if (i >= 0 && Close != null) Close(i); e.Handled = true; }
        }
        protected override void OnRender(DrawingContext dc)
        {
            if (Titles.Count < 2) return;
            for (int i = 0; i < Titles.Count; i++)
            {
                var r = R(i); bool on = i == Cur;
                dc.DrawRoundedRectangle(Ui.Alpha(on ? Th.AccentC : Th.TextC, on ? .22 : (hot == i ? .10 : .05)), null, r, 7, 7);
                if (on) dc.DrawRoundedRectangle(Th.Accent, null, new Rect(r.X + 8, r.Bottom - 2, r.Width - 16, 2), 1, 1);
                string t = Titles[i] ?? ""; if (t.Length > 14) t = t.Substring(0, 14) + "\u2026"; if (t.Trim().Length == 0) t = "new";
                var ft = Txt.Make(t, 11, on ? Th.Text : Th.Dim, false, W - 30);
                dc.DrawText(ft, new Point(r.X + 9, r.Y + (H - ft.Height) / 2));
                if (hot == i) { var xf = Txt.Make("\u00d7", 13, hotX ? Th.Error : Th.Dim); dc.DrawText(xf, new Point(r.Right - 16, r.Y + (H - xf.Height) / 2)); }
            }
            var p = Plus();
            if (hot == -2) dc.DrawRoundedRectangle(Ui.Alpha(Th.TextC, .10), null, p, 7, 7);
            var pf = Txt.Make("+", 14, Th.Dim); dc.DrawText(pf, new Point(p.X + (H - pf.WidthIncludingTrailingWhitespace) / 2, p.Y + (H - pf.Height) / 2));
        }
    }
}
