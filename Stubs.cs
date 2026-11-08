using System;
using System.Windows;
namespace SearchApp
{
    public partial class AppRoot
    {
        void BuildPane() { }
        void PaneFont() { }
        void PaneTheme() { }
        void PaneUpdate() { }
        void PaneSoon() { }
        void ClearSnips() { }
        void CloseMenu() { }
        void OpenHit(int i, bool dry) { }
        void OnRowRightClick(int i, Point p) { }
        void OnDragOut(int i) { }
        void CpNarrow() { }
        void HpDraw() { }
        class PopState { public bool Open; }
        PopState HP = new PopState();
    }
}
namespace SearchApp
{
    public partial class AppRoot
    {
        public void OnKey(object s, System.Windows.Input.KeyEventArgs e) { }
        public void OnTextInput(object s, System.Windows.Input.TextCompositionEventArgs e) { }
        public void ShotAction(string a) { }
    }
}
