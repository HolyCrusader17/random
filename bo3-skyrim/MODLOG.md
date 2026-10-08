# MODLOG: BO3 Arsenal for Skyrim

## 2026-10-08: intake and design sheets
- Melty: Skyrim SE (skyrim-se) is the host; one-click route = .asi via ultimate-asi-loader, launch
  {game}/SkyrimSE.exe (game_info ASI recipe; same as live mashup prepare-to-die-dragonborn, 1.7.104).
  SKSE64 auto-installs only on 1.6.1179 / 1.5.97: not used.
- BO3 is not in Melty's catalog (custom-call-of-duty-black-ops-iii, Steam 311210): role secondary;
  the mod finds the install itself. No Skyrim × CoD mashup exists on Melty.
- User choices: v1 = whole arsenal (all guns incl. wonder weapons, all attachments) + scorestreaks +
  movement; Gunsmith menu F6 + Mystery Box at Riverwood; solo now, co-op later.
- Open risk: reading BO3 content offline. Weapon defs/models live in zone/*.ff fastfiles; community
  extractors (Greyhound) read them from a running BO3. Mod Tools reportedly ship only some assets
  (SoE, The Giant). Sound banks are sound/*.sabs/.sabl. Needs recon of a real BO3 install.
- Sheets written (13); tools/preflight.py: 8 blocking guesses, all BO3 internal names.
- Neither game is on this cloud machine; build + test happen on the user's Windows PC.
