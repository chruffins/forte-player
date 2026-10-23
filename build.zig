const std = @import("std");

const system_libs = [_][]const u8{
    "allegro",
    "allegro_primitives",
    "allegro_image",
    "allegro_font",
    "allegro_ttf",
    "allegro_audio",
    "allegro_acodec",
    "allegro_dialog",
    "allegro_memfile",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Optional prefix of a custom Allegro 5 build (e.g. one compiled with MP3
    // and Opus support added to the acodec addon). When set, <prefix>/lib is
    // added to the linker search path AND to the runtime search path of the
    // produced binaries so they load that build instead of the distro's.
    //   zig build -Dallegro_prefix=/path/to/allegro
    // Prefer local MP3-enabled Allegro builds where the packaging helpers
    // install them; override with `-Dallegro_prefix=<path>` when needed.
    const default_allegro_prefix = switch (target.result.os.tag) {
        .linux => if (b.graph.environ_map.get("HOME")) |home| b.fmt("{s}/.local/forte-allegro-streaming", .{home}) else "",
        .macos => "/opt/homebrew/opt/allegro-mp3",
        else => "",
    };
    const allegro_prefix = b.option([]const u8, "allegro_prefix", "Prefix of a custom Allegro 5 install (adds <prefix>/lib to link + rpath)") orelse default_allegro_prefix;
    const taglib_prefix = b.option([]const u8, "taglib_prefix", "TagLib installation prefix (for example /usr or /opt/homebrew/opt/taglib)") orelse if (target.result.os.tag == .macos) "/opt/homebrew" else "/usr";
    const cxx = b.option([]const u8, "cxx", "C++ compiler used for the TagLib shim") orelse if (target.result.os.tag == .macos) "clang++" else "g++";
    const allegro_include = b.fmt("{s}/include", .{allegro_prefix});
    const taglib_include_root = b.fmt("{s}/include", .{taglib_prefix});
    const taglib_include = b.fmt("{s}/include/taglib", .{taglib_prefix});
    const taglib_lib = b.fmt("{s}/lib", .{taglib_prefix});
    const windows_stdcpp_import = b.fmt("{s}/lib/libstdc++.dll.a", .{taglib_prefix});
    const windows_libgcc = b.fmt("{s}/lib/libgcc_s.a", .{taglib_prefix});

    // Import the allegro5-zig wrapper as a dependency module.
    const dep = b.dependency("allegro", .{
        .target = target,
        .optimize = optimize,
        .include_path = b.fmt("{s}/include", .{allegro_prefix}),
    });
    const allegro = dep.module("allegro");

    const vaxis_dep = b.dependency("vaxis", .{ .target = target, .optimize = optimize });
    const vaxis = vaxis_dep.module("vaxis");

    // zig-sqlite (vendored in external/zig-sqlite).
    const sdep = b.dependency("sqlite", .{ .target = target, .optimize = optimize });
    const sqlite = sdep.module("sqlite");

    // zscrobble (github.com/chruffins/zscrobble) for Last.fm scrobbling. Its
    // build doesn't publish a module, so root a module at its source path.
    const zscrobble_dep = b.dependency("zscrobble", .{ .target = target, .optimize = optimize });
    const zscrobble = b.createModule(.{
        .root_source_file = zscrobble_dep.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const c_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/forte_c.h"),
        .target = target,
        .optimize = optimize,
    });
    c_translate.addIncludePath(.{ .cwd_relative = "src/music" });
    c_translate.addIncludePath(.{ .cwd_relative = "src/world" });
    c_translate.addIncludePath(.{ .cwd_relative = allegro_include });
    c_translate.addIncludePath(.{ .cwd_relative = taglib_include_root });
    c_translate.addIncludePath(.{ .cwd_relative = taglib_include });
    const forte_c = c_translate.createModule();

    const control_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/control/control_c.h"),
        .target = target,
        .optimize = optimize,
    });
    const control_c = control_translate.createModule();

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "allegro", .module = allegro },
        .{ .name = "control_c", .module = control_c },
        .{ .name = "forte_c", .module = forte_c },
        .{ .name = "sqlite", .module = sqlite },
        .{ .name = "zscrobble", .module = zscrobble },
        .{ .name = "vaxis", .module = vaxis },
    };

    // C++ shim exposing TagLib embedded-art extraction. Compiled with the
    // system g++ (not Zig's clang) because libtag is built against libstdc++
    // and the std::string ABI must match at the symbol level.
    const shim_cmd = b.addSystemCommand(&.{ cxx, "-std=c++17", "-c" });
    shim_cmd.addFileArg(b.path("src/music/taglib_art.cpp"));
    shim_cmd.addArg(b.fmt("-I{s}", .{taglib_include_root}));
    shim_cmd.addArg("-o");
    const taglib_art_obj = shim_cmd.addOutputFileArg("taglib_art.o");

    // libtag.so is built with libstdc++; the shim object needs it at link
    // time too (no libstdc++.so dev symlink on this system, so link the
    // runtime soname directly).
    const libstdcpp: std.Build.LazyPath = .{ .cwd_relative = "/usr/lib/x86_64-linux-gnu/libstdc++.so.6" };
    const libgcc_s: std.Build.LazyPath = .{ .cwd_relative = "/usr/lib/x86_64-linux-gnu/libgcc_s.so.1" };

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = imports,
    });
    addCppShimRuntime(root_mod, target, taglib_art_obj, libstdcpp, libgcc_s, windows_stdcpp_import, windows_libgcc);
    root_mod.addIncludePath(.{ .cwd_relative = "src/music" });
    addLocalControlTransport(root_mod, target.result.os.tag);
    root_mod.addIncludePath(.{ .cwd_relative = allegro_include });
    root_mod.addIncludePath(.{ .cwd_relative = taglib_include });
    linkTagLib(root_mod, target, taglib_prefix);

    linkAllegroLibraries(root_mod, target, allegro_prefix);
    maybeUseAllegro(b, root_mod, allegro_prefix);
    root_mod.addLibraryPath(.{ .cwd_relative = taglib_lib });

    const exe = b.addExecutable(.{ .name = "forte-player", .root_module = root_mod });
    b.installArtifact(exe);
    // Ship the GUI font family and licenses alongside the executable. Runtime
    // lookup is deliberately separate so development builds can use assets/
    // directly while packaged builds use the installed share directory.
    b.installDirectory(.{
        .source_dir = b.path("assets"),
        .install_dir = .prefix,
        .install_subdir = "share/forte-player",
    });

    // ---- TUI frontend (second executable sharing the same deps) ----
    const tui_imports: []const std.Build.Module.Import = &.{
        .{ .name = "allegro", .module = allegro },
        .{ .name = "control_c", .module = control_c },
        .{ .name = "forte_c", .module = forte_c },
        .{ .name = "sqlite", .module = sqlite },
        .{ .name = "zscrobble", .module = zscrobble },
        .{ .name = "vaxis", .module = vaxis },
    };
    const tui_mod = b.createModule(.{
        .root_source_file = b.path("src/tui_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = tui_imports,
    });
    addCppShimRuntime(tui_mod, target, taglib_art_obj, libstdcpp, libgcc_s, windows_stdcpp_import, windows_libgcc);
    tui_mod.addIncludePath(.{ .cwd_relative = "src/music" });
    addLocalControlTransport(tui_mod, target.result.os.tag);
    tui_mod.addIncludePath(.{ .cwd_relative = allegro_include });
    tui_mod.addIncludePath(.{ .cwd_relative = taglib_include });
    linkTagLib(tui_mod, target, taglib_prefix);
    linkAllegroLibraries(tui_mod, target, allegro_prefix);
    maybeUseAllegro(b, tui_mod, allegro_prefix);
    tui_mod.addLibraryPath(.{ .cwd_relative = taglib_lib });

    const tui_exe = b.addExecutable(.{ .name = "forte-tui", .root_module = tui_mod });
    b.installArtifact(tui_exe);

    const mcp_mod = b.createModule(.{
        .root_source_file = b.path("src/mcp_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "control_c", .module = control_c }},
    });
    addLocalControlTransport(mcp_mod, target.result.os.tag);
    const mcp_exe = b.addExecutable(.{ .name = "forte-mcp", .root_module = mcp_mod });
    b.installArtifact(mcp_exe);

    const tui_run_cmd = b.addRunArtifact(tui_exe);
    tui_run_cmd.step.dependOn(b.getInstallStep());
    const tui_run_step = b.step("run-tui", "Run the TUI frontend");
    tui_run_step.dependOn(&tui_run_cmd.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run forte-player");
    run_step.dependOn(&run_cmd.step);

    // ---- Immersive third frontend: Zig app/HUD, wrapped template C renderer ----
    const world_mod = b.createModule(.{
        .root_source_file = b.path("src/world_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = imports,
    });
    addCppShimRuntime(world_mod, target, taglib_art_obj, libstdcpp, libgcc_s, windows_stdcpp_import, windows_libgcc);
    world_mod.addIncludePath(.{ .cwd_relative = allegro_include });
    world_mod.addIncludePath(.{ .cwd_relative = "src/music" });
    world_mod.addIncludePath(.{ .cwd_relative = taglib_include });
    world_mod.addLibraryPath(.{ .cwd_relative = taglib_lib });
    linkTagLib(world_mod, target, taglib_prefix);
    linkAllegroLibraries(world_mod, target, allegro_prefix);
    maybeUseAllegro(b, world_mod, allegro_prefix);
    addWorldRenderer(b, world_mod, target.result.os.tag);
    const world_exe = b.addExecutable(.{ .name = "forte-world", .root_module = world_mod });
    b.installArtifact(world_exe);
    const world_run = b.addRunArtifact(world_exe);
    world_run.step.dependOn(b.getInstallStep());
    b.step("run-world", "Run the firefly visualizer world").dependOn(&world_run.step);
    const recording_tests = b.addSystemCommand(&.{ "python3", "-B", "-m", "unittest", "discover", "-s", "tests", "-p", "test_world_recording.py" });
    b.step("test-recording", "Recording helper tests (Python 3; no display/audio)").dependOn(&recording_tests.step);

    const world_smoke_mod = b.createModule(.{
        .root_source_file = b.path("src/world_smoke.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "allegro", .module = allegro }, .{ .name = "forte_c", .module = forte_c } },
    });
    world_smoke_mod.addIncludePath(.{ .cwd_relative = allegro_include });
    linkAllegroLibraries(world_smoke_mod, target, allegro_prefix);
    maybeUseAllegro(b, world_smoke_mod, allegro_prefix);
    addWorldRenderer(b, world_smoke_mod, target.result.os.tag);
    const world_smoke = b.addExecutable(.{ .name = "forte-world-smoke", .root_module = world_smoke_mod });
    b.step("test-world", "Real-GPU checkerboard/skybox/firefly smoke test (requires display)")
        .dependOn(&b.addRunArtifact(world_smoke).step);

    // ---- Unit tests: ring buffer + transport (headless, no audio device) ----
    const unit_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = imports,
    });
    addCppShimRuntime(unit_mod, target, taglib_art_obj, libstdcpp, libgcc_s, windows_stdcpp_import, windows_libgcc);
    unit_mod.addIncludePath(.{ .cwd_relative = "src/music" });
    unit_mod.addIncludePath(.{ .cwd_relative = allegro_include });
    unit_mod.addIncludePath(.{ .cwd_relative = taglib_include });
    linkTagLib(unit_mod, target, taglib_prefix);
    linkAllegroLibraries(unit_mod, target, allegro_prefix);
    maybeUseAllegro(b, unit_mod, allegro_prefix);
    unit_mod.addLibraryPath(.{ .cwd_relative = taglib_lib });

    const unit_tests = b.addTest(.{ .root_module = unit_mod });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // Opt-in real-OpenGL verification. Not part of headless `test`, and never
    // starts the music engine or touches user configuration/library data.
    const gpu_mod = b.createModule(.{
        .root_source_file = b.path("src/gui_visualizer_smoke.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "allegro", .module = allegro }},
    });
    gpu_mod.addIncludePath(.{ .cwd_relative = allegro_include });
    linkAllegroLibraries(gpu_mod, target, allegro_prefix);
    maybeUseAllegro(b, gpu_mod, allegro_prefix);
    const gpu_exe = b.addExecutable(.{ .name = "forte-gpu-smoke", .root_module = gpu_mod });
    const gpu_run = b.addRunArtifact(gpu_exe);
    const gpu_step = b.step("test-gpu", "Run the real-OpenGL visualizer smoke test (requires display)");
    gpu_step.dependOn(&gpu_run.step);
}

fn addLocalControlTransport(mod: *std.Build.Module, os: std.Target.Os.Tag) void {
    mod.addIncludePath(.{ .cwd_relative = "src/control" });
    mod.addCSourceFiles(.{
        .files = &.{"src/control/local_ipc.c"},
        .flags = &.{"-std=c11"},
    });
    if (os == .windows) mod.linkSystemLibrary("advapi32", .{});
}

fn addWorldRenderer(b: *std.Build, mod: *std.Build.Module, os: std.Target.Os.Tag) void {
    mod.addIncludePath(b.path("src/world"));
    mod.addIncludePath(b.path("vendor/world-template"));
    mod.addCSourceFiles(.{
        .files = &.{ "src/world/bridge.c", "vendor/world-template/camera.c", "vendor/world-template/skybox.c" },
        .flags = &.{"-std=c17"},
    });
    switch (os) {
        .linux => {
            mod.linkSystemLibrary("GL", .{});
            mod.linkSystemLibrary("m", .{});
        },
        .macos => mod.linkFramework("OpenGL", .{}),
        .windows => mod.linkSystemLibrary("opengl32", .{}),
        else => @panic("Visualizer world requires desktop OpenGL on Linux, macOS or Windows"),
    }
}

fn addCppShimRuntime(mod: *std.Build.Module, target: std.Build.ResolvedTarget, shim: std.Build.LazyPath, libstdcpp: std.Build.LazyPath, libgcc_s: std.Build.LazyPath, windows_stdcpp_import: []const u8, windows_libgcc: []const u8) void {
    mod.addObjectFile(shim);
    switch (target.result.os.tag) {
        .linux => {
            // This installation has no libstdc++.so development symlink, so
            // retain the explicit runtime objects used by the local build.
            mod.addObjectFile(libstdcpp);
            mod.addObjectFile(libgcc_s);
        },
        .macos => mod.linkSystemLibrary("c++", .{}),
        .windows => {
            mod.addObjectFile(.{ .cwd_relative = windows_stdcpp_import });
            mod.addObjectFile(.{ .cwd_relative = windows_libgcc });
        },
        else => mod.linkSystemLibrary("stdc++", .{}),
    }
}

/// Use the shared TagLib import libraries on Windows. Linking TagLib's static
/// archives drags its C++/zlib implementation into the Zig link and requires
/// toolchain-specific runtime resolution; the packaged DLLs are already shipped.
fn linkTagLib(mod: *std.Build.Module, target: std.Build.ResolvedTarget, prefix: []const u8) void {
    if (target.result.os.tag == .windows) {
        mod.addObjectFile(.{ .cwd_relative = std.fmt.allocPrint(mod.owner.allocator, "{s}/lib/libtag.dll.a", .{prefix}) catch @panic("OOM") });
        mod.addObjectFile(.{ .cwd_relative = std.fmt.allocPrint(mod.owner.allocator, "{s}/lib/libtag_c.dll.a", .{prefix}) catch @panic("OOM") });
    } else {
        mod.linkSystemLibrary("tag", .{});
        mod.linkSystemLibrary("tag_c", .{});
    }
}

/// If a custom Allegro prefix was supplied, add <prefix>/lib to both the link
/// search path and the produced binary's runtime path, so it loads that build
/// (e.g. one with MP3/Opus in acodec) instead of the distro's Allegro.
fn linkAllegroLibraries(mod: *std.Build.Module, target: std.Build.ResolvedTarget, prefix: []const u8) void {
    if (target.result.os.tag == .windows) {
        for (system_libs) |lib| mod.addObjectFile(.{ .cwd_relative = std.fmt.allocPrint(mod.owner.allocator, "{s}/lib/lib{s}.dll.a", .{ prefix, lib }) catch @panic("OOM") });
    } else {
        for (system_libs) |lib| mod.linkSystemLibrary(lib, .{});
    }
}

fn maybeUseAllegro(b: *std.Build, mod: *std.Build.Module, prefix: []const u8) void {
    if (prefix.len == 0) return;
    const lib = b.fmt("{s}/lib", .{prefix});
    mod.addLibraryPath(.{ .cwd_relative = lib });
    mod.addRPath(.{ .cwd_relative = lib });
}
