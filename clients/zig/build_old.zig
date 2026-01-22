const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Options
    const build_tests = b.option(bool, "test", "Build tests") orelse true;
    const build_examples = b.option(bool, "example", "Build examples") orelse true;

    // C library dependency
    // We'll assume the C library is built separately or available as a system library
    // For now, we'll link against it

    // Expose modules
    _ = b.addModule("bitbarrel", .{
        .root_source_file = b.path("src/client.zig"),
        .target = target,
        .optimize = optimize,
    });

    _ = b.addModule("bitbarrel-errors", .{
        .root_source_file = b.path("src/errors.zig"),
        .target = target,
        .optimize = optimize,
    });

    _ = b.addModule("bitbarrel-message", .{
        .root_source_file = b.path("src/message.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tests
    if (build_tests) {
        // Unit tests in the source files
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .source_file = .{ .path = "src/client.zig" },
                .dependencies = &.{},
            }),
        });
        unit_tests.linkLibC();
        unit_tests.linkSystemLibrary("bitbarrel");
        unit_tests.linkSystemLibrary("ssl");
        unit_tests.linkSystemLibrary("crypto");
        unit_tests.linkSystemLibrary("pthread");

        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }

    // Examples
    if (build_examples) {
        const basic_example = b.addExecutable(.{
            .name = "basic-example",
            .root_source_file = .{ .path = "examples/basic_example.zig" },
            .target = target,
            .optimize = optimize,
        });

        basic_example.linkLibC();
        basic_example.linkSystemLibrary("bitbarrel");
        basic_example.linkSystemLibrary("ssl");
        basic_example.linkSystemLibrary("crypto");
        basic_example.linkSystemLibrary("pthread");

        b.installArtifact(basic_example);

        const pubsub_example = b.addExecutable(.{
            .name = "pubsub-example",
            .root_source_file = .{ .path = "examples/pubsub_example.zig" },
            .target = target,
            .optimize = optimize,
        });

        pubsub_example.linkLibC();
        pubsub_example.linkSystemLibrary("bitbarrel");
        pubsub_example.linkSystemLibrary("ssl");
        pubsub_example.linkSystemLibrary("crypto");
        pubsub_example.linkSystemLibrary("pthread");

        b.installArtifact(pubsub_example);
    }

    // Documentation
    const docs = b.addObject(.{
        .name = "bitbarrel-docs",
        .root_source_file = .{ .path = "src/client.zig" },
        .target = target,
        .optimize = optimize,
    });

    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&docs.step);

    // Print summary
    std.debug.print(
        \\BitBarrel Zig Build Summary:
        \\  Target: {s}
        \\  Optimize: {s}
        \\  Build tests: {}
        \\  Build examples: {}
        \\  Install prefix: {s}
        \\
    , .{
        @tagName(target.result),
        @tagName(optimize),
        build_tests,
        build_examples,
        b.install_prefix,
    });
}
