const std = @import("std");
const bitbarrel = @import("bitbarrel");

pub fn main() !void {
    // Use GPA for memory allocation
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== BitBarrel Zig PubSub Chat Example (12-step pattern) ===\n\n", .{});

    // Step 1: Connect to BitBarrel server (localhost:9876)
    std.debug.print("1. Connecting to BitBarrel server...\n", .{});
    const config = bitbarrel.Config{
        .url = "ws://localhost:9876",
        .timeout_ms = 10000,
        .max_retries = 3,
        .enable_auto_reconnect = true,
    };
    var client = try bitbarrel.Client.init(allocator, config);
    defer client.deinit();
    std.debug.print("✓ Connected to BitBarrel server\n\n", .{});

    // Step 2: Setup chat storage barrel
    std.debug.print("2. Setting up chat storage barrel...\n", .{});
    const barrel_name = "chat_storage";
    client.createBarrel(barrel_name, .critbit) catch |err| {
        // Barrel might already exist
        _ = err;
        std.debug.print("✓ Using existing chat_storage barrel\n", .{});
    };
    try client.useBarrel(barrel_name);
    std.debug.print("✓ Using chat_storage barrel\n\n", .{});

    // Step 3: Subscribe to "room:general" with options (history replay, presence)
    std.debug.print("3. Subscribing to \"room:general\"...\n", .{});
    try client.subscribe("room:general");
    std.debug.print("✓ Subscribed to \"room:general\"\n\n", .{});

    // Step 4: Publish 5 chat messages from 5 users
    std.debug.print("4. Publishing 5 chat messages from 5 users...\n", .{});
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
        const timestamp = std.time.timestamp();
        const data = std.fmt.bufPrint(&json_buf,
            \\{"user":"{s}","message":"{s}","timestamp":{d}}
        , .{ user, message, timestamp }) catch "{}";

        try client.publish("room:general", data);
        std.debug.print("  {s}: {s}\n", .{ user, message });
        std.time.sleep(100_000_000); // 100ms delay
    }
    std.debug.print("✓ Published 5 messages\n\n", .{});

    // Step 5: Retrieve and display message history
    std.debug.print("5. Retrieving message history...\n", .{});
    const history = try client.getHistory("room:general", 10, 0);
    defer {
        for (history.items) |msg| {
            msg.deinit();
        }
        history.deinit();
    }
    std.debug.print("✓ Retrieved {d} messages from history:\n", .{history.items.len});
    for (history.items, 0..) |msg, idx| {
        std.debug.print("  [{d}] {s}: {s}\n", .{ idx + 1, msg.topic(), msg.data() });
    }
    std.debug.print("\n", .{});

    // Step 6: Subscribe to "room:*" pattern
    std.debug.print("6. Subscribing to \"room:*\" pattern...\n", .{});
    try client.watchKey("room:*");
    std.debug.print("✓ Subscribed to \"room:*\" pattern\n\n", .{});

    // Step 7: Publish to different rooms (tech, random)
    std.debug.print("7. Publishing to different rooms...\n", .{});
    const room_messages = [_]struct { room: []const u8, user: []const u8, message: []const u8 }{
        .{ .room = "room:tech", .user = "Alice", .message = "New TypeScript features are awesome!" },
        .{ .room = "room:random", .user = "Bob", .message = "Random thought: pineapples on pizza?" },
    };
    for (room_messages) |rm| {
        var json_buf: [256]u8 = undefined;
        const timestamp = std.time.timestamp();
        const data = std.fmt.bufPrint(&json_buf,
            \\{"user":"{s}","message":"{s}","timestamp":{d}}
        , .{ rm.user, rm.message, timestamp }) catch "{}";
        try client.publish(rm.room, data);
        std.debug.print("  Published to {s}: {s}: {s}\n", .{ rm.room, rm.user, rm.message });
    }
    std.debug.print("\n", .{});

    // Step 8: Query subscribers in "room:general"
    std.debug.print("8. Querying subscribers in \"room:general\"...\n", .{});
    const subscribers = try client.listSubscribers("room:general");
    defer subscribers.deinit();
    std.debug.print("✓ Subscribers in \"room:general\": {d} subscribers\n", .{subscribers.items.len});
    for (subscribers.items, 0..) |sub, idx| {
        std.debug.print("  {d}. {s}\n", .{ idx + 1, sub });
    }
    std.debug.print("\n", .{});

    // Step 9: Check presence information
    std.debug.print("9. Checking presence information...\n", .{});
    const presence_json = try client.getPresence("room:general");
    defer allocator.free(presence_json);
    std.debug.print("✓ Presence information: {s}\n", .{presence_json});
    std.debug.print("\n", .{});

    // Step 10: Get history with sequence filtering (sinceSeq=3)
    std.debug.print("10. Getting history since sequence 3...\n", .{});
    const history_since3 = try client.getHistory("room:general", 10, 3);
    defer {
        for (history_since3.items) |msg| {
            msg.deinit();
        }
        history_since3.deinit();
    }
    std.debug.print("✓ Retrieved {d} messages since sequence 3:\n", .{history_since3.items.len});
    for (history_since3.items) |msg| {
        std.debug.print("  [seq ?] {s}: {s}\n", .{ msg.topic(), msg.data() });
    }
    std.debug.print("\n", .{});

    // Step 11: Show history per room
    std.debug.print("11. Showing history per room...\n", .{});
    const rooms = [_][]const u8{ "room:general", "room:tech", "room:random" };
    for (rooms) |room| {
        const room_history = client.getHistory(room, 3, 0) catch |err| {
            std.debug.print("  {s}: No history available ({s})\n", .{ room, @errorName(err) });
            continue;
        };
        defer {
            for (room_history.items) |msg| {
                msg.deinit();
            }
            room_history.deinit();
        }
        std.debug.print("  {s}: {d} messages\n", .{ room, room_history.items.len });
        if (room_history.items.len > 0) {
            const last_msg = room_history.items[room_history.items.len - 1];
            std.debug.print("    Last: {s}\n", .{last_msg.data()});
        }
    }
    std.debug.print("\n", .{});

    // Step 12: Cleanup (unsubscribe, close)
    std.debug.print("12. Cleaning up...\n", .{});
    try client.unsubscribe("room:general");
    try client.unwatchKey("room:*");
    std.debug.print("✓ Unsubscribed from all topics\n", .{});
    // Client deinit will close connection
    std.debug.print("✓ Closed connection\n\n", .{});

    std.debug.print("=== Example completed successfully! ===\n", .{});
}