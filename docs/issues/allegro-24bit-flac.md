# Early stop playing 24-bit FLAC through Allegro

Status: reproducible locally; unresolved. Suspected Allegro acodec / stream-mixer
integration issue, **not yet isolated to a confirmed upstream decoder bug**.
Latest Allegro5 main has not been tested against this reproduction.

## Observed behavior

A generated stereo, 44.1 kHz, 60-second FLAC with 24-bit samples loads successfully
and reports the correct duration, but playback becomes inactive at approximately
0.12 seconds. The same signal encoded as 16-bit FLAC plays normally, advances its
position, and supplies nonzero samples to Forte's visualizer.

Reproduced in both `forte-world` and the ordinary `forte-player` gallery, using
isolated XDG config/data directories. This is not specific to the 3D renderer.
The world diagnostic log reported `playing=false position=0.12`; mixer capture
sequence numbers continued increasing, but visualization levels decayed to zero.

This observation does not establish that all 24-bit FLACs fail or identify whether
the cause is decoding, sample-depth conversion, stream feeding, or Forte's event
handling. No production workaround or backend change was made.

## Local backend and relevant configuration

- Linux desktop.
- Actual linked Allegro libraries: `~/.local/forte-allegro-streaming/lib/`.
- That installation's headers report **5.2.12 (GIT)**. Exact source commit and
  local patches have not been recorded here; this is not proof it matches main.
- `libFLAC.so.14` was loaded from the system library directory.
- Forte driver: `src/core/driver.zig`, `AllegroDriver`.
- Voice and mixer: 44100 Hz, stereo, `ALLEGRO_AUDIO_DEPTH_INT16`.
- Stream: `al_load_audio_stream(path, 4, 4096)`, attached to that mixer.
- Capture uses the existing mixer postprocess callback.

Important: plain `pkg-config --modversion allegro_acodec-5` reported the separate
system installation (5.2.10), **not** the libraries the executable loaded. Use
`ldd zig-out/bin/forte-world` to verify which installation is actually tested.

## Reproduction fixtures

Requires ffmpeg/ffprobe. These commands create a fresh temporary directory and
never touch your real library or config.

```sh
repro=$(mktemp -d /tmp/forte-flac-repro.XXXXXX)
mkdir -p "$repro/music" "$repro/config/forte-player" "$repro/data"

ffmpeg -v error -f lavfi \
  -i 'aevalsrc=0.13*sin(2*PI*120*t)*(0.4+0.6*sin(2*PI*0.7*t)^2)+0.06*sin(2*PI*720*t)*(0.5+0.5*sin(2*PI*1.1*t))+0.03*sin(2*PI*3100*t):s=44100' \
  -t 60 -ac 2 -sample_fmt s32 -c:a flac \
  -metadata title='24bit fixture' -metadata artist='Forte reproduction' \
  "$repro/music/24bit.flac"

ffmpeg -v error -i "$repro/music/24bit.flac" -sample_fmt s16 -c:a flac \
  -metadata title='16bit fixture' "$repro/music/16bit.flac"

for file in "$repro"/music/*.flac; do
  ffprobe -v error -show_entries \
    stream=sample_fmt,bits_per_raw_sample,sample_rate,channels:format=duration \
    "$file"
done

printf '[paths]\nmusic_directory=%s/music\n[audio]\nvolume_percent=2\n[profiles]\nactive=Default\n[profile_Default]\nvolume_percent=2\nnormalization_enabled=0\n' \
  "$repro" > "$repro/config/forte-player/config.ini"

XDG_CONFIG_HOME="$repro/config" XDG_DATA_HOME="$repro/data" \
  FORTE_WORLD_DIAGNOSTICS=1 zig build run-world
```

Expected probe results: 24-bit is `s32`, `bits_per_raw_sample=24`; 16-bit is
`s16`, `bits_per_raw_sample=16`. Both should report stereo, 44100 Hz, 60 seconds.
After scanning, use Tab to search `24bit`, then Enter. Observe position/playback
in the terminal diagnostic log. Repeat with `16bit`. Do not rely on startup
track ordering. Volume is deliberately low, but playback will be audible.

To check the gallery with the same fixtures, exit the world first, then run:

```sh
XDG_CONFIG_HOME="$repro/config" XDG_DATA_HOME="$repro/data" \
  zig build run
```

Original local evidence, while `/tmp` files remain available:

- `/tmp/forte-world-smoke/codec-music/test24.flac` (24-bit)
- `/tmp/forte-world-smoke/music/test.flac` (16-bit)
- `/tmp/forte-world-smoke/trace.log` (24-bit early-stop diagnostics)
- `/tmp/forte-world-smoke/trace16.log` (working 16-bit diagnostics)
- `/tmp/forte-world-smoke/codec-gallery.png` (gallery stopped at 0:00 / 1:00)

## Checking latest Allegro5 main

1. Build/install main with audio, acodec and FLAC support into a separate prefix.
   Record its git SHA, local patches, build options and libFLAC version.
2. Rebuild Forte with that prefix (matching headers **and** libraries):

   ```sh
   zig build -Dallegro_prefix=/path/to/allegro-main-install
   ldd zig-out/bin/forte-world | grep -E 'allegro|FLAC'
   ```

3. Run the isolated reproduction above using
   `zig build run-world -Dallegro_prefix=/path/to/allegro-main-install`.
4. Verify that each fixture plays well beyond 0.12 seconds, ideally through its
   full duration, with active playback, advancing position and nonzero capture.
   Also test pause/resume and seeking; repeat in the gallery.
5. If it still fails, reduce to a standalone C test with the same INT16 voice /
   mixer and stream parameters. Compare a FLOAT32 mixer, and playback without
   Forte's capture callback or queue/event logic, to isolate the failing layer
   before filing an upstream decoder report.

Record the tested SHA and outcome here once verified. Do not infer resolution
from a version string or unrelated FLAC release note alone.
