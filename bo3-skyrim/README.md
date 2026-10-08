# Black Ops III Arsenal for Skyrim (working title)

Black Ops III's whole arsenal in Skyrim Special Edition: every BO3 gun, Zombies wonder weapons
included, with its attachments; BO3 scorestreaks earned from kill chains; and BO3 movement (thrust
jump, slide, wall run). A free Gunsmith menu (F6) and a Mystery Box near Riverwood (950 gold).

**Status: design stage. Nothing here is built or tested yet.**

- **Host (primary): Skyrim Special Edition**, 1.7.104 first. One `.asi` plugin (CommonLibSSE-NG)
  loaded by Ultimate ASI Loader, which Melty installs for every player; Play starts `SkyrimSE.exe`.
- **Black Ops III (secondary):** not in Melty's catalog, so the plugin finds the player's own
  Steam copy (app 311210) itself and reads guns, models and sounds from it at runtime. No BO3
  files are shipped. Without BO3 the game shows a notice and offers no guns.
- **Solo** for v1. The sheets keep co-op in mind for a later update.

## How it's built
`sheets/` is the source of truth: one JSON sheet per kind of thing (weapons, attachments,
scorestreaks, movement, UI, hooks, BO3 sources...), one row per thing. Change the sheet before the
code. `python3 tools/preflight.py` lists every empty cell, guess, broken reference, unbuilt row and
unverified row; build only when it reports no blocking items.
