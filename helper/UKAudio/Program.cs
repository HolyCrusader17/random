using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;

namespace UKAudio
{
    // Plays ULTRAKILL's own music and sounds, read from the player's ULTRAKILL install, while Ready or Not runs.
    // The RoNUltrakill UE4SS mod writes one line per event to events.log; this program tails it.
    internal static class Program
    {
        internal static string DataDir;
        static StreamWriter logFile;

        internal static void Log(string msg)
        {
            var line = DateTime.Now.ToString("HH:mm:ss.fff") + " " + msg;
            lock (typeof(Program))
            {
                try { logFile?.WriteLine(line); logFile?.Flush(); } catch { }
            }
            Console.WriteLine(line);
        }

        static string Setting(string id) => (string)Sheets.Settings.First(r => r.id == id).value;

        static string Expand(string p) =>
            p.Replace("{localappdata}", Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData))
             .Replace('/', Path.DirectorySeparatorChar);

        static int Main(string[] args)
        {
            DataDir = Expand(Setting("data_dir"));
            Directory.CreateDirectory(DataDir);
            logFile = new StreamWriter(Path.Combine(DataDir, "helper.log"), false) { AutoFlush = true };

            using (var single = new Mutex(true, "RoNUltrakill.UKAudio", out bool first))
            {
                if (!first) { Log("already running"); return 0; }
                try { return Run(args); }
                catch (Exception e) { Log("fatal: " + e); return 1; }
            }
        }

        static string Arg(string[] args, string name)
        {
            int i = Array.IndexOf(args, name);
            return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
        }

        static string ReadUltrakillDirFromSettings()
        {
            // UKAudio.exe lives in <mod>/bin, so {mod} is its parent folder
            var mod = Path.GetDirectoryName(AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar));
            foreach (var file in new[] { Expand(Setting("settings_file")), Expand(Setting("settings_file_mod").Replace("{mod}", mod)) })
            {
                if (!File.Exists(file)) continue;
                foreach (var line in File.ReadAllLines(file))
                {
                    int eq = line.IndexOf('=');
                    if (eq > 0 && line.Substring(0, eq).Trim() == "ULTRAKILL_DIR") return line.Substring(eq + 1).Trim();
                }
            }
            return null;
        }

        static int Run(string[] args)
        {
            var ukDir = Arg(args, "--ultrakill");
            if (string.IsNullOrWhiteSpace(ukDir)) ukDir = ReadUltrakillDirFromSettings();
            Log("UKAudio 0.1.0, ULTRAKILL folder: " + (ukDir ?? "(none)"));
            if (string.IsNullOrWhiteSpace(ukDir) || !Directory.Exists(ukDir))
            {
                Log("ULTRAKILL folder not found; the meter still works, without ULTRAKILL audio");
                return 2;
            }

            var heartbeat = Expand(Setting("heartbeat_file"));
            var events = new EventTail(Expand(Setting("events_file")));
            var gameProcesses = Setting("game_process").Split('|');

            var engine = new AudioEngine();
            engine.Start();
            var library = new ClipLibrary(ukDir, DataDir);
            var music = new MusicDirector(engine, library);

            // Index and extract on a worker so the heartbeat and events keep flowing during the first run.
            var prep = new Thread(() =>
            {
                try { library.Prepare(); music.Ready(); }
                catch (Exception e) { Log("prepare failed: " + e); }
            }) { IsBackground = true };
            prep.Start();

            var started = DateTime.UtcNow;
            DateTime? lastSeenGame = null;
            var lastBeat = DateTime.MinValue;
            while (true)
            {
                foreach (var ev in events.ReadNew()) Handle(ev, engine, library, music);

                var now = DateTime.UtcNow;
                if ((now - lastBeat).TotalSeconds >= 1)
                {
                    lastBeat = now;
                    try { File.WriteAllText(heartbeat, ((long)(now - new DateTime(1970, 1, 1)).TotalSeconds).ToString()); } catch { }
                    bool running = gameProcesses.Any(p => Process.GetProcessesByName(p).Length > 0);
                    if (running) lastSeenGame = now;
                    if (lastSeenGame == null && (now - started).TotalSeconds > 180) { Log("game never started; exiting"); break; }
                    if (lastSeenGame != null && (now - lastSeenGame.Value).TotalSeconds > 10) { Log("game closed; exiting"); break; }
                }
                music.Update();
                Thread.Sleep(50);
            }
            engine.Stop();
            try { File.Delete(heartbeat); } catch { }
            return 0;
        }

        static void Handle(GameEvent ev, AudioEngine engine, ClipLibrary library, MusicDirector music)
        {
            switch (ev.Kind)
            {
                case "sfx":
                    var row = Sheets.Audio.FirstOrDefault(a => a.id == ev.Arg);
                    var file = library.FileFor(ev.Arg);
                    if (row != null && file != null) engine.PlaySfx(file, (float)row.volume);
                    else Log("sfx " + ev.Arg + " not ready");
                    break;
                case "music":
                    music.SetTier(ev.Arg);
                    break;
                case "mission_start":
                    music.NextTrack();
                    break;
                case "hello":
                case "mode":
                case "mission_end":
                    Log("event " + ev.Kind + " " + ev.Arg);
                    break;
            }
        }
    }
}
