const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Options
    const build_tests = b.option(bool, "test", "Build tests") orelse true;
    const build_examples = b.option(bool, "example", "Build examples") orelse true;

    // Create internal modules for protocol and websocket
    const protocol_mod = b.createModule(.{
        .root_source_file = b.path("src/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });

    const websocket_mod = b.createModule(.{
        .root_source_file = b.path("src/websocket.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    websocket_mod.linkSystemLibrary("websockets", .{});

    // Create the main client module with dependencies on protocol and websocket
    const client_mod = b.createModule(.{
        .root_source_file = b.path("src/client.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = protocol_mod },
            .{ .name = "websocket", .module = websocket_mod },
        },
        .link_libc = true,
    });
    client_mod.linkSystemLibrary("websockets", .{});

    // Expose bitbarrel module for external use
    _ = b.addModule("bitbarrel", .{
        .root_source_file = b.path("src/client.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = protocol_mod },
            .{ .name = "websocket", .module = websocket_mod },
        },
        .link_libc = true,
    });

    // Tests
    if (build_tests) {
        // Protocol tests (standalone, no system libs needed)
        const protocol_test_mod = b.createModule(.{
            .root_source_file = b.path("src/protocol.zig"),
            .target = target,
            .optimize = optimize,
        });
        const protocol_tests = b.addTest(.{
            .name = "protocol-test",
            .root_module = protocol_test_mod,
        });
        const run_protocol_tests = b.addRunArtifact(protocol_tests);

        // WebSocket tests
        const websocket_test_mod = b.createModule(.{
            .root_source_file = b.path("src/websocket.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        websocket_test_mod.linkSystemLibrary("websockets", .{});
        const websocket_tests = b.addTest(.{
            .name = "websocket-test",
            .root_module = websocket_test_mod,
        });
        const run_websocket_tests = b.addRunArtifact(websocket_tests);

        // Client unit tests
        const client_test_mod = b.createModule(.{
            .root_source_file = b.path("src/client.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "protocol", .module = protocol_mod },
                .{ .name = "websocket", .module = websocket_mod },
            },
            .link_libc = true,
        });
        client_test_mod.linkSystemLibrary("websockets", .{});
        const client_tests = b.addTest(.{
            .name = "client-test",
            .root_module = client_test_mod,
        });
        const run_client_tests = b.addRunArtifact(client_tests);

        // Integration tests
        const integration_test_mod = b.createModule(.{
            .root_source_file = b.path("tests/test_integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bitbarrel", .module = client_mod },
                .{ .name = "protocol", .module = protocol_mod },
            },
            .link_libc = true,
        });
        integration_test_mod.linkSystemLibrary("websockets", .{});
        const integration_tests = b.addTest(.{
            .name = "integration-test",
            .root_module = integration_test_mod,
        });
        const run_integration_tests = b.addRunArtifact(integration_tests);

        // Test step
        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_protocol_tests.step);
        test_step.dependOn(&run_websocket_tests.step);
        test_step.dependOn(&run_client_tests.step);
        test_step.dependOn(&run_integration_tests.step);

        // Separate test steps for individual modules
        const test_protocol_step = b.step("test-protocol", "Run protocol tests");
        test_protocol_step.dependOn(&run_protocol_tests.step);

        const test_websocket_step = b.step("test-websocket", "Run websocket tests");
        test_websocket_step.dependOn(&run_websocket_tests.step);

        const test_client_step = b.step("test-client", "Run client tests");
        test_client_step.dependOn(&run_client_tests.step);

        const test_integration_step = b.step("test-integration", "Run integration tests");
        test_integration_step.dependOn(&run_integration_tests.step);
    }

    // Examples
    if (build_examples) {
        const basic_example_mod = b.createModule(.{
            .root_source_file = b.path("examples/basic_example.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bitbarrel", .module = client_mod },
            },
            .link_libc = true,
        });
        basic_example_mod.linkSystemLibrary("websockets", .{});
        const basic_example = b.addExecutable(.{
            .name = "basic-example",
            .root_module = basic_example_mod,
        });
        b.installArtifact(basic_example);

        const pubsub_example_mod = b.createModule(.{
            .root_source_file = b.path("examples/pubsub_example.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bitbarrel", .module = client_mod },
            },
            .link_libc = true,
        });
        pubsub_example_mod.linkSystemLibrary("websockets", .{});
        const pubsub_example = b.addExecutable(.{
            .name = "pubsub-example",
            .root_module = pubsub_example_mod,
        });
        b.installArtifact(pubsub_example);
    }
}
