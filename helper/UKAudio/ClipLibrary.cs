using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using AssetsTools.NET;
using AssetsTools.NET.Extra;
using Fmod5Sharp;

namespace UKAudio
{
    // Finds ULTRAKILL's AudioClips in its Addressables bundles, picks the ones the audio sheet asks for, and
    // turns them into playable .ogg/.wav files in the player's own cache. Nothing here is shipped with the mod.
    internal sealed class ClipLibrary
    {
        internal sealed class Clip
        {
            public string Bundle;    // path relative to the bundles folder
            public string Name;      // AudioClip m_Name
            public string Resource;  // bundle entry holding the FSB5 data
            public long Offset, Size;
            public string Key => Regex.Replace(Bundle + "_" + Name, "[^A-Za-z0-9_.-]", "_");
        }

        readonly string bundlesDir, cacheDir, indexFile, resolvedFile;
        readonly Dictionary<string, Clip> chosenSfx = new Dictionary<string, Clip>();
        readonly Dictionary<string, string> files = new Dictionary<string, string>(); // clip key -> cached file
        internal readonly List<(Clip clean, Clip battle)> MusicPairs = new List<(Clip, Clip)>();
        List<Clip> index = new List<Clip>();

        public ClipLibrary(string ultrakillDir, string dataDir)
        {
            bundlesDir = Path.Combine(ultrakillDir, "ULTRAKILL_Data", "StreamingAssets", "aa", "StandaloneWindows64");
            cacheDir = Path.Combine(dataDir, "cache");
            indexFile = Path.Combine(dataDir, "clip-index.txt");
            resolvedFile = Path.Combine(dataDir, "clip-choices.txt");
            Directory.CreateDirectory(cacheDir);
        }

        public void Prepare()
        {
            var sw = Stopwatch.StartNew();
            BuildIndex();
            Program.Log($"index: {index.Count} AudioClips ({sw.Elapsed.TotalSeconds:0.0}s)");
            Resolve();
            ExtractAll();
            Program.Log($"audio ready ({sw.Elapsed.TotalSeconds:0.0}s)");
        }

        public string FileFor(string audioId)
        {
            lock (files)
                return chosenSfx.TryGetValue(audioId, out var c) && files.TryGetValue(c.Key, out var f) ? f : null;
        }

        public string FileFor(Clip c)
        {
            lock (files) return files.TryGetValue(c.Key, out var f) ? f : null;
        }

        static Regex Glob(string glob) =>
            new Regex("^" + Regex.Escape(glob).Replace(@"\*", ".*").Replace(@"\?", ".") + "$", RegexOptions.IgnoreCase);

        // ------------------------------------------------------------------ index (cached per bundle size+time)
        void BuildIndex()
        {
            if (!Directory.Exists(bundlesDir)) { Program.Log("no bundles folder at " + bundlesDir); return; }
            var cached = new Dictionary<string, (string stamp, List<Clip> clips)>();
            if (File.Exists(indexFile))
            {
                foreach (var line in File.ReadAllLines(indexFile))
                {
                    var p = line.Split('\t');
                    if (p[0] == "#bundle" && p.Length == 3) cached[p[1]] = (p[2], new List<Clip>());
                    else if (p[0] == "clip" && p.Length == 7 && cached.TryGetValue(p[1], out var b))
                        b.clips.Add(new Clip { Bundle = p[1], Name = p[2], Resource = p[3], Offset = long.Parse(p[4]), Size = long.Parse(p[5]) });
                }
            }

            // music bundles first, so the soundtrack is ready soonest on a first run
            var musicGlobs = Sheets.Audio.Where(a => a.kind == "music").Select(a => Glob(a.bundles)).ToList();
            var bundles = Directory.GetFiles(bundlesDir, "*.bundle", SearchOption.AllDirectories)
                .OrderBy(f => musicGlobs.Any(g => g.IsMatch(Path.GetFileName(f))) ? 0 : 1).ThenBy(f => f).ToList();

            var lines = new List<string>();
            var result = new List<Clip>();
            var am = new AssetsManager();
            try
            {
                foreach (var path in bundles)
                {
                    var rel = path.Substring(bundlesDir.Length).TrimStart('\\', '/').Replace('\\', '/');
                    var fi = new FileInfo(path);
                    var stamp = fi.Length + ":" + fi.LastWriteTimeUtc.Ticks;
                    List<Clip> clips;
                    if (cached.TryGetValue(rel, out var hit) && hit.stamp == stamp) clips = hit.clips;
                    else
                    {
                        clips = new List<Clip>();
                        try { IndexBundle(am, path, rel, clips); }
                        catch (Exception e) { Program.Log("skip " + rel + ": " + e.Message); }
                    }
                    lines.Add($"#bundle\t{rel}\t{stamp}");
                    foreach (var c in clips) lines.Add($"clip\t{c.Bundle}\t{c.Name}\t{c.Resource}\t{c.Offset}\t{c.Size}\t-");
                    result.AddRange(clips);
                }
            }
            finally { am.UnloadAll(true); }
            File.WriteAllLines(indexFile, lines);
            index = result;
        }

        BundleFileInstance Open(AssetsManager am, string path, out string tmp)
        {
            tmp = null;
            var bun = am.LoadBundleFile(path, false);
            if (!bun.file.DataIsCompressed) return bun;
            tmp = Path.Combine(cacheDir, "unpack.tmp");
            using (var fs = File.Create(tmp)) bun.file.Unpack(new AssetsFileWriter(fs));
            am.UnloadAll(true);
            return am.LoadBundleFile(tmp, false);
        }

        void Close(AssetsManager am, string tmp)
        {
            am.UnloadAll(true);
            if (tmp != null) try { File.Delete(tmp); } catch { }
        }

        void IndexBundle(AssetsManager am, string path, string rel, List<Clip> clips)
        {
            var bun = Open(am, path, out var tmp);
            try
            {
                var names = bun.file.GetAllFileNames();
                for (int i = 0; i < names.Count; i++)
                {
                    if (names[i].EndsWith(".resS") || names[i].EndsWith(".resource")) continue;
                    var af = am.LoadAssetsFileFromBundle(bun, i, false);
                    foreach (var info in af.file.GetAssetsOfType(AssetClassID.AudioClip))
                    {
                        var bf = am.GetBaseField(af, info);
                        var res = bf["m_Resource"];
                        clips.Add(new Clip
                        {
                            Bundle = rel,
                            Name = bf["m_Name"].AsString,
                            Resource = Path.GetFileName(res["m_Source"].AsString),
                            Offset = res["m_Offset"].AsLong,
                            Size = res["m_Size"].AsLong,
                        });
                    }
                }
            }
            finally { Close(am, tmp); }
        }

        // ------------------------------------------------------------------ pick clips per audio sheet row
        List<Clip> Matches(Sheets.AudioRow row)
        {
            var g = Glob(row.bundles);
            var pool = index.Where(c => g.IsMatch(Path.GetFileName(c.Bundle))).ToList();
            foreach (var pattern in row.match)
            {
                var rx = new Regex(pattern.Replace("(?i)", ""), RegexOptions.IgnoreCase);
                var hits = pool.Where(c => rx.IsMatch(c.Name)).OrderBy(c => c.Name).ToList();
                if (hits.Count > 0) return hits;
            }
            return new List<Clip>();
        }

        static string PairKey(string name, string[] patterns)
        {
            foreach (var p in patterns) name = Regex.Replace(name, p.Replace("(?i)", ""), "", RegexOptions.IgnoreCase);
            return Regex.Replace(name.ToLowerInvariant(), "[^a-z0-9]", "");
        }

        void Resolve()
        {
            var report = new List<string>();
            foreach (var row in Sheets.Audio.Where(a => a.kind == "sfx"))
            {
                var m = Matches(row);
                if (m.Count > 0) chosenSfx[row.id] = m[0];
                report.Add($"{row.id}\t{(m.Count > 0 ? m[0].Bundle + " :: " + m[0].Name : "NO MATCH")}\t({m.Count} candidates)");
            }
            var cleanRow = Sheets.Audio.First(a => a.id == "music_clean");
            var battleRow = Sheets.Audio.First(a => a.id == "music_battle");
            var battles = Matches(battleRow).GroupBy(c => PairKey(c.Name, battleRow.match)).ToDictionary(g => g.Key, g => g.First());
            foreach (var clean in Matches(cleanRow))
            {
                if (battles.TryGetValue(PairKey(clean.Name, cleanRow.match), out var battle))
                    MusicPairs.Add((clean, battle));
            }
            foreach (var p in MusicPairs) report.Add($"music\t{p.clean.Name} <-> {p.battle.Name}");
            if (MusicPairs.Count == 0) report.Add("music\tNO clean/battle PAIRS");
            File.WriteAllLines(resolvedFile, report);
            Program.Log($"resolved {chosenSfx.Count} sfx, {MusicPairs.Count} music pairs (see clip-choices.txt)");
        }

        // ------------------------------------------------------------------ FSB5 -> .ogg/.wav in the cache
        void ExtractAll()
        {
            var wanted = chosenSfx.Values.Concat(MusicPairs.SelectMany(p => new[] { p.clean, p.battle })).ToList();
            foreach (var c in wanted)
            {
                foreach (var ext in new[] { ".ogg", ".wav" })
                {
                    var f = Path.Combine(cacheDir, c.Key + ext);
                    if (File.Exists(f)) lock (files) files[c.Key] = f;
                }
            }
            var todo = wanted.Where(c => FileFor(c) == null).GroupBy(c => c.Bundle).ToList();
            var am = new AssetsManager();
            try
            {
                foreach (var group in todo)
                {
                    var bun = Open(am, Path.Combine(bundlesDir, group.Key), out var tmp);
                    try
                    {
                        foreach (var c in group)
                        {
                            try { Extract(bun, c); }
                            catch (Exception e) { Program.Log("extract " + c.Name + " failed: " + e.Message); }
                        }
                    }
                    finally { Close(am, tmp); }
                }
            }
            finally { am.UnloadAll(true); }
        }

        void Extract(BundleFileInstance bun, Clip c)
        {
            var entry = bun.file.BlockAndDirInfo.DirectoryInfos.FirstOrDefault(d => d.Name == c.Resource)
                        ?? throw new InvalidDataException("resource " + c.Resource + " not in bundle");
            var reader = bun.file.DataReader;
            reader.Position = entry.Offset + c.Offset;
            var bytes = reader.ReadBytes((int)c.Size);
            if (!FsbLoader.TryLoadFsbFromByteArray(bytes, out var bank) || bank.Samples.Count == 0)
                throw new InvalidDataException("not an FSB5 sound bank");
            if (!bank.Samples[0].RebuildAsStandardFileFormat(out var data, out var ext))
                throw new InvalidDataException("unsupported FSB5 format " + bank.Header.AudioType);
            var file = Path.Combine(cacheDir, c.Key + "." + ext);
            File.WriteAllBytes(file, data);
            lock (files) files[c.Key] = file;
        }
    }
}
