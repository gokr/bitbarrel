const std = @import("std");

// Import BitBarrel client
const bitbarrel = @import("bitbarrel");

pub fn main() !void {
    // Use GPA for memory allocation
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("BitBarrel Zig Client Example\n", .{});
    std.debug.print("============================\n\n", .{});

    // Create client configuration
    const config = bitbarrel.Config{
        .url = "ws://localhost:7687",
        .timeout_ms = 5000,
        .max_retries = 3,
        .enable_auto_reconnect = true,
    };

    // Create and connect client
    var client = try bitbarrel.Client.init(allocator, config);
    defer client.deinit();

    std.debug.print("✓ Connected to BitBarrel server\n", .{});

    // Create a barrel
    const barrel_name = "zig_test";
    client.createBarrel(barrel_name, .hash) catch |err| {
        std.debug.print("ℹ Barrel may already exist: {}\n", .{err});
    };

    // Open and use the barrel
    try client.openBarrel(barrel_name);
    try client.useBarrel(barrel_name);
    std.debug.print("✓ Using barrel: {s}\n", .{barrel_name});

    // Store some data
    const data = [_]struct { key: []const u8, value: []const u8 }{
        .{ .key = "name", .value = "Zig Client" },
        .{ .key = "version", .value = "1.0.0" },
        .{ .key = "language", .value = "Zig" },
    };

    std.debug.print("\nStoring data:\n", .{});
    for (data) |item| {
        try client.set(item.key, item.value);
        std.debug.print("  ✓ Set: {s} = {s}\n", .{ item.key, item.value });
    }

    // Retrieve data
    std.debug.print("\nRetrieving data:\n", .{});
    for (data) |item| {
        const value = try client.get(item.key);
        if (value) |v| {
            std.debug.print("  ✓ Get: {s} = {s}\n", .{ item.key, v });
        }
    }

    // Check existence
    std.debug.print("\nChecking existence:\n", .{});
    for (data) |item| {
        if (client.exists(item.key)) {
            std.debug.print("  ✓ Key exists: {s}\n", .{item.key});
        } else {
            std.debug.print("  ✗ Key not found: {s}\n", .{item.key});
        }
    }

    // Count keys
    const count = try client.count();
    std.debug.print("\n✓ Total keys in barrel: {}\n", .{count});

    // List all barrels
    std.debug.print("\nListing barrels:\n", .{});
    const barrels = try client.listBarrels();
    defer barrels.deinit();
    for (barrels.items) |barrel| {
        std.debug.print("  - {s}\n", .{barrel});
    }

    // Delete a key
    std.debug.print("\nDeleting key: {s}\n", .{data[0].key});
    try client.delete(data[0].key);

    // Verify deletion
    if (!client.exists(data[0].key)) {
        std.debug.print("✓ Key successfully deleted\n", .{});
    }

    // Close barrel
    try client.closeBarrel();
    std.debug.print("✓ Closed barrel\n", .{});

    std.debug.print("\n✓ Example completed successfully!\n", .{});
}
