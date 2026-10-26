// Clawd.exe - a single-file Clawd Pet. It hosts clawd-pet.ps1 in-process on the same PowerShell
// engine powershell.exe uses (so it runs exactly as fast), with the native helpers (ClawdNative.cs)
// compiled in - no C# compiler at start-up - and the script, tools and assets embedded. They are
// unpacked to %LOCALAPPDATA%\ClawdPet on the first run and after an update; clawd.json there holds
// the user's settings and is never overwritten. Built by build.ps1.
//   Clawd.exe [standby] [-PerfLog <file.json>] [-TestBlink]
using System;
using System.Collections.Generic;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;

public static class ClawdHost {
    const string Prefix = "payload/";

    [STAThread]
    public static int Main(string[] args) {
        string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ClawdPet");
        bool testBlink = false;
        foreach (string a in args) if (Norm(a) == "testblink") testBlink = true;
        try {
            // Already running? Leave quietly (and before unpacking: it keeps the asset files open)
            if (!testBlink && IsRunning()) return 0;
            Unpack(dir);
            Environment.SetEnvironmentVariable("CLAWD_EXE", Application.ExecutablePath);
            var iss = InitialSessionState.CreateDefault();
            iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
            using (var rs = RunspaceFactory.CreateRunspace(iss)) {
                rs.ApartmentState = ApartmentState.STA;              // WinForms
                rs.ThreadOptions = PSThreadOptions.UseCurrentThread; // the message loop runs on this thread
                rs.Open();
                using (var ps = PowerShell.Create()) {
                    ps.Runspace = rs;
                    ps.AddCommand(Path.Combine(dir, "clawd-pet.ps1"));
                    for (int i = 0; i < args.Length; i++) {
                        string a = Norm(args[i]);
                        if (a == "standby") ps.AddParameter("Standby");
                        else if (a == "testblink") ps.AddParameter("TestBlink");
                        else if (a == "perflog" && i + 1 < args.Length) ps.AddParameter("PerfLog", args[++i]);
                    }
                    foreach (var o in ps.Invoke()) Console.WriteLine(o);   // (-TestBlink prints its result)
                    if (ps.Streams.Error.Count > 0) {
                        var lines = new List<string>();
                        foreach (var e in ps.Streams.Error) lines.Add(e.ToString() + Environment.NewLine + e.InvocationInfo.PositionMessage);
                        Log(dir, string.Join(Environment.NewLine, lines));
                    }
                }
            }
            return 0;
        } catch (Exception e) {
            Log(dir, e.ToString());
            MessageBox.Show("Clawd could not start:\n\n" + e.Message + "\n\nDetails: " + Path.Combine(dir, "clawd-error.log"),
                            "Clawd Pet", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return 1;
        }
    }

    static string Norm(string a) { return a.TrimStart('-', '/').ToLowerInvariant(); }

    // The same named mutex clawd-pet.ps1 holds while it runs
    static bool IsRunning() {
        using (var m = new Mutex(false, "ClawdPetMutex")) {
            try { if (!m.WaitOne(0)) return true; }
            catch (AbandonedMutexException) { }   // previous owner was killed: it is ours now
            m.ReleaseMutex();
            return false;
        }
    }

    // Unpack the embedded files when this build's payload differs from what is on disk
    static void Unpack(string dir) {
        var asm = Assembly.GetExecutingAssembly();
        string version;
        using (var s = asm.GetManifestResourceStream("payload.version"))
        using (var r = new StreamReader(s)) version = r.ReadToEnd().Trim();
        string stamp = Path.Combine(dir, ".payload-version");
        if (File.Exists(stamp) && File.ReadAllText(stamp).Trim() == version && File.Exists(Path.Combine(dir, "clawd-pet.ps1"))) return;
        foreach (string name in asm.GetManifestResourceNames()) {
            if (!name.StartsWith(Prefix)) continue;
            string rel = name.Substring(Prefix.Length).Replace('/', Path.DirectorySeparatorChar);
            string dest = Path.Combine(dir, rel);
            if (rel == "clawd.json" && File.Exists(dest)) continue;   // the user's settings
            Directory.CreateDirectory(Path.GetDirectoryName(dest));
            using (var s = asm.GetManifestResourceStream(name))
            using (var f = File.Create(dest)) s.CopyTo(f);
        }
        File.WriteAllText(stamp, version);
    }

    static void Log(string dir, string text) {
        try {
            Directory.CreateDirectory(dir);
            File.AppendAllText(Path.Combine(dir, "clawd-error.log"), DateTime.Now.ToString("s") + "  " + text + Environment.NewLine + Environment.NewLine);
        } catch { }
    }
}
