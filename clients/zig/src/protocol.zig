const std = @import("std");

// Command types - must match BitBarrel protocol
pub const Command = enum(u8) {
    // Data operations
    get = 0x01,
    set = 0x02,
    delete = 0x03,
    exists = 0x04,
    count = 0x05,
    list_keys = 0x06,
    ping = 0x09,

    // Traversal and range queries
    traverse = 0x20,
    range_query = 0x21,
    prefix_query = 0x22,
    range_count = 0x23,
    range_keys = 0x24,
    prefix_keys = 0x25,

    // Batch operations
    batch_get = 0x26,
    batch_set = 0x27,
    batch_delete = 0x28,

    // Barrel management
    create_barrel = 0x10,
    open_barrel = 0x11,
    use_barrel = 0x12,
    close_barrel = 0x13,
    list_barrels = 0x14,
    drop_barrel = 0x15,
    get_barrel_config = 0x16,
    set_barrel_config = 0x17,
    get_barrel_stats = 0x18,

    // Pub/Sub commands
    subscribe = 0x40,
    unsubscribe = 0x41,
    publish = 0x42,
    list_subscribers = 0x43,
    history = 0x44,
    list_topics = 0x45,
    presence = 0x46,

    // Key watching
    watch_key = 0x60,
    unwatch_key = 0x61,

    // Push notification (server to client)
    pubsub_event = 0xFF,
};

// Status codes - must match BitBarrel protocol
pub const Status = enum(u8) {
    ok = 0x00,
    not_found = 0x01,
    err = 0x02,
    invalid = 0x03,
    no_barrel = 0x04,
    barrel_exists = 0x05,
    barrel_not_found = 0x06,
    unauthorized = 0x07,
};

// Request flags (v1.1)
pub const RequestFlags = struct {
    pub const none: u8 = 0x00;
    pub const has_ttl: u8 = 0x01;
};

// Size limits
pub const max_key_size: usize = 65535; // 64KB
pub const max_value_size: usize = 33554432; // 32MB

// Message types for Pub/Sub
pub const MessageType = enum(u8) {
    data = 0,
    presence = 1,
    kv_change = 2,
};

// Request structure
pub const Request = struct {
    command: Command,
    seq: u32,
    flags: u8 = 0,
    key: []const u8,
    value: []const u8,
    ttl: ?u32 = null,

    // Encode request to binary format (v1.1)
    // Format: [cmd:1][seq:4][flags:1][keyLen:2][key:N][valLen:4][value:M][ttl:4?]
    pub fn encode(self: Request, allocator: std.mem.Allocator) ![]u8 {
        if (self.key.len > max_key_size) {
            return error.KeyTooLarge;
        }
        if (self.value.len > max_value_size) {
            return error.ValueTooLarge;
        }

        const has_ttl = self.ttl != null;
        const ttl_size: usize = if (has_ttl) 4 else 0;
        const total_size = 1 + 4 + 1 + 2 + self.key.len + 4 + self.value.len + ttl_size;

        var buf = try allocator.alloc(u8, total_size);
        errdefer allocator.free(buf);

        var offset: usize = 0;

        // Command type (1 byte)
        buf[offset] = @intFromEnum(self.command);
        offset += 1;

        // Sequence number (4 bytes, big-endian)
        std.mem.writeInt(u32, buf[offset..][0..4], self.seq, .big);
        offset += 4;

        // Flags (1 byte)
        const flags: u8 = if (has_ttl) RequestFlags.has_ttl else RequestFlags.none;
        buf[offset] = flags;
        offset += 1;

        // Key length (2 bytes, big-endian)
        std.mem.writeInt(u16, buf[offset..][0..2], @intCast(self.key.len), .big);
        offset += 2;

        // Key data
        @memcpy(buf[offset..][0..self.key.len], self.key);
        offset += self.key.len;

        // Value length (4 bytes, big-endian)
        std.mem.writeInt(u32, buf[offset..][0..4], @intCast(self.value.len), .big);
        offset += 4;

        // Value data
        @memcpy(buf[offset..][0..self.value.len], self.value);
        offset += self.value.len;

        // TTL (4 bytes, optional)
        if (self.ttl) |ttl| {
            std.mem.writeInt(u32, buf[offset..][0..4], ttl, .big);
        }

        return buf;
    }
};

// Response structure
pub const Response = struct {
    status: Status,
    seq: u32,
    value: []const u8,

    // Decode response from binary format
    // Format: [status:1][seq:4][valLen:4][value:M]
    pub fn decode(data: []const u8, allocator: std.mem.Allocator) !Response {
        if (data.len < 9) {
            return error.ResponseTooShort;
        }

        var offset: usize = 0;

        // Status code (1 byte)
        const status: Status = @enumFromInt(data[offset]);
        offset += 1;

        // Sequence number (4 bytes, big-endian)
        const seq = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;

        // Value length (4 bytes, big-endian)
        const value_len = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;

        if (value_len > max_value_size) {
            return error.ValueTooLarge;
        }

        if (data.len < offset + value_len) {
            return error.TruncatedResponse;
        }

        // Copy value data
        const value = try allocator.alloc(u8, value_len);
        @memcpy(value, data[offset..][0..value_len]);

        return Response{
            .status = status,
            .seq = seq,
            .value = value,
        };
    }

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        if (self.value.len > 0) {
            allocator.free(self.value);
        }
    }
};

// Server handshake info
pub const ServerInfo = struct {
    version_major: u8,
    version_minor: u8,
    server_id: []const u8,
    plugins: [][]const u8,

    pub fn decode(data: []const u8, allocator: std.mem.Allocator) !ServerInfo {
        if (data.len < 4) {
            return error.HandshakeTooShort;
        }

        var offset: usize = 0;

        // Version (2 bytes)
        const version_major = data[offset];
        offset += 1;
        const version_minor = data[offset];
        offset += 1;

        // Server ID length (2 bytes)
        const server_id_len = std.mem.readInt(u16, data[offset..][0..2], .big);
        offset += 2;

        if (data.len < offset + server_id_len) {
            return error.TruncatedHandshake;
        }

        // Server ID
        const server_id = try allocator.alloc(u8, server_id_len);
        @memcpy(server_id, data[offset..][0..server_id_len]);
        offset += server_id_len;

        // Plugins (optional)
        var plugins = std.ArrayList([]const u8).init(allocator);
        errdefer {
            for (plugins.items) |p| allocator.free(p);
            plugins.deinit();
        }

        if (offset < data.len) {
            const plugin_count = data[offset];
            offset += 1;

            var i: usize = 0;
            while (i < plugin_count and offset + 2 <= data.len) : (i += 1) {
                const plugin_len = std.mem.readInt(u16, data[offset..][0..2], .big);
                offset += 2;

                if (offset + plugin_len > data.len) break;

                const plugin = try allocator.alloc(u8, plugin_len);
                @memcpy(plugin, data[offset..][0..plugin_len]);
                offset += plugin_len;
                try plugins.append(plugin);
            }
        }

        return ServerInfo{
            .version_major = version_major,
            .version_minor = version_minor,
            .server_id = server_id,
            .plugins = try plugins.toOwnedSlice(),
        };
    }

    pub fn deinit(self: *ServerInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.server_id);
        for (self.plugins) |p| {
            allocator.free(p);
        }
        allocator.free(self.plugins);
    }
};

// Pub/Sub event structure
pub const PubSubEvent = struct {
    topic: []const u8,
    message_type: MessageType,
    sequence: u64,
    timestamp: i64,
    headers: []const u8,
    payload: []const u8,

    // Decode PubSub event from binary format
    // Format: [cmd:1][seq:4][topicLen:2][topic][msgType:1][seq:8][ts:8][headersLen:4][headers][payloadLen:4][payload]
    pub fn decode(data: []const u8, allocator: std.mem.Allocator) !PubSubEvent {
        if (data.len < 30) {
            return error.EventTooShort;
        }

        var offset: usize = 0;

        // Skip command byte (0xFF) and request sequence (not used for events)
        offset += 5;

        // Topic length (2 bytes)
        if (offset + 2 > data.len) return error.TruncatedEvent;
        const topic_len = std.mem.readInt(u16, data[offset..][0..2], .big);
        offset += 2;

        // Topic
        if (offset + topic_len > data.len) return error.TruncatedEvent;
        const topic = try allocator.alloc(u8, topic_len);
        errdefer allocator.free(topic);
        @memcpy(topic, data[offset..][0..topic_len]);
        offset += topic_len;

        // Message type (1 byte)
        if (offset >= data.len) return error.TruncatedEvent;
        const msg_type: MessageType = @enumFromInt(data[offset]);
        offset += 1;

        // Sequence (8 bytes)
        if (offset + 8 > data.len) return error.TruncatedEvent;
        const sequence = std.mem.readInt(u64, data[offset..][0..8], .big);
        offset += 8;

        // Timestamp (8 bytes)
        if (offset + 8 > data.len) return error.TruncatedEvent;
        const timestamp: i64 = @bitCast(std.mem.readInt(u64, data[offset..][0..8], .big));
        offset += 8;

        // Headers length (4 bytes)
        if (offset + 4 > data.len) return error.TruncatedEvent;
        const headers_len = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;

        // Headers
        var headers: []u8 = &[_]u8{};
        if (headers_len > 0) {
            if (offset + headers_len > data.len) return error.TruncatedEvent;
            headers = try allocator.alloc(u8, headers_len);
            @memcpy(headers, data[offset..][0..headers_len]);
            offset += headers_len;
        }
        errdefer if (headers.len > 0) allocator.free(headers);

        // Payload length (4 bytes)
        if (offset + 4 > data.len) return error.TruncatedEvent;
        const payload_len = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;

        // Payload
        var payload: []u8 = &[_]u8{};
        if (payload_len > 0) {
            if (offset + payload_len > data.len) return error.TruncatedEvent;
            payload = try allocator.alloc(u8, payload_len);
            @memcpy(payload, data[offset..][0..payload_len]);
        }

        return PubSubEvent{
            .topic = topic,
            .message_type = msg_type,
            .sequence = sequence,
            .timestamp = timestamp,
            .headers = headers,
            .payload = payload,
        };
    }

    pub fn deinit(self: *PubSubEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.topic);
        if (self.headers.len > 0) allocator.free(@constCast(self.headers));
        if (self.payload.len > 0) allocator.free(@constCast(self.payload));
    }
};

// Check if data is a PubSub event (starts with 0xFF)
pub fn isPubSubEvent(data: []const u8) bool {
    return data.len > 0 and data[0] == @intFromEnum(Command.pubsub_event);
}

// Range query request encoding
// Format: [startKeyLen:2][startKey][endKeyLen:2][endKey][limit:4][cursorLen:2][cursor]
pub fn encodeRangeRequest(
    allocator: std.mem.Allocator,
    start_key: []const u8,
    end_key: []const u8,
    limit: u32,
    cursor: []const u8,
) ![]u8 {
    const total_size = 2 + start_key.len + 2 + end_key.len + 4 + 2 + cursor.len;
    var buf = try allocator.alloc(u8, total_size);
    errdefer allocator.free(buf);

    var offset: usize = 0;

    // Start key
    std.mem.writeInt(u16, buf[offset..][0..2], @intCast(start_key.len), .big);
    offset += 2;
    @memcpy(buf[offset..][0..start_key.len], start_key);
    offset += start_key.len;

    // End key
    std.mem.writeInt(u16, buf[offset..][0..2], @intCast(end_key.len), .big);
    offset += 2;
    @memcpy(buf[offset..][0..end_key.len], end_key);
    offset += end_key.len;

    // Limit
    std.mem.writeInt(u32, buf[offset..][0..4], limit, .big);
    offset += 4;

    // Cursor
    std.mem.writeInt(u16, buf[offset..][0..2], @intCast(cursor.len), .big);
    offset += 2;
    @memcpy(buf[offset..][0..cursor.len], cursor);

    return buf;
}

// Prefix query request encoding
// Format: [prefixLen:2][prefix][limit:4][cursorLen:2][cursor]
pub fn encodePrefixRequest(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    limit: u32,
    cursor: []const u8,
) ![]u8 {
    const total_size = 2 + prefix.len + 4 + 2 + cursor.len;
    var buf = try allocator.alloc(u8, total_size);
    errdefer allocator.free(buf);

    var offset: usize = 0;

    // Prefix
    std.mem.writeInt(u16, buf[offset..][0..2], @intCast(prefix.len), .big);
    offset += 2;
    @memcpy(buf[offset..][0..prefix.len], prefix);
    offset += prefix.len;

    // Limit
    std.mem.writeInt(u32, buf[offset..][0..4], limit, .big);
    offset += 4;

    // Cursor
    std.mem.writeInt(u16, buf[offset..][0..2], @intCast(cursor.len), .big);
    offset += 2;
    @memcpy(buf[offset..][0..cursor.len], cursor);

    return buf;
}

// Key-value pair for range results
pub const KeyValue = struct {
    key: []const u8,
    value: []const u8,

    pub fn deinit(self: *KeyValue, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
    }
};

// Range query response
pub const RangeResponse = struct {
    items: []KeyValue,
    next_cursor: []const u8,
    has_more: bool,

    // Decode range response
    // Format: [count:4][items...][hasMore:1][nextCursorLen:2][nextCursor]
    // Each item: [keyLen:2][key][valueLen:4][value]
    pub fn decode(data: []const u8, allocator: std.mem.Allocator) !RangeResponse {
        if (data.len < 5) {
            return error.ResponseTooShort;
        }

        var offset: usize = 0;

        // Count
        const count = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;

        var items = try allocator.alloc(KeyValue, count);
        errdefer {
            for (items) |*item| item.deinit(allocator);
            allocator.free(items);
        }

        // Items
        var i: usize = 0;
        while (i < count) : (i += 1) {
            // Key length
            if (offset + 2 > data.len) return error.TruncatedResponse;
            const key_len = std.mem.readInt(u16, data[offset..][0..2], .big);
            offset += 2;

            // Key
            if (offset + key_len > data.len) return error.TruncatedResponse;
            const key = try allocator.alloc(u8, key_len);
            @memcpy(key, data[offset..][0..key_len]);
            offset += key_len;

            // Value length
            if (offset + 4 > data.len) {
                allocator.free(key);
                return error.TruncatedResponse;
            }
            const val_len = std.mem.readInt(u32, data[offset..][0..4], .big);
            offset += 4;

            // Value
            if (offset + val_len > data.len) {
                allocator.free(key);
                return error.TruncatedResponse;
            }
            const value = try allocator.alloc(u8, val_len);
            @memcpy(value, data[offset..][0..val_len]);
            offset += val_len;

            items[i] = KeyValue{ .key = key, .value = value };
        }

        // Has more flag
        if (offset >= data.len) return error.TruncatedResponse;
        const has_more = data[offset] != 0;
        offset += 1;

        // Next cursor length
        if (offset + 2 > data.len) return error.TruncatedResponse;
        const cursor_len = std.mem.readInt(u16, data[offset..][0..2], .big);
        offset += 2;

        // Next cursor
        var next_cursor: []u8 = &[_]u8{};
        if (cursor_len > 0) {
            if (offset + cursor_len > data.len) return error.TruncatedResponse;
            next_cursor = try allocator.alloc(u8, cursor_len);
            @memcpy(next_cursor, data[offset..][0..cursor_len]);
        }

        return RangeResponse{
            .items = items,
            .next_cursor = next_cursor,
            .has_more = has_more,
        };
    }

    pub fn deinit(self: *RangeResponse, allocator: std.mem.Allocator) void {
        for (self.items) |*item| {
            item.deinit(allocator);
        }
        allocator.free(self.items);
        if (self.next_cursor.len > 0) {
            allocator.free(@constCast(self.next_cursor));
        }
    }
};

// Keys-only response (for range_keys and prefix_keys)
pub const KeysResponse = struct {
    keys: [][]const u8,
    next_cursor: []const u8,
    has_more: bool,

    // Decode keys response
    // Format: [count:4][keys...][hasMore:1][nextCursorLen:2][nextCursor]
    // Each key: [keyLen:2][key]
    pub fn decode(data: []const u8, allocator: std.mem.Allocator) !KeysResponse {
        if (data.len < 5) {
            return error.ResponseTooShort;
        }

        var offset: usize = 0;

        // Count
        const count = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;

        var keys = try allocator.alloc([]const u8, count);
        errdefer {
            for (keys) |k| allocator.free(k);
            allocator.free(keys);
        }

        // Keys
        var i: usize = 0;
        while (i < count) : (i += 1) {
            // Key length
            if (offset + 2 > data.len) return error.TruncatedResponse;
            const key_len = std.mem.readInt(u16, data[offset..][0..2], .big);
            offset += 2;

            // Key
            if (offset + key_len > data.len) return error.TruncatedResponse;
            const key = try allocator.alloc(u8, key_len);
            @memcpy(key, data[offset..][0..key_len]);
            offset += key_len;

            keys[i] = key;
        }

        // Has more flag
        if (offset >= data.len) return error.TruncatedResponse;
        const has_more = data[offset] != 0;
        offset += 1;

        // Next cursor length
        if (offset + 2 > data.len) return error.TruncatedResponse;
        const cursor_len = std.mem.readInt(u16, data[offset..][0..2], .big);
        offset += 2;

        // Next cursor
        var next_cursor: []u8 = &[_]u8{};
        if (cursor_len > 0) {
            if (offset + cursor_len > data.len) return error.TruncatedResponse;
            next_cursor = try allocator.alloc(u8, cursor_len);
            @memcpy(next_cursor, data[offset..][0..cursor_len]);
        }

        return KeysResponse{
            .keys = keys,
            .next_cursor = next_cursor,
            .has_more = has_more,
        };
    }

    pub fn deinit(self: *KeysResponse, allocator: std.mem.Allocator) void {
        for (self.keys) |k| {
            allocator.free(@constCast(k));
        }
        allocator.free(self.keys);
        if (self.next_cursor.len > 0) {
            allocator.free(@constCast(self.next_cursor));
        }
    }
};

// Subscribe request encoding
// Format: [options:1][topicLen:2][topic][patternLen:2][pattern]
pub fn encodeSubscribeRequest(
    allocator: std.mem.Allocator,
    topic: []const u8,
    pattern: []const u8,
    enable_kv_events: bool,
    enable_presence: bool,
    replay_history: bool,
) ![]u8 {
    const total_size = 1 + 2 + topic.len + 2 + pattern.len;
    var buf = try allocator.alloc(u8, total_size);
    errdefer allocator.free(buf);

    var offset: usize = 0;

    // Options byte
    var options: u8 = 0;
    if (enable_kv_events) options |= 0x01;
    if (enable_presence) options |= 0x02;
    if (replay_history) options |= 0x04;
    buf[offset] = options;
    offset += 1;

    // Topic
    std.mem.writeInt(u16, buf[offset..][0..2], @intCast(topic.len), .big);
    offset += 2;
    @memcpy(buf[offset..][0..topic.len], topic);
    offset += topic.len;

    // Pattern
    std.mem.writeInt(u16, buf[offset..][0..2], @intCast(pattern.len), .big);
    offset += 2;
    @memcpy(buf[offset..][0..pattern.len], pattern);

    return buf;
}

// Publish request encoding
// Format: [topicLen:2][topic][msgType:1][headersLen:4][headers][payloadLen:4][payload]
pub fn encodePublishRequest(
    allocator: std.mem.Allocator,
    topic: []const u8,
    msg_type: MessageType,
    headers: []const u8,
    payload: []const u8,
) ![]u8 {
    const total_size = 2 + topic.len + 1 + 4 + headers.len + 4 + payload.len;
    var buf = try allocator.alloc(u8, total_size);
    errdefer allocator.free(buf);

    var offset: usize = 0;

    // Topic
    std.mem.writeInt(u16, buf[offset..][0..2], @intCast(topic.len), .big);
    offset += 2;
    @memcpy(buf[offset..][0..topic.len], topic);
    offset += topic.len;

    // Message type
    buf[offset] = @intFromEnum(msg_type);
    offset += 1;

    // Headers
    std.mem.writeInt(u32, buf[offset..][0..4], @intCast(headers.len), .big);
    offset += 4;
    @memcpy(buf[offset..][0..headers.len], headers);
    offset += headers.len;

    // Payload
    std.mem.writeInt(u32, buf[offset..][0..4], @intCast(payload.len), .big);
    offset += 4;
    @memcpy(buf[offset..][0..payload.len], payload);

    return buf;
}

// Watch request encoding
// Format: [barrelLen:2][barrel][patternLen:2][pattern][options:1]
pub fn encodeWatchRequest(
    allocator: std.mem.Allocator,
    barrel_name: []const u8,
    pattern: []const u8,
    include_values: bool,
) ![]u8 {
    const total_size = 2 + barrel_name.len + 2 + pattern.len + 1;
    var buf = try allocator.alloc(u8, total_size);
    errdefer allocator.free(buf);

    var offset: usize = 0;

    // Barrel name
    std.mem.writeInt(u16, buf[offset..][0..2], @intCast(barrel_name.len), .big);
    offset += 2;
    @memcpy(buf[offset..][0..barrel_name.len], barrel_name);
    offset += barrel_name.len;

    // Pattern
    std.mem.writeInt(u16, buf[offset..][0..2], @intCast(pattern.len), .big);
    offset += 2;
    @memcpy(buf[offset..][0..pattern.len], pattern);
    offset += pattern.len;

    // Options
    buf[offset] = if (include_values) 1 else 0;

    return buf;
}

// History request encoding
// Format: [topicLen:2][topic][count:4][sinceSeq:8]
pub fn encodeHistoryRequest(
    allocator: std.mem.Allocator,
    topic: []const u8,
    count: u32,
    since_seq: u64,
) ![]u8 {
    const total_size = 2 + topic.len + 4 + 8;
    var buf = try allocator.alloc(u8, total_size);
    errdefer allocator.free(buf);

    var offset: usize = 0;

    // Topic
    std.mem.writeInt(u16, buf[offset..][0..2], @intCast(topic.len), .big);
    offset += 2;
    @memcpy(buf[offset..][0..topic.len], topic);
    offset += topic.len;

    // Count
    std.mem.writeInt(u32, buf[offset..][0..4], count, .big);
    offset += 4;

    // Since sequence
    std.mem.writeInt(u64, buf[offset..][0..8], since_seq, .big);

    return buf;
}

// Convert status to error
pub fn statusToError(status: Status) ?anyerror {
    return switch (status) {
        .ok => null,
        .not_found => error.NotFound,
        .err => error.ServerError,
        .invalid => error.InvalidRequest,
        .no_barrel => error.NoBarrel,
        .barrel_exists => error.BarrelExists,
        .barrel_not_found => error.BarrelNotFound,
        .unauthorized => error.Unauthorized,
    };
}

// Tests
test "request encode" {
    const allocator = std.testing.allocator;

    const req = Request{
        .command = .set,
        .seq = 42,
        .key = "test_key",
        .value = "test_value",
    };

    const encoded = try req.encode(allocator);
    defer allocator.free(encoded);

    // Verify structure
    try std.testing.expectEqual(@as(u8, 0x02), encoded[0]); // Command
    try std.testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, encoded[1..5], .big)); // Seq
    try std.testing.expectEqual(@as(u8, 0), encoded[5]); // Flags
    try std.testing.expectEqual(@as(u16, 8), std.mem.readInt(u16, encoded[6..8], .big)); // Key len
}

test "response decode" {
    const allocator = std.testing.allocator;

    // Create a response: status=OK, seq=42, value="hello"
    var data: [14]u8 = undefined;
    data[0] = 0x00; // Status OK
    std.mem.writeInt(u32, data[1..5], 42, .big); // Seq
    std.mem.writeInt(u32, data[5..9], 5, .big); // Value len
    @memcpy(data[9..14], "hello");

    var resp = try Response.decode(&data, allocator);
    defer resp.deinit(allocator);

    try std.testing.expectEqual(Status.ok, resp.status);
    try std.testing.expectEqual(@as(u32, 42), resp.seq);
    try std.testing.expectEqualStrings("hello", resp.value);
}
