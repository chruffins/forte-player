# Single-track world recording

## Compose the shot, then export

1. Run `zig build run-world` and walk/look until you like the framing.
2. Press **V** to save the viewpoint named `saved` (position, yaw/pitch and window
   dimensions). You can keep editing and press V again to replace that preset.
3. Press **F2** to record the current track, or open **Tab**, search/select another
   track and press **F2** in the picker. You do not need to start playback first.
4. The interactive window closes. A locked-camera render window opens with no
   HUD, and the recording is exported to `recordings/<filename>.mp4` under the
   current working directory. Repeats use `-2`, `-3`, etc.; nothing is overwritten.
   After export the app exits. Relaunch to compose another shot.

The preset must exist before F2; otherwise the HUD/picker asks you to save it.
The normal world restores the named preset on subsequent launches.

For named shots, start the composition session with:

```sh
zig build run-world -- --view my-shot
# Frame the shot, then V saves my-shot.
```

Presets are stored in Forte's existing config.ini under `[world_view_<name>]`.
Names allow 1–40 ASCII letters, digits, underscores and hyphens. Multiple named
presets can coexist. The camera cannot move during recording.

## Invoke directly

```sh
zig-out/bin/forte-world record "/music/track.flac" --view my-shot

zig build run-world -- record "/music/track.flac" --view my-shot \
  --output "/videos/track.mp4" --width 1920 --height 1080 --fps 60
```

`record --help` lists options. Python 3 and FFmpeg (including libx264 and AAC)
are required on PATH. No Python packages or desktop audio routing are needed.
A desktop compatibility OpenGL display is still required; this is not a
headless EGL renderer.

Defaults: saved viewpoint, saved window dimensions, 60 fps, H.264 CRF 18 / AAC
192 kbit/s in MP4. Dimensions must be even, between 480x320 and 3840x2160;
odd saved dimensions round down one pixel. Explicit width and height must be
specified together and may change the framing/aspect ratio. Older viewpoint
sections without dimensions default to 1280x720. Supported frame rates: 30/60.
Maximum track length is 24 hours. The default output name is based on the input
filename; explicit output paths fail if they already exist.

## Synchronization and sound

Export is **offline, frame-clocked**, not a screen recorder. FFmpeg decodes the
selected track once into 44.1 kHz stereo PCM. A mono derivative feeds Forte's
shared FFT/AGC and world glow envelope at a fixed 20 Hz analysis clock. The
renderer advances at `frame / fps`, with the same seeded fireflies and saved
pose, irrespective of wall time or pipe/encoder speed. The decoded stereo audio
is muxed into the final video. No input devices, desktop notifications, cursor,
window borders or HUD are captured.

This deliberately differs from live mixer capture: exports do not play through
speakers and do not depend on speaker volume, saved queue, repeat mode,
crossfade or normalization profiles. They use FFmpeg's decoding/downmixing,
not Allegro's realtime decoder. Consequently the local Allegro 24-bit FLAC
failure does not affect this export path. Original audio is converted to stereo
16-bit 44.1 kHz PCM and then AAC; this is not bit-perfect audio archival.

The final fractional video frame is included, so video may extend less than one
frame past the exact audio duration. AAC priming/padding is represented by the
container. No dropped render frames or accumulated wall-clock A/V drift occur.
The scene phase starts at zero on every recording; it does not capture the exact
momentary firefly positions you saw while composing. Repeat exports are visually
reproducible on the same renderer/backend, not guaranteed byte-identical across
GPU drivers or FFmpeg versions.

The render window shows progress via terminal logs. **Esc/window close** cancels
rendering; **Ctrl-C** cancels CLI recording. A failure or cancellation cleans up
children, decoded intermediates and partial video. Only successful rendering
and encoding publishes the final path, atomically without overwriting another
file. Encoding may run faster or slower than track duration. Decoded intermediates
consume temporary disk space, roughly stereo PCM plus mono float PCM (~350 KB/s).

## Implementation and validation

- `src/world_main.zig`: named viewpoint persistence and V/F2/CLI dispatch.
- `src/world/recording.zig`: streaming PCM analysis, fixed clock, locked native
  renderer, framebuffer-to-pipe output and cancellation events. No App/database
  or audio device is created in the rendering subprocess.
- `assets/world/record_world.py`: decode, encode/mux, child cleanup and safe final
  publication. Bundled with installed assets, not dependent on this checkout.
- `model.recordingFrames`: integer frame count with final partial frame.

`zig build test` includes recording-clock/name checks.
`zig build test-recording` runs Python view parsing and cleanup tests without
OpenGL/audio. `zig build test-world` retains GPU/state/lighting regression checks.

Live isolated-XDG smoke tests composed/saved a nondefault camera pose, exported
through the CLI and picker F2, and used ffprobe to verify a 3.01-second track:
91 H.264 frames at 30 fps and 3.01-second stereo AAC audio. UI export preserved
1120x720 saved framing. Repeating the export yielded identical decoded video
frame hashes. CLI interruption left no final/partial output; explicit existing
outputs were refused. Exported screenshots contain only the world.

Skybox source licensing is still unverified; resolve the asset permissions before
distributing the application or recordings that contain it.
