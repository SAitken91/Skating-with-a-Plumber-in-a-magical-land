# Deploys the bridge, host and Lua mod into the private coopdx copy (game\) and starts it.
# First run: tools\launch.ps1 -Assets <folder with your converted Skate 3 assets>
param([switch]$NoLaunch, [string]$Assets)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$game = Join-Path $root "game"
$exe = Join-Path $game "sm64coopdx.exe"
if (-not (Test-Path $exe)) { throw "Missing $exe - extract sm64coopdx 1.5.1 (Windows) into the game folder" }

# Bridge: the original Discord SDK becomes discord_game_sdk_real.dll (exports are forwarded to it).
$real = Join-Path $game "discord_game_sdk_real.dll"
$sdk = Join-Path $game "discord_game_sdk.dll"
if (-not (Test-Path $real)) {
    if ((Get-Item $sdk).Length -ne 3891512) { throw "discord_game_sdk.dll is not the original SDK; restore it first" }
    Move-Item $sdk $real
}
Copy-Item (Join-Path $root "native\discord_game_sdk.dll") $sdk -Force

# Host and its settings.
$skate = Join-Path $game "skate"
New-Item -ItemType Directory -Force $skate | Out-Null
Get-Process sm64-skate-host -ErrorAction SilentlyContinue | Stop-Process -Force
Copy-Item (Join-Path $root "host\target\debug\sm64-skate-host.exe") $skate -Force
$ini = Join-Path $skate "settings.ini"
if ($Assets) { "[Skate]`r`nAssets=$Assets`r`n" | Set-Content -Encoding ascii $ini }
if (-not (Test-Path $ini)) { throw "Run once with -Assets <folder with your converted Skate 3 assets>" }

# Lua mod (mirrored so deleted files disappear too).
$mod = Join-Path $game "mods\sm64-skate"
if (Test-Path $mod) { Remove-Item -Recurse -Force $mod }
Copy-Item -Recurse (Join-Path $root "mod\sm64-skate") $mod
Remove-Item (Join-Path $skate "bridge.log") -ErrorAction SilentlyContinue

if ($NoLaunch) { return }
$save = Join-Path $game "user"
if (-not (Test-Path (Join-Path $save "baserom.us.z64"))) {
    throw "Put your Super Mario 64 (USA) ROM at game\user\baserom.us.z64 (tools\convert-rom.py converts .n64/.v64 dumps)"
}
Get-Process sm64coopdx -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 300
Start-Process -FilePath $exe -WorkingDirectory $game -ArgumentList @(
    "--savepath", "`"$save`"", "--skip-intro", "--no-discord", "--skip-update-check",
    "--windowed", "--width", "1280", "--height", "720", "--server", "7777", "--enable-mod", "sm64-skate")
