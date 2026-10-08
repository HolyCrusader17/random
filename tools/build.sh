#!/usr/bin/env bash
# Preflight the sheets, run the offline simulation, build the audio helper and package the release.
#   tools/build.sh            -> dist/RoN-ULTRAKILL-<version>.zip
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"

python3 tools/gen.py                       # fails on any blocking preflight issue
lua5.4 tests/sim_test.lua                  # mod logic against fake UE4SS / Ready or Not
dotnet build helper/UKAudio/UKAudio.csproj -c Release -p:Version="$VERSION" -nologo -v q

STAGE=dist/stage
MOD="$STAGE/ReadyOrNot/Binaries/Win64/Mods/RoNUltrakill"
rm -rf "$STAGE" && mkdir -p "$MOD/Scripts" "$MOD/bin"
cp mod/RoNUltrakill/enabled.txt mod/RoNUltrakill/README.txt mod/RoNUltrakill/THIRD-PARTY-NOTICES.txt "$MOD/"
cp mod/RoNUltrakill/Scripts/main.lua mod/RoNUltrakill/Scripts/sheets.lua "$MOD/Scripts/"
cp helper/UKAudio/bin/Release/net472/*.dll helper/UKAudio/bin/Release/net472/UKAudio.exe \
   helper/UKAudio/bin/Release/net472/UKAudio.exe.config "$MOD/bin/"

ZIP="dist/RoN-ULTRAKILL-$VERSION.zip"
rm -f "$ZIP"
(cd "$STAGE" && TZ=UTC find . -exec touch -t 202601010000 {} + && zip -qrX "../$(basename "$ZIP")" ReadyOrNot)
echo "built $ZIP ($(stat -c %s "$ZIP") bytes, sha256 $(sha256sum "$ZIP" | cut -d' ' -f1))"
