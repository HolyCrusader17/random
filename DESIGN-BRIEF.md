# Ready or Not × ULTRAKILL — design brief

(Copied from the creator's brief; the original lives in `D:\Mashups\RoN-ULTRAKILL-Mashup\DESIGN-BRIEF.md`.)

- **Host (primary): Ready or Not.** The player is in a normal raid with their AI squad.
- **Companion: ULTRAKILL.** Its real sounds and soundtrack are read from the player's own ULTRAKILL
  install at runtime via `{game:ultrakill}`; nothing from ULTRAKILL is shipped.
- **Full design:** ULTRAKILL style meter (D → C → B → A → S → SS → SSS → ULTRAKILL) with ULTRAKILL
  sounds; Blood-is-fuel healing; parry; ULTRAKILL soundtrack that gets more intense with rank.
- **Three modes**, switched with an in-game hotkey (mode shown on the meter):
  1. **Clean:** arrests, non-lethal takedowns, fast clears give most style; unauthorized kills drop you to D.
  2. **ULTRAKILL Rules:** Ready or Not's unauthorized-force penalties off; kills, headshots, multi-kills
     feed the meter; end score = best rank.
  3. **Power:** both earn style; higher rank buffs reload speed and movement; near-unstoppable at
     ULTRAKILL rank until hit.
- **Solo first** (with AI squad), structured so co-op can be added later.
- **Version 1 scope:** style meter + ULTRAKILL sounds + soundtrack, all three modes. Blood healing and
  parry in later updates.
- **Risks to check early:** drawing the HUD meter via UE4SS without the Unreal Editor; playing ULTRAKILL
  audio inside Ready or Not (bundled audio helper); where ULTRAKILL stores its sounds/music.
