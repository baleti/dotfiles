using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace SearchApp
{
    public partial class AppRoot
    {
        static bool Mod(ModifierKeys m) { return (Keyboard.Modifiers & m) != 0; }

        /// <summary>Printable key while the list has focus: the text goes to the query box.</summary>
        public void OnTextInput(object s, TextCompositionEventArgs e)
        {
            if (SettingsOpen || MenuOpen || Q.IsFocusedBox || string.IsNullOrEmpty(e.Text) || e.Text[0] < ' ') return;
            if (Mod(ModifierKeys.Control) || Mod(ModifierKeys.Alt)) return;
            if (Keyboard.FocusedElement is TextBox) return;
            FocusQuery(false);
            Q.Box.SelectedText = e.Text; Q.Box.CaretIndex = Q.Box.SelectionStart + Q.Box.SelectionLength;
            e.Handled = true;
        }

        public void OnKey(object sender, KeyEventArgs e)
        {
            Key k = e.Key == Key.System ? e.SystemKey : (e.Key == Key.ImeProcessed ? e.ImeProcessedKey : e.Key);
            bool ctrl = Mod(ModifierKeys.Control), alt = Mod(ModifierKeys.Alt), shift = Mod(ModifierKeys.Shift);
            // settings panel: Ctrl+P toggles, Esc closes, everything else belongs to the panel's own controls
            if (ctrl && !alt && !shift && k == Key.P) { e.Handled = true; if (SettingsOpen) CloseSettings(); else OpenSettings(); return; }
            if (SettingsOpen) { if (k == Key.Escape) { e.Handled = true; CloseSettings(); } return; }
            if (MenuOpen) { MenuKey(k, ctrl, e); return; }
            lastInput = DateTime.UtcNow;
            if (k == Key.Escape && dlCts != null) { dlCts.Cancel(); e.Handled = true; return; }
            if (ctrl && !alt)
            {
                if (k == Key.OemPlus || k == Key.Add) { e.Handled = true; SetThumb(Cols.Thumb * 1.15); return; }
                if (k == Key.OemMinus || k == Key.Subtract) { e.Handled = true; SetThumb(Cols.Thumb / 1.15); return; }
                if (k == Key.D0 || k == Key.NumPad0) { e.Handled = true; SetThumb(16); return; }
                if (k == Key.D9 || k == Key.NumPad9) { e.Handled = true; SetThumb(320); return; }
                if (k == Key.R && shift) { e.Handled = true; RestartApp(); return; }
                if (k == Key.T && !shift) { e.Handled = true; TabNew(); return; }
                if (k == Key.Tab) { e.Handled = true; TabNext(shift ? -1 : 1); return; }
                if (k == Key.W && !shift) { e.Handled = true; if (TabCount > 1) TabCloseCurrent(); else if (Host != null) Host.CloseWindow(); return; }
                if (k == Key.N) { e.Handled = true; if (Host != null) Host.NewWindow(Q.Text); return; }
            }
            bool inQ = Q.IsFocusedBox;
            if (((ctrl && !alt && k == Key.R) || k == Key.F4) && !inQ) { e.Handled = true; FocusQuery(false); HpOpen(); return; }
            if (alt && !ctrl && k == Key.D) { e.Handled = true; FocusQuery(true); return; }
            int cols = List.Compute().Cols;
            if (inQ)
            {
                bool tab = k == Key.Tab && !shift, cs = ctrl && k == Key.Space;
                if (HP.Open)
                {
                    int n = HP.M.Count;
                    if (k == Key.Escape) { e.Handled = true; HpClose(); return; }
                    if (tab) { e.Handled = true; HP.Picked = true; HpAccept(); return; }
                    if (k == Key.Enter || (k == Key.Space && HP.Picked && !ctrl && !alt)) { e.Handled = true; HpAccept(); return; }
                    if (k == Key.Down || (ctrl && k == Key.J)) { e.Handled = true; if (n > 0) { if (HP.Picked) HP.Sel = Math.Min(HP.Sel + 1, n - 1); else { HP.Picked = true; HP.Sel = 0; } } HpDraw(); return; }
                    if (k == Key.Up || (ctrl && k == Key.K)) { e.Handled = true; if (HP.Picked) HP.Sel = Math.Max(0, HP.Sel - 1); HpDraw(); return; }
                }
                if ((ctrl && !alt && k == Key.R) || k == Key.F4) { e.Handled = true; HpOpen(); return; }
                if (ctrl && !alt && k == Key.E) { e.Handled = true; Q.CaretIndex = Q.Text.Length; return; }
                if (CP.Open)
                {
                    int n = CP.Cands.Count;
                    if (k == Key.Escape) { e.Handled = true; CpClose(); return; }
                    if (k == Key.Enter || tab || (k == Key.Space && !ctrl && !alt)) { e.Handled = true; CpAccept(); return; }
                    if (k == Key.Down || (ctrl && k == Key.J)) { e.Handled = true; CP.Sel = (CP.Sel + 1) % n; CpDraw(); return; }
                    if (k == Key.Up || (ctrl && k == Key.K)) { e.Handled = true; CP.Sel = (CP.Sel + n - 1) % n; CpDraw(); return; }
                    if (cs)
                    {
                        e.Handled = true;
                        if (CP.Multi == null) { var tmp = new List<Cand>(); CP.Multi = Dsl.Completions(Q.Text, facets, hist, tmp); }
                        if (!Q.Text.EndsWith(" ")) { Q.Box.Text += " "; Q.CaretIndex = Q.Text.Length; }
                        return;
                    }
                }
                else if (tab || cs) { e.Handled = true; CpStart(); return; }
                if (k == Key.Enter) { e.Handled = true; debounce.Stop(); q = Q.Text; Remember(q); Send(q); return; }
                if (k == Key.Up || (ctrl && k == Key.K)) { e.Handled = true; HistWalk(-1); return; }
                if (k == Key.Down || (ctrl && k == Key.J))
                {
                    e.Handled = true;
                    if (hpos >= 0) { HistWalk(1); return; }
                    if (total > 0) { listFocus = true; Keyboard.Focus(List); Remember(Q.Text); Select(sel < 0 ? 0 : sel); }
                    return;
                }
                return;
            }
            // list focus (or nothing focused)
            if (k == Key.Tab || k == Key.Escape) { e.Handled = true; FocusQuery(false); return; }
            if (ctrl && k == Key.C && !(Keyboard.FocusedElement is TextBox)) { e.Handled = true; var r = Current; if (r != null) { CopyText(r.Path); Flash("copied path", 1500); } return; }
            if (k == Key.Apps || (shift && k == Key.F10)) { e.Handled = true; if (sel >= 0) ShowMenuForSelection(); return; }
            if (Keyboard.FocusedElement is TextBox) return;
            bool h = true;
            if (k == Key.Down || (ctrl && k == Key.J)) Move(cols);
            else if (k == Key.Up || (ctrl && k == Key.K)) Move(-cols);
            else if (k == Key.Right || (ctrl && k == Key.L)) Move(1);
            else if (k == Key.Left || (ctrl && k == Key.H)) Move(-1);
            else if (k == Key.PageDown) { var g = List.Compute(); Move(Math.Max(1, (int)Math.Floor(g.H / g.Stride) - 1) * cols); }
            else if (k == Key.PageUp) { var g = List.Compute(); Move(-Math.Max(1, (int)Math.Floor(g.H / g.Stride) - 1) * cols); }
            else if (k == Key.Home) Select(0);
            else if (k == Key.End) Select((int)total - 1);
            else if (k == Key.Enter) OpenHit(sel, false);
            else h = false;
            if (h) e.Handled = true;
        }

        public static void CopyText(string s) { try { Clipboard.SetText(s); } catch { try { System.Threading.Thread.Sleep(50); Clipboard.SetText(s); } catch { } } }
    }
}
