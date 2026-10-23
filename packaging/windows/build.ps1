param([switch]$RunSmokeTest)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Dist = Join-Path $Root 'dist\windows'
$TagLib = if ($env:TAGLIB_PREFIX) { $env:TAGLIB_PREFIX } else { 'C:\msys64\mingw64' }
$LocalMp3Allegro = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'forte-player\allegro-mp3' } else { $null }
if ($env:ALLEGRO_PREFIX) {
    $Allegro = $env:ALLEGRO_PREFIX
} elseif ($LocalMp3Allegro -and (Test-Path (Join-Path $LocalMp3Allegro 'include\allegro5\allegro_acodec.h'))) {
    # Prefer the optional MP3-enabled Allegro build when installed, otherwise
    # fall back to MSYS2's standard build (which may not decode MP3).
    $Allegro = $LocalMp3Allegro
} else {
    $Allegro = 'C:\msys64\mingw64'
}
$Cxx = if ($env:CXX) { $env:CXX } else { 'g++' }
$RunningPlayer = Get-Process -Name 'forte-player', 'forte-tui' -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($Dist, [System.StringComparison]::OrdinalIgnoreCase) }
if ($RunningPlayer) {
    $Names = ($RunningPlayer | ForEach-Object { $_.ProcessName }) -join ', '
    throw "Close the running packaged player ($Names) before rebuilding; its DLLs are locked."
}
if (Test-Path $Dist) { Remove-Item -Recurse -Force $Dist }
New-Item -ItemType Directory -Force -Path $Dist | Out-Null

Push-Location $Root
try {
    & zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows-gnu `
        "-Dallegro_prefix=$Allegro" "-Dtaglib_prefix=$TagLib" "-Dcxx=$Cxx"
    if ($LASTEXITCODE -ne 0) { throw "zig build failed with exit code $LASTEXITCODE" }
} finally { Pop-Location }

Copy-Item "$Root\zig-out\bin\forte-player.exe" $Dist
Copy-Item "$Root\zig-out\bin\forte-tui.exe" $Dist
Copy-Item "$Root\zig-out\bin\forte-mcp.exe" $Dist
New-Item -ItemType Directory -Force -Path "$Dist\share\forte-player" | Out-Null
Copy-Item "$Root\zig-out\share\forte-player\*" "$Dist\share\forte-player\" -Recurse -Force

# Resolve and bundle the complete non-system DLL dependency closure of both
# frontends. Allegro codecs and TagLib have transitive MinGW DLL dependencies.
$DllDirs = @("$Allegro\bin", "$TagLib\bin") | Select-Object -Unique
$Seeds = @('allegro*.dll', 'libtag*.dll', 'libstdc++-6.dll', 'libgcc_s_seh-1.dll', 'libwinpthread-1.dll')
foreach ($Dir in $DllDirs) {
    foreach ($Name in $Seeds) {
        Get-ChildItem -Path $Dir -Filter $Name -ErrorAction SilentlyContinue | ForEach-Object {
            $Destination = Join-Path $Dist $_.Name
            if (-not (Test-Path $Destination)) { Copy-Item $_.FullName $Destination }
        }
    }
}

$Objdump = (Get-Command objdump -ErrorAction Stop).Source
$Pending = [System.Collections.Generic.Queue[string]]::new()
Get-ChildItem $Dist -Filter '*.exe' | ForEach-Object { $Pending.Enqueue($_.FullName) }
Get-ChildItem $Dist -Filter '*.dll' | ForEach-Object { $Pending.Enqueue($_.FullName) }
$Scanned = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$WindowsSystemDir = Join-Path $env:WINDIR 'System32'
$SystemDll = '^(api-ms-win-|ext-ms-win-)'
while ($Pending.Count -gt 0) {
    $Binary = $Pending.Dequeue()
    if (-not $Scanned.Add($Binary)) { continue }
    $Dependencies = & $Objdump -p $Binary 2>$null | ForEach-Object {
        if ($_ -match '^\s*DLL Name:\s*(.+)$') { $Matches[1].Trim() }
    }
    foreach ($Dependency in $Dependencies) {
        if ($Dependency -match $SystemDll -or (Test-Path (Join-Path $WindowsSystemDir $Dependency))) { continue }
        $Bundled = Join-Path $Dist $Dependency
        if (Test-Path $Bundled) { $Pending.Enqueue($Bundled); continue }
        $Source = $null
        foreach ($Dir in $DllDirs) {
            $Candidate = Join-Path $Dir $Dependency
            if (Test-Path $Candidate) { $Source = $Candidate; break }
        }
        if (-not $Source) { throw "Missing runtime DLL '$Dependency' required by '$Binary'" }
        Copy-Item $Source $Bundled -Force
        $Pending.Enqueue($Bundled)
    }
}

$Archive = Join-Path $Root 'dist\forte-player-windows.zip'
Compress-Archive -Path "$Dist\*" -DestinationPath $Archive -Force

# Validate the actual archive, not only the staging directory. Extract to a
# clean temporary location so stale DLLs in a developer's install cannot hide
# missing or mismatched package files.
$SmokeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("forte-package-smoke-" + [guid]::NewGuid().ToString('N'))
try {
    Expand-Archive -LiteralPath $Archive -DestinationPath $SmokeRoot
    foreach ($Required in @('forte-player.exe', 'forte-tui.exe', 'forte-mcp.exe', 'allegro-5.2.dll', 'allegro_acodec-5.2.dll', 'share/forte-player')) {
        if (-not (Test-Path (Join-Path $SmokeRoot $Required))) { throw "Package is missing '$Required'" }
    }

    # The Allegro DLLs must all come from the selected prefix. Mixing builds
    # with matching DLL names can load but fail during addon initialization.
    Get-ChildItem -Path $Allegro\bin -Filter 'allegro*.dll' -ErrorAction Stop | ForEach-Object {
        $PackagedDll = Join-Path $SmokeRoot $_.Name
        if (-not (Test-Path $PackagedDll) -or (Get-FileHash $_.FullName).Hash -ne (Get-FileHash $PackagedDll).Hash) {
            throw "Packaged Allegro DLL '$($_.Name)' does not match selected prefix '$Allegro'"
        }
    }

    # Check imports from the extracted files to make sure the archive contains
    # the complete non-system DLL closure.
    $ExtractedBinaries = @(Get-ChildItem $SmokeRoot -File -Include '*.exe', '*.dll' -Recurse)
    foreach ($Binary in $ExtractedBinaries) {
        $Dependencies = & $Objdump -p $Binary.FullName 2>$null | ForEach-Object {
            if ($_ -match '^\s*DLL Name:\s*(.+)$') { $Matches[1].Trim() }
        }
        foreach ($Dependency in $Dependencies) {
            if ($Dependency -match $SystemDll -or (Test-Path (Join-Path $WindowsSystemDir $Dependency))) { continue }
            if (-not (Test-Path (Join-Path $SmokeRoot $Dependency))) {
                throw "Extracted package '$($Binary.Name)' is missing dependency '$Dependency'"
            }
        }
    }

    if ($RunSmokeTest) {
        $ProfileRoot = Join-Path $SmokeRoot 'profile'
        $TestAppData = Join-Path $ProfileRoot 'Roaming'
        $TestLocalAppData = Join-Path $ProfileRoot 'Local'
        New-Item -ItemType Directory -Force -Path $TestAppData, $TestLocalAppData | Out-Null
        $OldAppData = $env:APPDATA
        $OldLocalAppData = $env:LOCALAPPDATA
        $Player = $null
        try {
            $env:APPDATA = $TestAppData
            $env:LOCALAPPDATA = $TestLocalAppData
            $Stdout = Join-Path $SmokeRoot 'smoke.stdout.log'
            $Stderr = Join-Path $SmokeRoot 'smoke.stderr.log'
            $Player = Start-Process -FilePath (Join-Path $SmokeRoot 'forte-player.exe') -WorkingDirectory $SmokeRoot `
                -PassThru -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr
            Start-Sleep -Seconds 4
            $Player.Refresh()
            if ($Player.HasExited) {
                $Details = if (Test-Path $Stderr) { Get-Content $Stderr -Raw } else { '' }
                throw "Freshly extracted GUI exited during startup (exit code $($Player.ExitCode)). $Details"
            }
            Write-Host 'Fresh-extract GUI smoke launch passed.'
        } finally {
            $env:APPDATA = $OldAppData
            $env:LOCALAPPDATA = $OldLocalAppData
            if ($Player) {
                $Player.Refresh()
                if (-not $Player.HasExited) {
                    Stop-Process -Id $Player.Id -Force
                    Wait-Process -Id $Player.Id -Timeout 10 -ErrorAction SilentlyContinue
                }
            }
        }
    }
} finally {
    if (Test-Path $SmokeRoot) {
        for ($Attempt = 0; $Attempt -lt 5; $Attempt++) {
            try {
                Remove-Item -LiteralPath $SmokeRoot -Recurse -Force -ErrorAction Stop
                break
            } catch {
                if ($Attempt -eq 4) { Write-Warning "Could not remove temporary smoke directory '$SmokeRoot': $_" }
                else { Start-Sleep -Seconds 1 }
            }
        }
    }
}
Write-Host "Created and validated $Archive"
