const std = @import("std");
const bitbarrel = @import("bitbarrel");

pub fn main() !void {
    // Use GPA for memory allocation
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== BitBarrel Zig PubSub Example ===\n\n", .{});

    // Step 1: Connect to BitBarrel server
    std.debug.print("1. Connecting to BitBarrel server...\n", .{});
    const config = bitbarrel.Config{
        .url = "ws://localhost:9876/ws",
        .timeout_ms = 10000,
        .max_retries = 3,
        .enable_auto_reconnect = true,
    };
    var client = bitbarrel.Client.init(allocator, config) catch |err| {
        std.debug.print("Failed to connect: {}\n", .{err});
        return;
    };
    defer client.deinit();
    std.debug.print("Connected to BitBarrel server\n\n", .{});

    // Step 2: Setup chat storage barrel
    std.debug.print("2. Setting up chat storage barrel...\n", .{});
    const barrel_name = "chat_storage";
    _ = client.createBarrel(barrel_name, .critbit) catch {
        // Barrel might already exist
        std.debug.print("Using existing chat_storage barrel\n", .{});
    };
    try client.useBarrel(barrel_name);
    std.debug.print("Using chat_storage barrel\n\n", .{});

    // Step 3: Subscribe to "room:general"
    std.debug.print("3. Subscribing to \"room:general\"...\n", .{});
    try client.subscribe("room:general");
    std.debug.print("Subscribed to \"room:general\"\n\n", .{});

    // Step 4: Publish chat messages
    std.debug.print("4. Publishing chat messages...\n", .{});
    const users = [_][]const u8{ "Alice", "Bob", "Charlie", "Diana", "Eve" };
    const messages = [_][]const u8{
        "Hello everyone!",
        "How are you all doing?",
        "This chat system is great!",
        "Anyone working on interesting projects?",
        "Let's schedule a meetup next week.",
    };

    for (users, messages, 0..) |user, message, i| {
        // Simple JSON construction
        var json_buf: [256]u8 = undefined;
        const data = std.fmt.bufPrint(&json_buf,
            \\{{"user":"{s}","message":"{s}","timestamp":{d}}}
        , .{ user, message, i }) catch "{}";

        try client.publish("room:general", data);
        std.debug.print("  {s}: {s}\n", .{ user, message });
    }
    std.debug.print("Published 5 messages\n\n", .{});

    // Step 5: Poll for messages
    std.debug.print("5. Polling for messages...\n", .{});
    var poll_count: usize = 0;
    while (poll_count < 10) : (poll_count += 1) {
        if (client.pollMessage()) |msg| {
            defer msg.deinit();
            std.debug.print("  Received: {s}: {s}\n", .{ msg.topic(), msg.data() });
        }
    }
    std.debug.print("Finished polling\n\n", .{});

    // Step 6: Watch key pattern
    std.debug.print("6. Watching key pattern \"user:*\"...\n", .{});
    try client.watchKey("user:*");
    std.debug.print("Watching \"user:*\" pattern\n\n", .{});

    // Step 7: Set some keys that match the pattern
    std.debug.print("7. Setting keys that match \"user:*\"...\n", .{});
    try client.set("user:1", "Alice");
    try client.set("user:2", "Bob");
    try client.set("user:3", "Charlie");
    std.debug.print("Set 3 user keys\n\n", .{});

    // Step 8: Poll for key change events
    std.debug.print("8. Polling for key change events...\n", .{});
    poll_count = 0;
    while (poll_count < 5) : (poll_count += 1) {
        if (client.pollMessage()) |msg| {
            defer msg.deinit();
            std.debug.print("  Key event: {s}: {s}\n", .{ msg.topic(), msg.data() });
        }
    }
    std.debug.print("Finished polling for key events\n\n", .{});

    // Step 9: Cleanup
    std.debug.print("9. Cleaning up...\n", .{});
    try client.unsubscribe("room:general");
    try client.unwatchKey("user:*");
    std.debug.print("Unsubscribed and unwatched\n", .{});

    std.debug.print("\n=== Example completed successfully! ===\n", .{});
}
