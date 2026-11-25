const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Single source of truth for the version: build.zig.zon.
    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);

    const exe = b.addExecutable(.{
        .name = "jsift",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", options);

    b.installArtifact(exe);

    // Shared library with a C ABI, loaded by the Python bindings. `zig build lib`.
    const lib = b.addLibrary(.{
        .name = "jsift",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .pic = true,
            // Keep debug info out of the wheels.
            .strip = optimize != .Debug,
        }),
    });
    lib.root_module.addOptions("build_options", options);
    const lib_step = b.step("lib", "Build the shared library (libjsift) for the Python bindings");
    lib_step.dependOn(&b.addInstallArtifact(lib, .{}).step);

    const test_step = b.step("test", "Run unit tests");

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addOptions("build_options", options);

    const run_tests = b.addRunArtifact(tests);

    test_step.dependOn(&run_tests.step);
}
