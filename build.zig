const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dusty_dep = b.dependency("dusty", .{
        .target = target,
        .optimize = optimize,
    });

    const zio_dep = dusty_dep.builder.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    });

    // Main library module
    const mod = b.addModule("testcontainers", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("dusty", dusty_dep.module("dusty"));
    mod.addImport("zio", zio_dep.module("zio"));

    // Unit tests
    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    lib_tests.root_module.addImport("dusty", dusty_dep.module("dusty"));
    lib_tests.root_module.addImport("zio", zio_dep.module("zio"));

    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_lib_tests.step);

    // Basic example executable
    const example = b.addExecutable(.{
        .name = "example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/basic.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    example.root_module.addImport("testcontainers", mod);
    example.root_module.addImport("zio", zio_dep.module("zio"));
    example.root_module.addImport("dusty", dusty_dep.module("dusty"));
    b.installArtifact(example);

    const run_example = b.addRunArtifact(example);
    const example_step = b.step("example", "Run the basic example");
    example_step.dependOn(&run_example.step);
}
