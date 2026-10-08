using System;
using System.IO;
using System.Linq;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using NVorbis;

namespace UKAudio
{
    // A float stereo mixer on the default output device: two looping music layers with gain ramps, plus
    // one-shot sound effects.
    internal sealed class AudioEngine
    {
        const int Rate = 48000;
        readonly WaveFormat format = WaveFormat.CreateIeeeFloatWaveFormat(Rate, 2);
        MixingSampleProvider mixer;
        WaveOutEvent output;
        internal readonly Layer Clean = new Layer(), Battle = new Layer();

        public void Start()
        {
            mixer = new MixingSampleProvider(format) { ReadFully = true };
            mixer.AddMixerInput(Clean);
            mixer.AddMixerInput(Battle);
            output = new WaveOutEvent { DesiredLatency = 120 };
            output.Init(mixer);
            output.Play();
        }

        public void Stop()
        {
            try { output?.Stop(); output?.Dispose(); } catch { }
        }

        public void PlaySfx(string file, float volume)
        {
            try { mixer.AddMixerInput(new Gain(Convert(Open(file, loop: false)), volume)); }
            catch (Exception e) { Program.Log("sfx " + file + ": " + e.Message); }
        }

        internal ISampleProvider Convert(ISampleProvider src)
        {
            if (src.WaveFormat.Channels == 1) src = new MonoToStereoSampleProvider(src);
            else if (src.WaveFormat.Channels > 2) src = new FirstTwoChannels(src);
            if (src.WaveFormat.SampleRate != Rate) src = new WdlResamplingSampleProvider(src, Rate);
            return src;
        }

        internal static ISampleProvider Open(string file, bool loop)
        {
            if (file.EndsWith(".ogg", StringComparison.OrdinalIgnoreCase)) return new VorbisSource(file, loop);
            return new WavSource(file, loop);
        }

        // ------------------------------------------------------------------ providers
        sealed class VorbisSource : ISampleProvider, IDisposable
        {
            readonly VorbisReader reader;
            readonly bool loop;
            public VorbisSource(string file, bool loop)
            {
                reader = new VorbisReader(file);
                this.loop = loop;
                WaveFormat = WaveFormat.CreateIeeeFloatWaveFormat(reader.SampleRate, reader.Channels);
            }
            public WaveFormat WaveFormat { get; }
            public int Read(float[] buffer, int offset, int count)
            {
                int total = 0;
                while (total < count)
                {
                    int n = reader.ReadSamples(buffer, offset + total, count - total);
                    if (n == 0)
                    {
                        if (!loop || total == 0 && reader.SamplePosition == 0) break;
                        reader.SamplePosition = 0;
                        continue;
                    }
                    total += n;
                }
                if (total == 0 && !loop) Dispose();
                return total;
            }
            public void Dispose() => reader.Dispose();
        }

        sealed class WavSource : ISampleProvider
        {
            readonly WaveFileReader reader;
            readonly ISampleProvider samples;
            readonly bool loop;
            public WavSource(string file, bool loop)
            {
                reader = new WaveFileReader(file);
                samples = reader.ToSampleProvider();
                this.loop = loop;
            }
            public WaveFormat WaveFormat => samples.WaveFormat;
            public int Read(float[] buffer, int offset, int count)
            {
                int total = 0;
                while (total < count)
                {
                    int n = samples.Read(buffer, offset + total, count - total);
                    if (n == 0)
                    {
                        if (!loop || reader.Length == 0) break;
                        reader.Position = 0;
                        continue;
                    }
                    total += n;
                }
                if (total == 0 && !loop) reader.Dispose();
                return total;
            }
        }

        sealed class FirstTwoChannels : ISampleProvider
        {
            readonly ISampleProvider src;
            float[] tmp = new float[0];
            public FirstTwoChannels(ISampleProvider src)
            {
                this.src = src;
                WaveFormat = WaveFormat.CreateIeeeFloatWaveFormat(src.WaveFormat.SampleRate, 2);
            }
            public WaveFormat WaveFormat { get; }
            public int Read(float[] buffer, int offset, int count)
            {
                int ch = src.WaveFormat.Channels, frames = count / 2;
                if (tmp.Length < frames * ch) tmp = new float[frames * ch];
                int got = src.Read(tmp, 0, frames * ch) / ch;
                for (int i = 0; i < got; i++) { buffer[offset + 2 * i] = tmp[i * ch]; buffer[offset + 2 * i + 1] = tmp[i * ch + 1]; }
                return got * 2;
            }
        }

        sealed class Gain : ISampleProvider
        {
            readonly ISampleProvider src;
            readonly float gain;
            public Gain(ISampleProvider src, float gain) { this.src = src; this.gain = gain; }
            public WaveFormat WaveFormat => src.WaveFormat;
            public int Read(float[] buffer, int offset, int count)
            {
                int n = src.Read(buffer, offset, count);
                for (int i = 0; i < n; i++) buffer[offset + i] *= gain;
                return n;
            }
        }

        // A looping music layer whose source can be swapped and whose volume ramps to a target.
        internal sealed class Layer : ISampleProvider
        {
            ISampleProvider src;
            float gain, target, step;
            readonly object gate = new object();
            public WaveFormat WaveFormat { get; } = WaveFormat.CreateIeeeFloatWaveFormat(Rate, 2);

            public void SetSource(ISampleProvider s) { lock (gate) { (src as IDisposable)?.Dispose(); src = s; } }

            public void FadeTo(float to, double seconds)
            {
                lock (gate)
                {
                    target = to;
                    double samples = Math.Max(1, seconds * Rate * 2);
                    step = (float)(Math.Abs(to - gain) / samples);
                }
            }

            public int Read(float[] buffer, int offset, int count)
            {
                lock (gate)
                {
                    int n = src != null && (gain > 0 || target > 0) ? src.Read(buffer, offset, count) : 0;
                    for (int i = n; i < count; i++) buffer[offset + i] = 0;
                    for (int i = 0; i < count; i++)
                    {
                        if (gain < target) gain = Math.Min(target, gain + step);
                        else if (gain > target) gain = Math.Max(target, gain - step);
                        buffer[offset + i] *= gain;
                    }
                    return count;
                }
            }
        }
    }

    // Keeps the clean and battle halves of one ULTRAKILL track playing in sync and mixes them by music tier.
    internal sealed class MusicDirector
    {
        readonly AudioEngine engine;
        readonly ClipLibrary library;
        readonly Random rng = new Random();
        volatile bool ready;
        string tier = "calm";
        bool wantTrack = true;

        public MusicDirector(AudioEngine engine, ClipLibrary library) { this.engine = engine; this.library = library; }

        public void Ready() => ready = true;
        public void NextTrack() => wantTrack = true;

        public void SetTier(string id)
        {
            tier = id;
            Apply();
        }

        void Apply()
        {
            var t = Sheets.MusicTiers.FirstOrDefault(r => r.id == tier);
            if (t == null) return;
            var clean = Sheets.Audio.First(a => a.id == t.clean_layer);
            var battle = Sheets.Audio.First(a => a.id == t.battle_layer);
            engine.Clean.FadeTo((float)(t.clean_gain * clean.volume), t.crossfade_s);
            engine.Battle.FadeTo((float)(t.battle_gain * battle.volume), t.crossfade_s);
        }

        public void Update()
        {
            if (!ready || !wantTrack) return;
            wantTrack = false;
            var pairs = library.MusicPairs.Where(p => library.FileFor(p.clean) != null && library.FileFor(p.battle) != null).ToList();
            if (pairs.Count == 0) { Program.Log("no music pair available"); return; }
            var pick = pairs[rng.Next(pairs.Count)];
            Program.Log("music: " + pick.clean.Name + " / " + pick.battle.Name);
            // both layers restart together so the clean and battle versions stay in step
            engine.Clean.SetSource(engine.Convert(AudioEngine.Open(library.FileFor(pick.clean), loop: true)));
            engine.Battle.SetSource(engine.Convert(AudioEngine.Open(library.FileFor(pick.battle), loop: true)));
            Apply();
        }
    }
}
