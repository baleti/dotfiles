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
        const double MaxW = 208, MinW = 48, H = 17, Gap = 4;
        int hot = -1; bool hotX;
        public TabStrip(Theme th) { Th = th; Height = 22; Cursor = Cursors.Arrow; Background = null; }
        Brush Background;
        string Title(int i) { string t = Titles[i] ?? ""; return t.Trim().Length == 0 ? "new" : t; }
        double TabW(int i) { return Math.Max(MinW, Math.Min(MaxW, Txt.Make(Title(i), 11, Th.Text).WidthIncludingTrailingWhitespace + 28)); }
        double X(int i) { double x = 0; for (int k = 0; k < i; k++) x += TabW(k) + Gap; return x; }
        Rect R(int i) { return new Rect(X(i), 2, TabW(i), H); }
        Rect Plus() { return new Rect(X(Titles.Count), 2, H, H); }
        /// <summary>Fits text into maxW by cutting the middle: "C:/ho\u2026 file.txt".</summary>
        string Mid(string t, double maxW)
        {
            if (Txt.Make(t, 11, Th.Text).WidthIncludingTrailingWhitespace <= maxW) return t;
            for (int n = t.Length - 1; n > 2; n--)
            {
                int head = (n + 1) / 2, tail = n - head;
                string c = t.Substring(0, head) + "\u2026" + t.Substring(t.Length - tail);
                if (Txt.Make(c, 11, Th.Text).WidthIncludingTrailingWhitespace <= maxW) return c;
            }
            return "\u2026";
        }
        int At(Point p, out bool x)
        {
            x = false;
            for (int i = 0; i < Titles.Count; i++) { var r = R(i); if (r.Contains(p)) { x = p.X > r.Right - 20; return i; } }
            return Plus().Contains(p) ? -2 : -1;
        }
        protected override Size MeasureOverride(Size a) { return new Size(0, Titles.Count > 1 ? 22 : 0); }
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
                dc.DrawRoundedRectangle(Ui.Alpha(on ? Th.AccentC : Th.TextC, on ? .22 : (hot == i ? .10 : .05)), null, r, 5, 5);
                if (on) dc.DrawRoundedRectangle(Th.Accent, null, new Rect(r.X + 6, r.Bottom - 1.5, r.Width - 12, 1.5), 1, 1);
                string t = Mid(Title(i), r.Width - 26);
                var ft = Txt.Make(t, 11, on ? Th.Text : Th.Dim);
                dc.DrawText(ft, new Point(r.X + 9, r.Y + (H - ft.Height) / 2));
                if (hot == i) { var xf = Txt.Make("\u00d7", 13, hotX ? Th.Error : Th.Dim); dc.DrawText(xf, new Point(r.Right - 14, r.Y + (H - xf.Height) / 2)); }
            }
            var p = Plus();
            if (hot == -2) dc.DrawRoundedRectangle(Ui.Alpha(Th.TextC, .10), null, p, 5, 5);
            var pf = Txt.Make("+", 14, Th.Dim); dc.DrawText(pf, new Point(p.X + (H - pf.WidthIncludingTrailingWhitespace) / 2, p.Y + (H - pf.Height) / 2));
        }
    }
}
