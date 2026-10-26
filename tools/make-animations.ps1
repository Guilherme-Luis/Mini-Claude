# Generates the extra Clawd animations (coffee, magnifier, celebrate, love, sneeze, stretch, nap)
# as GIFs in assets. Clawd is drawn as a pixel puppet with the official sprite's proportions and
# colours, on a 140x120 canvas (sprite at 30,20), saved at 3x. Re-run after editing an animation:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\make-animations.ps1
# Colours that must keep their own hue when the shell colour changes (hearts, coffee, handle) stay
# outside the coral range that ClawdFrames.Recolor shifts.
# Timing: every animation is authored on a time line ('t', in the original frames) and sampled at
# 30 fps, stored with delays of 3,3,4 cs (exactly 30 fps on average). Clawd re-times GIFs onto the
# display grid, so these play at an even 2 display frames each.
# Size: at the Tiny size one sprite unit is about half a screen pixel, so anything that must stay
# visible (strokes, outlines, particles) is at least 2 units thick.
param([string]$OutDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'assets'), [int]$Scale = 3)
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

// Minimal animated GIF89a writer: one global palette (index 0 = transparent), LZW, looping.
public static class GifOut {
    public static void Save(string path, List<Bitmap> frames, int[] delaysCs) {
        int w = frames[0].Width, h = frames[0].Height;
        var pal = new List<int>(); pal.Add(0);
        var idx = new Dictionary<int, int>();
        var data = new List<byte[]>();
        foreach (var f in frames) {
            var bd = f.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            int[] px = new int[w * h];
            for (int y = 0; y < h; y++) Marshal.Copy(new IntPtr(bd.Scan0.ToInt64() + (long)y * bd.Stride), px, y * w, w);
            f.UnlockBits(bd);
            byte[] ind = new byte[w * h];
            for (int i = 0; i < px.Length; i++) {
                int c = px[i];
                if (((c >> 24) & 255) < 128) { ind[i] = 0; continue; }
                c &= 0xFFFFFF;
                int k;
                if (!idx.TryGetValue(c, out k)) {
                    if (pal.Count < 256) { k = pal.Count; pal.Add(c); } else k = Nearest(pal, c);
                    idx[c] = k;
                }
                ind[i] = (byte)k;
            }
            data.Add(ind);
        }
        using (var s = File.Create(path)) {
            var bw = new BinaryWriter(s);
            bw.Write(Encoding.ASCII.GetBytes("GIF89a"));
            bw.Write((ushort)w); bw.Write((ushort)h);
            bw.Write((byte)0xF7); bw.Write((byte)0); bw.Write((byte)0);
            for (int i = 0; i < 256; i++) {
                int c = i < pal.Count ? pal[i] : 0;
                bw.Write((byte)((c >> 16) & 255)); bw.Write((byte)((c >> 8) & 255)); bw.Write((byte)(c & 255));
            }
            bw.Write(new byte[] { 0x21, 0xFF, 0x0B }); bw.Write(Encoding.ASCII.GetBytes("NETSCAPE2.0")); bw.Write(new byte[] { 3, 1, 0, 0, 0 });
            for (int fi = 0; fi < data.Count; fi++) {
                bw.Write(new byte[] { 0x21, 0xF9, 4, (byte)((2 << 2) | 1) }); bw.Write((ushort)delaysCs[fi]); bw.Write((byte)0); bw.Write((byte)0);
                bw.Write((byte)0x2C); bw.Write((ushort)0); bw.Write((ushort)0); bw.Write((ushort)w); bw.Write((ushort)h); bw.Write((byte)0);
                Lzw(bw, data[fi], 8);
            }
            bw.Write((byte)0x3B);
        }
    }
    static int Nearest(List<int> pal, int c) {
        int best = 1, bd = int.MaxValue;
        for (int i = 1; i < pal.Count; i++) {
            int dr = ((pal[i] >> 16) & 255) - ((c >> 16) & 255), dg = ((pal[i] >> 8) & 255) - ((c >> 8) & 255), db = (pal[i] & 255) - (c & 255);
            int d = dr * dr + dg * dg + db * db; if (d < bd) { bd = d; best = i; }
        }
        return best;
    }
    // LZW as in the classic GIF encoders (variable code size, clear at 4096)
    static void Lzw(BinaryWriter bw, byte[] px, int minBits) {
        bw.Write((byte)minBits);
        var outB = new List<byte>();
        int clear = 1 << minBits, eof = clear + 1;
        int nBits = minBits + 1, maxcode = (1 << nBits) - 1, freeEnt = clear + 2;
        bool clearFlg = false;
        var table = new Dictionary<int, int>();
        int acc = 0, accBits = 0;
        Action<int> output = null;
        output = delegate(int code) {
            acc |= code << accBits; accBits += nBits;
            while (accBits >= 8) { outB.Add((byte)(acc & 255)); acc >>= 8; accBits -= 8; }
            if (freeEnt > maxcode || clearFlg) {
                if (clearFlg) { nBits = minBits + 1; maxcode = (1 << nBits) - 1; clearFlg = false; }
                else { nBits++; maxcode = nBits == 12 ? 4096 : (1 << nBits) - 1; }
            }
            if (code == eof) { while (accBits > 0) { outB.Add((byte)(acc & 255)); acc >>= 8; accBits -= 8; } }
        };
        output(clear);
        int ent = px[0];
        for (int i = 1; i < px.Length; i++) {
            int c = px[i];
            int key = (c << 12) | ent;
            int v;
            if (table.TryGetValue(key, out v)) { ent = v; continue; }
            output(ent);
            ent = c;
            if (freeEnt < 4096) { table[key] = freeEnt++; }
            else { table.Clear(); freeEnt = clear + 2; clearFlg = true; output(clear); }
        }
        output(ent); output(eof);
        for (int p = 0; p < outB.Count; p += 255) {
            int n = Math.Min(255, outB.Count - p);
            bw.Write((byte)n);
            for (int j = 0; j < n; j++) bw.Write(outB[p + j]);
        }
        bw.Write((byte)0);
    }
}

// Clawd as a pixel puppet with the official sprite's proportions (80x100 grid, head 13..66 x 47..86,
// arms 0..12 / 67..79 x 60..72, eyes 7x7 at (20,53) and (53,53), four legs 87..99).
public class Clawd {
    public static readonly Color Body = Color.FromArgb(217, 119, 87);
    public static readonly Color Ink = Color.FromArgb(0, 0, 0);
    public const int CW = 140, CH = 120, OX = 30, OY = 20;   // canvas, sprite top-left in it
    public Bitmap Bmp; public Graphics G;
    // pose
    public float X, Y, Sx = 1, Sy = 1, Lean;
    public int ArmL, ArmR;                // 0 out, 1 up
    public float ArmLdy, ArmRdy, ArmLdx, ArmRdx;
    public string Eyes = "open"; public float EyeDx, EyeDy;
    public float[] LegDy = new float[4];
    public bool Blush; public int Mouth;

    public Clawd() {
        Bmp = new Bitmap(CW, CH, PixelFormat.Format32bppArgb);
        G = Graphics.FromImage(Bmp);
        G.SmoothingMode = SmoothingMode.None;
        G.Clear(Color.Transparent);
    }
    public PointF Map(float x, float y) {
        float lx = 40 + (x - 40) * Sx + Lean * (100 - y) / 60f;
        float ly = 100 + (y - 100) * Sy;
        return new PointF(OX + X + lx, OY + Y + ly);
    }
    public void R(float x, float y, float w, float h, Color c) {
        PointF a = Map(x, y), b = Map(x + w, y + h);
        int x0 = (int)Math.Round(Math.Min(a.X, b.X)), y0 = (int)Math.Round(Math.Min(a.Y, b.Y));
        int x1 = (int)Math.Round(Math.Max(a.X, b.X)), y1 = (int)Math.Round(Math.Max(a.Y, b.Y));
        if (x1 <= x0) x1 = x0 + 1; if (y1 <= y0) y1 = y0 + 1;
        using (var br = new SolidBrush(c)) G.FillRectangle(br, x0, y0, x1 - x0, y1 - y0);
    }
    // Raw canvas-space rectangle (particles that should not squash)
    public void P(float x, float y, float w, float h, Color c) {
        using (var br = new SolidBrush(c)) G.FillRectangle(br, (int)Math.Round(OX + x), (int)Math.Round(OY + y), Math.Max(1, (int)Math.Round(w)), Math.Max(1, (int)Math.Round(h)));
    }
    public void Pattern(float x, float y, string[] rows, Color c, float cell, bool squash) {
        for (int r = 0; r < rows.Length; r++)
            for (int k = 0; k < rows[r].Length; k++)
                if (rows[r][k] == '#') { if (squash) R(x + k * cell, y + r * cell, cell, cell, c); else P(x + k * cell, y + r * cell, cell, cell, c); }
    }
    // Several colours by character (a sprite): '.' = transparent. The cells snap to whole canvas
    // units as a block, so a moving sprite never tears apart.
    public void Sprite(float x, float y, string[] rows, float cell, Dictionary<char, Color> pal) {
        float x0 = (float)Math.Round(x), y0 = (float)Math.Round(y);
        for (int r = 0; r < rows.Length; r++)
            for (int k = 0; k < rows[r].Length; k++) {
                Color c;
                if (pal.TryGetValue(rows[r][k], out c)) P(x0 + k * cell, y0 + r * cell, cell, cell, c);
            }
    }
    public void Draw() {
        int[] lx = { 13, 27, 47, 60 }; int[] lw = { 7, 6, 6, 7 };
        for (int i = 0; i < 4; i++) R(lx[i], 87 - LegDy[i], lw[i], 13, Body);
        if (ArmL == 1) { R(5 + ArmLdx, 58 + ArmLdy, 9, 9, Body); R(0 + ArmLdx, 50 + ArmLdy, 9, 9, Body); R(-4 + ArmLdx, 42 + ArmLdy, 8, 9, Body); }
        else R(0 + ArmLdx, 60 + ArmLdy, 13, 13, Body);
        if (ArmR == 1) { R(66 + ArmRdx, 58 + ArmRdy, 9, 9, Body); R(71 + ArmRdx, 50 + ArmRdy, 9, 9, Body); R(76 + ArmRdx, 42 + ArmRdy, 8, 9, Body); }
        else R(67 + ArmRdx, 60 + ArmRdy, 13, 13, Body);
        R(13, 47, 54, 40, Body);
        DrawEye(20, 53, false); DrawEye(53, 53, true);
        if (Blush) { var pk = Color.FromArgb(240, 150, 150); R(18, 63, 7, 2, pk); R(55, 63, 7, 2, pk); }
        if (Mouth > 0) { int mw = 2 + Mouth, mh = 1 + Mouth; R(40 - mw / 2f, 70, mw, mh, Color.FromArgb(70, 28, 22)); }
    }
    void DrawEye(float ex, float ey, bool right) {
        float x = ex + EyeDx, y = ey + EyeDy;
        switch (Eyes) {
            case "closed": R(ex, ey + 5, 7, 2, Ink); break;
            case "half": R(x, y + 4, 7, 3, Ink); break;
            // a closed, smiling arch with 2-unit strokes (1-unit lines vanish at the small sizes)
            case "happy": Pattern(ex, ey + 1, new[] { "..###..", ".#####.", "##...##", "##...##" }, Ink, 1, true); break;
            case "squint": Pattern(ex, ey, right ? new[] { ".....##", "..###..", "##.....", "..###..", ".....##" } : new[] { "##.....", "..###..", ".....##", "..###..", "##....." }, Ink, 1, true); break;
            case "wide": R(x - 1, y - 2, 9, 10, Ink); R(x + 1, y, 2, 2, Color.White); break;
            case "dizzy": Pattern(ex, ey, new[] { "#.....#", ".#...#.", "..#.#..", "...#...", "..#.#..", ".#...#.", "#.....#" }, Ink, 1, true); break;
            default: R(x, y, 7, 7, Ink); break;
        }
    }
    public Bitmap Frame(int scale) {
        var o = new Bitmap(CW * scale, CH * scale, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(o)) {
            g.InterpolationMode = InterpolationMode.NearestNeighbor; g.PixelOffsetMode = PixelOffsetMode.Half;
            g.Clear(Color.Transparent);
            g.DrawImage(Bmp, new Rectangle(0, 0, CW * scale, CH * scale));
        }
        G.Dispose(); Bmp.Dispose();
        return o;
    }
}

public static class Anims {
    // Outlined hearts ('o' outline, '#' fill, 'w' shine): readable on any wallpaper. Drawn at cell 2.
    static readonly string[] HeartM = {
        ".ooo...ooo.", "o###o.o###o", "o#w##o####o", "o#w#######o", "o#########o",
        ".o#######o.", "..o#####o..", "...o###o...", "....o#o....", ".....o....." };
    static readonly string[] HeartS = { ".oo.oo.", "o#wo##o", "o#####o", ".o###o.", "..o#o..", "...o..." };
    static readonly string[] Spark = { ".#.", "###", ".#." };
    static readonly string[] Ex = { "##", "##", "##", "##", "##", "..", "##" };
    static readonly Color Cream = Color.FromArgb(246, 238, 226);
    static readonly Color Glyph = Color.FromArgb(70, 52, 44);
    static readonly Color Pink = Color.FromArgb(230, 80, 150), PinkDeep = Color.FromArgb(150, 30, 85), PinkShine = Color.FromArgb(255, 214, 232);
    static readonly Dictionary<char, Color> HeartPal = new Dictionary<char, Color> { { 'o', PinkDeep }, { '#', Pink }, { 'w', PinkShine } };
    static readonly Dictionary<char, Color> SparkPal = new Dictionary<char, Color> { { '#', PinkShine } };
    static float Ease(float t) { t = Math.Max(0, Math.Min(1, t)); return t * t * (3 - 2 * t); }
    static float Lerp(float a, float b, float t) { return a + (b - a) * t; }
    // Frames at 30 fps for a time line authored as n frames of ms each (the tempo stays the same)
    public static int Frames30(int n, int ms) { return (int)Math.Round(n * ms * 0.03); }
    public static int[] Delays30(int n) { var d = new int[n]; for (int i = 0; i < n; i++) d[i] = i % 3 == 2 ? 4 : 3; return d; }

    // A heart centred at x whose bottom edge is at y (sprite units), cell 2
    static void Heart(Clawd c, string[] pat, float x, float bottom) {
        c.Sprite(x - pat[0].Length, bottom - pat.Length * 2, pat, 2, HeartPal);
    }

    // ---- 1. Coffee break: holds a mug, steam rises, takes a sip, a happy little heart ----
    public static List<Bitmap> Coffee(int sc) {
        var L = new List<Bitmap>();
        Color mug = Color.FromArgb(240, 236, 228), stripe = Color.FromArgb(176, 92, 64), coffee = Color.FromArgb(60, 38, 28), steam = Color.FromArgb(214, 210, 204);
        int M = Frames30(64, 40);
        for (int i = 0; i < M; i++) {
            float t = i * 64f / M;
            var c = new Clawd();
            float lift = 0;
            if (t >= 28 && t < 36) lift = Ease((t - 28) / 8f);
            else if (t >= 36 && t < 46) lift = 1;
            else if (t >= 46 && t < 52) lift = 1 - Ease((t - 46) / 6f);
            c.ArmRdy = -3 - 7 * lift; c.ArmRdx = -6 * lift; c.Lean = 2 * lift;
            c.Sy = 1 + 0.012f * (float)Math.Sin(t * 0.2);
            c.Eyes = (t >= 12 && t < 14) ? "half" : (lift > 0.6f ? "happy" : "open");
            if (lift < 0.6f) c.EyeDx = 1.5f;
            c.Blush = t >= 50 && t < 62;
            c.Draw();
            float mx = Lerp(70, 50, lift), my = Lerp(52, 60, lift);
            c.R(mx, my, 12, 13, mug); c.R(mx, my + 5, 12, 2, stripe); c.R(mx + 1, my, 10, 2, coffee);
            c.R(mx + 12, my + 3, 3, 2, mug); c.R(mx + 13, my + 3, 2, 7, mug); c.R(mx + 12, my + 8, 3, 2, mug);
            if (lift < 0.3f) {
                for (int w = 0; w < 3; w++) {
                    float ph = ((t * 0.9f + w * 7) % 20) / 20f;
                    float sy = my - 3 - ph * 16, sx = mx + 1 + w * 4 + (float)Math.Sin(ph * 6.28f + w) * 1.5f;
                    if (ph < 0.85f) c.R(sx, sy, 2, 2, steam);
                }
            }
            if (t >= 52 && t < 62) {
                float r = (t - 52) / 10f;
                if (r < 0.12f) c.Sprite(63, 38, Spark, 2, SparkPal); else Heart(c, HeartS, 66 + (float)Math.Sin(r * 5) * 1.5f, 46 - r * 12);
            }
            L.Add(c.Frame(sc));
        }
        return L;
    }

    // ---- 2. Magnifier: searches left and right, the eye behind the lens looks huge, finds it! ----
    public static List<Bitmap> Magnifier(int sc) {
        var L = new List<Bitmap>();
        Color ring = Color.FromArgb(78, 78, 88), handle = Color.FromArgb(112, 100, 92), glass = Color.FromArgb(215, 235, 250);
        int M = Frames30(76, 40);
        for (int i = 0; i < M; i++) {
            float t = i * 76f / M;
            var c = new Clawd();
            float lx = 40 + 26 * (float)Math.Sin(t / 50f * 6.283f * 1.0f);
            if (t >= 50) lx = Lerp(40 + 26 * (float)Math.Sin(6.283f), 40, Ease((t - 50) / 6f));
            float ly = 57 + (float)Math.Sin(t * 0.5f) * 1.2f;
            float hop = 0;
            if (t >= 54 && t < 64) hop = (float)Math.Sin(Math.PI * (t - 54) / 10.0) * 8;
            c.Y = -hop;
            c.ArmLdy = -4; c.ArmLdx = 2;
            c.EyeDx = Math.Max(-2, Math.Min(2, (lx - 40) / 10f));
            c.Eyes = t >= 52 && t < 66 ? "wide" : "open";
            c.Draw();
            // handle from the left arm to the lens
            for (int s = 0; s <= 14; s++) { float q = s / 14f; c.R(Lerp(8, lx - 6, q), Lerp(70, ly + 6, q), 3, 3, handle); }
            // lens: glass tint + big eye inside when it is over one of his eyes
            float lr = 8;
            for (int a = 0; a < 40; a++) { double an = a / 40.0 * 6.283; c.R(lx + (float)Math.Cos(an) * lr - 1, ly + (float)Math.Sin(an) * lr - 1, 2, 2, ring); }
            foreach (float exc in new float[] { 23.5f, 56.5f }) {
                if (Math.Abs(lx - exc) < 7 && !(t >= 52 && t < 66)) { c.R(lx - 5, ly - 5, 10, 10, Ink()); c.R(lx - 3, ly - 3, 3, 3, glass); }
            }
            if (t >= 52 && t < 70) { c.P(70, 8 - hop, 14, 16, Cream); c.Pattern(76, 12 - hop, Ex, Color.FromArgb(217, 119, 87), 1, false); }
            L.Add(c.Frame(sc));
        }
        return L;
    }
    static Color Ink() { return Color.Black; }

    // ---- 3. Celebrate: crouch, big jump with arms up, confetti burst, a second little hop ----
    public static List<Bitmap> Celebrate(int sc) {
        var L = new List<Bitmap>();
        var rng = new Random(7);
        Color[] cols = { Color.FromArgb(217, 119, 87), Color.FromArgb(236, 190, 80), Color.FromArgb(120, 210, 170), Color.FromArgb(120, 170, 240), Color.FromArgb(235, 130, 170), Color.FromArgb(246, 238, 226) };
        int n = 22; float[] px = new float[n], py = new float[n], vx = new float[n], vy = new float[n]; int[] pc = new int[n];
        for (int i = 0; i < n; i++) { px[i] = 40; py[i] = 40; vx[i] = (float)(rng.NextDouble() * 6 - 3); vy[i] = (float)(-2 - rng.NextDouble() * 4.5); pc[i] = rng.Next(cols.Length); }
        int M = Frames30(66, 40); float dt = 66f / M;
        for (int f = 0; f < M; f++) {
            float t = f * dt;
            var c = new Clawd();
            if (t < 6) { float q = Ease(t / 5f); c.Sx = 1 + 0.1f * q; c.Sy = 1 - 0.12f * q; c.Eyes = "squint"; }
            else if (t < 22) { float p = (t - 6) / 16f; c.Y = -22 * (float)Math.Sin(Math.PI * p); c.Sy = 1 + 0.08f * (float)Math.Sin(Math.PI * p); c.Sx = 2 - c.Sy; c.ArmL = c.ArmR = 1; c.Eyes = "happy"; for (int i = 0; i < 4; i++) c.LegDy[i] = 2; }
            else if (t < 26) { float q = 1 - (t - 22) / 4f; c.Sx = 1 + 0.12f * q; c.Sy = 1 - 0.14f * q; c.Eyes = "happy"; c.ArmL = c.ArmR = 1; }
            else if (t < 38) { float p = (t - 26) / 12f; c.Y = -10 * (float)Math.Sin(Math.PI * p); c.ArmL = c.ArmR = 1; c.Eyes = "happy"; }
            else { c.ArmL = c.ArmR = 1; bool up = ((int)(t / 3)) % 2 == 0; c.ArmLdy = up ? -3 : 0; c.ArmRdy = up ? 0 : -3; c.Eyes = "happy"; c.Blush = true; }
            c.Draw();
            if (t >= 8) {
                for (int i = 0; i < n; i++) {
                    if (t - dt >= 8) { px[i] += vx[i] * dt; py[i] += vy[i] * dt; vy[i] += 0.32f * dt; vx[i] *= (float)Math.Pow(0.97, dt); if (vy[i] > 1.6f) vy[i] = 1.6f; }
                    bool flip = ((int)((t + i) / 2)) % 2 == 0;
                    if (py[i] < 96) c.P(px[i] + (float)Math.Sin((t + i) * 0.6) * 1.5f, py[i], flip ? 3 : 2, flip ? 2 : 3, cols[pc[i]]);
                }
            }
            L.Add(c.Frame(sc));
        }
        return L;
    }

    // ---- 4. Love: happy eyes, rosy cheeks, a little squeeze each time a big heart pops out and
    //         floats up, swaying, until it bursts into sparkles. No heart is left mid-air at the
    //         loop's end, so a single play finishes cleanly too. ----
    public static List<Bitmap> Love(int sc) {
        var L = new List<Bitmap>();
        const int M = 90, life = 36;                     // 3 s loop at 30 fps; each heart lives 1.2 s
        int[] spawn = { 0, 27, 53 };
        float[] hx = { 40, 64, 16 }, side = { 0, 1, -1 };
        bool[] big = { true, false, true };
        for (int i = 0; i < M; i++) {
            var c = new Clawd();
            float sw = (float)Math.Sin(i / (float)M * 6.283f * 2);
            float sq = 0;                                // squeeze as a heart comes out
            foreach (int s0 in spawn) { int f = i - s0; if (f >= 0 && f < 9) sq = Math.Max(sq, (float)Math.Sin(Math.PI * f / 9.0)); }
            c.Lean = 2.5f * sw;
            c.Sy = 1 - 0.035f * sq; c.Sx = 1 + 0.025f * sq;
            c.Eyes = "happy"; c.Blush = true;
            c.ArmLdx = 2.5f * sq; c.ArmRdx = -2.5f * sq;
            c.ArmLdy = sw * 1.5f - 1.5f * sq; c.ArmRdy = -sw * 1.5f - 1.5f * sq;
            c.Draw();
            for (int h = 0; h < spawn.Length; h++) {
                int f = i - spawn[h];
                if (f < 0 || f >= life) continue;
                const int burst = 7, fly = life - burst;
                float q = Math.Min(1f, f / (float)fly);
                float rise = big[h] ? 24 : 30;
                float bottom = 46 - rise * (1 - (1 - q) * (1 - q));                // eases out as it floats up
                float x = hx[h] + side[h] * 7 * q + 2.5f * (float)Math.Sin(q * 6.283f * 1.2f + h);
                string[] pat = big[h] ? HeartM : HeartS;
                if (f < 3) c.Sprite(x - 3, bottom - 6, Spark, 2, SparkPal);           // pop in: sparkle,
                else if (f < 6 && big[h]) Heart(c, HeartS, x, bottom);                // small heart,
                else if (f < fly) Heart(c, pat, x, bottom);                            // full heart
                else {                                                                 // burst into sparkles
                    float b = (f - fly) / (float)(burst - 1), cy = bottom - pat.Length;
                    if (f - fly < 2) Heart(c, HeartS, x, bottom - (pat.Length - 6));
                    float r = 4 + 11 * (1 - (1 - b) * (1 - b));
                    for (int a = 0; a < 6; a++) {
                        double an = (a * 60 + 30) * Math.PI / 180;
                        c.P(x + (float)Math.Cos(an) * r - 1, cy + (float)Math.Sin(an) * r - 1, 2, 2, a % 2 == 0 ? Pink : PinkShine);
                    }
                }
            }
            L.Add(c.Frame(sc));
        }
        return L;
    }

    // ---- 5. Sneeze: "ah... ah..." (inhales, squinting, leaning back) then ATCHOO with a puff, dizzy ----
    public static List<Bitmap> Sneeze(int sc) {
        var L = new List<Bitmap>();
        var rng = new Random(3);
        int n = 14; float[] px = new float[n], py = new float[n], vx = new float[n], vy = new float[n], pr = new float[n];
        for (int i = 0; i < n; i++) { double a = Math.PI * (1.05 + rng.NextDouble() * 0.9); float sp = (float)(1.5 + rng.NextDouble() * 2.5); px[i] = 40; py[i] = 70; vx[i] = (float)Math.Cos(a) * sp * (rng.Next(2) == 0 ? -1 : 1); vy[i] = -Math.Abs((float)Math.Sin(a) * sp) * 0.6f; pr[i] = (float)(1.5 + rng.NextDouble() * 2); }
        int M = Frames30(66, 40);
        for (int f = 0; f < M; f++) {
            float t = f * 66f / M;
            var c = new Clawd();
            if (t < 26) {
                int step = Math.Min(2, (int)(t / 9)); float within = (t % 9) / 9f;
                c.Sy = 1 + 0.04f * (step + 1) * Ease(within * 1.5f); c.Sx = 2 - c.Sy;
                c.Lean = -1.5f * (step + 1) * Ease(within * 1.5f);
                c.Eyes = step == 0 ? "half" : "squint";
                c.Mouth = step + 1;
            } else if (t < 30) { c.Sy = 1.14f; c.Sx = 0.9f; c.Lean = -5; c.Eyes = "squint"; c.Mouth = 4; }
            else if (t < 36) { float q = 1 - (t - 30) / 6f; c.Sx = 1 + 0.2f * q; c.Sy = 1 - 0.2f * q; c.Lean = 6 * q; c.Eyes = "squint"; c.ArmLdy = c.ArmRdy = 4 * q; }
            else if (t < 52) { c.Eyes = "dizzy"; c.Lean = (float)Math.Sin((t - 36) * 0.9f) * 2 * (1 - (t - 36) / 16f); }
            else { c.Eyes = (t >= 58 && t < 60) ? "half" : "open"; c.EyeDx = (t < 56) ? ((t % 4) < 2 ? -1.5f : 1.5f) : 0; }
            c.Draw();
            if (t >= 30 && t < 50) {
                for (int i = 0; i < n; i++) {
                    float age = t - 30;
                    float x = px[i] + vx[i] * age * 1.4f, y = py[i] + vy[i] * age - age * 0.25f;
                    float r = pr[i] * (age < 4 ? (age + 1) / 4f : 1) * (age > 12 ? Math.Max(0, (20 - age) / 8f) : 1);
                    if (r >= 0.8f) using (var br = new SolidBrush(Cream)) c.G.FillEllipse(br, (int)(Clawd.OX + x - r), (int)(Clawd.OY + y - r), (int)(2 * r) + 1, (int)(2 * r) + 1);
                }
            }
            if (t >= 30 && t < 40) { c.P(78, 26, 3, 9, Glyph); c.P(78, 37, 3, 3, Glyph); }   // "!"
            L.Add(c.Frame(sc));
        }
        return L;
    }

    // ---- 6. Stretch: arms up, a long stretch and a yawn, snaps back, shakes it off ----
    public static List<Bitmap> Stretch(int sc) {
        var L = new List<Bitmap>();
        int M = Frames30(66, 50);
        for (int f = 0; f < M; f++) {
            float t = f * 66f / M;
            var c = new Clawd();
            if (t < 8) { c.Eyes = "half"; if (t >= 4) c.ArmL = c.ArmR = 1; }
            else if (t < 30) { float q = Ease((t - 8) / 18f); c.ArmL = c.ArmR = 1; c.ArmLdy = c.ArmRdy = -6 * q; c.Sy = 1 + 0.14f * q; c.Sx = 1 - 0.08f * q; c.Eyes = "closed"; c.Mouth = (int)Math.Round(5 * q); c.Lean = (float)Math.Sin(t * 0.35f) * 1.2f * q; }
            else if (t < 38) { c.ArmL = c.ArmR = 1; c.ArmLdy = c.ArmRdy = -6; c.Sy = 1.14f; c.Sx = 0.92f; c.Eyes = "closed"; c.Mouth = 5; for (int i = 0; i < 4; i++) c.LegDy[i] = (i % 2 == 0) ? 1 : 0; }
            else if (t < 44) { float q = 1 - (t - 38) / 6f; c.Sx = 1 + 0.1f * q; c.Sy = 1 - 0.1f * q; c.Eyes = "closed"; }
            else if (t < 56) { float d = 1 - (t - 44) / 12f; c.Lean = 2.8f * (float)Math.Sin(t * Math.PI) * d; c.Eyes = "squint"; }   // shake it off
            else { c.Eyes = (t >= 60 && t < 62) ? "half" : "open"; }
            c.Draw();
            if (t >= 30 && t < 38) c.Pattern(64, 30, new[] { "..##.", ".#..#", "#...." }, Glyph, 1, false);   // a little "~" sigh
            L.Add(c.Frame(sc));
        }
        return L;
    }

    // ---- 7. Nap with a bubble: asleep, a bubble grows and shrinks with his breath... and pops ----
    public static List<Bitmap> NapBubble(int sc) {
        var L = new List<Bitmap>();
        Color bub = Color.FromArgb(196, 228, 248), bubEdge = Color.FromArgb(140, 190, 226);
        int M = Frames30(84, 50);
        for (int f = 0; f < M; f++) {
            float t = f * 84f / M;
            var c = new Clawd();
            float breath = (float)Math.Sin(t / 30f * 6.283f);
            c.Sy = 1 + 0.025f * breath;
            float r = -1;
            if (t < 30) r = 2 + 2.5f * (0.5f + 0.5f * (float)Math.Sin(t / 30f * 6.283f - 1.57f));
            else if (t < 62) r = 2 + 6.5f * Ease((t - 30) / 32f) + 0.6f * (float)Math.Sin(t * 0.6f);
            c.Eyes = "closed";
            if (t >= 62 && t < 68) { c.Eyes = "wide"; c.Y = -(float)Math.Sin(Math.PI * (t - 62) / 6.0) * 4; }
            else if (t >= 68 && t < 74) c.Eyes = "half";
            c.Draw();
            if (r > 0) {
                PointF m = c.Map(44, 66 - r);
                int ri = (int)Math.Round(r);
                using (var b1 = new SolidBrush(bubEdge)) c.G.FillEllipse(b1, (int)(m.X - ri - 1), (int)(m.Y - ri - 1), 2 * ri + 2, 2 * ri + 2);
                using (var b2 = new SolidBrush(bub)) c.G.FillEllipse(b2, (int)(m.X - ri), (int)(m.Y - ri), 2 * ri, 2 * ri);
                using (var b3 = new SolidBrush(Color.White)) c.G.FillRectangle(b3, (int)(m.X - ri / 2f), (int)(m.Y - ri / 2f), Math.Max(1, ri / 3), Math.Max(1, ri / 3));
            }
            if (t >= 62 && t < 67) {
                float k = (t - 62) * 2.5f + 4;
                PointF m = c.Map(44, 58);
                for (int a = 0; a < 6; a++) { double an = a / 6.0 * 6.283; using (var br = new SolidBrush(bubEdge)) c.G.FillRectangle(br, (int)(m.X + Math.Cos(an) * k), (int)(m.Y + Math.Sin(an) * k), 2, 2); }
            }
            if (t < 60 || t >= 76) {
                for (int z = 0; z < 2; z++) {
                    float ph = ((t + z * 15) % 30) / 30f;
                    c.Pattern(62 + ph * 8 + z * 2, 38 - ph * 22, new[] { "###", "..#", ".#.", "###" }, Glyph, 1, false);
                }
            }
            L.Add(c.Frame(sc));
        }
        return L;
    }
}
"@

[void][IO.Directory]::CreateDirectory($OutDir)
$list = @(
    @('Coffee',     'Coffee'),
    @('Magnifier',  'Magnifier'),
    @('Celebrate',  'Celebrate'),
    @('Love',       'Love'),
    @('Sneeze',     'Sneeze'),
    @('Stretch',    'Stretch'),
    @('Nap',        'NapBubble')
)
foreach ($a in $list) {
    $frames = [Anims]::($a[1]).Invoke($Scale)
    $path = Join-Path $OutDir ("Clawd-" + $a[0] + '.gif')
    [GifOut]::Save($path, $frames, [Anims]::Delays30($frames.Count))
    foreach ($f in $frames) { $f.Dispose() }
    '{0,-28} {1,3} frames  {2,6:0} KB' -f (Split-Path $path -Leaf), $frames.Count, ((Get-Item $path).Length / 1KB)
}
