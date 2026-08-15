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
    //   zig build -Dallegro_prefix=/home/chris/.local/forte-allegro
    const allegro_prefix = b.option([]const u8, "allegro_prefix", "Prefix of a custom Allegro 5 install (adds <prefix>/lib to link + rpath)") orelse "";

    // Import the allegro5-zig wrapper as a dependency module.
    const dep = b.dependency("allegro", .{ .target = target, .optimize = optimize });
    const allegro = dep.module("allegro");

    // zig-sqlite (vendored in external/zig-sqlite).
    const sdep = b.dependency("sqlite", .{ .target = target, .optimize = optimize });
    const sqlite = sdep.module("sqlite");

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "allegro", .module = allegro },
        .{ .name = "sqlite", .module = sqlite },
    };

    // C++ shim exposing TagLib embedded-art extraction. Compiled with the
    // system g++ (not Zig's clang) because libtag is built against libstdc++
    // and the std::string ABI must match at the symbol level.
    const shim_cmd = b.addSystemCommand(&.{ "g++", "-std=c++17", "-c", "src/music/taglib_art.cpp", "-I/usr/include", "-o" });
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
    root_mod.addObjectFile(taglib_art_obj);
    root_mod.addObjectFile(libstdcpp);
    root_mod.addObjectFile(libgcc_s);
    root_mod.addIncludePath(.{ .cwd_relative = "src/music" });
    root_mod.addIncludePath(.{ .cwd_relative = "/usr/include/taglib" });
    root_mod.linkSystemLibrary("tag", .{});

    for (system_libs) |lib| root_mod.linkSystemLibrary(lib, .{});
    maybeUseAllegro(b, root_mod, allegro_prefix);
    root_mod.addIncludePath(.{ .cwd_relative = "/usr/include/taglib" });
    root_mod.linkSystemLibrary("tag_c", .{});
    const exe = b.addExecutable(.{ .name = "forte-player", .root_module = root_mod });
    b.installArtifact(exe);

    // ---- TUI frontend (second executable sharing the same deps) ----
    const tui_mod = b.createModule(.{
        .root_source_file = b.path("src/tui_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = imports,
    });
    tui_mod.addObjectFile(taglib_art_obj);
    tui_mod.addObjectFile(libstdcpp);
    tui_mod.addObjectFile(libgcc_s);
    tui_mod.addIncludePath(.{ .cwd_relative = "src/music" });
    tui_mod.addIncludePath(.{ .cwd_relative = "/usr/include/taglib" });
    tui_mod.linkSystemLibrary("tag", .{});
    for (system_libs) |lib| tui_mod.linkSystemLibrary(lib, .{});
    maybeUseAllegro(b, tui_mod, allegro_prefix);
    tui_mod.addIncludePath(.{ .cwd_relative = "/usr/include/taglib" });
    tui_mod.linkSystemLibrary("tag_c", .{});
    const tui_exe = b.addExecutable(.{ .name = "forte-tui", .root_module = tui_mod });
    b.installArtifact(tui_exe);

    const tui_run_cmd = b.addRunArtifact(tui_exe);
    tui_run_cmd.step.dependOn(b.getInstallStep());
    const tui_run_step = b.step("run-tui", "Run the TUI frontend");
    tui_run_step.dependOn(&tui_run_cmd.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run forte-player");
    run_step.dependOn(&run_cmd.step);

    // ---- Unit tests: ring buffer + transport (headless, no audio device) ----
    const unit_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = imports,
    });
    unit_mod.addObjectFile(taglib_art_obj);
    unit_mod.addObjectFile(libstdcpp);
    unit_mod.addObjectFile(libgcc_s);
    unit_mod.addIncludePath(.{ .cwd_relative = "src/music" });
    unit_mod.addIncludePath(.{ .cwd_relative = "/usr/include/taglib" });
    unit_mod.linkSystemLibrary("tag", .{});
    for (system_libs) |lib| unit_mod.linkSystemLibrary(lib, .{});
    maybeUseAllegro(b, unit_mod, allegro_prefix);

    const unit_tests = b.addTest(.{ .root_module = unit_mod });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
}

/// If a custom Allegro prefix was supplied, add <prefix>/lib to both the link
/// search path and the produced binary's runtime path, so it loads that build
/// (e.g. one with MP3/Opus in acodec) instead of the distro's Allegro.
fn maybeUseAllegro(b: *std.Build, mod: *std.Build.Module, prefix: []const u8) void {
    if (prefix.len == 0) return;
    const lib = b.fmt("{s}/lib", .{prefix});
    mod.addLibraryPath(.{ .cwd_relative = lib });
    mod.addRPath(.{ .cwd_relative = lib });
}
