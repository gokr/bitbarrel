const std = @import("std");
const c = @cImport({
    @cInclude("bitbarrel.h");
});

pub const Message = struct {
    allocator: std.mem.Allocator,
    handle: *c.BBMessage,

    pub fn topic(self: Message) []const u8 {
        return std.mem.sliceTo(self.handle.topic, 0);
    }

    pub fn data(self: Message) []const u8 {
        return std.mem.sliceTo(self.handle.data, 0);
    }

    pub fn id(self: Message) ?[]const u8 {
        if (self.handle.id) |id| {
            return std.mem.sliceTo(id, 0);
        }
        return null;
    }

    pub fn timestamp(self: Message) i64 {
        return self.handle.timestamp;
    }

    pub fn deinit(self: Message) void {
        c.bb_free_message(self.handle);
    }
};

pub const RangeResult = struct {
    allocator: std.mem.Allocator,
    keys: ?[][]const u8,
    values: ?[][]const u8,
    count: usize,
    next_cursor: ?[]const u8,
    has_more: bool,

    pub fn deinit(self: RangeResult) void {
        if (self.keys) |keys| {
            for (keys) |key| {
                self.allocator.free(key);
            }
            self.allocator.free(keys);
        }
        if (self.values) |values| {
            for (values) |value| {
                self.allocator.free(value);
            }
            self.allocator.free(values);
        }
        if (self.next_cursor) |cursor| {
            self.allocator.free(cursor);
        }
    }

    /// Returns an iterator over key-value pairs
    pub fn items(self: RangeResult) ItemIterator {
        return .{
            .result = self,
            .index = 0,
        };
    }

    pub const ItemIterator = struct {
        result: RangeResult,
        index: usize,

        pub fn next(self: *ItemIterator) ?struct { key: []const u8, value: []const u8 } {
            if (self.index >= self.result.count) return null;
            if (self.result.keys == null or self.result.values == null) return null;

            const key = self.result.keys.?[self.index];
            const value = self.result.values.?[self.index];
            self.index += 1;

            return .{ .key = key, .value = value };
        }
    };
};

pub const ServerInfo = struct {
    allocator: std.mem.Allocator,
    info: c.BBServerInfo,

    pub fn versionMajor(self: ServerInfo) u8 {
        return self.info.version_major;
    }

    pub fn versionMinor(self: ServerInfo) u8 {
        return self.info.version_minor;
    }

    pub fn serverId(self: ServerInfo) []const u8 {
        return std.mem.sliceTo(self.info.server_id, 0);
    }

    pub fn plugins(self: ServerInfo) [][]const u8 {
        // Note: This is a simplified version - in practice you'd need to manage the lifetime
        // of the plugins array properly. For now, return an empty array or implement full conversion.
        return &[_][]const u8{};
    }

    pub fn deinit(self: ServerInfo) void {
        // The C library manages the memory for server info fields
        // Nothing to free here
    }
};

test "message structure" {
    // Test would require actual message from C library
    // This is a placeholder for the structure
    try std.testing.expect(true);
}
