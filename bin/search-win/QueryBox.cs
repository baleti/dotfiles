using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;

namespace SearchApp
{
    /// <summary>Single-line query box: a transparent TextBox over a TextBlock of coloured runs (command tokens bold in the accent colour).</summary>
    public class QueryBox : Grid
    {
        public TextBox Box; public TextBlock Hl; readonly Theme th; ScrollViewer sv; bool silent;
        public event Action UserChanged;
        public bool DebugShowText;

        public QueryBox(Theme t)
        {
            th = t; Height = 20; ClipToBounds = true;
            Hl = new TextBlock { FontSize = 13, IsHitTestVisible = false, VerticalAlignment = VerticalAlignment.Center, Height = 20, RenderTransform = new TranslateTransform(1, 1) };
            Box = Ui.PlainTextBox(); Box.FontSize = 13; Box.VerticalContentAlignment = VerticalAlignment.Center; Box.VerticalAlignment = VerticalAlignment.Stretch;
            Box.SelectionOpacity = 1; Box.Foreground = Brushes.Transparent; Box.SpellCheck.IsEnabled = false; Box.UndoLimit = 100;
            Children.Add(Hl); Children.Add(Box);
            Box.TextChanged += (s, e) => { Redraw(); if (!silent && UserChanged != null) UserChanged(); };
            Box.SelectionChanged += (s, e) => SyncScroll();
            Box.Loaded += (s, e) => HookScroll();
            Box.AddHandler(ScrollViewer.ScrollChangedEvent, new ScrollChangedEventHandler((s, e) => SyncScroll()));
        }
        void HookScroll() { Box.ApplyTemplate(); sv = Box.Template.FindName("PART_ContentHost", Box) as ScrollViewer; SyncScroll(); }
        void SyncScroll() { if (sv == null) { HookScroll(); } if (sv != null) { var tt = (TranslateTransform)Hl.RenderTransform; tt.X = 1 - sv.HorizontalOffset; tt.Y = 1; } }

        public string Text { get { return Box.Text; } }
        public void SetText(string s) { silent = true; Box.Text = s ?? ""; silent = false; Box.CaretIndex = Box.Text.Length; Redraw(); }
        public void SetTextCaretEnd(string s) { SetText(s); }
        public void FocusBox() { Keyboard.Focus(Box); Box.Focus(); }
        public void SelectAll() { Box.SelectAll(); }
        public bool IsFocusedBox { get { return Box.IsKeyboardFocused; } }
        public int CaretIndex { get { return Box.CaretIndex; } set { Box.CaretIndex = value; } }
        public void ApplyFont() { Hl.FontFamily = Fonts.Family; Box.FontFamily = Fonts.Family; Redraw(); }
        public void ApplyTheme()
        {
            Hl.Foreground = th.Text; Box.CaretBrush = th.Text;
            Box.SelectionBrush = Ui.Alpha(th.AccentC, .35);
            Box.Foreground = DebugShowText ? Ui.Alpha(Colors.Red, .5) : Brushes.Transparent;
            Redraw();
        }
        public void Redraw()
        {
            string q = Box.Text; Hl.Inlines.Clear(); int pos = 0;
            foreach (var sp in Dsl.CmdSpans(q))
            {
                if (sp[0] > pos) Hl.Inlines.Add(new Run(q.Substring(pos, sp[0] - pos)));
                Hl.Inlines.Add(new Run(q.Substring(sp[0], sp[1] - sp[0])) { FontWeight = FontWeights.Bold, Foreground = th.Accent });
                pos = sp[1];
            }
            if (pos < q.Length) Hl.Inlines.Add(new Run(q.Substring(pos)));
            if (Hl.Inlines.Count == 0) Hl.Inlines.Add(new Run(""));
        }
    }
}
