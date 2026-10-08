# MODLOG

## Facts
- Ready or Not: Unreal; Melty installs UE4SS v3.0.1; UE4SS mods go in `{game}/ReadyOrNot/Binaries/Win64/Mods/<Name>/Scripts/main.lua` + `enabled.txt`. game_info flags no account risk.
- ULTRAKILL: Unity; music lives in Addressables bundles at `ULTRAKILL_Data/StreamingAssets/aa/StandaloneWindows64` (`music_assets*.bundle`, per a Steam community thread). AudioClip data is FSB5 inside `.resource` bundle entries.
- Vanilla ULTRAKILL has no distinct sound per style rank (UltraRankSounds / Grey_Announcer mods add them by hooking `StyleHUD.AscendRank`), so rank-up sounds are picked from real ULTRAKILL clips via `sheets/audio.json` regexes.
- No public, confirmed list of Ready or Not class names was found; the mod tries candidate names from `sheets/hooks.json` and logs which answer.

## Melty
- Draft listing "ULTRAKILL OR NOT", modId d3ed94ab-50fc-46da-8540-f2cd7a447e88 (Studio: https://melty.gg/studio/d3ed94ab-50fc-46da-8540-f2cd7a447e88). Nothing uploaded or published yet.

## Route
UE4SS Lua (loader Melty installs) for the game side; a bundled .NET Framework 4.7.2 helper for audio,
started by Melty (`recipe.together`) with `{game:ultrakill}`; Melty writes `ULTRAKILL_DIR` into
`%LOCALAPPDATA%/RoNUltrakill/settings.cfg` before every Play as a fallback.

## Tested (offline, in the cloud container)
- `tools/gen.py`: preflight clean (no empty cells, refs resolve, every row used by code).
- `tests/sim_test.lua`: 38 checks pass against fake UE4SS/RoN objects (all three modes, buffs, absorb, decay, HUD, recon, mission end).
- Helper builds (net472, 0 warnings). Not run: needs Windows + a real ULTRAKILL install.
- Melty: inspect_package / validate_recipe / one_click_check → one click: yes.

## In-game checklist (on the creator's PC)
1. Launch from Melty; `UE4SS.log` shows `[RoNUK] loaded` and `style meter built`; meter visible top-right.
2. Start a raid; the log lists `character class ... -> suspect/civilian/swat`. Fix `class_*` candidates if needed.
3. Arrest, take down, kill: log shows `hook state_* ok via <name>`; fix candidates for any `NOT SEEN` (F10).
4. `%LOCALAPPDATA%/RoNUltrakill/helper.log`: index count, `clip-choices.txt` sfx + clean/battle pairs; music audible; rank sounds play. Adjust `sheets/audio.json` regexes from `clip-index.txt`.
5. F7 through all three modes; Power speeds you up; F8 hides the meter.
6. F10: note `penalty_suppress candidate` functions for the next update.
7. Capture a screenshot of the meter in a raid for the listing.
