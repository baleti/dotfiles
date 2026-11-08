using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shell;
using Microsoft.Win32;

namespace SearchApp
{
    public class MainWindow : Window, IHost
    {
        public AppRoot Root; readonly Config cfg; readonly Theme th;
        public MainWindow(Config c, Theme t, string initialQuery)
        {
            cfg = c; th = t;
            Title = "Search files"; WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.CanResize;
            MinWidth = 420; MinHeight = 240; Background = th.Bg;
            UseLayoutRounding = true; SnapsToDevicePixels = true;
            TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);
            WindowChrome.SetWindowChrome(this, new WindowChrome { CaptionHeight = 40, ResizeBorderThickness = new Thickness(6), GlassFrameThickness = new Thickness(0), CornerRadius = new CornerRadius(0), UseAeroCaptionButtons = false });
            var w = cfg.Window; Width = w.w; Height = w.h;
            if (!double.IsNaN(w.x) && !double.IsNaN(w.y) && OnScreen(w.x, w.y)) { WindowStartupLocation = WindowStartupLocation.Manual; Left = w.x; Top = w.y; }
            else WindowStartupLocation = WindowStartupLocation.CenterScreen;
            if (w.max) WindowState = WindowState.Maximized;
            Root = new AppRoot(cfg, th, this);
            Content = Root;
            try { Icon = BitmapFrame.Create(new Uri("pack://application:,,,/icon.ico")); } catch { }
            StateChanged += (s, e) => { AdjustMax(); Root.UpdateMaxIcon(); };
            PreviewKeyDown += Root.OnKey; PreviewTextInput += Root.OnTextInput;
            Closing += OnClosing;
            Loaded += async (s, e) =>
            {
                AdjustMax(); Root.UpdateMaxIcon();
                Root.FocusQuery(false);
                var f = Fonts.EnsureAsync(Root.Api);
                await Root.InitialAsync(initialQuery);
                Root.StartPolling();
                Root.FocusQuery(false);
            };
            Microsoft.Win32.SystemEvents.UserPreferenceChanged += (s, e) => Dispatcher.BeginInvoke(new Action(() => th.SetLight(Theme.WindowsLight())));
            th.Changed += () => Background = th.Bg;
        }
        static bool OnScreen(double x, double y) { return x > SystemParameters.VirtualScreenLeft - 50 && y > SystemParameters.VirtualScreenTop - 50 && x < SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth - 100 && y < SystemParameters.VirtualScreenTop + SystemParameters.VirtualScreenHeight - 100; }
        void AdjustMax() { Root.Margin = WindowState == WindowState.Maximized ? SystemParameters.WindowResizeBorderThickness : new Thickness(0); }
        void OnClosing(object s, System.ComponentModel.CancelEventArgs e)
        {
            var rb = RestoreBounds; cfg.Window.max = WindowState == WindowState.Maximized;
            if (!rb.IsEmpty) { cfg.Window.x = rb.Left; cfg.Window.y = rb.Top; cfg.Window.w = rb.Width; cfg.Window.h = rb.Height; }
            cfg.LastQuery = Root.q; cfg.Thumb = Root.Cols.Thumb; cfg.Save();
        }
        public void Minimize() { WindowState = WindowState.Minimized; }
        public void ToggleMax() { WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized; }
        public void CloseWindow() { Close(); }
        public bool IsMax { get { return WindowState == WindowState.Maximized; } }
        public Window Win { get { return this; } }
        public void NewWindow(string query)
        {
            try
            {
                var psi = new ProcessStartInfo(Process.GetCurrentProcess().MainModule.FileName) { UseShellExecute = false };
                if (!string.IsNullOrEmpty(query)) psi.Arguments = "\"" + query.Replace("\"", "\\\"") + "\"";
                Process.Start(psi);
            }
            catch { }
        }
    }
}
