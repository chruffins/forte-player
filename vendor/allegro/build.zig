const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const al_translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    const system_include = if (target.result.os.tag == .macos) "/opt/homebrew/include" else "/usr/include";
    al_translate_c.addSystemIncludePath(.{ .cwd_relative = system_include });

    const allegro = b.addModule("allegro", .{
        .root_source_file = b.path("src/allegro.zig"),
        .target = target,
        .link_libc = true,
        .imports = &.{
            .{ .name = "c", .module = al_translate_c.createModule() },
        },
    });

    // ---- Test executable (exercises the wrapper headlessly where possible) ----
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .link_libc = true,
        .imports = &.{
            .{ .name = "allegro", .module = allegro },
        },
    });
    const tests = b.addExecutable(.{ .name = "allegro5-zig-tests", .root_module = test_mod });
    tests.root_module.linkSystemLibrary("allegro", .{});
    tests.root_module.linkSystemLibrary("allegro_primitives", .{});
    tests.root_module.linkSystemLibrary("allegro_image", .{});
    tests.root_module.linkSystemLibrary("allegro_font", .{});
    tests.root_module.linkSystemLibrary("allegro_ttf", .{});
    tests.root_module.linkSystemLibrary("allegro_audio", .{});
    tests.root_module.linkSystemLibrary("allegro_acodec", .{});
    tests.root_module.linkSystemLibrary("allegro_dialog", .{});
    tests.root_module.linkSystemLibrary("allegro_video", .{});
    b.installArtifact(tests);

    const test_step = b.step("test", "Build and run the wrapper tests");
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
