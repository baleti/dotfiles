using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;

namespace SearchApp
{
    public partial class AppRoot
    {
        Opener opener; CancellationTokenSource dlCts;
        public Opener Op { get { return opener ?? (opener = new Opener(Cfg, Api)); } }

        /// <summary>The original (through the drive map) or a downloaded copy, with progress in the status line; null on failure or cancel.</summary>
        async Task<string> LocalizeUi(Hit h)
        {
            if (dlCts != null) { Flash("a download is already running (Esc cancels it)", 2500); return null; }
            var cts = new CancellationTokenSource(); dlCts = cts;
            try
            {
                var plan = Op.Plan(h);
                if (plan.Kind == OpenKind.Download) Flash("downloading " + Opener.SafeName(h.Path) + "… (Esc cancels)", 600000);
                var p = await Op.Localize(h, (done, tot) => Dispatcher.BeginInvoke(new Action(() =>
                {
                    if (dlCts == cts) { flash = "downloading " + Opener.SafeName(h.Path) + "… " + Dsl.HSize(done) + (tot > 0 ? " of " + Dsl.HSize(tot) + " (" + (int)(100.0 * done / tot) + "%)" : "") + " (Esc cancels)"; UpdateStatus(); }
                })), cts.Token);
                if (plan.Kind == OpenKind.Download) { flash = null; UpdateStatus(); }
                if (p == null) Flash("cannot open: " + h.Path, 3000);
                return p;
            }
            catch (OperationCanceledException) { Flash("download cancelled", 1500); return null; }
            catch (Exception e) { Flash("could not fetch the file (" + e.GetBaseException().Message + ")", 4000); return null; }
            finally { if (dlCts == cts) dlCts = null; }
        }

        public async void OpenHit(int i, bool unused)
        {
            var h = Hit(i); if (h == null) return;
            Remember(sent);
            var plan = Op.Plan(h);
            if (plan.Kind == OpenKind.Refuse) { Flash("cannot serve: " + h.Path, 3000); return; }
            if (plan.Kind == OpenKind.Url) { try { Opener.Shell(plan.Target); } catch (Exception e) { Flash("could not open the address (" + e.Message + ")", 3000); } return; }
            if (!ConfirmDanger(h.Path)) return;
            var path = await LocalizeUi(h); if (path == null) return;
            try { Opener.Shell(path); } catch (Exception e) { Flash("could not open: " + e.Message, 4000); }
        }

        bool ConfirmDanger(string path)
        {
            if (!Opener.IsDangerous(Cfg, path)) return true;
            if (Opener.Dry) return true;
            var r = MessageBox.Show(Host != null ? Host.Win : null, "This is a program or script file:\n\n" + path + "\n\nOpen it anyway?", "Open file", MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No);
            return r == MessageBoxResult.Yes;
        }

        async void OpenWithHit(Hit h)
        {
            if (!ConfirmDanger(h.Path)) return;
            var p = await LocalizeUi(h); if (p == null) return;
            try { Opener.OpenWith(p); } catch (Exception e) { Flash("could not show the chooser: " + e.Message, 3000); }
        }
        async void ShowInFolderHit(Hit h)
        {
            var p = await LocalizeUi(h); if (p == null) return;
            try { Opener.ShowInFolder(p); } catch (Exception e) { Flash("could not open the folder: " + e.Message, 3000); }
        }
        async void SaveCopyHit(Hit h)
        {
            var dlg = new Microsoft.Win32.SaveFileDialog { FileName = Opener.SafeName(h.Path), Title = "Save a copy" };
            if (dlg.ShowDialog(Host != null ? Host.Win : null) != true) return;
            var p = await LocalizeUi(h); if (p == null) return;
            try { if (!string.Equals(Path.GetFullPath(p), Path.GetFullPath(dlg.FileName), StringComparison.OrdinalIgnoreCase)) File.Copy(p, dlg.FileName, true); Flash("saved " + dlg.FileName, 2500); }
            catch (Exception e) { Flash("could not save: " + e.Message, 4000); }
        }
        void OpenInBrowser(Hit h) { try { Opener.Shell(Api.FileUrl(h.Path)); } catch (Exception e) { Flash("could not open the browser: " + e.Message, 3000); } }

        // ---- drag a result out to Explorer / Outlook / Teams ----
        async void OnDragOut(int i)
        {
            var h = Hit(i); if (h == null || !h.FileOk) return;
            var p = await LocalizeUi(h); if (p == null) return;
            if (Mouse.LeftButton != MouseButtonState.Pressed) return;
            try { DragDrop.DoDragDrop(List, new DataObject(DataFormats.FileDrop, new[] { p }), DragDropEffects.Copy); } catch { }
        }

        // ---- context menu (drawn in the overlay layer, themed) ----
        class MenuDef { public string Label, Hint; public bool Enabled = true, Sep; public Action Act; }
        Border menuBox; Border menuScrim; StackPanel menuSp; List<MenuDef> menuItems; List<Border> menuRows; int menuSel = -1;
        public bool MenuOpen { get { return menuBox != null; } }

        void OnRowRightClick(int i, Point local)
        {
            CloseMenu(); listFocus = true; Keyboard.Focus(List); Select(i, false);
            var p = List.TranslatePoint(local, Overlay); ShowMenu(i, p);
        }
        void ShowMenuForSelection() { var r = List.ItemRect(sel); var p = List.TranslatePoint(new Point(Math.Min(r.X + 40, r.Right), r.Bottom - 2), Overlay); ShowMenu(sel, p); }

        void ShowMenu(int i, Point at)
        {
            var h = Hit(i); if (h == null) return;
            bool ok = h.FileOk; string win = Cfg.MapToWindows(h.Path) ?? h.WinPath;
            menuItems = new List<MenuDef> {
                new MenuDef { Label = "Open", Hint = "Enter", Act = () => OpenHit(i, false) },
                new MenuDef { Label = "Open with…", Enabled = ok, Act = () => OpenWithHit(h) },
                new MenuDef { Label = "Show in folder", Enabled = ok, Act = () => ShowInFolderHit(h) },
                new MenuDef { Sep = true },
                new MenuDef { Label = "Copy path", Hint = "Ctrl+C", Act = () => { CopyText(h.Path); Flash("copied path", 1500); } },
                new MenuDef { Label = "Copy Windows path", Enabled = win != null, Act = () => { CopyText(win); Flash("copied Windows path", 1500); } },
                new MenuDef { Sep = true },
                new MenuDef { Label = "Save a copy as…", Enabled = ok, Act = () => SaveCopyHit(h) },
                new MenuDef { Label = "Open in browser", Enabled = ok, Act = () => OpenInBrowser(h) },
            };
            menuScrim = new Border { Background = Brushes.Transparent };
            menuScrim.PreviewMouseDown += (s, e) => { CloseMenu(); e.Handled = true; };
            menuSp = new StackPanel(); menuRows = new List<Border>();
            menuBox = new Border { Background = Th.Bg, BorderBrush = Th.Border, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(12), Padding = new Thickness(6), Child = menuSp, MinWidth = 230 };
            menuBox.Effect = new DropShadowEffect { BlurRadius = 24, ShadowDepth = 8, Direction = 270, Opacity = .45, Color = Colors.Black };
            for (int k = 0; k < menuItems.Count; k++)
            {
                var d = menuItems[k]; int ix = k;
                if (d.Sep) { menuSp.Children.Add(new Border { Height = 1, Background = Th.Border, Margin = new Thickness(8, 5, 8, 5), Opacity = .6 }); menuRows.Add(null); continue; }
                var g = new Grid { Margin = new Thickness(10, 6, 10, 6) };
                g.Children.Add(new TextBlock { Text = d.Label, FontFamily = Fonts.Family, FontSize = 12, Foreground = d.Enabled ? Th.Text : Th.Dim, Opacity = d.Enabled ? 1 : .55 });
                if (d.Hint != null) g.Children.Add(new TextBlock { Text = d.Hint, FontFamily = Fonts.Family, FontSize = 11, Foreground = Th.Dim, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(30, 0, 0, 0) });
                var row = new Border { Child = g, Background = Brushes.Transparent, Tag = ix, CornerRadius = new CornerRadius(7) };
                row.MouseEnter += (s, e) => { if (d.Enabled) { menuSel = ix; MenuPaint(); } };
                row.PreviewMouseLeftButtonUp += (s, e) => { e.Handled = true; MenuRun(ix); };
                menuSp.Children.Add(row); menuRows.Add(row);
            }
            menuSel = menuItems.FindIndex(d => !d.Sep && d.Enabled);
            Overlay.IsHitTestVisible = true;
            menuScrim.Width = Overlay.ActualWidth; menuScrim.Height = Overlay.ActualHeight;
            Overlay.Children.Add(menuScrim); Overlay.Children.Add(menuBox);
            menuBox.Measure(new Size(Overlay.ActualWidth, Overlay.ActualHeight));
            double x = Math.Max(0, Math.Min(at.X, Overlay.ActualWidth - menuBox.DesiredSize.Width - 4)), y = Math.Max(0, Math.Min(at.Y, Overlay.ActualHeight - menuBox.DesiredSize.Height - 4));
            Canvas.SetLeft(menuBox, x); Canvas.SetTop(menuBox, y);
            MenuPaint();
        }
        void MenuPaint() { for (int k = 0; k < menuRows.Count; k++) if (menuRows[k] != null) menuRows[k].Background = k == menuSel ? Th.Sel : Brushes.Transparent; }
        void MenuRun(int ix) { var d = menuItems[ix]; if (!d.Enabled) return; CloseMenu(); d.Act(); }
        public void CloseMenu()
        {
            if (menuBox == null) return;
            Overlay.Children.Remove(menuBox); Overlay.Children.Remove(menuScrim); menuBox = null; menuScrim = null;
            if (Overlay.Children.Count == 0 || (Overlay.Children.Count == 1 && dropBox != null)) { }
            if (listFocus) Keyboard.Focus(List);
        }
        void MenuKey(Key k, bool ctrl, KeyEventArgs e)
        {
            e.Handled = true;
            if (k == Key.Escape) { CloseMenu(); return; }
            if (k == Key.Enter || k == Key.Space) { if (menuSel >= 0) MenuRun(menuSel); return; }
            int dir = (k == Key.Down || (ctrl && k == Key.J)) ? 1 : (k == Key.Up || (ctrl && k == Key.K)) ? -1 : 0;
            if (dir == 0) return;
            int n = menuItems.Count, s = menuSel;
            for (int t = 0; t < n; t++) { s = (s + dir + n) % n; if (!menuItems[s].Sep && menuItems[s].Enabled) break; }
            menuSel = s; MenuPaint();
        }
    }
}
