using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace SearchApp
{
    /// <summary>Async thumbnail loader with an LRU of decoded, frozen images and the page's retry rules for pending thumbnails.</summary>
    public class ThumbCache
    {
        class Entry { public int N; public bool Loading, Dead; public DateTime Next = DateTime.MinValue; public long Wanted; }
        readonly Api api; readonly Dispatcher disp;
        readonly Dictionary<string, ImageSource> imgs = new Dictionary<string, ImageSource>();
        readonly LinkedList<string> order = new LinkedList<string>();
        readonly Dictionary<string, LinkedListNode<string>> nodes = new Dictionary<string, LinkedListNode<string>>();
        readonly Dictionary<string, Entry> ent = new Dictionary<string, Entry>();
        readonly SemaphoreSlim gate = new SemaphoreSlim(6);
        public event Action Loaded;
        public int Capacity = 900;
        public int Requests;

        public ThumbCache(Api api, Dispatcher d) { this.api = api; disp = d; }

        static int Bucket(double px)
        {
            int b = 32; while (b < px && b < 1024) b *= 2; return b;
        }

        public void Clear() { imgs.Clear(); order.Clear(); nodes.Clear(); ent.Clear(); }

        /// <summary>Cached image or null (a load is started when needed). px = displayed size in device pixels.</summary>
        public ImageSource Get(Hit h, double px)
        {
            if (string.IsNullOrEmpty(h.Thumb)) return null;
            int bucket = Bucket(px);
            string key = h.Thumb + "@" + bucket;
            ImageSource im;
            if (imgs.TryGetValue(key, out im))
            {
                var n = nodes[key]; order.Remove(n); order.AddFirst(n);
                return im;
            }
            Entry e; if (!ent.TryGetValue(key, out e)) ent[key] = e = new Entry();
            e.Wanted = Environment.TickCount;
            if (e.Loading || e.Dead || DateTime.UtcNow < e.Next) return null;
            e.Loading = true;
            Load(key, h, bucket, e);
            return null;
        }

        async void Load(string key, Hit h, int bucket, Entry e)
        {
            ImageSource result = null; bool cancelled = false;
            await gate.WaitAsync().ConfigureAwait(false);
            try
            {
                if (Environment.TickCount - e.Wanted > 1500) { cancelled = true; }
                else
                {
                    Interlocked.Increment(ref Requests);
                    string url = h.Thumb + (e.N > 0 ? "&r=" + e.N : "");
                    var bytes = await api.GetBytes(url, CancellationToken.None).ConfigureAwait(false);
                    result = Decode(bytes, bucket);
                }
            }
            catch { result = null; }
            finally { gate.Release(); }
            disp.BeginInvoke(new Action(() =>
            {
                e.Loading = false;
                if (cancelled) return;
                if (result != null) { Store(key, result); if (Loaded != null) Loaded(); return; }
                if (!h.Pending || ++e.N > 90) { e.Dead = true; return; }
                int delay = e.N < 5 ? 1000 : 2500;
                e.Next = DateTime.UtcNow.AddMilliseconds(delay);
                var t = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(delay + 20) };
                t.Tick += (s, a) => { t.Stop(); if (Loaded != null) Loaded(); };
                t.Start();
            }));
        }

        static ImageSource Decode(byte[] bytes, int bucket)
        {
            var bi = new BitmapImage();
            bi.BeginInit();
            bi.CacheOption = BitmapCacheOption.OnLoad;
            if (bucket < 256) bi.DecodePixelWidth = bucket;
            bi.StreamSource = new MemoryStream(bytes);
            bi.EndInit();
            bi.Freeze();
            return bi;
        }

        void Store(string key, ImageSource im)
        {
            imgs[key] = im; nodes[key] = order.AddFirst(key);
            while (order.Count > Capacity) { var last = order.Last; order.RemoveLast(); imgs.Remove(last.Value); nodes.Remove(last.Value); }
        }
    }
}
