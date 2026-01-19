const std = @import("std");

// Import C library
const c = @cImport({
    @cInclude("bitbarrel.h");
    @cInclude("stdlib.h");
});

// Error types
pub const Error = error{
    ConnectionError,
    Timeout,
    ProtocolError,
    InvalidRequest,
    BarrelNotFound,
    BarrelExists,
    UnknownError,
    OutOfMemory,
};

// Configuration
pub const Config = struct {
    url: [:0]const u8 = "ws://localhost:7687",
    timeout_ms: i32 = 5000,
    max_retries: i32 = 3,
    enable_auto_reconnect: bool = true,

    pub fn toC(self: Config) c.BBConfig {
        return c.BBConfig{
            .url = self.url.ptr,
            .timeout_ms = self.timeout_ms,
            .max_retries = self.max_retries,
            .enable_auto_reconnect = self.enable_auto_reconnect,
        };
    }
};

// Barrel mode
pub const Mode = enum(i32) {
    hash = @intFromEnum(c.BM_HASH),
    critbit = @intFromEnum(c.BM_CRITBIT),
};

// Client wrapper
pub const Client = struct {
    handle: ?*c.BBClient,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: Config) Error!Client {
        // Initialize C library
        if (c.bb_init() != c.BB_OK) {
            return Error.UnknownError;
        }

        const c_config = config.toC();
        const handle = c.bb_client_create(&c_config);
        if (handle == null) {
            return Error.OutOfMemory;
        }

        // Connect to server
        if (c.bb_connect(handle) != c.BB_OK) {
            const err = c.bb_get_last_error(handle);
            c.bb_client_destroy(handle);
            std.debug.print("Connection error: {s}\n", .{err});
            return Error.ConnectionError;
        }

        return Client{
            .handle = handle,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.handle) |handle| {
            _ = c.bb_disconnect(handle);
            c.bb_client_destroy(handle);
            self.handle = null;
        }
        c.bb_cleanup();
    }

    pub fn isConnected(self: Client) bool {
        return if (self.handle) |handle| c.bb_is_connected(handle) else false;
    }

    // Barrel operations
    pub fn createBarrel(self: *Client, name: []const u8, mode: Mode) Error!void {
        const handle = self.handle orelse return Error.UnknownError;
        const result = c.bb_create_barrel(handle, name.ptr, @intFromEnum(mode));
        if (result != c.BB_OK) {
            return translateError(result);
        }
    }

    pub fn openBarrel(self: *Client, name: []const u8) Error!void {
        const handle = self.handle orelse return Error.UnknownError;
        const result = c.bb_open_barrel(handle, name.ptr);
        if (result != c.BB_OK) {
            return translateError(result);
        }
    }

    pub fn useBarrel(self: *Client, name: []const u8) Error!void {
        const handle = self.handle orelse return Error.UnknownError;
        const result = c.bb_use_barrel(handle, name.ptr);
        if (result != c.BB_OK) {
            return translateError(result);
        }
    }

    pub fn closeBarrel(self: *Client) Error!void {
        const handle = self.handle orelse return Error.UnknownError;
        const result = c.bb_close_barrel(handle);
        if (result != c.BB_OK) {
            return translateError(result);
        }
    }

    pub fn listBarrels(self: *Client) Error!std.ArrayList([]const u8) {
        const handle = self.handle orelse return Error.UnknownError;

        var barrels_ptr: [*c][*c]u8 = undefined;
        var count: usize = 0;

        const result = c.bb_list_barrels(handle, &barrels_ptr, &count);
        if (result != c.BB_OK) {
            return translateError(result);
        }

        var list = std.ArrayList([]const u8).init(self.allocator);
        errdefer list.deinit();

        var i: usize = 0;
        while (i < count) : (i += 1) {
            const barrel = std.mem.sliceTo(barrels_ptr[i], 0);
            try list.append(barrel);
            c.bb_free_string(barrels_ptr[i]);
        }
        c.bb_free_string_array(barrels_ptr, count);

        return list;
    }

    // Key-Value operations
    pub fn set(self: *Client, key: []const u8, value: []const u8) Error!void {
        return self.setWithTtl(key, value, null);
    }

    pub fn setWithTtl(self: *Client, key: []const u8, value: []const u8, ttl: ?u32) Error!void {
        const handle = self.handle orelse return Error.UnknownError;
        const ttl_value: i32 = if (ttl) |t| @intCast(t) else -1;
        const result = c.bb_set(handle, key.ptr, value.ptr, ttl_value);
        if (result != c.BB_OK) {
            return translateError(result);
        }
    }

    pub fn get(self: *Client, key: []const u8) Error!?[]const u8 {
        const handle = self.handle orelse return Error.UnknownError;
        const value = c.bb_get(handle, key.ptr);
        if (value == null) {
            // Check if it's a "not found" or an error
            return null;
        }
        errdefer c.bb_free_string(value);
        // Note: In a real implementation, we'd need to manage the lifetime better
        return std.mem.sliceTo(value, 0);
    }

    pub fn delete(self: *Client, key: []const u8) Error!void {
        const handle = self.handle orelse return Error.UnknownError;
        const result = c.bb_delete(handle, key.ptr);
        if (result != c.BB_OK) {
            return translateError(result);
        }
    }

    pub fn exists(self: *Client, key: []const u8) bool {
        const handle = self.handle orelse return false;
        return c.bb_exists(handle, key.ptr);
    }

    pub fn count(self: *Client) Error!i64 {
        const handle = self.handle orelse return Error.UnknownError;
        var count: i64 = 0;
        const result = c.bb_count(handle, &count);
        if (result != c.BB_OK) {
            return translateError(result);
        }
        return count;
    }

    // Pub/Sub operations
    pub fn subscribe(self: *Client, topic: []const u8) Error!void {
        const handle = self.handle orelse return Error.UnknownError;
        const result = c.bb_subscribe(handle, topic.ptr);
        if (result != c.BB_OK) {
            return translateError(result);
        }
    }

    pub fn unsubscribe(self: *Client, topic: []const u8) Error!void {
        const handle = self.handle orelse return Error.UnknownError;
        const result = c.bb_unsubscribe(handle, topic.ptr);
        if (result != c.BB_OK) {
            return translateError(result);
        }
    }

    pub fn publish(self: *Client, topic: []const u8, data: []const u8) Error!void {
        const handle = self.handle orelse return Error.UnknownError;
        const result = c.bb_publish(handle, topic.ptr, data.ptr);
        if (result != c.BB_OK) {
            return translateError(result);
        }
    }

    pub fn listSubscribers(self: *Client, topic: []const u8) Error!std.ArrayList([]const u8) {
        const handle = self.handle orelse return Error.UnknownError;
        var subscribers_ptr: [*c][*c]u8 = undefined;
        var count: usize = 0;
        const result = c.bb_list_subscribers(handle, topic.ptr, &subscribers_ptr, &count);
        if (result != c.BB_OK) {
            return translateError(result);
        }
        var list = std.ArrayList([]const u8).init(self.allocator);
        errdefer list.deinit();
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const sub = std.mem.sliceTo(subscribers_ptr[i], 0);
            try list.append(sub);
            c.bb_free_string(subscribers_ptr[i]);
        }
        c.bb_free_string_array(subscribers_ptr, count);
        return list;
    }

    pub fn listTopics(self: *Client) Error!std.ArrayList([]const u8) {
        const handle = self.handle orelse return Error.UnknownError;
        var topics_ptr: [*c][*c]u8 = undefined;
        var count: usize = 0;
        const result = c.bb_list_topics(handle, &topics_ptr, &count);
        if (result != c.BB_OK) {
            return translateError(result);
        }
        var list = std.ArrayList([]const u8).init(self.allocator);
        errdefer list.deinit();
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const topic = std.mem.sliceTo(topics_ptr[i], 0);
            try list.append(topic);
            c.bb_free_string(topics_ptr[i]);
        }
        c.bb_free_string_array(topics_ptr, count);
        return list;
    }

    pub fn getHistory(self: *Client, topic: []const u8, limit: i32, since_seq: i32) Error!std.ArrayList(Message) {
        const handle = self.handle orelse return Error.UnknownError;
        var messages_ptr: [*c][*c]c.BBMessage = undefined;
        var count: usize = 0;
        const result = c.bb_get_history(handle, topic.ptr, limit, since_seq, &messages_ptr, &count);
        if (result != c.BB_OK) {
            return translateError(result);
        }
        var list = std.ArrayList(Message).init(self.allocator);
        errdefer list.deinit();
        var i: usize = 0;
        while (i < count) : (i += 1) {
            // Wrap each C message in our Message type
            try list.append(Message{ .handle = messages_ptr[i] });
        }
        // Free the array of pointers (messages themselves are now owned by Message wrappers)
        c.free(@ptrCast(messages_ptr));
        return list;
    }

    pub fn getPresence(self: *Client, topic: []const u8) Error![]const u8 {
        const handle = self.handle orelse return Error.UnknownError;
        var presence_json: [*c]u8 = undefined;
        const result = c.bb_get_presence(handle, topic.ptr, &presence_json);
        if (result != c.BB_OK) {
            return translateError(result);
        }
        errdefer c.bb_free_string(presence_json);
        return std.mem.sliceTo(presence_json, 0);
    }

    pub fn pollMessage(self: *Client) ?Message {
        const handle = self.handle orelse return null;
        const msg = c.bb_poll_message(handle);
        if (msg == null) return null;
        return Message{ .handle = msg };
    }

    pub fn waitMessage(self: *Client, timeout_ms: i32) ?Message {
        const handle = self.handle orelse return null;
        const msg = c.bb_wait_message(handle, timeout_ms);
        if (msg == null) return null;
        return Message{ .handle = msg };
    }

    pub fn getServerInfo(self: *Client) Error!ServerInfo {
        const handle = self.handle orelse return Error.UnknownError;

        var c_info: c.BBServerInfo = undefined;
        const result = c.bb_get_server_info(handle, &c_info);
        if (result != c.BB_OK) {
            return translateError(result);
        }

        return ServerInfo{
            .allocator = self.allocator,
            .info = c_info,
        };
    }

    pub fn setMessageCallback(self: *Client, callback: c.BBMessageCallback, userdata: ?*anyopaque) Error!void {
        const handle = self.handle orelse return Error.UnknownError;
        const result = c.bb_set_message_callback(handle, callback, userdata);
        if (result != c.BB_OK) {
            return translateError(result);
        }
    }

    pub fn watchKey(self: *Client, pattern: []const u8) Error!void {
        const handle = self.handle orelse return Error.UnknownError;
        const result = c.bb_watch_key(handle, pattern.ptr);
        if (result != c.BB_OK) {
            return translateError(result);
        }
    }

    pub fn unwatchKey(self: *Client, pattern: []const u8) Error!void {
        const handle = self.handle orelse return Error.UnknownError;
        const result = c.bb_unwatch_key(handle, pattern.ptr);
        if (result != c.BB_OK) {
            return translateError(result);
        }
    }

    // Range queries
    pub const RangeResult = struct {
        items: std.ArrayList(Item),
        next_cursor: ?[]const u8,
        has_more: bool,

        pub const Item = struct {
            key: []const u8,
            value: []const u8,
        };

        pub fn deinit(self: *RangeResult) void {
            self.items.deinit();
            if (self.next_cursor) |cursor| {
                self.allocator.free(cursor);
            }
        }
    };

    // Helper to translate C errors
    fn translateError(result: c.BBResult) Error {
        return switch (result) {
            c.BB_OK => unreachable,
            c.BB_ERROR => Error.UnknownError,
            c.BB_NOT_FOUND => Error.UnknownError,
            c.BB_NO_BARREL => Error.BarrelNotFound,
            c.BB_BARREL_EXISTS => Error.BarrelExists,
            c.BB_INVALID_REQUEST => Error.InvalidRequest,
            c.BB_CONNECTION_ERROR => Error.ConnectionError,
            c.BB_TIMEOUT => Error.Timeout,
            c.BB_PROTOCOL_ERROR => Error.ProtocolError,
            else => Error.UnknownError,
        };
    }
};

// Message type for Pub/Sub
pub const Message = struct {
    handle: *c.BBMessage,

    pub fn topic(self: Message) []const u8 {
        return std.mem.sliceTo(self.handle.topic, 0);
    }

    pub fn data(self: Message) []const u8 {
        return std.mem.sliceTo(self.handle.data, 0);
    }

    pub fn timestamp(self: Message) i64 {
        return self.handle.timestamp;
    }

    pub fn deinit(self: Message) void {
        c.bb_free_message(@ptrCast(self.handle));
    }
};

test "basic client creation" {
    const allocator = std.testing.allocator;

    var client = try Client.init(allocator, .{});
    defer client.deinit();

    try std.testing.expect(client.isConnected());
}

test "config translation" {
    const config = Config{
        .url = "ws://test:8080",
        .timeout_ms = 10000,
        .enable_auto_reconnect = false,
    };

    const c_config = config.toC();
    try std.testing.expectEqual(@as([*c]const u8, config.url.ptr), c_config.url);
    try std.testing.expectEqual(@as(i32, 10000), c_config.timeout_ms);
    try std.testing.expectEqual(@as(bool, false), c_config.enable_auto_reconnect);
}
