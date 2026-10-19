# Firefly world v1

`forte-world` is a separate third executable. It shares Forte's `App`, music
library/queue, sample capture and FFT, not the gallery's presentation. No change
to the gallery landing page or TUI controls is required.

## Scene

- One procedural dark checkerboard plane, fogged into the night-ocean sky.
- Same cubemap faces/orientation as `~/projects/template`; runtime linear sky
  intensity 0.035. Face bytes and conversion provenance are retained unchanged.
- Eye-level, camera-relative WASD walking, arrow or right-drag looking, bounded
  to the floor. No avatar, rigid bodies, spawned cubes, jumping or Box3D runtime.
- 288 fireflies represented by one immutable vertex buffer. Their seed centers,
  phases, colors and FFT-band indices are created once. Billboard position,
  flutter, radius, flicker and core/halo glow are evaluated in GLSL, in one swarm
  draw. No CPU particle update or per-firefly draw/texture upload each frame.
- Twelve vec4 uniforms carry 48 sanitized bands. Each firefly now emits a moving
  colored point light onto the checkerboard: upward-normal diffuse response,
  inverse-square-like attenuation and a smooth six-meter range cutoff. A second
  batched draw reuses the same immutable seed buffer and the exact same GPU
  center, FFT power, tint and flicker as the sprites. Only bounded floor
  footprints are shaded, not 288 lights per full-screen pixel. The old four
  synthetic pools are removed. Lights are unshadowed and currently affect the
  only scene surface, the floor; no HDR, bloom or full PBR/IBL is claimed.
  Near-eye size/fade limits prevent huge sprite orbs without extinguishing their
  ground light when the camera approaches. Ground-light strength is 2.4 (about
  2.7x the previous 0.9 setting).
- FFT runs at roughly 20 Hz only on fresh PCM capture; envelopes update at frame
  cadence and decay when playback is paused/stopped. A separate low-cost vocal
  prominence estimate downsamples each mono window to 11.025 kHz, measures
  normalized autocorrelation for 80–1000 Hz periodicity, applies an audibility
  gate, then smooths at frame cadence. A deterministic one-in-six subset of
  fireflies turns violet and modestly increases glow/size; all others keep their
  FFT-driven mint/amber palette. The general FFT spectrum is unchanged. This is a
  voice-like periodicity heuristic, not source separation: pitched instruments
  can trigger it, while breathy/unvoiced vocals may score low. That ambiguity is
  accepted for expressive visualization. Export uses the same analysis. Flight
  position no longer depends on FFT power; sampled audio cannot change the flight
  trajectory abruptly. World-only frame-rate-independent 65 ms attack / 100 ms
  release easing smooths billboard size and illumination without changing the
  shared GUI/TUI spectrum behavior. Shader time wraps at the shared 200*pi
  motion/flicker period rather than discontinuously restarting trajectories.
  The GPU smoke executable uses synthetic bands and vocal score.

## Native boundary

`vendor/world-template/camera.c/.h` and `skybox.c/.h` are the rendering subset of
the C template. The camera's three-float position type is locally adapted to
avoid pulling in unused Box3D APIs; its view/projection mathematics are unchanged.
`src/world/bridge.c/.h` owns the plane/swarm buffers, scene shaders and cubemap.
`template.zig` provides the typed, display-scoped Zig owner. The game template's
main loop, demo scene, audio system and physics are deliberately not imported.

The bridge restores caller shader, transforms, projection, blending, depth,
alpha, write masks and compatibility enables before HUD drawing. Resources are
released before display destruction. A compatibility-profile desktop OpenGL
context with a depth buffer is required. Missing sky falls back to a dark clear
background; missing scene shaders or unsupported world renderer produce a clean
error rather than pretending a 2D fallback is this experience.

## Frontend and input

`world_main.zig` owns App/scan lifecycle, playback, snapshots, text input, held
movement keys, and HUD. Fast startup scans are reconciled even if they complete
before the first frame. `model.zig` keeps walking/geometry/filtering testable
without a display. Focus loss clears held movement, dragging and pressed controls;
background playback intentionally continues. Right-drag look does not grab or
warp the desktop cursor.

The normal view has only track text, three transport controls and a seek line.
`H` hides it. `F1` shows controls. `Tab` opens a transient searchable music picker;
movement is suspended while picking, but playback/world animation continue.
Picker text/rows are owned by the frontend, not temporary input copies. Selecting
music transactionally replaces the saved album/playlist queue with the full
unfiltered library snapshot, starting at the selected row. Filtering never
changes next/previous order. This avoids `SongNotInQueue` for music outside the
old queue; a failed stream load restores the previous queue and playback.

- WASD walk; Shift faster; arrows/right-drag look; R reset camera.
- Space pause/resume; N/P next/previous; +/- volume.
- Tab picker; type to search; arrows/page keys select; Enter/click play.
- V saves the named viewpoint; F2 records the current/selected track from it.
- Esc closes the picker or exits the world.

`forte-world --view NAME` composes/restores named presets. `forte-world record
TRACK --view NAME` invokes the per-track, fixed-camera recording harness. It
uses a fixed frame clock and FFmpeg-decoded PCM for synchronized video/audio,
not live desktop or mixer capture. See [RECORDING.md](RECORDING.md).

Music settings/database/saved queue are shared with the other frontends; each app
has its own live playback engine. Avoid running multiple frontends together if
you need predictable saved-state ownership: last exit wins. `[world] width/height`
are independent of gallery dimensions and clamped to 480x320 through 8192x8192.
`FORTE_WORLD_DIAGNOSTICS=1` logs playback/capture/envelope health, approximate
frontend cadence, CPU draw-call time and camera position once per second. It is
not a GPU timer or benchmark. Pending resize/input events are drained before
swapping to avoid blocking on the window manager's resize handshake.

## Verification and known limits

`zig build test` includes pure camera movement, diagonal normalization, bounds,
compact HUD/picker geometry, filtering, selection outside an old album queue,
bounded/frame-rate-independent glow smoothing at 30/60/144 Hz, and vocal
periodicity confidence for silence, periodic tones, and noise.
`zig build test-world` is opt-in and
requires a real display; it does not create App, open user config/database or
initialize an audio device. It checks cubemap loading, silent/active/first/last
and invalid-band rendering, independently toggled point-light ground response
(with identical sprites), independent vocal accent response, continuity across
the old hourly clock boundary, camera change, caller-state restoration, exact
reinitialization, and resize. Pixel readback is confined to this test. Set
`FORTE_WORLD_CAPTURE=/tmp/world.png` to capture its active framebuffer.

Live app smoke checks used isolated XDG directories, a generated 16-bit FLAC
frequency fixture, playback/pause decay, picker filtering, HUD/help toggles and
1280x720 / 480x320 resizing. A separate two-track fixture with a saved one-song
album queue verified selecting the excluded song through a search, then previous /
next navigation through both songs. An existing local codec issue was also reproduced
in the gallery: a 24-bit FLAC fixture stops at about 0.12 seconds; the 16-bit
version plays and captures correctly. This frontend retains the existing audio
backend; investigating its 24-bit FLAC failure is separate work. The failing
layer is not yet isolated. See [the issue notes](../../docs/issues/allegro-24bit-flac.md)
for fixtures, backend details and latest-main verification steps.

The template explicitly says the source skybox attribution/license is unverified.
Verify permission or replace the images before distributing this prototype.
Controller bindings, pointer lock, physical interaction, library management,
accessibility, frame-time GPU profiling, returning to composition after export, camera paths
and additional worlds are future work.
