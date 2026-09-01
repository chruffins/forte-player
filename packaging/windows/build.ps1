$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Dist = Join-Path $Root 'dist\windows'
$TagLib = if ($env:TAGLIB_PREFIX) { $env:TAGLIB_PREFIX } else { 'C:\msys64\mingw64' }
$Allegro = if ($env:ALLEGRO_PREFIX) { $env:ALLEGRO_PREFIX } else { 'C:\msys64\mingw64' }
$Cxx = if ($env:CXX) { $env:CXX } else { 'g++' }

if (Test-Path $Dist) { Remove-Item -Recurse -Force $Dist }
New-Item -ItemType Directory -Force -Path $Dist | Out-Null

Push-Location $Root
try {
    zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows-gnu `
        -Dallegro_prefix=$Allegro -Dtaglib_prefix=$TagLib -Dcxx=$Cxx
} finally { Pop-Location }

Copy-Item "$Root\zig-out\bin\forte-player.exe" $Dist
Copy-Item "$Root\zig-out\bin\forte-tui.exe" $Dist
New-Item -ItemType Directory -Force -Path "$Dist\share\forte-player" | Out-Null
Copy-Item "$Root\zig-out\share\forte-player\*" "$Dist\share\forte-player\" -Recurse -Force

# Portable Windows builds need runtime DLLs beside the executables.
$DllDirs = @("$Allegro\bin", "$TagLib\bin")
$Names = @('allegro*.dll', 'libtag*.dll', 'libstdc++-6.dll', 'libgcc_s_seh-1.dll', 'libwinpthread-1.dll')
foreach ($Dir in $DllDirs) {
    foreach ($Name in $Names) {
        Get-ChildItem -Path $Dir -Filter $Name -ErrorAction SilentlyContinue | Copy-Item -Destination $Dist -Force
    }
}

Compress-Archive -Path "$Dist\*" -DestinationPath "$Root\dist\forte-player-windows.zip" -Force
Write-Host "Created $Root\dist\forte-player-windows.zip"
