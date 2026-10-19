# Template rendering subset

Copied from `/home/chris/projects/template/src/render/` for Forte's separate
visualizer-world executable. `skybox.c/.h` are unchanged. `camera.c/.h` retain
the template camera mathematics, but replace the Box3D `b3Vec3` parameter with
an equivalent local three-float `TemplateVec3`; no rigid-body system is needed
for the checkerboard-only free-walk prototype.

The Zig-facing ownership boundary is `src/world/template.zig`, backed by
`src/world/bridge.c`. The gallery GUI and TUI do not link this renderer.
OpenGL compatibility profile is required by the original skybox state bridge.

The six original night-ocean faces and their conversion provenance are copied
under `assets/world/skybox/night-ocean`. The template explicitly states that
the source skybox attribution/license could not be found. Verify permission
or replace those images before distributing this app. No asset permission is
implied by this local prototype.
