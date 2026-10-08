# Ready or Not × ULTRAKILL

An ULTRAKILL style meter for Ready or Not raids. Play a normal raid with your AI squad while ULTRAKILL's
style ranks (D → C → B → A → S → SS → SSS → ULTRAKILL) judge how you clear it, and ULTRAKILL's own
soundtrack, read from your ULTRAKILL install, shifts from a track's clean version to its battle version as
your rank climbs.

- **Host game:** Ready or Not (UE4SS Lua mod; Melty installs UE4SS 3.0.1).
- **Companion game:** ULTRAKILL. Its music and sounds are read from the player's own install
  (`{game:ultrakill}`) by the bundled audio helper. No ULTRAKILL files are shipped.
- **Solo** (with the AI squad). Timing uses the server clock so co-op can be added later.

## Modes (F7 cycles, shown on the meter)
| Mode | What earns style | Special |
|---|---|---|
| Clean | arrests, non-lethal takedowns, fast clears | an unauthorized kill drops you to D |
| ULTRAKILL Rules | kills, headshots, multi-kills | score = best rank reached |
| Power | everything | rank speeds up movement and reloads; at ULTRAKILL rank the next hit is cancelled |

F8 shows/hides the meter, F9 writes a diagnostic report to `UE4SS.log`.

## How it's built
- `sheets/*.json` are the source of truth: ranks, modes, style events, hooks into the game, audio, music
  tiers, HUD and settings. Each row generates one struct.
- `tools/gen.py` preflights the sheets (empty cells, types, cross-sheet references, rows the code never uses)
  and generates `mod/RoNUltrakill/Scripts/sheets.lua` and `helper/UKAudio/Sheets.g.cs`. It also prints the
  list of rows still unverified in the running game.
- `mod/RoNUltrakill/Scripts/main.lua`: the UE4SS mod (meter, modes, HUD built from stock UMG classes,
  events to the helper).
- `helper/UKAudio`: .NET Framework 4.7.2 program (ships with Windows 10/11) that indexes ULTRAKILL's
  Addressables bundles with AssetsTools.NET, rebuilds the FSB5 clips with Fmod5Sharp and plays them with
  NAudio/NVorbis. Melty starts it alongside the game.
- `tests/sim_test.lua`: offline simulation of a raid against fake UE4SS/Ready or Not objects.
- `tools/build.sh`: preflight → simulation → helper build → `dist/RoN-ULTRAKILL-<version>.zip`.

## Status
Version 0.1.0 is **built but not yet tested in the real game**. The class and property names Ready or Not
uses are tried from candidate lists and logged; see `MODLOG.md` for the in-game checklist. Suppressing
Ready or Not's own unauthorized-force penalties in ULTRAKILL Rules is not in v1 (F9 lists the candidate
functions for a later update). Blood-is-fuel healing and parry are planned for later updates.

## License
MIT for this project's own code (see LICENSE). Others may remix it on Melty.

## Credits
Built with Claude Code. Bundled libraries (all MIT): AssetsTools.NET (nesrak1), Fmod5Sharp (Sam Byass),
NVorbis (Andrew Ward), NAudio (Mark Heath), OggVorbisEncoder (Steve Lillis), IndexRange (Bradley Grainger),
.NET System.* packages (.NET Foundation). Ready or Not © VOID Interactive; ULTRAKILL © Arsi "Hakita" Patala /
New Blood Interactive. This is an unofficial fan mashup.
