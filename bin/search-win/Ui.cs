using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Markup;
using System.Windows.Media;

namespace SearchApp
{
    /// <summary>JetBrains Mono from the server (cached in LOCALAPPDATA), Consolas as the fallback.</summary>
    public static class Fonts
    {
        public static FontFamily Family = new FontFamily("Consolas");
        public static Typeface Reg = new Typeface(Family, FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);
        public static Typeface Bold = new Typeface(Family, FontStyles.Normal, FontWeights.Bold, FontStretches.Normal);
        public static bool Loaded;
        public static event Action Changed;
        public static string Dir { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SearchApp", "fonts"); } }

        public static void Use(FontFamily f)
        {
            Family = f;
            Reg = new Typeface(f, FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);
            Bold = new Typeface(f, FontStyles.Normal, FontWeights.Bold, FontStretches.Normal);
        }

        public static async Task EnsureAsync(Api api)
        {
            try
            {
                Directory.CreateDirectory(Dir);
                foreach (var n in new[] { "regular", "bold" })
                {
                    string p = Path.Combine(Dir, n + ".ttf");
                    if (!File.Exists(p) || new FileInfo(p).Length < 1000)
                    {
                        var b = await api.GetBytes("/font/" + n + ".ttf", System.Threading.CancellationToken.None);
                        File.WriteAllBytes(p, b);
                    }
                }
                Apply();
            }
            catch { }
        }
        public static void Apply()
        {
            var uri = new Uri("file:///" + Dir.Replace('\\', '/').TrimEnd('/') + "/");
            Use(new FontFamily(uri, "./#JetBrains Mono"));
            Loaded = true;
            if (Changed != null) Changed();
        }
    }

    public static class Txt
    {
        public static double Ppd = 1.0;
        public static FormattedText Make(string s, double size, Brush b, bool bold = false, double maxW = double.PositiveInfinity)
        {
            var ft = new FormattedText(s ?? "", CultureInfo.InvariantCulture, FlowDirection.LeftToRight, bold ? Fonts.Bold : Fonts.Reg, size, b, null, TextFormattingMode.Ideal, Ppd);
            ft.MaxLineCount = 1; ft.Trimming = TextTrimming.CharacterEllipsis;
            if (!double.IsInfinity(maxW)) ft.MaxTextWidth = Math.Max(1, maxW);
            return ft;
        }
    }

    /// <summary>Keeps the FormattedText objects of visible rows so scrolling does not rebuild them.</summary>
    public class TextCache
    {
        readonly Dictionary<string, FormattedText> d = new Dictionary<string, FormattedText>();
        public void Clear() { d.Clear(); }
        public FormattedText Get(string key, Func<FormattedText> make)
        {
            FormattedText f;
            if (d.TryGetValue(key, out f)) return f;
            if (d.Count > 6000) d.Clear();
            return d[key] = make();
        }
    }

    public static class Ui
    {
        public static Pen P(Brush b, double t) { var p = new Pen(b, t); p.Freeze(); return p; }
        public static Brush Alpha(Color c, double a) { var b = new SolidColorBrush(Color.FromArgb((byte)Math.Round(255 * a), c.R, c.G, c.B)); b.Freeze(); return b; }
        public static double Snap(double v) { return Math.Round(v) + 0.5; }

        const string TplXaml = "<ControlTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' TargetType='TextBox'>" +
            "<Border Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='{TemplateBinding BorderThickness}' CornerRadius='{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}' SnapsToDevicePixels='True'>" +
            "<ScrollViewer x:Name='PART_ContentHost' Focusable='False' HorizontalScrollBarVisibility='Hidden' VerticalScrollBarVisibility='Hidden' Padding='{TemplateBinding Padding}'/></Border></ControlTemplate>";
        static ControlTemplate tpl;
        /// <summary>A TextBox without any system chrome (Tag = CornerRadius).</summary>
        public static TextBox PlainTextBox()
        {
            if (tpl == null) tpl = (ControlTemplate)XamlReader.Parse(TplXaml);
            var t = new TextBox { Template = tpl, Tag = new CornerRadius(0), BorderThickness = new Thickness(0), Padding = new Thickness(0), Background = Brushes.Transparent, AcceptsReturn = false, AcceptsTab = false };
            t.ContextMenu = null;
            System.Windows.Documents.Typography.SetStandardLigatures(t, false);
            return t;
        }

        public static IEnumerable<T> Descendants<T>(DependencyObject o) where T : DependencyObject
        {
            int n = VisualTreeHelper.GetChildrenCount(o);
            for (int i = 0; i < n; i++)
            {
                var c = VisualTreeHelper.GetChild(o, i);
                if (c is T) yield return (T)c;
                foreach (var x in Descendants<T>(c)) yield return x;
            }
        }
    }

    /// <summary>Small outlined button; accent border on hover/focus.</summary>
    public class Btn : FrameworkElement
    {
        public string Text; public Theme Th; public Action Click; bool hot;
        public Btn(Theme th, string text, Action click) { Th = th; Text = text; Click = click; Cursor = Cursors.Hand; Focusable = true; }
        protected override Size MeasureOverride(Size a) { var ft = Txt.Make(Text, 12, Th.Text); return new Size(ft.WidthIncludingTrailingWhitespace + 22, ft.Height + 12); }
        protected override void OnMouseEnter(MouseEventArgs e) { hot = true; InvalidateVisual(); }
        protected override void OnMouseLeave(MouseEventArgs e) { hot = false; InvalidateVisual(); }
        protected override void OnGotKeyboardFocus(KeyboardFocusChangedEventArgs e) { InvalidateVisual(); }
        protected override void OnLostKeyboardFocus(KeyboardFocusChangedEventArgs e) { InvalidateVisual(); }
        protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e) { if (Click != null) Click(); e.Handled = true; }
        protected override void OnKeyDown(KeyEventArgs e) { if (e.Key == Key.Enter || e.Key == Key.Space) { if (Click != null) Click(); e.Handled = true; } }
        protected override void OnRender(DrawingContext dc)
        {
            var r = new Rect(0.5, 0.5, ActualWidth - 1, ActualHeight - 1);
            dc.DrawRoundedRectangle(Brushes.Transparent, Ui.P(hot || IsKeyboardFocused ? Th.Accent : Th.Border, 1), r, 6, 6);
            var ft = Txt.Make(Text, 12, Th.Text);
            dc.DrawText(ft, new Point(Math.Round((ActualWidth - ft.WidthIncludingTrailingWhitespace) / 2), Math.Round((ActualHeight - ft.Height) / 2)));
        }
    }

    /// <summary>Checkbox square with accent fill when on.</summary>
    public class CheckBoxMark : FrameworkElement
    {
        public bool On; public Theme Th;
        public CheckBoxMark(Theme th) { Th = th; Width = 14; Height = 14; }
        protected override void OnRender(DrawingContext dc)
        {
            var r = new Rect(0.5, 0.5, 13, 13);
            dc.DrawRoundedRectangle(On ? Th.Accent : Brushes.Transparent, Ui.P(On ? Th.Accent : Th.Border, 1), r, 3, 3);
            if (On) { var g = new StreamGeometry(); using (var c = g.Open()) { c.BeginFigure(new Point(3.5, 7.2), false, false); c.LineTo(new Point(6, 9.7), true, false); c.LineTo(new Point(10.5, 4.3), true, false); } g.Freeze(); dc.DrawGeometry(null, Ui.P(Th.Bg, 1.8), g); }
        }
    }
}
