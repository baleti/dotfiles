using System;
using System.Collections.Generic;

namespace SearchApp
{
    /// <summary>Search tabs: each tab keeps its query; switching restores it and searches again.</summary>
    public partial class AppRoot
    {
        public TabStrip Tabs; readonly List<string> tabQ = new List<string> { "" }; int tabCur;

        void TabSync()
        {
            tabQ[tabCur] = q;
            Tabs.Titles.Clear(); Tabs.Titles.AddRange(tabQ); Tabs.Cur = tabCur;
            Tabs.InvalidateMeasure(); Tabs.InvalidateVisual();
        }
        void TabLoad(int to)
        {
            tabCur = to; q = tabQ[to]; Q.SetText(q); Send(q); sel = -1; TabSync(); FocusQuery(false);
        }
        public int TabCount { get { return tabQ.Count; } }
        public void TabSwitch(int to) { if (to < 0 || to >= tabQ.Count || to == tabCur) return; tabQ[tabCur] = q; TabLoad(to); }
        public void TabNext(int d) { int n = tabQ.Count; if (n > 1) TabSwitch(((tabCur + d) % n + n) % n); }
        public void TabNew() { tabQ[tabCur] = q; tabQ.Insert(tabCur + 1, ""); TabLoad(tabCur + 1); }
        public void TabClose(int i)
        {
            if (tabQ.Count < 2 || i < 0 || i >= tabQ.Count) return;
            tabQ[tabCur] = q; tabQ.RemoveAt(i);
            TabLoad(Math.Max(0, Math.Min(i < tabCur ? tabCur - 1 : tabCur, tabQ.Count - 1)));
        }
        public void TabCloseCurrent() { TabClose(tabCur); }
    }
}
