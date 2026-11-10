using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shell;
using System.Windows.Threading;

namespace SearchApp
{
    public interface IHost
    {
        void Minimize(); void ToggleMax(); void CloseWindow(); bool IsMax { get; }
        void NewWindow(string query); Window Win { get; }
    }

    /// <summary>Keeps a child at most MaxW wide, left aligned.</summary>
    public class ClampPanel : Decorator
    {
        public double MaxW = 640;
        protected override Size MeasureOverride(Size a) { double w = Math.Min(MaxW, a.Width); if (Child != null) Child.Measure(new Size(w, a.Height)); return new Size(w, Child == null ? 0 : Child.DesiredSize.Height); }
        protected override Size ArrangeOverride(Size a) { double w = Math.Min(MaxW, a.Width); if (Child != null) Child.Arrange(new Rect(0, 0, w, a.Height)); return new Size(w, a.Height); }
    }

    /// <summary>The whole UI. Not tied to a visible window, so it can also be rendered offscreen (--shot).</summary>
    public partial class AppRoot : Grid
    {
        public Config Cfg; public Api Api; public Theme Th; public IHost Host;
        public ResultsView List; public HeaderView Hdr; public QueryBox Q; public ThumbCache Thumbs;
        public TextBlock StatusTb; public Canvas Overlay; public Border TitleLine; public Grid MainGrid;
        // ---- state (the page's S object) ----
        public string q = "", sent = ""; public int seq; public string cid = Guid.NewGuid().ToString("N").Substring(0, 10);
        public long total; public Stats stats; public List<string> errors = new List<string>();
        public Dictionary<int, List<Hit>> pages = new Dictionary<int, List<Hit>>(); Dictionary<int, int> inflight = new Dictionary<int, int>();
        public bool busy; public DateTime busySince = DateTime.UtcNow; public long ver = -1, verSeen = -1; bool fresh;
        public DateTime lastInput = DateTime.MinValue, lastRefresh = DateTime.MinValue;
        public List<string> hist = new List<string>(); public int hpos = -1; string hdraft = "";
        public int sel = -1; public string flash; DispatcherTimer flashT;
        bool anyScore; public bool listFocus;
        public Facets facets = new Facets();
        readonly DispatcherTimer debounce = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(280) };
        readonly DispatcherTimer spin = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(100) };
        readonly DispatcherTimer pollT = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        const string Spin = "⠋⠙⠹⠸⠼⠴⠦⠧";
        CaptionButton cbMax;

        public AppRoot(Config cfg, Theme th, IHost host)
        {
            Cfg = cfg; Th = th; Host = host; Api = new Api(cfg.Server);
            Thumbs = new ThumbCache(Api, Dispatcher);
            SnapsToDevicePixels = true; UseLayoutRounding = true;
            TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);
            BuildUi();
            Th.Changed += OnThemeChanged; Fonts.Changed += OnFontChanged;
            Thumbs.Loaded += () => List.InvalidateVisual();
            debounce.Tick += (s, e) => { debounce.Stop(); Send(q); };
            spin.Tick += (s, e) => { if (busy) UpdateStatus(); };
            spin.Start();
        }

        // ------------------------------------------------------------ layout
        void BuildUi()
        {
            RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto, MinHeight = 44 });
            RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

            // title row: query box in the title bar, caption buttons at the right
            var title = new Grid { Height = 40, VerticalAlignment = VerticalAlignment.Top };
            title.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            title.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            TitleLine = new Border { Margin = new Thickness(10, 0, 0, 0), BorderThickness = new Thickness(0, 0, 0, 1), Height = 40 };
            Q = new QueryBox(Th);
            var clamp = new ClampPanel { Child = Q, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(4, 0, 4, 0), VerticalAlignment = VerticalAlignment.Center, Height = 20 };
            WindowChrome.SetIsHitTestVisibleInChrome(Q, true);
            TitleLine.Child = clamp;
            title.Children.Add(TitleLine);
            var btns = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Top };
            Grid.SetColumn(btns, 1);
            var cbMin = new CaptionButton(Th, CaptionKind.Min, () => { if (Host != null) Host.Minimize(); });
            cbMax = new CaptionButton(Th, CaptionKind.Max, () => { if (Host != null) Host.ToggleMax(); });
            var cbClose = new CaptionButton(Th, CaptionKind.Close, () => { if (Host != null) Host.CloseWindow(); });
            foreach (var b in new[] { cbMin, cbMax, cbClose }) { WindowChrome.SetIsHitTestVisibleInChrome(b, true); btns.Children.Add(b); }
            title.Children.Add(btns);
            TitleGrid = title;
            Tabs = new TabStrip(Th) { Margin = new Thickness(10, 3, 0, 0), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
            Tabs.Visibility = Visibility.Collapsed; Tabs.Titles.Add(""); Tabs.Select = TabSwitch; Tabs.Close = TabClose; Tabs.New = TabNew;
            WindowChrome.SetIsHitTestVisibleInChrome(Tabs, true);
            SetRow(title, 0); Children.Add(title);
            SetRow(Tabs, 0); Children.Add(Tabs);

            Cols = new ColModel { Thumb = Cfg.Thumb, CW = Cfg.Cw, ShowOwner = Cfg.ShowOwner };
            Owners = new OwnerCache(Cfg, Dispatcher); Owners.Loaded += () => List.InvalidateVisual();
            Hdr = new HeaderView { Cols = Cols, Th = Th, Height = 18, Margin = new Thickness(10, 0, 10, 0) };
            SetRow(Hdr, 1); Children.Add(Hdr);

            List = new ResultsView { Cols = Cols, Th = Th, Thumbs = Thumbs, Owners = Owners, GetHit = Hit };
            MainGrid = new Grid { Margin = new Thickness(10, 0, 10, 0) };
            MainGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            MainGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            MainGrid.Children.Add(List);
            BuildPane();
            SetRow(MainGrid, 2); Children.Add(MainGrid);

            StatusTb = new TextBlock { FontSize = 11, Margin = new Thickness(10, 1, 10, 3), MinHeight = 17, TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap };
            SetRow(StatusTb, 3); Children.Add(StatusTb);

            Overlay = new Canvas { IsHitTestVisible = true };
            Overlay.Background = null;
            SetRow(Overlay, 0); SetRowSpan(Overlay, 4); Children.Add(Overlay);
            Overlay.IsHitTestVisible = false;

            WireEvents();
            ApplyThemeAll();
            ApplyFont();
            Hdr.Visibility = Visibility.Collapsed;
        }
        public static void SetRow(UIElement e, int r) { Grid.SetRow(e, r); }
        static void SetRowSpan(UIElement e, int r) { Grid.SetRowSpan(e, r); }
        public ColModel Cols; public OwnerCache Owners;

        void WireEvents()
        {
            List.NeedRange += (a, b) => NeedRange(a, b);
            List.RowClick += (i, n) => OnRowClick(i, n);
            List.RowRightClick += (i, p) => OnRowRightClick(i, p);
            List.ZoomWheel += dy => SetThumb(Cols.Thumb * Math.Exp(-dy / 400));
            List.ViewChanged += () => { Hdr.RightPad = List.Compute().Bar ? Const.Bar : 0; Hdr.InvalidateVisual(); };
            List.DragOut += i => OnDragOut(i);
            Hdr.SortClick += k => { q = Dsl.SetSort(q, k); Q.SetText(q); Send(q); };
            Hdr.Resized += () => List.InvalidateVisual();
            Hdr.WidthsChanged += () => { Cfg.Save(); };
            Q.UserChanged += OnQueryInput;
            Q.Box.GotKeyboardFocus += (s, e) => listFocus = false;   // the box has the keys, whatever the list was last told
            Q.Box.LostKeyboardFocus += (s, e) => Dispatcher.BeginInvoke(new Action(() => { if (!Q.IsFocusedBox) ClosePopups(); }), DispatcherPriority.Background);
        }

        void OnThemeChanged() { ApplyThemeAll(); }
        void OnFontChanged() { ApplyFont(); }
        public void ApplyFont()
        {
            StatusTb.FontFamily = Fonts.Family; Q.ApplyFont();
            List.ThemeChanged(); Hdr.ThemeChanged(); PaneFont();
            List.InvalidateVisual();
        }
        public void ApplyThemeAll()
        {
            Background = Th.Bg;
            TitleLine.BorderBrush = Th.Border;
            Q.ApplyTheme();
            List.ThemeChanged(); Hdr.ThemeChanged();
            foreach (var cb in Ui.Descendants<CaptionButton>(this)) cb.InvalidateVisual();
            UpdateStatus(); PaneTheme();
        }

        // ------------------------------------------------------------ data access
        public Hit Hit(int i)
        {
            List<Hit> p; if (!pages.TryGetValue(i / Const.Page, out p)) return null;
            int k = i % Const.Page; return k < p.Count ? p[k] : null;
        }
        public Hit Current { get { return sel >= 0 ? Hit(sel) : null; } }

        // ------------------------------------------------------------ searching
        public void Send(string query)
        {
            debounce.Stop();
            sent = query; seq++; busy = true; busySince = DateTime.UtcNow; verSeen = ver; fresh = true;
            inflight.Clear(); FetchPage(0, true); UpdateStatus();
        }
        public void RefreshInPlace()
        {
            seq++; lastRefresh = DateTime.UtcNow; verSeen = ver; fresh = false; inflight.Clear();
            var ps = new HashSet<int>(pages.Keys) { 0 };
            foreach (var p in ps) FetchPage(p, true);
        }
        async void FetchPage(int p, bool force)
        {
            int inf;
            if (fresh && p != 0 && !force) return;   // a new query is waiting for its first page: do not mix its later pages into the old rows
            if (!force && (pages.ContainsKey(p) || (inflight.TryGetValue(p, out inf) && inf == seq))) return;
            int mySeq = seq; string qq = sent; inflight[p] = mySeq;
            try
            {
                var r = await Api.Query(qq, p * Const.Page, Const.Page, cid, mySeq, CancellationToken.None);
                if (mySeq != seq || r.Stale) return;
                inflight.Remove(p);
                if (p == 0)
                {
                    if (fresh) { pages = new Dictionary<int, List<Hit>>(); sel = r.Count > 0 ? 0 : -1; List.Off = 0; fresh = false; ClearSnips(); }
                    total = r.Count; stats = r.Stats; errors = r.Errors; busy = false;
                    if (sel >= total) sel = (int)total - 1;
                }
                pages[p] = r.Results;
                anyScore = pages.Values.Any(l => l.Any(h => h.HasScore));
                RenderAll(); UpdateStatus(); PaneUpdate();
            }
            catch
            {
                if (mySeq != seq) return;
                inflight.Remove(p);
                if (p == 0) { busy = false; errors = new List<string> { "search server unreachable" }; UpdateStatus(); }
            }
        }
        void NeedRange(int a, int b)
        {
            for (int p = a / Const.Page; p <= b / Const.Page; p++) FetchPage(p, false);
        }

        public void RenderAll()
        {
            Cols.HasScore = anyScore; Cols.Thumb = Cols.Thumb;
            List.Total = total; List.Sel = sel; List.Terms = Dsl.QueryTerms(sent); List.ShowNone = !busy && total == 0;
            bool showHdr = !List.IsGrid && total > 0;
            Hdr.Query = sent.Length > 0 ? sent : q;
            Hdr.Visibility = showHdr ? Visibility.Visible : Visibility.Collapsed;
            Hdr.RightPad = List.Compute().Bar ? Const.Bar : 0;
            List.InvalidateVisual(); Hdr.InvalidateVisual();
        }

        // ------------------------------------------------------------ query box
        void OnQueryInput()
        {
            q = Q.Text; lastInput = DateTime.UtcNow; hpos = -1; if (Tabs != null && Tabs.Titles.Count > 1) TabSync();
            debounce.Stop(); debounce.Start();
            if (HP.Open) HpDraw();
            CpNarrow();
        }
        public void Remember(string query)
        {
            query = Dsl.NormQ(query);
            if (query.Length == 0 || (hist.Count > 0 && hist[0] == query)) return;
            hist.Insert(0, query); for (int i = hist.Count - 1; i > 0; i--) if (hist[i] == query) hist.RemoveAt(i);
            if (hist.Count > 500) hist.RemoveRange(500, hist.Count - 500);
            var t = Api.PostHistory(query); t.ContinueWith(x => { var _ = x.Exception; });
        }
        public async void LoadHist() { try { hist = await Api.History(CancellationToken.None); } catch { } }
        bool HistWalk(int dir)
        {
            if (dir < 0) { if (hpos < 0) hdraft = Q.Text; hpos = Math.Min(hist.Count - 1, hpos + 1); if (hpos < 0) return true; }
            else { if (hpos < 0) return false; hpos--; }
            Q.SetText(hpos < 0 ? hdraft : hist[hpos]); q = Q.Text; Send(q); return true;
        }
        public void FocusQuery(bool select) { listFocus = false; Q.FocusBox(); if (select) Q.SelectAll(); }

        // ------------------------------------------------------------ selection / zoom
        public void Select(int i, bool scroll = true)
        {
            if (i < 0 || i >= total) return;
            sel = i; List.Sel = i;
            if (scroll) List.EnsureVisible(i);
            List.InvalidateVisual(); PaneSoon();
        }
        void Move(int n) { if (total == 0) return; Select((int)Math.Max(0, Math.Min(total - 1, (sel < 0 ? 0 : sel) + (long)n))); }
        void OnRowClick(int i, int clicks)
        {
            listFocus = true; Keyboard.Focus(List); CloseMenu();
            Select(i, false);
            if (clicks == 2) OpenHit(i, false);
        }

        public void SetThumb(double v, double? focusY = null)
        {
            v = Math.Min(800, Math.Max(16, v)); if (Math.Abs(v - Cols.Thumb) < .01) return;
            var g0 = List.Compute(); double fy = focusY ?? g0.H / 2, at = (List.Off + fy) / g0.Stride * g0.Cols;
            Cols.Thumb = v; Cfg.Thumb = v;
            var g1 = List.Compute(); List.Off = Math.Max(0, at / g1.Cols * g1.Stride - fy);
            List.SetOff(List.Off);
            RenderAll(); Cfg.Save();
        }

        // ------------------------------------------------------------ status line
        public void Flash(string text, int ms)
        {
            flash = text; UpdateStatus();
            if (flashT != null) flashT.Stop();
            flashT = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(ms) };
            var t = flashT; t.Tick += (s, e) => { t.Stop(); if (flashT == t) { flash = null; UpdateStatus(); } };
            t.Start();
        }
        public string StatusText; public string StatusKind = "";
        public void UpdateStatus()
        {
            string txt; Brush b = Th.Dim; StatusKind = "";
            if (flash != null) txt = flash;
            else if (busy)
            {
                double t = (DateTime.UtcNow - busySince).TotalMilliseconds; b = Th.Accent; StatusKind = "busy";
                txt = Spin[(int)(t / 100) % 8] + " " + (Dsl.IsContent(sent) ? "searching file contents" : "searching") + "… " + (int)(t / 1000) + "s" + (total > 0 ? " · showing the previous results" : "");
            }
            else if (errors.Count > 0) { b = Th.Error; StatusKind = "err"; txt = string.Join("; ", errors); }
            else
            {
                var sb = new StringBuilder(Dsl.Digits(total) + " shown");
                if (stats != null && total > 0)
                {
                    sb.Append(" · " + (stats.Approx ? "≈ " : "") + Dsl.HSize(stats.Size));
                    if (!string.IsNullOrEmpty(stats.DMin) && !string.IsNullOrEmpty(stats.DMax)) sb.Append(stats.DMin == stats.DMax ? " · " + stats.DMin : " · " + stats.DMin + " → " + stats.DMax);
                    var k = stats.Kinds.Where(x => x.Key != "no ext").Select(x => x.Key + " " + Dsl.Digits(x.Value)).ToList();
                    if (k.Count > 0) sb.Append(" · " + string.Join(", ", k));
                }
                txt = sb.ToString();
            }
            if (Updater.Pending && flash == null && !busy && errors.Count == 0) txt += "   \u00b7   update installed: Ctrl+Shift+R to restart into it";
            StatusText = txt; StatusTb.Text = txt; StatusTb.Foreground = b;
        }

        // ------------------------------------------------------------ live refresh + theme poll
        public void StartPolling()
        {
            pollT.Tick += async (s, e) => await PollOnce();
            pollT.Start();
        }
        async Task PollOnce()
        {
            try
            {
                if (Updater.Check()) UpdateStatus();
                var j = await Api.Ver(CancellationToken.None);
                if (j.Theme != null) Th.Apply(j.Theme, false);
                if (j.Ver >= 0)
                {
                    bool first = ver < 0; ver = j.Ver;
                    if (first) verSeen = j.Ver;
                    else if (j.Ver != verSeen && !busy && (DateTime.UtcNow - lastInput).TotalMilliseconds > 1500 && (DateTime.UtcNow - lastRefresh).TotalMilliseconds > 2000) RefreshInPlace();
                }
            }
            catch { }
        }

        public async Task InitialAsync(string initialQuery)
        {
            q = initialQuery ?? ""; Q.SetText(q);
            try { var j = await Api.Ver(CancellationToken.None); if (j.Theme != null) Th.Apply(j.Theme, false); ver = j.Ver; } catch { }
            LoadFacets(); LoadHist();
            Send(q);
        }
        async void LoadFacets()
        {
            try
            {
                facets = await Api.GetFacets(CancellationToken.None);
                Dsl.AttrNames = facets.Attrs.Select(a => a.Name).Concat(facets.ExtraTags.Select(t => t[0])).ToList(); Q.Redraw();
            }
            catch { }
        }

        public void RestartApp()
        {
            if (Host == null) return;
            Host.NewWindow(Q.Text);   // the new process is the exe now on disk
            Host.CloseWindow();
        }
        public void UpdateMaxIcon() { if (cbMax != null) { cbMax.Restore = Host != null && Host.IsMax; cbMax.InvalidateVisual(); } }
    }

    public enum CaptionKind { Min, Max, Close }

    public class CaptionButton : FrameworkElement
    {
        readonly Theme th; readonly CaptionKind kind; readonly Action click; bool hot, down; public bool Restore;
        public CaptionButton(Theme t, CaptionKind k, Action c) { th = t; kind = k; click = c; Width = 46; Height = 40; }
        protected override void OnMouseEnter(MouseEventArgs e) { hot = true; InvalidateVisual(); }
        protected override void OnMouseLeave(MouseEventArgs e) { hot = false; down = false; InvalidateVisual(); }
        protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e) { down = true; CaptureMouse(); e.Handled = true; }
        protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
        {
            bool was = down; down = false; if (IsMouseCaptured) ReleaseMouseCapture();
            if (was && IsMouseOver && click != null) click();
            e.Handled = true;
        }
        protected override void OnRender(DrawingContext dc)
        {
            bool close = kind == CaptionKind.Close;
            Brush bg = hot ? (close ? new SolidColorBrush(Color.FromRgb(0xc4, 0x2b, 0x1c)) : Ui.Alpha(th.TextC, down ? .16 : .10)) : Brushes.Transparent;
            dc.DrawRectangle(bg, null, new Rect(0, 0, 46, 40));
            Brush fg = hot && close ? Brushes.White : th.Text; var pen = Ui.P(fg, 1);
            double cx = 23, cy = 20;
            switch (kind)
            {
                case CaptionKind.Min: dc.DrawLine(pen, new Point(cx - 5, cy + .5), new Point(cx + 5, cy + .5)); break;
                case CaptionKind.Max:
                    if (Restore) { dc.DrawRectangle(null, pen, new Rect(cx - 4.5, cy - 2.5, 7, 7)); dc.DrawLine(pen, new Point(cx - 2.5, cy - 4.5), new Point(cx + 4.5, cy - 4.5)); dc.DrawLine(pen, new Point(cx + 4.5, cy - 4.5), new Point(cx + 4.5, cy + 2.5)); }
                    else dc.DrawRectangle(null, pen, new Rect(cx - 4.5, cy - 4.5, 9, 9));
                    break;
                default: dc.DrawLine(pen, new Point(cx - 5, cy - 5), new Point(cx + 5, cy + 5)); dc.DrawLine(pen, new Point(cx - 5, cy + 5), new Point(cx + 5, cy - 5)); break;
            }
        }
    }
}
