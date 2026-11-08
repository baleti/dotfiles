using System;
using System.Collections.Generic;
using System.Globalization;
using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;

namespace SearchApp
{
    public class Palette
    {
        public string Bg, Text, Dim, Border, Accent, Error;
        public static Palette DarkFallback() { return new Palette { Bg = "#1a1c1e", Text = "#e2e2e5", Dim = "#c2c7cf", Border = "#42474e", Accent = "#99cbff", Error = "#ffb4ab" }; }
        public static Palette LightFallback() { return new Palette { Bg = "#fdfcff", Text = "#1a1c1e", Dim = "#43474e", Border = "#c2c7cf", Accent = "#00639b", Error = "#ba1a1a" }; }
        public string Sig() { return Bg + Text + Dim + Border + Accent + Error; }
    }

    public static class ThemeMath
    {
        public static void HexHsl(string hex, out double h, out double s, out double l)
        {
            int n = int.Parse(hex.TrimStart('#'), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
            double r = ((n >> 16) & 255) / 255.0, g = ((n >> 8) & 255) / 255.0, b = (n & 255) / 255.0;
            double mx = Math.Max(r, Math.Max(g, b)), mn = Math.Min(r, Math.Min(g, b)); l = (mx + mn) / 2; double d = mx - mn;
            h = 0; s = 0;
            if (d != 0)
            {
                s = d / (1 - Math.Abs(2 * l - 1));
                h = mx == r ? ((g - b) / d) % 6 : mx == g ? (b - r) / d + 2 : (r - g) / d + 4;
                h = (h * 60 + 360) % 360;
            }
        }
        static string Hex2(double v) { int x = (int)Math.Floor(v * 255 + 0.5); if (x < 0) x = 0; if (x > 255) x = 255; return x.ToString("x2", CultureInfo.InvariantCulture); }
        public static string HslHex(double h, double s, double l)
        {
            double c = (1 - Math.Abs(2 * l - 1)) * s, x = c * (1 - Math.Abs((h / 60) % 2 - 1)), m = l - c / 2, r, g, b;
            if (h < 60) { r = c; g = x; b = 0; } else if (h < 120) { r = x; g = c; b = 0; } else if (h < 180) { r = 0; g = c; b = x; }
            else if (h < 240) { r = 0; g = x; b = c; } else if (h < 300) { r = x; g = 0; b = c; } else { r = c; g = 0; b = x; }
            return "#" + Hex2(r + m) + Hex2(g + m) + Hex2(b + m);
        }
        public static Palette LightFrom(Palette t)
        {
            double h, s, l, ha, sa, l2; HexHsl(t.Bg, out h, out s, out l); HexHsl(t.Accent, out ha, out sa, out l2);
            return new Palette
            {
                Bg = HslHex(h, Math.Min(s, .35), .98), Text = HslHex(h, Math.Min(s, .25), .10), Dim = HslHex(h, Math.Min(s, .20), .30),
                Border = HslHex(h, Math.Min(s, .20), .80), Accent = HslHex(ha, Math.Min(Math.Max(sa, .5), .9), .36), Error = "#ba1a1a"
            };
        }
        public static Color Col(string hex)
        {
            int n = int.Parse(hex.TrimStart('#'), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
            return Color.FromRgb((byte)(n >> 16), (byte)(n >> 8), (byte)n);
        }
        public static Color Over(Color fg, double a, Color bg)
        {
            return Color.FromRgb((byte)Math.Round(fg.R * a + bg.R * (1 - a)), (byte)Math.Round(fg.G * a + bg.G * (1 - a)), (byte)Math.Round(fg.B * a + bg.B * (1 - a)));
        }
    }

    /// <summary>Brushes for the current palette plus the Windows light/dark preference.</summary>
    public class Theme
    {
        public bool Light;
        public Palette Raw;           // server (dark) palette, null until first answer
        public Palette P;             // effective palette
        public Brush Bg, Text, TextSoft, Dim, Border, Accent, Error, Sel, Placeholder, AccentLine;
        public Color BgC, TextC, DimC, BorderC, AccentC, ErrorC;
        public string Sig = "";
        public event Action Changed;

        public static bool WindowsLight()
        {
            try { using (var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize")) { var v = k == null ? null : k.GetValue("AppsUseLightTheme"); if (v is int) return (int)v != 0; } }
            catch { }
            return false;
        }

        public Theme(bool light) { Light = light; Apply(null, true); }

        public void SetLight(bool light) { if (light == Light) return; Light = light; Apply(null, false); }

        public void Apply(Palette raw, bool silent)
        {
            if (raw != null) Raw = raw;
            Palette p = Light ? (Raw != null ? ThemeMath.LightFrom(Raw) : Palette.LightFallback()) : (Raw ?? Palette.DarkFallback());
            string sig = (Light ? "L" : "D") + p.Sig();
            if (sig == Sig) return;
            Sig = sig; P = p;
            BgC = ThemeMath.Col(p.Bg); TextC = ThemeMath.Col(p.Text); DimC = ThemeMath.Col(p.Dim); BorderC = ThemeMath.Col(p.Border); AccentC = ThemeMath.Col(p.Accent); ErrorC = ThemeMath.Col(p.Error);
            Bg = Fz(BgC); Text = Fz(TextC); Dim = Fz(DimC); Border = Fz(BorderC); Accent = Fz(AccentC); Error = Fz(ErrorC);
            TextSoft = Fz(ThemeMath.Over(TextC, .85, BgC));
            Sel = Fz(ThemeMath.Over(AccentC, .18, BgC));
            Placeholder = Fz(ThemeMath.Over(BorderC, .5, BgC));
            if (!silent && Changed != null) Changed();
        }
        static Brush Fz(Color c) { var b = new SolidColorBrush(c); b.Freeze(); return b; }
    }
}
