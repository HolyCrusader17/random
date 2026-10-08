# Windows twin of tools/build.sh: preflight the sheets, run the offline simulation, build the audio helper
# and package the release.
#   powershell -ExecutionPolicy Bypass -File tools\build.ps1            -> dist\RoN-ULTRAKILL-<version>.zip
#   powershell -ExecutionPolicy Bypass -File tools\build.ps1 -Install   -> also copies the mod into Ready or Not
param(
    [string]$Version = $(if ($env:VERSION) { $env:VERSION } else { "0.1.0" }),
    [switch]$Install,
    [string]$GameDir = "E:\SteamLibrary\steamapps\common\Ready Or Not"
)
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

function Find-Tool([string[]]$names, [string[]]$extra) {
    foreach ($n in $names) { $c = Get-Command $n -ErrorAction SilentlyContinue | Where-Object Source -notmatch 'WindowsApps'; if ($c) { return $c[0].Source } }
    foreach ($p in $extra) { $hit = Get-ChildItem $p -ErrorAction SilentlyContinue | Select-Object -First 1; if ($hit) { return $hit.FullName } }
    throw "not found: $($names -join ', ')"
}
function Run([string]$exe) { & $exe @args; if ($LASTEXITCODE -ne 0) { throw "$exe failed ($LASTEXITCODE)" } }

$python = Find-Tool @("python3", "python") @("$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe")
$lua = Find-Tool @("lua5.4", "lua54", "lua") @("C:\Program Files*\Lua\*\lua*.exe", "$env:LOCALAPPDATA\Programs\Lua\*\lua*.exe")

Run $python tools/gen.py                         # fails on any blocking preflight issue
$env:SIM_TMP = "dist/sim"                        # sim_test's own rm/mkdir are Unix-only
if (Test-Path $env:SIM_TMP) { Remove-Item -Recurse -Force $env:SIM_TMP }
New-Item -ItemType Directory -Force "$env:SIM_TMP/RoNUltrakill" | Out-Null
Run $lua tests/sim_test.lua                      # mod logic against fake UE4SS / Ready or Not
Run dotnet build helper/UKAudio/UKAudio.csproj -c Release "-p:Version=$Version" -nologo -v q

$stage = "dist/stage"
$mod = "$stage/ReadyOrNot/Binaries/Win64/Mods/RoNUltrakill"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force "$mod/Scripts", "$mod/bin" | Out-Null
Copy-Item mod/RoNUltrakill/enabled.txt, mod/RoNUltrakill/README.txt, mod/RoNUltrakill/THIRD-PARTY-NOTICES.txt "$mod/"
Copy-Item mod/RoNUltrakill/Scripts/main.lua, mod/RoNUltrakill/Scripts/sheets.lua "$mod/Scripts/"
$out = "helper/UKAudio/bin/Release/net472"
Copy-Item "$out/*.dll", "$out/UKAudio.exe", "$out/UKAudio.exe.config" "$mod/bin/"

$zip = "dist/RoN-ULTRAKILL-$Version.zip"
if (Test-Path $zip) { Remove-Item $zip }
$fixed = [DateTime]::new(2026, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
Get-ChildItem -Recurse $stage | ForEach-Object { $_.LastWriteTimeUtc = $fixed }
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$root = (Resolve-Path $stage).Path
$z = [IO.Compression.ZipFile]::Open((Join-Path (Get-Location) $zip), "Create")
try {
    Get-ChildItem -Recurse -File "$root/ReadyOrNot" | Sort-Object FullName | ForEach-Object {
        $name = $_.FullName.Substring($root.Length + 1).Replace('\', '/')
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $_.FullName, $name) | Out-Null
    }
} finally { $z.Dispose() }
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
"built $zip ($((Get-Item $zip).Length) bytes, sha256 $hash)"

if ($Install) {
    $dest = Join-Path $GameDir "ReadyOrNot/Binaries/Win64/Mods/RoNUltrakill"
    $keep = if (Test-Path "$dest/settings.cfg") { Get-Content -Raw "$dest/settings.cfg" }
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    Copy-Item -Recurse "$mod" $dest
    if ($keep) { Set-Content -NoNewline -Encoding ascii "$dest/settings.cfg" $keep }
    "installed to $dest"
}
