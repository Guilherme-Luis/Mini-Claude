// Clawd Pet - native helpers (see each class comment).
// Compiled into Clawd.exe by build.ps1; when clawd-pet.ps1 runs as a plain script it compiles this
// file once with Add-Type and caches the DLL (%LOCALAPPDATA%\ClawdPet\cache), so a launch never
// waits for the C# compiler again. C# 5 only (the compiler that ships with Windows).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

// Animation frame cache: every GIF frame is decoded and scaled ONCE to the exact size it is drawn
// at, so a frame costs a tiny 1:1 copy instead of scaling a 2750x1850 canvas.
public static class ClawdFrames {
    public static int Count(Image img) {
        try { return Math.Max(1, img.GetFrameCount(new FrameDimension(img.FrameDimensionsList[0]))); }
        catch { return 1; }
    }
    // Per-frame delays in ms (GIF stores centiseconds; 0/1 cs means "default", like browsers: 100 ms)
    public static int[] Delays(Image img) {
        int n = Count(img);
        int[] d = new int[n];
        byte[] raw = null;
        try { raw = img.GetPropertyItem(0x5100).Value; } catch { }
        for (int i = 0; i < n; i++) {
            int cs = (raw != null && raw.Length >= i * 4 + 4) ? BitConverter.ToInt32(raw, i * 4) : 10;
            d[i] = cs <= 1 ? 100 : cs * 10;
        }
        return d;
    }
    public static Bitmap[] Extract(Image img, Rectangle src, int dw, int dh, bool smooth) {
        int n = Count(img);
        var fd = new FrameDimension(img.FrameDimensionsList[0]);
        var list = new Bitmap[n];
        for (int f = 0; f < n; f++) {
            if (n > 1) img.SelectActiveFrame(fd, f);
            var bmp = new Bitmap(Math.Max(1, dw), Math.Max(1, dh), PixelFormat.Format32bppPArgb);
            using (var g = Graphics.FromImage(bmp)) {
                g.InterpolationMode = smooth ? System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic
                                             : System.Drawing.Drawing2D.InterpolationMode.NearestNeighbor;
                g.PixelOffsetMode = smooth ? System.Drawing.Drawing2D.PixelOffsetMode.HighQuality
                                           : System.Drawing.Drawing2D.PixelOffsetMode.Half;
                g.DrawImage(img, new Rectangle(0, 0, dw, dh), src, GraphicsUnit.Pixel);
            }
            list[f] = bmp;
        }
        if (n > 1) img.SelectActiveFrame(fd, 0);
        return list;
    }
    // Width/height straight from the GIF/PNG header - no need to decode a 2750x1850 image for it.
    public static Size ImageSize(string path) {
        try {
            using (var s = File.OpenRead(path)) {
                var b = new byte[24];
                int r = s.Read(b, 0, 24);
                if (r >= 10 && b[0] == 'G' && b[1] == 'I' && b[2] == 'F') return new Size(b[6] | (b[7] << 8), b[8] | (b[9] << 8));
                if (r >= 24 && b[0] == 0x89 && b[1] == 'P' && b[2] == 'N' && b[3] == 'G')
                    return new Size((b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19], (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23]);
            }
        } catch { }
        using (var img = Image.FromFile(path)) return img.Size;
    }
    // Re-time a GIF onto the display-frame grid. GIF delays are whole centiseconds, so a 12 fps
    // animation is stored as 80/90/80 ms and a 30 fps one as 30/30/40 ms: played literally they land
    // unevenly on 60 Hz frames (a frame held 2 then 3 then 2 frames = judder). Each frame becomes a
    // whole number of 'base' periods (base = the most common delay, in display frames), so the
    // cadence is perfectly even and holds stay multiples of it. Returns cumulative ms; div = base.
    public static double[] Snap(int[] delays, double frameMs, out int div) {
        var counts = new Dictionary<int, int>();
        int common = delays[0], best = 0;
        foreach (int d in delays) {
            int c; counts.TryGetValue(d, out c); counts[d] = ++c;
            if (c > best) { best = c; common = d; }
        }
        int q = Math.Max(1, (int)Math.Round(common / frameMs));
        var cum = new double[delays.Length];
        long frames = 0;
        for (int i = 0; i < delays.Length; i++) {
            frames += q * Math.Max(1, (int)Math.Round(delays[i] / (q * frameMs)));
            cum[i] = frames * frameMs;
        }
        div = q;
        return cum;
    }
    // The same grid with every frame lasting exactly 'frames' display frames (custom tempo)
    public static double[] Uniform(int n, int frames, double frameMs) {
        var cum = new double[n];
        for (int i = 0; i < n; i++) cum[i] = (i + 1) * frames * frameMs;
        return cum;
    }
    // Largest divisor of n that is <= max (a render rate that still lands on every frame change)
    public static int DivisorAtMost(int n, int max) {
        for (int d = Math.Min(n, max); d > 1; d--) if (n % d == 0) return d;
        return 1;
    }
    // Frame index for a looping animation 'ms' milliseconds after it started (cum = running end times)
    public static int Index(double[] cum, double ms) {
        double total = cum[cum.Length - 1];
        if (total <= 0) return 0;
        double t = ms % total;
        if (t < 0) t += total;
        for (int i = 0; i < cum.Length; i++) if (t < cum[i]) return i;
        return cum.Length - 1;
    }
    // Shell colour swap: only the coral body hues move (keeping their shading offset), so the eyes,
    // the chef hat, the laptop, the pan etc. keep their own colours. hue < 0 = plain copy.
    public static Bitmap Recolor(Bitmap src, double hue, double satMul, double valMul) {
        var r = new Rectangle(0, 0, src.Width, src.Height);
        var dst = new Bitmap(src.Width, src.Height, PixelFormat.Format32bppPArgb);
        var sd = src.LockBits(r, ImageLockMode.ReadOnly, PixelFormat.Format32bppPArgb);
        int n = sd.Stride * src.Height;
        byte[] d = new byte[n];
        Marshal.Copy(sd.Scan0, d, 0, n);
        src.UnlockBits(sd);
        if (hue >= 0) {
            for (int i = 0; i < n; i += 4) {
                int a = d[i + 3];
                if (a == 0) continue;
                double b = d[i] * 255.0 / a, g = d[i + 1] * 255.0 / a, rr = d[i + 2] * 255.0 / a;
                double mx = Math.Max(rr, Math.Max(g, b)), mn = Math.Min(rr, Math.Min(g, b));
                double v = mx / 255.0, s = mx <= 0 ? 0 : (mx - mn) / mx;
                if (s < 0.25 || v < 0.3) continue;
                double h;
                double c = mx - mn;
                if (mx == rr) h = 60 * (((g - b) / c) % 6); else if (mx == g) h = 60 * ((b - rr) / c + 2); else h = 60 * ((rr - g) / c + 4);
                if (h < 0) h += 360;
                if (!(h <= 50 || h >= 340)) continue;          // not part of the coral shell
                double off = (h > 180 ? h - 360 : h) - 15;      // shading offset from the base coral
                double nh = (hue + off + 360) % 360;
                double ns = Math.Min(1, s * satMul), nv = Math.Min(1, v * valMul);
                double cc = nv * ns, x = cc * (1 - Math.Abs((nh / 60) % 2 - 1)), m = nv - cc;
                double r1 = 0, g1 = 0, b1 = 0;
                if (nh < 60) { r1 = cc; g1 = x; } else if (nh < 120) { r1 = x; g1 = cc; } else if (nh < 180) { g1 = cc; b1 = x; }
                else if (nh < 240) { g1 = x; b1 = cc; } else if (nh < 300) { r1 = x; b1 = cc; } else { r1 = cc; b1 = x; }
                d[i]     = (byte)Math.Round((b1 + m) * a);
                d[i + 1] = (byte)Math.Round((g1 + m) * a);
                d[i + 2] = (byte)Math.Round((r1 + m) * a);
            }
        }
        var dd = dst.LockBits(r, ImageLockMode.WriteOnly, PixelFormat.Format32bppPArgb);
        Marshal.Copy(d, 0, dd.Scan0, n);
        dst.UnlockBits(dd);
        return dst;
    }
}

// Disk cache of the pre-scaled frames. Decoding the 2750x1850 official GIFs and scaling ~500 frames
// took ~4 s on every start; now that happens once per asset and size. An entry's key holds the
// source file's size and time stamp plus every parameter that shapes the result, so an edited
// asset, another size or a new processing version simply misses and is rebuilt.
public static class ClawdCache {
    public static string Dir;            // null = caching off
    const int Version = 1;               // bump when frame processing changes
    const int Magic = 0x44574C43;        // "CLWD"
    public static string Key(string path, params object[] parts) {
        var fi = new FileInfo(path);
        return Version + "|" + fi.Name + "|" + fi.Length + "|" + fi.LastWriteTimeUtc.Ticks + "|" + string.Join("|", parts);
    }
    static string FileFor(string key) {
        using (var md5 = System.Security.Cryptography.MD5.Create())
            return Path.Combine(Dir, BitConverter.ToString(md5.ComputeHash(Encoding.UTF8.GetBytes(key))).Replace("-", "") + ".frames");
    }
    public static bool TryLoad(string key, out Bitmap[] frames, out int[] meta) {
        frames = null; meta = null;
        if (Dir == null) return false;
        string f = FileFor(key);
        if (!File.Exists(f)) return false;
        try {
            using (var gz = new GZipStream(File.OpenRead(f), CompressionMode.Decompress))
            using (var br = new BinaryReader(gz)) {
                if (br.ReadInt32() != Magic) throw new InvalidDataException();
                int n = br.ReadInt32(), w = br.ReadInt32(), h = br.ReadInt32(), m = br.ReadInt32();
                meta = new int[m];
                for (int i = 0; i < m; i++) meta[i] = br.ReadInt32();
                frames = new Bitmap[n];
                int row = w * 4;
                for (int i = 0; i < n; i++) {
                    byte[] px = br.ReadBytes(row * h);
                    if (px.Length != row * h) throw new InvalidDataException();
                    var bmp = new Bitmap(w, h, PixelFormat.Format32bppPArgb);
                    var bd = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, PixelFormat.Format32bppPArgb);
                    for (int y = 0; y < h; y++) Marshal.Copy(px, y * row, new IntPtr(bd.Scan0.ToInt64() + (long)y * bd.Stride), row);
                    bmp.UnlockBits(bd);
                    frames[i] = bmp;
                }
            }
            return true;
        } catch {
            if (frames != null) foreach (var b in frames) if (b != null) b.Dispose();
            frames = null; meta = null;
            try { File.Delete(f); } catch { }
            return false;
        }
    }
    public static void Save(string key, Bitmap[] frames, int[] meta) {
        if (Dir == null) return;
        try {
            Directory.CreateDirectory(Dir);
            string f = FileFor(key), tmp = f + "." + Process.GetCurrentProcess().Id + ".tmp";
            int w = frames.Length > 0 ? frames[0].Width : 0, h = frames.Length > 0 ? frames[0].Height : 0;
            using (var gz = new GZipStream(File.Create(tmp), CompressionLevel.Fastest))
            using (var bw = new BinaryWriter(gz)) {
                bw.Write(Magic); bw.Write(frames.Length); bw.Write(w); bw.Write(h); bw.Write(meta.Length);
                foreach (int v in meta) bw.Write(v);
                int row = w * 4;
                byte[] px = new byte[row * h];
                foreach (var bmp in frames) {
                    var bd = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppPArgb);
                    for (int y = 0; y < h; y++) Marshal.Copy(new IntPtr(bd.Scan0.ToInt64() + (long)y * bd.Stride), px, y * row, row);
                    bmp.UnlockBits(bd);
                    bw.Write(px);
                }
            }
            if (File.Exists(f)) File.Delete(f);
            File.Move(tmp, f);
        } catch { }
    }
    // A GIF's frames scaled to dw x dh (+ its delays in ms), from the cache when possible
    public static Bitmap[] LoadAnim(string path, Rectangle src, int dw, int dh, bool smooth, out int[] delays) {
        string key = Key(path, "anim", src.X, src.Y, src.Width, src.Height, dw, dh, smooth);
        Bitmap[] frames;
        if (TryLoad(key, out frames, out delays)) return frames;
        using (var img = Image.FromFile(path)) {
            frames = ClawdFrames.Extract(img, src, dw, dh, smooth);
            delays = ClawdFrames.Delays(img);
        }
        Save(key, frames, delays);
        return frames;
    }
    // Asset validation (a full decode) is remembered per file version: a known-good file is not re-checked
    public static bool IsKnownGood(string path) { return Dir != null && File.Exists(path) && File.Exists(FileFor(Key(path, "valid"))); }
    public static void MarkGood(string path) { Save(Key(path, "valid"), new Bitmap[0], new int[0]); }
}

// List of visible app windows -> platform footings (their top edge).
// Format: [hwnd, left, top, right, bottom] per window, ordered by z-order (topmost first).
public static class ClawdWin {
    private delegate bool EnumProc(IntPtr h, IntPtr lp);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr lp);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] private static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr h, int idx);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT rect, int size);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int val, int size);
    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int L, T, R, B; }
    public static long[] PlatformsArr(long selfHwnd) {
        var list = new List<long>();
        EnumWindows(delegate(IntPtr h, IntPtr lp) {
            if ((long)h == selfHwnd) return true;
            if (!IsWindowVisible(h) || IsIconic(h)) return true;
            if (GetWindowTextLength(h) == 0) return true;
            if ((GetWindowLong(h, -20) & 0x80) != 0) return true;   // WS_EX_TOOLWINDOW
            int cloaked;
            if (DwmGetWindowAttribute(h, 14, out cloaked, 4) == 0 && cloaked != 0) return true;
            RECT r;
            if (DwmGetWindowAttribute(h, 9, out r, Marshal.SizeOf(typeof(RECT))) != 0) return true;
            if (r.R - r.L < 120 || r.B - r.T < 80) return true;
            list.Add((long)h); list.Add(r.L); list.Add(r.T); list.Add(r.R); list.Add(r.B);
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }
    public static int[] GetRect(long h) {
        if (!IsWindowVisible((IntPtr)h) || IsIconic((IntPtr)h)) return null;
        int cloaked;
        if (DwmGetWindowAttribute((IntPtr)h, 14, out cloaked, 4) == 0 && cloaked != 0) return null;
        RECT r;
        if (DwmGetWindowAttribute((IntPtr)h, 9, out r, Marshal.SizeOf(typeof(RECT))) != 0) return null;
        return new int[] { r.L, r.T, r.R, r.B };
    }
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint flags);
    // Move a window by a few pixels (for Clawd window-tugging mischief)
    public static void Nudge(long h, int dx, int dy) {
        RECT wr;
        if (!GetWindowRect((IntPtr)h, out wr)) return;
        SetWindowPos((IntPtr)h, IntPtr.Zero, wr.L + dx, wr.T + dy, 0, 0, 0x0001 | 0x0004 | 0x0010);   // NOSIZE|NOZORDER|NOACTIVATE
    }
    // Move a window to (x, y) without touching its size, z-order or focus
    public static void MoveTo(IntPtr h, int x, int y) { SetWindowPos(h, IntPtr.Zero, x, y, 0, 0, 0x0001 | 0x0004 | 0x0010); }
    [DllImport("user32.dll", CharSet = CharSet.Auto)] private static extern int GetClassName(IntPtr h, System.Text.StringBuilder sb, int max);
    // Foreground window covers the whole screen (fullscreen/borderless game)?
    public static bool IsFullscreenForeground(int bL, int bT, int bR, int bB) {
        IntPtr h = GetForegroundWindow();
        if (h == IntPtr.Zero) return false;
        var sb = new System.Text.StringBuilder(64);
        GetClassName(h, sb, 64);
        string c = sb.ToString();
        if (c == "Progman" || c == "WorkerW" || c == "Shell_TrayWnd") return false;   // the desktop/taskbar itself
        RECT r;
        if (!GetWindowRect(h, out r)) return false;
        return r.L <= bL && r.T <= bT && r.R >= bR && r.B >= bB;
    }
    // Return unused pages to the OS (lightens the reported working set in the background).
    [DllImport("psapi.dll")] private static extern bool EmptyWorkingSet(IntPtr h);
    [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
    public static void TrimMemory() { EmptyWorkingSet(GetCurrentProcess()); }
    // Give the right-click menu the foreground. The pet window is WS_EX_NOACTIVATE, so the
    // menu opens without activation and WinForms never sees the "click outside" that would
    // dismiss it. Foregrounding the menu restores normal click-away-to-close behavior.
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr h);
    public static void SetForeground(long h) { SetForegroundWindow((IntPtr)h); }
    // Free the HICON behind a tray icon made with Bitmap.GetHicon()
    [DllImport("user32.dll")] private static extern bool DestroyIcon(IntPtr h);
    public static void FreeIcon(IntPtr h) { if (h != IntPtr.Zero) DestroyIcon(h); }
    // Refresh rate of the primary display (Hz), 0 if unknown
    [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")] private static extern int GetDeviceCaps(IntPtr dc, int idx);
    public static int RefreshRate() {
        IntPtr dc = GetDC(IntPtr.Zero);
        try { return GetDeviceCaps(dc, 116); } finally { ReleaseDC(IntPtr.Zero, dc); }   // VREFRESH
    }
}

// Detect a keyboard key press (mouse buttons excluded) + how long the user has been idle.
public static class ClawdInput {
    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);
    [StructLayout(LayoutKind.Sequential)]
    private struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")]
    private static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    [DllImport("kernel32.dll")]
    private static extern uint GetTickCount();
    public static bool AnyKeyDown() {
        for (int vk = 0x08; vk <= 0xFE; vk++) {
            if (vk == 0x01 || vk == 0x02 || vk == 0x04 || vk == 0x05 || vk == 0x06) continue;
            if ((GetAsyncKeyState(vk) & 0x8000) != 0) return true;
        }
        return false;
    }
    // Total CPU load (%) since the previous call, from GetSystemTimes - instant, unlike creating a
    // PerformanceCounter (which took seconds at startup). The first call returns 0.
    [DllImport("kernel32.dll")] private static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
    private static long _idle, _kernel, _user;
    public static double CpuPercent() {
        long idle, kernel, user;
        if (!GetSystemTimes(out idle, out kernel, out user)) return 0;
        long di = idle - _idle, dt = (kernel - _kernel) + (user - _user);   // kernel time includes idle
        bool first = _kernel == 0;
        _idle = idle; _kernel = kernel; _user = user;
        if (first || dt <= 0) return 0;
        return Math.Max(0, Math.Min(100, 100.0 * (dt - di) / dt));
    }
    public static int IdleSeconds() {
        LASTINPUTINFO li = new LASTINPUTINFO();
        li.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref li)) return 0;
        return (int)((GetTickCount() - li.dwTime) / 1000);
    }
}

// Analyze the eye pixels (black squares) on the official sprite -> blink variant, no-eyes variant,
// and the position of both eyes (to redraw them following the cursor / panic bulge).
public static class ClawdFx {
    private static byte[] Grab(Bitmap bmp, out int stride) {
        var bd = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        stride = bd.Stride;
        byte[] d = new byte[stride * bmp.Height];
        Marshal.Copy(bd.Scan0, d, 0, d.Length);
        bmp.UnlockBits(bd);
        return d;
    }
    private static void Put(Bitmap bmp, byte[] d) {
        var bd = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        Marshal.Copy(d, 0, bd.Scan0, d.Length);
        bmp.UnlockBits(bd);
    }
    private static List<Point> Dark(byte[] d, int stride, int x0, int y0, int x1, int y1) {
        var dark = new List<Point>();
        for (int y = y0; y <= y1; y++) {
            int row = y * stride;
            for (int x = x0; x <= x1; x++) {
                int i = row + x * 4;
                if (d[i + 3] >= 200 && d[i + 2] < 70 && d[i + 1] < 70 && d[i] < 70) dark.Add(new Point(x, y));
            }
        }
        return dark;
    }
    private static int BodyColor(byte[] d, int stride, int x0, int y0, int x1, int y1) {
        var counts = new Dictionary<int, int>();
        for (int y = y0; y <= y1; y++) {
            int row = y * stride;
            for (int x = x0; x <= x1; x++) {
                int i = row + x * 4;
                byte b = d[i], g = d[i + 1], r = d[i + 2], a = d[i + 3];
                if (a < 200 || (r < 70 && g < 70 && b < 70)) continue;
                int key = (r << 16) | (g << 8) | b;
                int c; counts.TryGetValue(key, out c); counts[key] = c + 1;
            }
        }
        int best = 0, bestC = 0;
        foreach (var kv in counts) if (kv.Value > bestC) { bestC = kv.Value; best = kv.Key; }
        return best;
    }
    private static Bitmap Clone32(Bitmap src) {
        var bmp = new Bitmap(src.Width, src.Height, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp)) g.DrawImage(src, 0, 0, src.Width, src.Height);
        return bmp;
    }
    public static int[] FindEyes(Bitmap src, int rx, int ry, int rw, int rh) {
        int stride;
        var bmp = Clone32(src);
        byte[] d = Grab(bmp, out stride);
        bmp.Dispose();
        int x1c = Math.Min(src.Width - 1, rx + rw), y1c = Math.Min(src.Height - 1, ry + rh);
        var dark = Dark(d, stride, Math.Max(0, rx), Math.Max(0, ry), x1c, y1c);
        if (dark.Count == 0) return new int[8];
        int minX = int.MaxValue, maxX = int.MinValue;
        foreach (var p in dark) { if (p.X < minX) minX = p.X; if (p.X > maxX) maxX = p.X; }
        int midX = (minX + maxX) / 2;
        int[] o = new int[8];
        for (int side = 0; side < 2; side++) {
            int cnX = int.MaxValue, cxX = int.MinValue, cnY = int.MaxValue, cxY = int.MinValue;
            foreach (var p in dark) {
                bool left = p.X <= midX;
                if ((side == 0) != left) continue;
                if (p.X < cnX) cnX = p.X; if (p.X > cxX) cxX = p.X;
                if (p.Y < cnY) cnY = p.Y; if (p.Y > cxY) cxY = p.Y;
            }
            o[side * 4] = cnX; o[side * 4 + 1] = cnY; o[side * 4 + 2] = cxX - cnX + 1; o[side * 4 + 3] = cxY - cnY + 1;
        }
        return o;
    }
    private static Bitmap Erase(Bitmap src, int rx, int ry, int rw, int rh, bool lid) {
        var bmp = Clone32(src);
        int stride;
        byte[] d = Grab(bmp, out stride);
        int x1c = Math.Min(src.Width - 1, rx + rw), y1c = Math.Min(src.Height - 1, ry + rh);
        int x0 = Math.Max(0, rx), y0 = Math.Max(0, ry);
        var dark = Dark(d, stride, x0, y0, x1c, y1c);
        int body = BodyColor(d, stride, x0, y0, x1c, y1c);
        byte br = (byte)(body >> 16), bg = (byte)((body >> 8) & 255), bb = (byte)(body & 255);
        foreach (var p in dark) {
            int i = p.Y * stride + p.X * 4;
            d[i] = bb; d[i + 1] = bg; d[i + 2] = br; d[i + 3] = 255;
        }
        if (lid && dark.Count > 0) {
            int minX = int.MaxValue, maxX = int.MinValue;
            foreach (var p in dark) { if (p.X < minX) minX = p.X; if (p.X > maxX) maxX = p.X; }
            int midX = (minX + maxX) / 2;
            byte lr = (byte)(br * 3 / 4), lg = (byte)(bg * 3 / 4), lb = (byte)(bb * 3 / 4);
            for (int side = 0; side < 2; side++) {
                int cnX = int.MaxValue, cxX = int.MinValue, cnY = int.MaxValue, cxY = int.MinValue;
                bool any = false;
                foreach (var p in dark) {
                    bool left = p.X <= midX;
                    if ((side == 0) != left) continue;
                    any = true;
                    if (p.X < cnX) cnX = p.X; if (p.X > cxX) cxX = p.X;
                    if (p.Y < cnY) cnY = p.Y; if (p.Y > cxY) cxY = p.Y;
                }
                if (!any) continue;
                int lidH = Math.Max(1, (cxY - cnY + 1) / 5);
                for (int y = cxY - lidH + 1; y <= cxY; y++)
                    for (int x = cnX; x <= cxX; x++) {
                        int i = y * stride + x * 4;
                        d[i] = lb; d[i + 1] = lg; d[i + 2] = lr; d[i + 3] = 255;
                    }
            }
        }
        Put(bmp, d);
        return bmp;
    }
    public static Bitmap MakeBlink(Bitmap src, int rx, int ry, int rw, int rh)  { return Erase(src, rx, ry, rw, rh, true); }
    public static Bitmap MakeNoEyes(Bitmap src, int rx, int ry, int rw, int rh) { return Erase(src, rx, ry, rw, rh, false); }
    // Shadow version: crop the region, body -> dark color, eyes -> the specified eye color
    public static Bitmap Darken(Bitmap src, int rx, int ry, int rw, int rh, int dr, int dg, int db, int er, int eg, int eb) {
        var bmp = new Bitmap(rw, rh, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp))
            g.DrawImage(src, new Rectangle(0, 0, rw, rh), new Rectangle(rx, ry, rw, rh), GraphicsUnit.Pixel);
        int stride;
        byte[] d = Grab(bmp, out stride);
        for (int y = 0; y < rh; y++) {
            int row = y * stride;
            for (int x = 0; x < rw; x++) {
                int i = row + x * 4;
                if (d[i + 3] < 200) { d[i + 3] = 0; continue; }
                if (d[i + 2] < 70 && d[i + 1] < 70 && d[i] < 70) {
                    d[i] = (byte)eb; d[i + 1] = (byte)eg; d[i + 2] = (byte)er;   // eyes
                } else {
                    d[i] = (byte)db; d[i + 1] = (byte)dg; d[i + 2] = (byte)dr;   // dark body
                }
            }
        }
        Put(bmp, d);
        return bmp;
    }
    public static int CountOpaque(Bitmap bmp) {
        int stride;
        byte[] d = Grab(bmp, out stride);
        int c = 0;
        for (int i = 3; i < d.Length; i += 4) if (d[i] >= 200) c++;
        return c;
    }
    // Find the top of the legs: the first row (from the bottom) at least half the body width
    public static int FindLegTop(Bitmap src, int rx, int ry, int rw, int rh) {
        var bmp = Clone32(src);
        int stride;
        byte[] d = Grab(bmp, out stride);
        bmp.Dispose();
        int x0 = Math.Max(0, rx), x1 = Math.Min(src.Width - 1, rx + rw);
        int yEnd = Math.Min(src.Height - 1, ry + rh);
        int maxC = 0;
        int[] counts = new int[yEnd + 1];
        for (int y = ry; y <= yEnd; y++) {
            int c = 0, row = y * stride;
            for (int x = x0; x <= x1; x++) if (d[row + x * 4 + 3] >= 200) c++;
            counts[y] = c;
            if (c > maxC) maxC = c;
        }
        int th = maxC / 2;
        for (int y = yEnd; y >= ry; y--) if (counts[y] >= th) return y + 1;
        return yEnd;
    }
    // Flatten to 2D: every opaque non-eye pixel becomes one flat body color
    // (removes the shading/ghosting that looks 3D on the GIF frames)
    public static Bitmap MakeFlat(Bitmap src, int rx, int ry, int rw, int rh) {
        var bmp = Clone32(src);
        int stride;
        byte[] d = Grab(bmp, out stride);
        int x1 = Math.Min(src.Width - 1, rx + rw), y1 = Math.Min(src.Height - 1, ry + rh);
        int x0 = Math.Max(0, rx), y0 = Math.Max(0, ry);
        int body = BodyColor(d, stride, x0, y0, x1, y1);
        byte br = (byte)(body >> 16), bg = (byte)((body >> 8) & 255), bb = (byte)(body & 255);
        for (int y = y0; y <= y1; y++) {
            int row = y * stride;
            for (int x = x0; x <= x1; x++) {
                int i = row + x * 4;
                if (d[i + 3] < 200) { d[i + 3] = 0; continue; }
                bool eye = (d[i + 2] < 70 && d[i + 1] < 70 && d[i] < 70);
                if (!eye) { d[i] = bb; d[i + 1] = bg; d[i + 2] = br; d[i + 3] = 255; }
            }
        }
        Put(bmp, d);
        return bmp;
    }
}

// Sky overlay for shooting stars: layered window with per-pixel alpha
// (soft glow & real gradients - impossible with TransparencyKey),
// click-through (WS_EX_TRANSPARENT) and never steals focus.
public class StarOverlay : Form {
    [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateCompatibleDC(IntPtr hDC);
    [DllImport("gdi32.dll")] private static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] private static extern IntPtr SelectObject(IntPtr hDC, IntPtr hObject);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr hObject);
    [DllImport("user32.dll")] private static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst, ref SIZE psize, IntPtr hdcSrc, ref POINT pprSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);
    [StructLayout(LayoutKind.Sequential)] private struct POINT { public int x, y; public POINT(int a, int b) { x = a; y = b; } }
    [StructLayout(LayoutKind.Sequential)] private struct SIZE { public int cx, cy; public SIZE(int a, int b) { cx = a; cy = b; } }
    [StructLayout(LayoutKind.Sequential)] private struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }

    public StarOverlay() {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
    }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x80000 | 0x20 | 0x80 | 0x8000000;   // LAYERED | TRANSPARENT | TOOLWINDOW | NOACTIVATE
            return cp;
        }
    }
    [DllImport("gdi32.dll")] private static extern IntPtr CreateDIBSection(IntPtr hdc, ref BITMAPINFOHEADER bmi, uint usage, out IntPtr bits, IntPtr hSection, uint offset);
    [DllImport("kernel32.dll", EntryPoint = "RtlMoveMemory")] private static extern void CopyMemory(IntPtr dst, IntPtr src, IntPtr len);
    [DllImport("msvcrt.dll", CallingConvention = CallingConvention.Cdecl)] private static extern int memcmp(IntPtr a, IntPtr b, UIntPtr n);
    [StructLayout(LayoutKind.Sequential)] private struct BITMAPINFOHEADER {
        public uint biSize; public int biWidth, biHeight; public ushort biPlanes, biBitCount;
        public uint biCompression, biSizeImage; public int biXPelsPerMeter, biYPelsPerMeter; public uint biClrUsed, biClrImportant;
    }

    // One DIB section is kept selected into one memory DC and reused for every frame (no GDI
    // allocation per frame). GDI+ hands us PREMULTIPLIED pixels (LockBits converts if needed),
    // which is exactly what UpdateLayeredWindow wants, so a frame is a single native copy.
    private IntPtr _memDc = IntPtr.Zero, _dib = IntPtr.Zero, _oldBmp = IntPtr.Zero, _bits = IntPtr.Zero;
    private int _dw, _dh;
    private bool _valid;
    private int _lx, _ly, _la;
    private void EnsureDib(int w, int h) {
        if (_dib != IntPtr.Zero && _dw == w && _dh == h) return;
        FreeDib();
        _memDc = CreateCompatibleDC(IntPtr.Zero);
        BITMAPINFOHEADER bi = new BITMAPINFOHEADER();
        bi.biSize = (uint)Marshal.SizeOf(typeof(BITMAPINFOHEADER));
        bi.biWidth = w; bi.biHeight = -h; bi.biPlanes = 1; bi.biBitCount = 32;
        _dib = CreateDIBSection(_memDc, ref bi, 0, out _bits, IntPtr.Zero, 0);
        _oldBmp = SelectObject(_memDc, _dib);
        _dw = w; _dh = h; _valid = false;
    }
    private void FreeDib() {
        if (_memDc != IntPtr.Zero) {
            if (_oldBmp != IntPtr.Zero) SelectObject(_memDc, _oldBmp);
            if (_dib != IntPtr.Zero) DeleteObject(_dib);
            DeleteDC(_memDc);
        }
        _memDc = _dib = _oldBmp = _bits = IntPtr.Zero;
        _valid = false;
    }
    protected override void Dispose(bool disposing) { FreeDib(); base.Dispose(disposing); }
    protected override void OnVisibleChanged(EventArgs e) { _valid = false; base.OnVisibleChanged(e); }
    // Frames skipped because nothing changed (diagnostics)
    public long Skipped;
    public void Render(Bitmap src0, int x, int y) { Render(src0, x, y, 255); }
    // alpha = whole-window fade (0..255), applied by the compositor for free.
    // Identical pixels + position + alpha -> nothing is sent to the compositor at all.
    public void Render(Bitmap src0, int x, int y, int alpha) {
        int w = src0.Width, h = src0.Height;
        EnsureDib(w, h);
        if (_bits == IntPtr.Zero) return;
        Rectangle r = new Rectangle(0, 0, w, h);
        BitmapData sd = src0.LockBits(r, ImageLockMode.ReadOnly, PixelFormat.Format32bppPArgb);
        bool same = false;
        try {
            int row = w * 4;
            if (sd.Stride == row) {
                UIntPtr n = (UIntPtr)(uint)(row * h);
                // Comparing costs about as much as copying, so only do it for pet-sized bitmaps
                same = _valid && row * h <= 1048576 && memcmp(sd.Scan0, _bits, n) == 0;
                if (!same) CopyMemory(_bits, sd.Scan0, (IntPtr)(row * h));
            } else {
                for (int yy = 0; yy < h; yy++)
                    CopyMemory(new IntPtr(_bits.ToInt64() + (long)yy * row), new IntPtr(sd.Scan0.ToInt64() + (long)yy * sd.Stride), (IntPtr)row);
            }
        } finally { src0.UnlockBits(sd); }
        alpha = Math.Max(0, Math.Min(255, alpha));
        if (same && x == _lx && y == _ly && alpha == _la) { Skipped++; return; }
        SIZE size = new SIZE(w, h);
        POINT src = new POINT(0, 0);
        POINT dst = new POINT(x, y);
        BLENDFUNCTION blend = new BLENDFUNCTION();
        blend.BlendOp = 0; blend.BlendFlags = 0; blend.SourceConstantAlpha = (byte)alpha; blend.AlphaFormat = 1;
        UpdateLayeredWindow(this.Handle, IntPtr.Zero, ref dst, ref size, _memDc, ref src, 0, ref blend, 2);
        _valid = true; _lx = x; _ly = y; _la = alpha;
    }
}

// Frame clock: a background thread paced by a high-resolution waitable timer posts ONE tick at a
// time to the UI thread (never a backlog). The WinForms Timer can't do this: it is quantized to
// the 15.6 ms system tick and actually fired at an uneven ~26-47 ms, which read as stutter.
// Each tick carries the time it was SCHEDULED for (DueMs), not the moment the UI thread got round
// to it, so motion advances by exactly one frame's worth per frame whatever the message-loop
// latency. Every due time sits on one grid of BaseUs (a display frame), which is what lets GIF
// frames (snapped to that grid, see ClawdFrames.Snap) change on an even cadence. The next due time
// is only worked out once a tick has run, so a PeriodUs set during a tick applies to the very next.
public class ClawdClock {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr CreateWaitableTimerExW(IntPtr attr, string name, uint flags, uint access);
    [DllImport("kernel32.dll")] private static extern bool SetWaitableTimer(IntPtr h, ref long due, int period, IntPtr cb, IntPtr arg, bool resume);
    [DllImport("kernel32.dll")] private static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr h);
    [DllImport("winmm.dll")] private static extern uint timeBeginPeriod(uint p);
    [DllImport("winmm.dll")] private static extern uint timeEndPeriod(uint p);
    public event EventHandler Tick;
    public volatile int PeriodUs = 16667;   // can be changed on the fly (a multiple of BaseUs)
    public volatile int BaseUs = 16667;     // one display frame: the grid every due time sits on
    // Native work run on EVERY frame (e.g. the meteor shower), while the PowerShell Tick only runs
    // every PsDivisor-th frame - smooth fast effects without paying PowerShell's cost per frame.
    public Action FastWork;
    public ClawdGlide Glide;                // window motion interpolated between script ticks
    public volatile int PsDivisor = 1;
    private int _n;
    private readonly Control _ctl;
    private volatile bool _run;
    private volatile int _gen;
    private int _pending;
    private readonly System.Threading.AutoResetEvent _fired = new System.Threading.AutoResetEvent(false);
    private readonly Stopwatch _sw = Stopwatch.StartNew();   // one time line for the whole run
    private double _due;                                     // UI thread only
    public ClawdClock(Control ctl) { _ctl = ctl; }
    public bool Running { get { return _run; } }
    public double NowMs { get { return _sw.Elapsed.TotalMilliseconds; } }
    public double DueMs { get { return _due; } }
    public void Start() {
        if (_run) return;
        _run = true;
        int gen = ++_gen;   // a thread from an earlier Start/Stop sees a stale generation and exits
        var th = new System.Threading.Thread(() => Loop(gen));
        th.IsBackground = true;
        th.Priority = System.Threading.ThreadPriority.AboveNormal;
        th.Start();
    }
    public void Stop() { _run = false; }
    private double OnGrid(double ms) { double b = BaseUs / 1000.0; return Math.Ceiling(ms / b) * b; }
    private void Loop(int gen) {
        IntPtr h = CreateWaitableTimerExW(IntPtr.Zero, null, 0x2, 0x1F0003);   // HIGH_RESOLUTION (Win10 1803+)
        bool hi = h != IntPtr.Zero;
        if (!hi) timeBeginPeriod(1);
        double next = OnGrid(_sw.Elapsed.TotalMilliseconds);
        try {
            while (_run && gen == _gen) {
                next += PeriodUs / 1000.0;
                double wait = next - _sw.Elapsed.TotalMilliseconds;
                if (wait < -100) { next = OnGrid(_sw.Elapsed.TotalMilliseconds); wait = 0; }   // after sleep/suspend: resync, no burst
                if (wait > 0) {
                    if (hi) {
                        long due = -(long)(wait * 10000);
                        SetWaitableTimer(h, ref due, 0, IntPtr.Zero, IntPtr.Zero, false);
                        WaitForSingleObject(h, 0xFFFFFFFF);
                    } else System.Threading.Thread.Sleep((int)Math.Max(1, Math.Round(wait)));
                }
                if (!_run || gen != _gen) break;
                if (System.Threading.Interlocked.CompareExchange(ref _pending, 1, 0) == 0) {
                    try { _ctl.BeginInvoke(new Action<double>(Fire), next); }
                    catch { _pending = 0; continue; }
                    _fired.WaitOne(1000);   // (a UI thread stuck that long just gets the next tick late)
                }
            }
        } finally { if (hi) CloseHandle(h); else timeEndPeriod(1); }
    }
    private void Fire(double due) {
        try {
            _pending = 0;
            if (!_run) return;
            _due = due;
            var fw = FastWork;
            if (fw != null) { try { fw(); } catch { } }
            var gl = Glide;
            if (gl != null) { try { gl.Frame(due); } catch { } }
            if (++_n < PsDivisor) return;
            _n = 0;
            var t = Tick;
            if (t != null) t(this, EventArgs.Empty);
        } finally { _fired.Set(); }
    }
}

// Smooth walking for the price of a 30 fps script: the logic says where Clawd is at each of its
// ticks (Push) and on every display frame in between the window glides there by linear
// interpolation, one logic tick behind so it never overshoots a stop or a turn. A frame whose
// rounded position did not change costs nothing.
public class ClawdGlide {
    private readonly Control _win;
    private double _x0, _y0, _t0, _x1, _y1, _t1;
    private int _lx, _ly;
    public bool Active;
    public ClawdGlide(Control win) { _win = win; }
    public void Push(double x, double y, double tMs) {
        if (!Active) {
            Active = true;
            _x0 = x; _y0 = y; _t0 = tMs;
            _lx = _win.Left; _ly = _win.Top;
        } else { _x0 = _x1; _y0 = _y1; _t0 = _t1; }
        _x1 = x; _y1 = y; _t1 = tMs;
    }
    public void Frame(double nowMs) {
        if (!Active) return;
        double span = _t1 - _t0;
        double a = span > 0 ? (nowMs - _t1) / span : 1.0;
        if (a < 0) a = 0; else if (a > 1) a = 1;
        MoveTo(_x0 + (_x1 - _x0) * a, _y0 + (_y1 - _y0) * a);
    }
    // The window stays where it is (at most a pixel behind the logic); whoever moves it next takes over
    public void Stop() { Active = false; }
    private void MoveTo(double x, double y) {
        int ix = (int)Math.Floor(x + 0.5), iy = (int)Math.Floor(y + 0.5);
        if (ix == _lx && iy == _ly) return;
        _lx = ix; _ly = iy;
        ClawdWin.MoveTo(_win.Handle, ix, iy);
    }
}

// Main pet window: per-pixel alpha layered - size+position+content updated ATOMICALLY
// in one call (no black flicker on resize), WITHOUT click-through:
// automatic per-pixel hit-test (transparent areas pass clicks, the crab body is draggable).
public class PetOverlay : StarOverlay {
    protected override CreateParams CreateParams {
        get {
            CreateParams cp = base.CreateParams;
            cp.ExStyle = cp.ExStyle & ~0x20;   // remove WS_EX_TRANSPARENT
            return cp;
        }
    }
}

// Meteor shower, simulated and drawn natively. The meteors and their sparks are drawn into a SMALL
// layered window that follows just them (redrawing a screen-wide bitmap every frame was what made
// the show heavy); the faint twinkling stars live on a second, screen-wide overlay that is only
// refreshed a few times a second. Timeline and physics are in logic ticks, like the rest of Clawd.
public class StarShow {
    class Meteor { public double X, Y, Vx, Vy, Sz; }
    class Spark { public double X, Y, Vx, Vy, Life, Max; public bool Cyan; }
    readonly List<Meteor> _m = new List<Meteor>();
    readonly List<Spark> _s = new List<Spark>();
    readonly int[] _tx = new int[16], _ty = new int[16], _tsz = new int[16];
    readonly double[] _tph = new double[16];
    readonly Random _r;
    readonly StarOverlay _metOv, _skyOv;
    readonly SolidBrush _br = new SolidBrush(Color.White);
    readonly StarOverlay[] _ovs = new StarOverlay[3];   // one small window per meteor
    readonly Bitmap[] _bmps = new Bitmap[3]; readonly Graphics[] _gs = new Graphics[3];
    Bitmap _sb; Graphics _sg;
    double _lastSky = double.MinValue;
    public readonly int L, T, W, H;
    public double Time;
    public double LastX, LastY;          // newest meteor, screen coordinates (for his eyes)
    public bool HasMeteor { get { return _m.Count > 0; } }

    readonly System.Diagnostics.Stopwatch _sw = System.Diagnostics.Stopwatch.StartNew();
    readonly double _tickMs;
    double _lastMs;
    ClawdClock _clock;
    public StarShow(StarOverlay metOv, StarOverlay skyOv, int l, int t, int w, int h, int seed, double tickMs) {
        _metOv = metOv; _skyOv = skyOv; L = l; T = t; W = w; H = h; _r = new Random(seed); _tickMs = tickMs;
        _ovs[0] = metOv;
        for (int i = 1; i < _ovs.Length; i++) _ovs[i] = new StarOverlay();
        for (int i = 0; i < 16; i++) {
            _tx[i] = _r.Next(30, Math.Max(31, W - 30)); _ty[i] = _r.Next(10, Math.Max(11, (int)(H * 0.8)));
            _tph[i] = _r.NextDouble() * 6.28; _tsz[i] = 1 + _r.Next(0, 2);
        }
        _sb = new Bitmap(W, H, PixelFormat.Format32bppPArgb);
        _sg = Graphics.FromImage(_sb); _sg.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
    }
    void Spawn(double size) {
        bool fromLeft = _r.NextDouble() < 0.5;
        double speed = 5.5 + _r.NextDouble() * 3.0, ang = (18 + _r.Next(0, 16)) * Math.PI / 180.0;
        var m = new Meteor { Vx = speed * Math.Cos(ang), Vy = speed * Math.Sin(ang), Sz = size, Y = _r.Next(0, 60) };
        if (fromLeft) m.X = _r.Next(0, (int)(W * 0.35)); else { m.X = _r.Next((int)(W * 0.65), W); m.Vx = -m.Vx; }
        _m.Add(m);
    }
    // Advance by k logic ticks: one big meteor, then a few smaller ones; sparks trail behind them
    public void Step(double k) {
        double t0 = Time; Time += k; double t = Time;
        double[] at = { 12, 150, 225, 320 }, sz = { 5.0, 3.0, 2.4, 4.0 };
        for (int i = 0; i < at.Length; i++) if (t0 < at[i] && t >= at[i]) Spawn(sz[i]);
        bool spark = Math.Floor(t / 2) != Math.Floor(t0 / 2);
        for (int i = _m.Count - 1; i >= 0; i--) {
            var m = _m[i];
            m.X += m.Vx * k; m.Y += m.Vy * k;
            if (spark) _s.Add(new Spark {
                X = m.X + (_r.NextDouble() - 0.5) * 6, Y = m.Y + (_r.NextDouble() - 0.5) * 6,
                Vx = -m.Vx * 0.06 + (_r.NextDouble() - 0.5) * 0.7, Vy = -m.Vy * 0.06 + (_r.NextDouble() - 0.5) * 0.7,
                Life = 38, Max = 38, Cyan = _r.NextDouble() < 0.35 });
            if (m.X < -80 || m.X > W + 80 || m.Y > H + 40) _m.RemoveAt(i);
        }
        for (int i = _s.Count - 1; i >= 0; i--) {
            var p = _s[i];
            p.X += p.Vx * k; p.Y += p.Vy * k; p.Vy += 0.025 * k; p.Life -= k;
            if (p.Life <= 0) _s.RemoveAt(i);
        }
        if (_m.Count > 0) { var n = _m[_m.Count - 1]; LastX = L + n.X; LastY = T + n.Y; }
    }
    void Dot(Graphics g, int a, int r, int gg, int b, double x, double y, double rad) {
        _br.Color = Color.FromArgb(Math.Max(0, Math.Min(255, a)), r, gg, b);
        g.FillEllipse(_br, (float)(x - rad), (float)(y - rad), (float)(rad * 2), (float)(rad * 2));
    }
    // Box around one meteor: head, tail, side ribbons and halo
    static void MeteorBox(Meteor m, out double x0, out double y0, out double x1, out double y1) {
        double pad = Math.Max(m.Sz * 3, 6.5 + m.Sz), tx = m.X - m.Vx * 48, ty = m.Y - m.Vy * 48;
        x0 = Math.Min(m.X, tx) - pad; x1 = Math.Max(m.X, tx) + pad; y0 = Math.Min(m.Y, ty) - pad; y1 = Math.Max(m.Y, ty) + pad;
    }
    // How far a spark is from a meteor's head-to-tail line (sparks belong to the closest meteor)
    static double DistToTail(Meteor m, double x, double y) {
        double ax = m.X, ay = m.Y, bx = m.X - m.Vx * 48, by = m.Y - m.Vy * 48, dx = bx - ax, dy = by - ay;
        double t = Math.Max(0, Math.Min(1, ((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy + 1e-9)));
        double ex = ax + t * dx - x, ey = ay + t * dy - y;
        return ex * ex + ey * ey;
    }
    void DrawMeteor(Graphics g, Meteor m) {
        double spd = Math.Sqrt(m.Vx * m.Vx + m.Vy * m.Vy), nx = m.Vx / spd, ny = m.Vy / spd, px = -ny, py = nx;
        const int segs = 24;
        // Tail: yellow -> orange -> cyan -> blue
        for (int s = segs; s >= 1; s--) {
            double f = s / (double)segs;
            int a = (int)(165 * Math.Pow(1 - f, 1.4));
            if (a <= 4) continue;
            int cr, cg, cb;
            if (f < 0.25) { double u = f / 0.25; cr = 255; cg = (int)(250 - 80 * u); cb = (int)(200 - 140 * u); }
            else if (f < 0.55) { double u = (f - 0.25) / 0.30; cr = (int)(255 - 165 * u); cg = (int)(170 + 30 * u); cb = (int)(60 + 195 * u); }
            else { double u = (f - 0.55) / 0.45; cr = (int)(90 - 30 * u); cg = (int)(200 - 90 * u); cb = (int)(255 - 35 * u); }
            Dot(g, a, cr, cg, cb, m.X - m.Vx * s * 2.0, m.Y - m.Vy * s * 2.0, Math.Max(0.7, m.Sz * (1 - f * 0.72)));
        }
        // Two thin ribbons along the sides (cyan & blue)
        int[][] bands = { new[] { 1, 110, 80, 200, 255 }, new[] { -1, 80, 60, 100, 230 } };
        foreach (var band in bands)
            for (int s = segs; s >= 3; s -= 2) {
                double f = s / (double)segs, off = band[0] * (1.6 + f * 4.5);
                int a = (int)(band[1] * Math.Pow(1 - f, 1.3));
                if (a <= 4) continue;
                Dot(g, a, band[2], band[3], band[4], m.X - m.Vx * s * 2.0 + px * off, m.Y - m.Vy * s * 2.0 + py * off, Math.Max(0.5, m.Sz * 0.45 * (1 - f * 0.6)));
            }
        Dot(g, 52, 255, 200, 110, m.X, m.Y, m.Sz * 3.0);   // warm halo
        Dot(g, 235, 255, 252, 240, m.X, m.Y, m.Sz);         // glowing core
    }
    void DrawSpark(Graphics g, Spark p) {
        double f = p.Life / p.Max, d = 1.0 + 1.6 * f;
        if (p.Cyan) Dot(g, (int)(165 * f), 130, 215, 255, p.X, p.Y, d / 2); else Dot(g, (int)(165 * f), 255, 215, 140, p.X, p.Y, d / 2);
    }
    public void Render(double globalT) {
        // --- one small window per meteor (with its sparks): two meteors far apart never make one
        //     huge box that has to be redrawn and recomposited every frame ---
        int slots = _ovs.Length, n = _m.Count;
        // Sparks belong to the nearest meteor; those left behind by a meteor that already flew off
        // (far from every meteor) get a window of their own instead of stretching another's.
        var sg = new int[_s.Count];
        int orphanGroup = Math.Min(n, slots - 1);
        bool anyOrphan = false;
        for (int j = 0; j < _s.Count; j++) {
            var p = _s[j];
            int best = -1; double bd = 60 * 60;
            for (int i = 0; i < n; i++) { double d = DistToTail(_m[i], p.X, p.Y); if (d < bd) { bd = d; best = i; } }
            if (best < 0) { sg[j] = orphanGroup; anyOrphan = true; } else sg[j] = Math.Min(best, slots - 1);
        }
        int groups = Math.Min(slots, Math.Max(n, anyOrphan ? orphanGroup + 1 : 0));
        var x0 = new double[slots]; var y0 = new double[slots]; var x1 = new double[slots]; var y1 = new double[slots];
        for (int i = 0; i < slots; i++) { x0[i] = y0[i] = double.MaxValue; x1[i] = y1[i] = double.MinValue; }
        var mg = new int[n];
        for (int i = 0; i < n; i++) {
            int gi = Math.Min(i, slots - 1); mg[i] = gi;
            double a0, b0, a1, b1; MeteorBox(_m[i], out a0, out b0, out a1, out b1);
            x0[gi] = Math.Min(x0[gi], a0); y0[gi] = Math.Min(y0[gi], b0); x1[gi] = Math.Max(x1[gi], a1); y1[gi] = Math.Max(y1[gi], b1);
        }
        for (int j = 0; j < _s.Count; j++) {
            var p = _s[j];
            int gi = sg[j];
            x0[gi] = Math.Min(x0[gi], p.X - 3); y0[gi] = Math.Min(y0[gi], p.Y - 3); x1[gi] = Math.Max(x1[gi], p.X + 3); y1[gi] = Math.Max(y1[gi], p.Y + 3);
        }
        for (int gi = 0; gi < slots; gi++) {
            var ov = _ovs[gi];
            if (gi >= groups || x1[gi] < x0[gi]) { if (ov.Visible) ov.Hide(); continue; }
            int bx = (int)Math.Floor(Math.Max(0, x0[gi])), by = (int)Math.Floor(Math.Max(0, y0[gi]));
            int bw = (int)Math.Ceiling(Math.Min(W, x1[gi])) - bx, bh = (int)Math.Ceiling(Math.Min(H, y1[gi])) - by;
            if (bw <= 0 || bh <= 0) { if (ov.Visible) ov.Hide(); continue; }
            bw = (bw + 15) / 16 * 16; bh = (bh + 15) / 16 * 16;   // fewer reallocations as it grows
            if (_bmps[gi] == null || _bmps[gi].Width != bw || _bmps[gi].Height != bh) {
                if (_gs[gi] != null) _gs[gi].Dispose(); if (_bmps[gi] != null) _bmps[gi].Dispose();
                _bmps[gi] = new Bitmap(bw, bh, PixelFormat.Format32bppPArgb);
                _gs[gi] = Graphics.FromImage(_bmps[gi]); _gs[gi].SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            }
            var g = _gs[gi];
            g.ResetTransform(); g.Clear(Color.Transparent); g.TranslateTransform(-bx, -by);
            for (int i = 0; i < n; i++) if (mg[i] == gi) DrawMeteor(g, _m[i]);
            for (int j = 0; j < _s.Count; j++) if (sg[j] == gi) DrawSpark(g, _s[j]);
            ov.Render(_bmps[gi], L + bx, T + by);
            if (!ov.Visible) { ov.Show(); ov.TopMost = true; }
        }
        // --- the faint twinkling stars pulse slowly: ~5 refreshes a second is plenty ---
        if (globalT - _lastSky >= 7) {
            _lastSky = globalT;
            _sg.Clear(Color.Transparent);
            for (int i = 0; i < 16; i++) Dot(_sg, (int)(55 + 55 * Math.Sin(globalT * 0.06 + _tph[i])), 255, 246, 222, _tx[i] + _tsz[i] / 2.0, _ty[i] + _tsz[i] / 2.0, _tsz[i] / 2.0);
            _skyOv.Render(_sb, L, T);
            if (!_skyOv.Visible) { _skyOv.Show(); _skyOv.TopMost = true; }
        }
    }
    // Run on every frame of the clock (60 fps) in native code; PowerShell only reads Time / LastX.
    public void Attach(ClawdClock clock) { _clock = clock; _lastMs = _sw.Elapsed.TotalMilliseconds; clock.FastWork = FastFrame; }
    void FastFrame() {
        double now = _sw.Elapsed.TotalMilliseconds;
        double k = Math.Max(0.05, Math.Min(2.5, (now - _lastMs) / _tickMs));
        _lastMs = now;
        Step(k);
        Render(now / _tickMs);
    }
    public void Close() {
        if (_clock != null) { _clock.FastWork = null; _clock = null; }
        for (int i = 0; i < _ovs.Length; i++) {
            if (_ovs[i].Visible) _ovs[i].Hide();
            if (i > 0) _ovs[i].Dispose();   // [0] is Clawd's own overlay, reused by the next show
            if (_gs[i] != null) _gs[i].Dispose(); if (_bmps[i] != null) _bmps[i].Dispose();
            _gs[i] = null; _bmps[i] = null;
        }
        if (_skyOv.Visible) _skyOv.Hide();
        _sg.Dispose(); _sb.Dispose(); _br.Dispose();
    }
}

// Claude-style right-click menu theme: warm dark background, coral highlight + edge
public class ClawdMenuColors : ProfessionalColorTable {
    static Color BG     = Color.FromArgb(38, 36, 33);
    static Color HILITE = Color.FromArgb(62, 48, 42);
    static Color CORAL  = Color.FromArgb(217, 119, 87);
    static Color MARGIN = Color.FromArgb(38, 36, 33);   // same as BG: no dark notch beside separators
    static Color SEP    = Color.FromArgb(70, 64, 58);
    static Color BORDER = Color.FromArgb(92, 72, 63);
    public override Color ToolStripDropDownBackground { get { return BG; } }
    public override Color MenuItemSelected { get { return HILITE; } }
    public override Color MenuItemSelectedGradientBegin { get { return HILITE; } }
    public override Color MenuItemSelectedGradientEnd { get { return HILITE; } }
    public override Color MenuItemBorder { get { return CORAL; } }
    public override Color MenuBorder { get { return BORDER; } }
    public override Color ImageMarginGradientBegin { get { return MARGIN; } }
    public override Color ImageMarginGradientMiddle { get { return MARGIN; } }
    public override Color ImageMarginGradientEnd { get { return MARGIN; } }
    public override Color SeparatorDark { get { return SEP; } }
    public override Color SeparatorLight { get { return SEP; } }
    public override Color MenuItemPressedGradientBegin { get { return BG; } }
    public override Color MenuItemPressedGradientEnd { get { return BG; } }
}

// Explicit renderer: the item highlight is drawn manually (warm fill + left coral bar),
// so it never falls back to the system blue highlight.
public class ClawdMenuRenderer : ToolStripProfessionalRenderer {
    public ClawdMenuRenderer() : base(new ClawdMenuColors()) { this.RoundedEdges = false; }
    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e) {
        Graphics g = e.Graphics;
        Rectangle r = new Rectangle(0, 0, e.Item.Width, e.Item.Height);
        if (e.Item.Selected || e.Item.Pressed) {
            using (SolidBrush b = new SolidBrush(Color.FromArgb(60, 47, 41)))
                g.FillRectangle(b, r);
            using (SolidBrush c = new SolidBrush(Color.FromArgb(217, 119, 87)))
                g.FillRectangle(c, 0, 0, 3, r.Height);
        } else {
            using (SolidBrush b = new SolidBrush(Color.FromArgb(38, 36, 33)))
                g.FillRectangle(b, r);
        }
    }
    // Coral check mark (the default one is dark and vanishes on the dark menu)
    protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e) {
        Graphics g = e.Graphics;
        Rectangle r = e.ImageRectangle;
        var sm = g.SmoothingMode;
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        using (Pen p = new Pen(Color.FromArgb(217, 119, 87), 2f)) {
            g.DrawLines(p, new PointF[] {
                new PointF(r.Left + r.Width * 0.18f, r.Top + r.Height * 0.52f),
                new PointF(r.Left + r.Width * 0.42f, r.Top + r.Height * 0.76f),
                new PointF(r.Left + r.Width * 0.84f, r.Top + r.Height * 0.26f) });
        }
        g.SmoothingMode = sm;
    }
    protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e) {
        e.ArrowColor = Color.FromArgb(200, 190, 180);
        base.OnRenderArrow(e);
    }
    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) {
        if (!e.Item.Enabled) e.TextColor = Color.FromArgb(150, 140, 130);
        base.OnRenderItemText(e);
    }
}
