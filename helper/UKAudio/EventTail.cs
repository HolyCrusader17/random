using System.Collections.Generic;
using System.IO;
using System.Text;

namespace UKAudio
{
    internal struct GameEvent
    {
        public long Seq;
        public string Kind;
        public string Arg;
    }

    // Tails events.log ("seq<TAB>kind<TAB>arg" per line). The Lua mod empties the file when the game starts,
    // so a file shorter than our position means a new session: start again from the top.
    internal sealed class EventTail
    {
        readonly string path;
        long position;
        long lastSeq = -1;
        string partial = "";

        public EventTail(string path) { this.path = path; }

        public IEnumerable<GameEvent> ReadNew()
        {
            var result = new List<GameEvent>();
            if (!File.Exists(path)) return result;
            try
            {
                using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    if (fs.Length < position) { position = 0; lastSeq = -1; partial = ""; }
                    if (fs.Length == position) return result;
                    fs.Position = position;
                    var bytes = new byte[fs.Length - position];
                    int n = fs.Read(bytes, 0, bytes.Length);
                    position += n;
                    var text = partial + Encoding.UTF8.GetString(bytes, 0, n);
                    var lines = text.Split('\n');
                    partial = lines[lines.Length - 1];
                    for (int i = 0; i < lines.Length - 1; i++)
                    {
                        var parts = lines[i].TrimEnd('\r').Split('\t');
                        if (parts.Length < 2 || !long.TryParse(parts[0], out var seq)) continue;
                        if (seq <= lastSeq) { lastSeq = -1; } // counter restarted with a new game session
                        lastSeq = seq;
                        result.Add(new GameEvent { Seq = seq, Kind = parts[1], Arg = parts.Length > 2 ? parts[2] : "" });
                    }
                }
            }
            catch (IOException) { }
            return result;
        }
    }
}
