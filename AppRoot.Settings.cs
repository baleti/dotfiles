using System;
using System.Collections.Generic;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Threading;

namespace SearchApp
{
    /// <summary>Ctrl+P settings, shared with the desktop picker through the server.</summary>
    public partial class AppRoot
    {
        Grid setLayer; Border setBox; public bool SettingsOpen { get { return setLayer != null; } }
        DispatcherTimer setSaveT; TextBox setText;
        static readonly string[][] SetBoxes = {
            new[]{"show_backup_restic","Show restic backup copies in results"}, new[]{"show_backup_btrfs","Show btrfs snapshot copies in results"},
            new[]{"show_fts_rvt","Include Revit files (rvt, rfa, rte, rft) in content searches"}, new[]{"show_fts_dwg","Include AutoCAD drawings (dwg, dxf, dwt) in content searches"} };

        async void SetSave(Dictionary<string, object> patch)
        {
            try { await Api.PostSettings(patch); Flash("settings saved", 1400); RefreshInPlace(); }
            catch { Flash("could not save settings", 2500); }
        }
        TextBlock SText(string t, double size, Brush b, bool bold = false, Thickness? m = null)
        {
            return new TextBlock { Text = t, FontFamily = Fonts.Family, FontSize = size, Foreground = b, FontWeight = bold ? FontWeights.Bold : FontWeights.Normal, TextWrapping = TextWrapping.Wrap, Margin = m ?? new Thickness(0) };
        }
        TextBlock SHeading(string t) { return SText(t.ToUpperInvariant(), 11, Th.Dim, true, new Thickness(0, 14, 0, 4)); }

        public async void OpenSettings()
        {
            if (SettingsOpen) return;
            ClosePopups(); CloseMenu();
            setLayer = new Grid { Background = Ui.Alpha(Th.BgC, .55), Width = Overlay.ActualWidth, Height = Overlay.ActualHeight };
            setLayer.MouseLeftButtonDown += (s, e) => { if (e.OriginalSource == setLayer) CloseSettings(); };
            setBox = new Border { Background = Th.Bg, BorderBrush = Th.Border, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(10), Padding = new Thickness(16, 14, 16, 14), MaxWidth = 540, VerticalAlignment = VerticalAlignment.Top, HorizontalAlignment = HorizontalAlignment.Stretch, Margin = new Thickness(12, Math.Max(12, Overlay.ActualHeight * 0.08), 12, 12) };
            setBox.Effect = new DropShadowEffect { BlurRadius = 40, ShadowDepth = 12, Direction = 270, Opacity = .35, Color = Colors.Black };
            setBox.Child = SText("loading…", 11, Th.Dim);
            setLayer.Children.Add(setBox);
            Overlay.IsHitTestVisible = true; Overlay.Children.Add(setLayer);
            try
            {
                var v = await Api.GetSettings(CancellationToken.None);
                if (!SettingsOpen) return;
                BuildSettings(v);
                if (setText != null) { Keyboard.Focus(setText); setText.Focus(); setText.CaretIndex = setText.Text.Length; }
            }
            catch (Exception e) { if (SettingsOpen) setBox.Child = SText("could not load settings (" + e.GetBaseException().Message + ")", 11, Th.Dim); }
        }

        void BuildSettings(ServerSettings v)
        {
            var sp = new StackPanel();
            var head = new Grid(); head.Children.Add(SText("Settings", 13, Th.Text, true));
            var x = new TextBlock { Text = "×", FontFamily = Fonts.Family, FontSize = 15, Foreground = Th.Dim, HorizontalAlignment = HorizontalAlignment.Right, Cursor = Cursors.Hand, Padding = new Thickness(7, 0, 7, 0), ToolTip = "Close (Esc)" };
            x.MouseLeftButtonUp += (s, e) => CloseSettings(); head.Children.Add(x); sp.Children.Add(head);
            sp.Children.Add(SText("Shared with the desktop search (Mod+1): a change here applies there too. Saved as you change it.", 11, Th.Dim, false, new Thickness(0, 2, 0, 6)));
            sp.Children.Add(SHeading("Left out of every search"));
            setText = Ui.PlainTextBox(); setText.Tag = new CornerRadius(6);
            setText.BorderThickness = new Thickness(1); setText.BorderBrush = Th.Border; setText.Padding = new Thickness(8, 6, 8, 6);
            setText.FontFamily = Fonts.Family; setText.FontSize = 12; setText.Foreground = Th.Text; setText.CaretBrush = Th.Text; setText.SelectionBrush = Ui.Alpha(Th.AccentC, .35);
            setText.Text = v.DefaultExclude ?? "";
            setText.GotKeyboardFocus += (s, e) => setText.BorderBrush = Th.Accent; setText.LostKeyboardFocus += (s, e) => setText.BorderBrush = Th.Border;
            setText.TextChanged += (s, e) =>
            {
                if (setSaveT == null) { setSaveT = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(600) }; setSaveT.Tick += (a, b) => { setSaveT.Stop(); SetSave(new Dictionary<string, object> { { "default_exclude", setText.Text } }); }; }
                setSaveT.Stop(); setSaveT.Start();
            };
            sp.Children.Add(setText);
            sp.Children.Add(SText("Comma separated: extensions (.dat), //mime directory, /dotfiles. A verb typed in a query overrides this for that search.", 11, Th.Dim, false, new Thickness(0, 4, 0, 0)));
            sp.Children.Add(SHeading("Backups and content searches"));
            var vals = new Dictionary<string, bool> { { "show_backup_restic", v.BackupRestic }, { "show_backup_btrfs", v.BackupBtrfs }, { "show_fts_rvt", v.FtsRvt }, { "show_fts_dwg", v.FtsDwg } };
            foreach (var bx in SetBoxes)
            {
                string key = bx[0]; var mark = new CheckBoxMark(Th) { On = vals[key], Margin = new Thickness(0, 1, 8, 0), VerticalAlignment = VerticalAlignment.Top };
                var row = new Grid { Background = Brushes.Transparent, Cursor = Cursors.Hand, Margin = new Thickness(0, 4, 0, 4) };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new ColumnDefinition());
                row.Children.Add(mark); var t = SText(bx[1], 12, Th.Text); Grid.SetColumn(t, 1); row.Children.Add(t);
                row.MouseLeftButtonUp += (s, e) => { mark.On = !mark.On; mark.InvalidateVisual(); SetSave(new Dictionary<string, object> { { key, mark.On } }); };
                sp.Children.Add(row);
            }
            sp.Children.Add(SHeading("This app"));
            var btns = new WrapPanel { Margin = new Thickness(0, 6, 0, 0) };
            btns.Children.Add(new Btn(Th, "Reset column widths", () => { Cols.CW.Clear(); Cfg.Save(); Hdr.InvalidateVisual(); List.InvalidateVisual(); Flash("column widths reset", 1400); }) { Margin = new Thickness(0, 0, 8, 0) });
            btns.Children.Add(new Btn(Th, "Reset thumbnail size", () => SetThumb(16)));
            sp.Children.Add(btns);
            setBox.Child = sp;
        }

        public void CloseSettings()
        {
            if (setLayer == null) return;
            Overlay.Children.Remove(setLayer); setLayer = null; setBox = null; setText = null;
            if (setSaveT != null) setSaveT.Stop();
            FocusQuery(false);
        }
    }
}
namespace SearchApp
{
    public partial class AppRoot
    {
        /// <summary>Used by --shot --do to show UI states offscreen.</summary>
        public void ShotAction(string a)
        {
            if (a == "settings") { OpenSettings(); Shot.Pump(1500, () => setText != null); }
            else if (a == "hist") { hist = hist.Count > 0 ? hist : new List<string> { "alpha", "beta" }; HpOpen(); HP.Picked = true; HpDraw(); }
            else if (a == "cp") { CpStart(); Shot.Pump(1500, () => CP.Open); }
            else if (a == "menu") { if (sel >= 0) ShowMenuForSelection(); }
            else if (a.StartsWith("type:")) { Q.Box.Text = a.Substring(5); Shot.Pump(3000, () => sent == a.Substring(5) && !busy); }
            else if (a == "busy") { busy = true; busySince = DateTime.UtcNow.AddSeconds(-3); UpdateStatus(); }
        }
    }
}
