// build.zig — Zig's build system configuration.
//
// Unlike C/C++ Makefiles or Node's package.json scripts, Zig's build system
// is itself written in Zig. The `zig build` command looks for this file and
// calls the `build` function below.

const std = @import("std");

// This function is called by `zig build`. The `b` parameter is a pointer
// to a Build object — think of it like a build recipe builder.
pub fn build(b: *std.Build) void {
    // target: what platform to compile for.
    // By defaulting to `b.standardTargetOptions()`, it uses the host machine
    // but can be overridden with `zig build -Dtarget=x86_64-linux`.
    const target = b.standardTargetOptions(.{});

    // optimize: debug, release-safe, release-fast, or release-small.
    // Debug is the default — gives us safety checks and stack traces.
    const optimize = b.standardOptimizeOption(.{});

    // In Zig 0.16, executables are built from a Module. A module groups
    // source files + target + optimization level together.
    // "src/main.zig" is the root — Zig follows all @import()s from there.
    const exe = b.addExecutable(.{
        .name = "ms-mcp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Tell the build system to install the binary into zig-out/bin/
    // when the user runs `zig build`.
    b.installArtifact(exe);

    // Add a `zig build run` command that builds AND runs the binary.
    // Handy for testing during development.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    // Wire it up so `zig build run` works.
    const run_step = b.step("run", "Run the MCP server");
    run_step.dependOn(&run_cmd.step);

    // Add a `zig build test` command that runs all inline test blocks.
    // Zig discovers tests transitively through @import chains from the root.
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
