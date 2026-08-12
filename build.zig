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
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = imports,
    });

    for (system_libs) |lib| root_mod.linkSystemLibrary(lib, .{});

    const exe = b.addExecutable(.{ .name = "forte-player", .root_module = root_mod });
    b.installArtifact(exe);

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
    for (system_libs) |lib| unit_mod.linkSystemLibrary(lib, .{});

    const unit_tests = b.addTest(.{ .root_module = unit_mod });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
}
