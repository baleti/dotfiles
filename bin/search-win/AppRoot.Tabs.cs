using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;

namespace SearchApp
{
    /// <summary>Search tabs: each tab keeps its query; switching restores it and searches again.</summary>
    public partial class AppRoot
    {
        public TabStrip Tabs; Grid TitleGrid; readonly List<string> tabQ = new List<string> { "" }; int tabCur;

        /// <summary>A tab's finished results, kept when leaving it so coming back is instant (slow queries are not recomputed).
        /// Only used while the tab's query is unchanged; if the index changed meanwhile the rows are refreshed in place.</summary>
        sealed class TabSnap { public string Sent; public Dictionary<int, List<Hit>> Pages; public long Total; public Stats Stats; public List<string> Errors; public bool AnyScore; public int Sel; public double Off; public long Ver; }
        readonly List<TabSnap> tabS = new List<TabSnap> { null };

        void SnapSave()
        {
            if (busy || fresh) { tabS[tabCur] = null; return; }
            tabS[tabCur] = new TabSnap { Sent = sent, Pages = new Dictionary<int, List<Hit>>(pages), Total = total, Stats = stats,
                Errors = new List<string>(errors), AnyScore = anyScore, Sel = sel, Off = List.Off, Ver = verSeen };
        }
        bool SnapRestore(int i)
        {
            var sn = tabS[i];
            if (sn == null || sn.Sent != tabQ[i]) return false;
            seq++; inflight.Clear();
            sent = sn.Sent; pages = new Dictionary<int, List<Hit>>(sn.Pages); total = sn.Total; stats = sn.Stats; errors = new List<string>(sn.Errors);
            anyScore = sn.AnyScore; busy = false; fresh = false; sel = sn.Sel; ClearSnips();
            List.Off = sn.Off; RenderAll(); UpdateStatus(); PaneUpdate();
            if (sn.Ver != ver) RefreshInPlace(); else verSeen = ver;
            return true;
        }

        void TabSync()
        {
            tabQ[tabCur] = q;
            Tabs.Titles.Clear(); Tabs.Titles.AddRange(tabQ); Tabs.Cur = tabCur;
            Tabs.Visibility = tabQ.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
            Tabs.InvalidateMeasure(); Tabs.InvalidateVisual();
            TitleGrid.Margin = new Thickness(0, tabQ.Count > 1 ? 24 : 0, 0, 0);
        }
        void TabLoad(int to)
        {
            tabCur = to; q = tabQ[to]; Q.SetText(q); if (!SnapRestore(to)) { Send(q); sel = -1; } TabSync(); FocusQuery(false);
        }
        public int TabCount { get { return tabQ.Count; } }
        public void TabSwitch(int to) { if (to < 0 || to >= tabQ.Count || to == tabCur) return; tabQ[tabCur] = q; SnapSave(); TabLoad(to); }
        public void TabNext(int d) { int n = tabQ.Count; if (n > 1) TabSwitch(((tabCur + d) % n + n) % n); }
        public void TabNew() { tabQ[tabCur] = q; SnapSave(); tabQ.Insert(tabCur + 1, ""); tabS.Insert(tabCur + 1, null); TabLoad(tabCur + 1); }
        public void TabClose(int i)
        {
            if (tabQ.Count < 2 || i < 0 || i >= tabQ.Count) return;
            tabQ[tabCur] = q; if (i != tabCur) SnapSave(); tabQ.RemoveAt(i); tabS.RemoveAt(i);
            TabLoad(Math.Max(0, Math.Min(i < tabCur ? tabCur - 1 : tabCur, tabQ.Count - 1)));
        }
        public void TabCloseCurrent() { TabClose(tabCur); }
    }
}
