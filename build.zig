const std = @import("std");
const rlz = @import("raylib_zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    
    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
    });
    // raylib-zig bails out of its build() while raylib's lazy dependencies are
    // still unfetched, leaving no module behind. Return so the build runner
    // fetches them and reruns us, rather than panicking on the lookup below.
    if (b.graph.needed_lazy_dependencies.count() != 0) return error.LazyDependencyNeeded;

    const raylib = raylib_dep.module("raylib"); // main raylib module
    const raylib_artifact = raylib_dep.artifact("raylib"); // raylib C library

    const exe = b.addExecutable(.{
        .name = "myminesweeper",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .optimize = optimize,
            .target = target,
        }),
    });

    exe.root_module.linkLibrary(raylib_artifact);
    exe.root_module.addImport("raylib", raylib);

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run myminesweeper");
    run_step.dependOn(&run_cmd.step);

    b.installArtifact(exe);
}
