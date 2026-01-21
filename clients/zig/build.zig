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

    // Main bitbarrel module
    const bitbarrel_module = b.addModule(.{
        .name = "bitbarrel",
        .source_file = .{ .path = "src/client.zig" },
        .dependencies = &.{},
    });

    // Expose sub-modules
    _ = b.addModule(.{
        .name = "bitbarrel-errors",
        .source_file = .{ .path = "src/errors.zig" },
        .dependencies = &.{},
    });

    _ = b.addModule(.{
        .name = "bitbarrel-message",
        .source_file = .{ .path = "src/message.zig" },
        .dependencies = &.{},
    });

    // Tests
    if (build_tests) {
        const tests = b.addTest(.{
            .root_source_file = .{ .path = "src/client.zig" },
            .target = target,
            .optimize = optimize,
        });

        // Link C library
        tests.linkLibC();
        tests.linkSystemLibrary("bitbarrel");
        tests.linkSystemLibrary("ssl");
        tests.linkSystemLibrary("crypto");
        tests.linkSystemLibrary("pthread");

        const run_tests = b.addRunArtifact(tests);
        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_tests.step);

        // Test specific modules
        const error_tests = b.addTest(.{
            .root_source_file = .{ .path = "src/errors.zig" },
            .target = target,
            .optimize = optimize,
        });
        const run_error_tests = b.addRunArtifact(error_tests);
        test_step.dependOn(&run_error_tests.step);

        const message_tests = b.addTest(.{
            .root_source_file = .{ .path = "src/message.zig" },
            .target = target,
            .optimize = optimize,
        });
        const run_message_tests = b.addRunArtifact(message_tests);
        test_step.dependOn(&run_message_tests.step);

        // Integration tests
        const integration_tests = b.addTest(.{
            .root_source_file = .{ .path = "tests/test_integration.zig" },
            .target = target,
            .optimize = optimize,
        });

        // Link C library for integration tests
        integration_tests.linkLibC();
        integration_tests.linkSystemLibrary("bitbarrel");
        integration_tests.linkSystemLibrary("ssl");
        integration_tests.linkSystemLibrary("crypto");
        integration_tests.linkSystemLibrary("pthread");

        const run_integration_tests = b.addRunArtifact(integration_tests);
        test_step.dependOn(&run_integration_tests.step);
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
