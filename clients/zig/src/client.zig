const std = @import("std");
const protocol = @import("protocol");
const websocket = @import("websocket");

// Re-export key types from protocol
pub const Command = protocol.Command;
pub const Status = protocol.Status;
pub const MessageType = protocol.MessageType;
pub const KeyValue = protocol.KeyValue;
pub const PubSubEvent = protocol.PubSubEvent;
pub const KeysResponse = protocol.KeysResponse;

// Error types
pub const Error = error{
    ConnectionError,
    Timeout,
    ProtocolError,
    InvalidRequest,
    NotFound,
    NoBarrel,
    BarrelExists,
    BarrelNotFound,
    Unauthorized,
    ServerError,
    UnknownError,
    OutOfMemory,
    NotConnected,
    SendFailed,
};

// Client configuration
pub const Config = struct {
    url: []const u8 = "ws://localhost:9876",
    timeout_ms: u32 = 5000,
    max_retries: u32 = 3,
    enable_auto_reconnect: bool = true,
};

// Barrel mode
pub const Mode = enum(u8) {
    hash = 0,
    critbit = 1,
};

// Batch item for batch operations
pub const BatchItem = struct {
    key: []const u8,
    value: []const u8,
};

// Batch get result
pub const BatchGetResult = struct {
    allocator: std.mem.Allocator,
    items: []BatchGetItem,

    pub const BatchGetItem = struct {
        key: []const u8,
        value: ?[]const u8,
    };

    pub fn deinit(self: *BatchGetResult) void {
        for (self.items) |*item| {
            self.allocator.free(item.key);
            if (item.value) |v| self.allocator.free(v);
        }
        self.allocator.free(self.items);
    }
};

// Range result
pub const RangeResult = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(Item),
    next_cursor: ?[]const u8,
    has_more: bool,

    pub const Item = struct {
        key: []const u8,
        value: []const u8,
    };

    pub fn deinit(self: *RangeResult) void {
        for (self.items.items) |item| {
            self.allocator.free(item.key);
            self.allocator.free(item.value);
        }
        self.items.deinit(self.allocator);
        if (self.next_cursor) |cursor| {
            self.allocator.free(cursor);
        }
    }
};

// Message for pub/sub
pub const Message = struct {
    allocator: std.mem.Allocator,
    event: protocol.PubSubEvent,

    pub fn topic(self: Message) []const u8 {
        return self.event.topic;
    }

    pub fn data(self: Message) []const u8 {
        return self.event.payload;
    }

    pub fn timestamp(self: Message) i64 {
        return self.event.timestamp;
    }

    pub fn messageType(self: Message) MessageType {
        return self.event.message_type;
    }

    pub fn deinit(self: *const Message) void {
        var event = self.event;
        event.deinit(self.allocator);
    }
};

// Server info
pub const ServerInfo = struct {
    allocator: std.mem.Allocator,
    info: protocol.ServerInfo,

    pub fn version(self: ServerInfo) [2]u8 {
        return .{ self.info.version_major, self.info.version_minor };
    }

    pub fn serverId(self: ServerInfo) []const u8 {
        return self.info.server_id;
    }

    pub fn plugins(self: ServerInfo) [][]const u8 {
        return self.info.plugins;
    }

    pub fn deinit(self: *ServerInfo) void {
        var info = self.info;
        info.deinit(self.allocator);
    }
};

// BitBarrel Client
pub const Client = struct {
    allocator: std.mem.Allocator,
    ws: websocket.WebSocket,
    url_components: websocket.UrlComponents,
    config: Config,
    seq: u32 = 0,
    currentBarrel: ?[]const u8 = null,
    recv_buffer: std.ArrayListUnmanaged(u8) = .empty,
    event_queue: std.ArrayListUnmanaged([]u8) = .empty,
    server_info: ?protocol.ServerInfo = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: Config) Error!Self {
        // Parse URL
        var url_components = websocket.UrlComponents.parse(allocator, config.url) catch {
            return Error.ConnectionError;
        };
        errdefer url_components.deinit(allocator);

        // Create WebSocket
        var ws = websocket.WebSocket.init(
            allocator,
            url_components.host,
            url_components.port,
            url_components.path,
            url_components.use_ssl,
        );

        // Connect
        ws.connect() catch {
            ws.deinit();
            // url_components will be deinited by errdefer
            return Error.ConnectionError;
        };
        errdefer ws.deinit();

        // Wait for connection
        ws.waitForConnection(config.timeout_ms) catch {
            ws.deinit();
            // url_components will be deinited by errdefer
            return Error.Timeout;
        };

        return Self{
            .allocator = allocator,
            .ws = ws,
            .url_components = url_components,
            .config = config,
        };
    }

    pub fn deinit(self: *Self) void {
        self.ws.deinit();
        self.url_components.deinit(self.allocator);
        self.recv_buffer.deinit(self.allocator);

        // Free queued events
        for (self.event_queue.items) |event_data| {
            self.allocator.free(event_data);
        }
        self.event_queue.deinit(self.allocator);

        if (self.currentBarrel) |barrel| {
            self.allocator.free(barrel);
        }

        if (self.server_info) |*info| {
            info.deinit(self.allocator);
        }
    }

    pub fn isConnected(self: *Self) bool {
        return self.ws.isConnected();
    }

    // Get next sequence number
    fn nextSeq(self: *Self) u32 {
        self.seq +%= 1;
        return self.seq;
    }

    // Send request and wait for response
    fn sendRequest(self: *Self, req: protocol.Request) Error!protocol.Response {
        // Encode request
        const encoded = req.encode(self.allocator) catch {
            return Error.OutOfMemory;
        };
        defer self.allocator.free(encoded);

        // Send
        self.ws.send(encoded) catch {
            return Error.SendFailed;
        };

        // Wait for response
        return self.waitForResponse(req.seq);
    }

    // Wait for response with matching sequence number
    fn waitForResponse(self: *Self, expected_seq: u32) Error!protocol.Response {
        var timer = std.time.Timer.start() catch return Error.Timeout;

        while (true) {
            // Service WebSocket
            self.ws.service(10);

            // Check for timeout
            const elapsed_ns = timer.read();
            const elapsed_ms = elapsed_ns / std.time.ns_per_ms;
            if (elapsed_ms > self.config.timeout_ms) {
                return Error.Timeout;
            }

            // Check if we have data
            if (self.ws.recv_buffer.items.len == 0) {
                continue;
            }

            // Copy received data
            const recv_data = self.allocator.alloc(u8, self.ws.recv_buffer.items.len) catch {
                return Error.OutOfMemory;
            };
            @memcpy(recv_data, self.ws.recv_buffer.items);
            self.ws.recv_buffer.clearRetainingCapacity();

            // Check if this is a PubSub event
            if (protocol.isPubSubEvent(recv_data)) {
                // Queue the event for later processing
                self.event_queue.append(self.allocator, recv_data) catch {
                    self.allocator.free(recv_data);
                    return Error.OutOfMemory;
                };
                continue;
            }

            // Decode response
            var resp = protocol.Response.decode(recv_data, self.allocator) catch {
                self.allocator.free(recv_data);
                return Error.ProtocolError;
            };
            self.allocator.free(recv_data);

            // Check sequence number
            if (resp.seq != expected_seq) {
                // Wrong sequence - discard and continue waiting
                resp.deinit(self.allocator);
                continue;
            }

            return resp;
        }
    }

    // Convert status to error
    fn checkStatus(status: protocol.Status) Error!void {
        switch (status) {
            .ok => return,
            .not_found => return Error.NotFound,
            .err => return Error.ServerError,
            .invalid => return Error.InvalidRequest,
            .no_barrel => return Error.NoBarrel,
            .barrel_exists => return Error.BarrelExists,
            .barrel_not_found => return Error.BarrelNotFound,
            .unauthorized => return Error.Unauthorized,
        }
    }

    // Barrel operations
    pub fn createBarrel(self: *Self, name: []const u8, mode: Mode) Error!void {
        const req = protocol.Request{
            .command = .create_barrel,
            .seq = self.nextSeq(),
            .key = name,
            .value = &[_]u8{@intFromEnum(mode)},
        };

        var resp = try self.sendRequest(req);
        defer resp.deinit(self.allocator);
        try checkStatus(resp.status);
    }

    pub fn openBarrel(self: *Self, name: []const u8) Error!void {
        const req = protocol.Request{
            .command = .open_barrel,
            .seq = self.nextSeq(),
            .key = name,
            .value = "",
        };

        var resp = try self.sendRequest(req);
        defer resp.deinit(self.allocator);
        try checkStatus(resp.status);
    }

    pub fn useBarrel(self: *Self, name: []const u8) Error!void {
        const req = protocol.Request{
            .command = .use_barrel,
            .seq = self.nextSeq(),
            .key = name,
            .value = "",
        };

        var resp = try self.sendRequest(req);
        defer resp.deinit(self.allocator);
        try checkStatus(resp.status);

        // Store current barrel name
        if (self.currentBarrel) |old| {
            self.allocator.free(old);
        }
        self.currentBarrel = self.allocator.dupe(u8, name) catch {
            return Error.OutOfMemory;
        };
    }

    pub fn closeBarrel(self: *Self) Error!void {
        const req = protocol.Request{
            .command = .close_barrel,
            .seq = self.nextSeq(),
            .key = "",
            .value = "",
        };

        var resp = try self.sendRequest(req);
        defer resp.deinit(self.allocator);
        try checkStatus(resp.status);

        if (self.currentBarrel) |barrel| {
            self.allocator.free(barrel);
            self.currentBarrel = null;
        }
    }

    pub fn dropBarrel(self: *Self, name: []const u8) Error!void {
        const req = protocol.Request{
            .command = .drop_barrel,
            .seq = self.nextSeq(),
            .key = name,
            .value = "",
        };

        var resp = try self.sendRequest(req);
        defer resp.deinit(self.allocator);
        try checkStatus(resp.status);

        // Clear current barrel if it matches
        if (self.currentBarrel) |current| {
            if (std.mem.eql(u8, current, name)) {
                self.allocator.free(current);
                self.currentBarrel = null;
            }
        }
    }

    pub fn listBarrels(self: *Self) Error!BarrelList {
        const req = protocol.Request{
            .command = .list_barrels,
            .seq = self.nextSeq(),
            .key = "",
            .value = "",
        };

        var resp = try self.sendRequest(req);
        defer resp.deinit(self.allocator);
        try checkStatus(resp.status);

        // Parse barrel list from response value
        // Format: [count:4][len:2][name]...
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (list.items) |item| self.allocator.free(item);
            list.deinit(self.allocator);
        }

        if (resp.value.len >= 4) {
            const barrel_count = std.mem.readInt(u32, resp.value[0..4], .big);
            var offset: usize = 4;

            var i: usize = 0;
            while (i < barrel_count and offset + 2 <= resp.value.len) : (i += 1) {
                const name_len = std.mem.readInt(u16, resp.value[offset..][0..2], .big);
                offset += 2;

                if (offset + name_len > resp.value.len) break;

                const name = self.allocator.alloc(u8, name_len) catch {
                    return Error.OutOfMemory;
                };
                @memcpy(name, resp.value[offset..][0..name_len]);
                offset += name_len;

                list.append(self.allocator, name) catch {
                    self.allocator.free(name);
                    return Error.OutOfMemory;
                };
            }
        }

        return BarrelList{
            .allocator = self.allocator,
            .items = list.toOwnedSlice(self.allocator) catch {
                return Error.OutOfMemory;
            },
        };
    }

    // Key-value operations
    pub fn set(self: *Self, key: []const u8, value: []const u8) Error!void {
        return self.setWithTtl(key, value, null);
    }

    pub fn setWithTtl(self: *Self, key: []const u8, value: []const u8, ttl: ?u32) Error!void {
        const req = protocol.Request{
            .command = .set,
            .seq = self.nextSeq(),
            .key = key,
            .value = value,
            .ttl = ttl,
        };

        var resp = try self.sendRequest(req);
        defer resp.deinit(self.allocator);
        try checkStatus(resp.status);
    }

    pub fn get(self: *Self, key: []const u8) Error!?[]const u8 {
        const req = protocol.Request{
            .command = .get,
            .seq = self.nextSeq(),
            .key = key,
            .value = "",
        };

        var resp = try self.sendRequest(req);
        defer resp.deinit(self.allocator);

        if (resp.status == .not_found) {
            return null;
        }
        try checkStatus(resp.status);

        // Copy value
        if (resp.value.len == 0) {
            return null;
        }

        const value = self.allocator.alloc(u8, resp.value.len) catch {
            return Error.OutOfMemory;
        };
        @memcpy(value, resp.value);
        return value;
    }

    pub fn delete(self: *Self, key: []const u8) Error!void {
        const req = protocol.Request{
            .command = .delete,
            .seq = self.nextSeq(),
            .key = key,
            .value = "",
        };

        var resp = try self.sendRequest(req);
        defer resp.deinit(self.allocator);
        try checkStatus(resp.status);
    }

    pub fn exists(self: *Self, key: []const u8) Error!bool {
        const req = protocol.Request{
            .command = .exists,
            .seq = self.nextSeq(),
            .key = key,
            .value = "",
        };

        var resp = try self.sendRequest(req);
        defer resp.deinit(self.allocator);

        if (resp.status == .not_found) {
            return false;
        }
        try checkStatus(resp.status);
        return true;
    }

    pub fn count(self: *Self) Error!i64 {
        const req = protocol.Request{
            .command = .count,
            .seq = self.nextSeq(),
            .key = "",
            .value = "",
        };

        var resp = try self.sendRequest(req);
        defer resp.deinit(self.allocator);
        try checkStatus(resp.status);

        // Parse count from response value (8 bytes big-endian)
        if (resp.value.len >= 8) {
            return @bitCast(std.mem.readInt(u64, resp.value[0..8], .big));
        }
        return 0;
    }

    // Batch operations
    pub fn batchSet(self: *Self, items: []const BatchItem) Error!usize {
        if (items.len == 0) return 0;

        // Encode batch: [count:4][keyLen:2][key][valLen:4][val]...
        var size: usize = 4;
        for (items) |item| {
            size += 2 + item.key.len + 4 + item.value.len;
        }

        var buf = self.allocator.alloc(u8, size) catch {
            return Error.OutOfMemory;
        };
        defer self.allocator.free(buf);

        var offset: usize = 0;
        std.mem.writeInt(u32, buf[offset..][0..4], @intCast(items.len), .big);
        offset += 4;

        for (items) |item| {
            std.mem.writeInt(u16, buf[offset..][0..2], @intCast(item.key.len), .big);
            offset += 2;
            @memcpy(buf[offset..][0..item.key.len], item.key);
            offset += item.key.len;
            std.mem.writeInt(u32, buf[offset..][0..4], @intCast(item.value.len), .big);
            offset += 4;
            @memcpy(buf[offset..][0..item.value.len], item.value);
            offset += item.value.len;
        }

        const req = protocol.Request{
            .command = .batch_set,
            .seq = self.nextSeq(),
            .key = "",
            .value = buf,
        };

        var resp = try self.sendRequest(req);
        defer resp.deinit(self.allocator);
        try checkStatus(resp.status);

        // Parse success count (4 bytes)
        if (resp.value.len >= 4) {
            return std.mem.readInt(u32, resp.value[0..4], .big);
        }
        return items.len;
    }

    pub fn batchGet(self: *Self, keys: []const []const u8) Error!BatchGetResult {
        if (keys.len == 0) {
            return BatchGetResult{
                .allocator = self.allocator,
                .items = &[_]BatchGetResult.BatchGetItem{},
            };
        }

        // Encode keys: [count:4][keyLen:2][key]...
        var size: usize = 4;
        for (keys) |key| {
            size += 2 + key.len;
        }

        var buf = self.allocator.alloc(u8, size) catch {
            return Error.OutOfMemory;
        };
        defer self.allocator.free(buf);

        var offset: usize = 0;
        std.mem.writeInt(u32, buf[offset..][0..4], @intCast(keys.len), .big);
        offset += 4;

        for (keys) |key| {
            std.mem.writeInt(u16, buf[offset..][0..2], @intCast(key.len), .big);
            offset += 2;
            @memcpy(buf[offset..][0..key.len], key);
            offset += key.len;
        }

        const req = protocol.Request{
            .command = .batch_get,
            .seq = self.nextSeq(),
            .key = "",
            .value = buf,
        };

        var resp = try self.sendRequest(req);
        defer resp.deinit(self.allocator);
        try checkStatus(resp.status);

        // Parse response: [count:4][found:1][keyLen:2][key][valLen:4][val]...
        var items: std.ArrayListUnmanaged(BatchGetResult.BatchGetItem) = .empty;
        errdefer {
            for (items.items) |*item| {
                self.allocator.free(item.key);
                if (item.value) |v| self.allocator.free(v);
            }
            items.deinit(self.allocator);
        }

        if (resp.value.len >= 4) {
            const result_count = std.mem.readInt(u32, resp.value[0..4], .big);
            var resp_offset: usize = 4;

            var i: usize = 0;
            while (i < result_count and resp_offset < resp.value.len) : (i += 1) {
                const found = resp.value[resp_offset] != 0;
                resp_offset += 1;

                if (resp_offset + 2 > resp.value.len) break;
                const key_len = std.mem.readInt(u16, resp.value[resp_offset..][0..2], .big);
                resp_offset += 2;

                if (resp_offset + key_len > resp.value.len) break;
                const key = self.allocator.alloc(u8, key_len) catch {
                    return Error.OutOfMemory;
                };
                @memcpy(key, resp.value[resp_offset..][0..key_len]);
                resp_offset += key_len;

                var value: ?[]u8 = null;
                if (found) {
                    if (resp_offset + 4 > resp.value.len) {
                        self.allocator.free(key);
                        break;
                    }
                    const val_len = std.mem.readInt(u32, resp.value[resp_offset..][0..4], .big);
                    resp_offset += 4;

                    if (resp_offset + val_len > resp.value.len) {
                        self.allocator.free(key);
                        break;
                    }
                    value = self.allocator.alloc(u8, val_len) catch {
                        self.allocator.free(key);
                        return Error.OutOfMemory;
                    };
                    @memcpy(value.?, resp.value[resp_offset..][0..val_len]);
                    resp_offset += val_len;
                }

                items.append(self.allocator, .{ .key = key, .value = value }) catch {
                    self.allocator.free(key);
                    if (value) |v| self.allocator.free(v);
                    return Error.OutOfMemory;
                };
            }
        }

        return BatchGetResult{
            .allocator = self.allocator,
            .items = items.toOwnedSlice(self.allocator) catch {
                return Error.OutOfMemory;
            },
        };
    }

    pub fn batchDelete(self: *Self, keys: []const []const u8) Error!usize {
        if (keys.len == 0) return 0;

        // Encode keys: [count:4][keyLen:2][key]...
        var size: usize = 4;
        for (keys) |key| {
            size += 2 + key.len;
        }

        var buf = self.allocator.alloc(u8, size) catch {
            return Error.OutOfMemory;
        };
        defer self.allocator.free(buf);

        var offset: usize = 0;
        std.mem.writeInt(u32, buf[offset..][0..4], @intCast(keys.len), .big);
        offset += 4;

        for (keys) |key| {
            std.mem.writeInt(u16, buf[offset..][0..2], @intCast(key.len), .big);
            offset += 2;
            @memcpy(buf[offset..][0..key.len], key);
            offset += key.len;
        }

        const req = protocol.Request{
            .command = .batch_delete,
            .seq = self.nextSeq(),
            .key = "",
            .value = buf,
        };

        var resp = try self.sendRequest(req);
        defer resp.deinit(self.allocator);
        try checkStatus(resp.status);

        // Parse success count
        if (resp.value.len >= 4) {
            return std.mem.readInt(u32, resp.value[0..4], .big);
        }
        return keys.len;
    }

    // Range queries
    pub fn itemsInRange(
        self: *Self,
        start_key: []const u8,
        end_key: []const u8,
        limit: usize,
        cursor: ?[]const u8,
    ) Error!RangeResult {
        const value = protocol.encodeRangeRequest(
            self.allocator,
            start_key,
            end_key,
            @intCast(limit),
            cursor orelse "",
        ) catch {
            return Error.OutOfMemory;
        };
        defer self.allocator.free(value);

        const req = protocol.Request{
            .command = .range_query,
            .seq = self.nextSeq(),
            .key = "",
            .value = value,
        };

        var resp = try self.sendRequest(req);
        defer resp.deinit(self.allocator);
        try checkStatus(resp.status);

        return parseRangeResponse(self.allocator, resp.value);
    }

    pub fn itemsWithPrefix(
        self: *Self,
        prefix: []const u8,
        limit: usize,
        cursor: ?[]const u8,
    ) Error!RangeResult {
        const value = protocol.encodePrefixRequest(
            self.allocator,
            prefix,
            @intCast(limit),
            cursor orelse "",
        ) catch {
            return Error.OutOfMemory;
        };
        defer self.allocator.free(value);

        const req = protocol.Request{
            .command = .prefix_query,
            .seq = self.nextSeq(),
            .key = "",
            .value = value,
        };

        var resp = try self.sendRequest(req);
        defer resp.deinit(self.allocator);
        try checkStatus(resp.status);

        return parseRangeResponse(self.allocator, resp.value);
    }

    fn parseRangeResponse(allocator: std.mem.Allocator, response_data: []const u8) Error!RangeResult {
        var range_resp = protocol.RangeResponse.decode(response_data, allocator) catch {
            return Error.ProtocolError;
        };
        defer range_resp.deinit(allocator);

        var items: std.ArrayListUnmanaged(RangeResult.Item) = .empty;
        errdefer {
            for (items.items) |item| {
                allocator.free(item.key);
                allocator.free(item.value);
            }
            items.deinit(allocator);
        }

        for (range_resp.items) |item| {
            const key = allocator.alloc(u8, item.key.len) catch {
                return Error.OutOfMemory;
            };
            @memcpy(key, item.key);

            const value = allocator.alloc(u8, item.value.len) catch {
                allocator.free(key);
                return Error.OutOfMemory;
            };
            @memcpy(value, item.value);

            items.append(allocator, .{ .key = key, .value = value }) catch {
                allocator.free(key);
                allocator.free(value);
                return Error.OutOfMemory;
            };
        }

        var next_cursor: ?[]u8 = null;
        if (range_resp.next_cursor.len > 0) {
            next_cursor = allocator.alloc(u8, range_resp.next_cursor.len) catch {
                return Error.OutOfMemory;
            };
            @memcpy(next_cursor.?, range_resp.next_cursor);
        }

        return RangeResult{
            .allocator = allocator,
            .items = items,
            .next_cursor = next_cursor,
            .has_more = range_resp.has_more,
        };
    }

    // Pub/Sub operations
    pub fn subscribe(self: *Self, subscribe_topic: []const u8) Error!void {
        const value = protocol.encodeSubscribeRequest(
            self.allocator,
            subscribe_topic,
            "",
            false,
            false,
            false,
        ) catch {
            return Error.OutOfMemory;
        };
        defer self.allocator.free(value);

        const req = protocol.Request{
            .command = .subscribe,
            .seq = self.nextSeq(),
            .key = "",
            .value = value,
        };

        var resp = try self.sendRequest(req);
        defer resp.deinit(self.allocator);
        try checkStatus(resp.status);
    }

    pub fn unsubscribe(self: *Self, unsubscribe_topic: []const u8) Error!void {
        const req = protocol.Request{
            .command = .unsubscribe,
            .seq = self.nextSeq(),
            .key = unsubscribe_topic,
            .value = "",
        };

        var resp = try self.sendRequest(req);
        defer resp.deinit(self.allocator);
        try checkStatus(resp.status);
    }

    pub fn publish(self: *Self, publish_topic: []const u8, publish_data: []const u8) Error!void {
        const value = protocol.encodePublishRequest(
            self.allocator,
            publish_topic,
            .data,
            "",
            publish_data,
        ) catch {
            return Error.OutOfMemory;
        };
        defer self.allocator.free(value);

        const req = protocol.Request{
            .command = .publish,
            .seq = self.nextSeq(),
            .key = "",
            .value = value,
        };

        var resp = try self.sendRequest(req);
        defer resp.deinit(self.allocator);
        try checkStatus(resp.status);
    }

    pub fn pollMessage(self: *Self) ?Message {
        // Service WebSocket to receive any pending messages
        self.ws.service(0);

        // Check for data in receive buffer
        if (self.ws.recv_buffer.items.len > 0) {
            const recv_data = self.allocator.alloc(u8, self.ws.recv_buffer.items.len) catch return null;
            @memcpy(recv_data, self.ws.recv_buffer.items);
            self.ws.recv_buffer.clearRetainingCapacity();

            if (protocol.isPubSubEvent(recv_data)) {
                const event = protocol.PubSubEvent.decode(recv_data, self.allocator) catch {
                    self.allocator.free(recv_data);
                    return null;
                };
                self.allocator.free(recv_data);
                return Message{
                    .allocator = self.allocator,
                    .event = event,
                };
            }
            self.allocator.free(recv_data);
        }

        // Check queued events
        if (self.event_queue.items.len > 0) {
            const event_data = self.event_queue.orderedRemove(0);
            const event = protocol.PubSubEvent.decode(event_data, self.allocator) catch {
                self.allocator.free(event_data);
                return null;
            };
            self.allocator.free(event_data);
            return Message{
                .allocator = self.allocator,
                .event = event,
            };
        }

        return null;
    }

    // Key watching
    pub fn watchKey(self: *Self, pattern: []const u8) Error!void {
        const barrel_name = self.currentBarrel orelse "";
        const value = protocol.encodeWatchRequest(
            self.allocator,
            barrel_name,
            pattern,
            true,
        ) catch {
            return Error.OutOfMemory;
        };
        defer self.allocator.free(value);

        const req = protocol.Request{
            .command = .watch_key,
            .seq = self.nextSeq(),
            .key = "",
            .value = value,
        };

        var resp = try self.sendRequest(req);
        defer resp.deinit(self.allocator);
        try checkStatus(resp.status);
    }

    pub fn unwatchKey(self: *Self, pattern: []const u8) Error!void {
        const req = protocol.Request{
            .command = .unwatch_key,
            .seq = self.nextSeq(),
            .key = pattern,
            .value = "",
        };

        var resp = try self.sendRequest(req);
        defer resp.deinit(self.allocator);
        try checkStatus(resp.status);
    }

    // ========================================================================
    // Additional features for parity with Nim client
    // ========================================================================

    /// Ping the server to check connectivity
    /// Returns true if server responds with "pong"
    pub fn ping(self: *Self) Error!bool {
        const req = protocol.Request{
            .command = .ping,
            .seq = self.nextSeq(),
            .key = "",
            .value = "",
        };

        var resp = try self.sendRequest(req);
        defer resp.deinit(self.allocator);

        if (resp.status != .ok) {
            return false;
        }

        return std.mem.eql(u8, resp.value, "pong");
    }

    /// Get value by key, returning default if not found
    pub fn getOrDefault(self: *Self, key: []const u8, default: []const u8) Error![]const u8 {
        const result = self.get(key) catch |err| {
            if (err == Error.NotFound) {
                // Copy the default value
                const value = self.allocator.alloc(u8, default.len) catch {
                    return Error.OutOfMemory;
                };
                @memcpy(value, default);
                return value;
            }
            return err;
        };

        if (result) |value| {
            return value;
        }

        // Key found but value was empty/null - return copy of default
        const value = self.allocator.alloc(u8, default.len) catch {
            return Error.OutOfMemory;
        };
        @memcpy(value, default);
        return value;
    }

    /// List all keys in the current barrel
    pub fn listKeys(self: *Self) Error!KeysResult {
        const req = protocol.Request{
            .command = .list_keys,
            .seq = self.nextSeq(),
            .key = "",
            .value = "",
        };

        var resp = try self.sendRequest(req);
        defer resp.deinit(self.allocator);
        try checkStatus(resp.status);

        // Parse comma-separated keys from response
        var keys: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (keys.items) |k| self.allocator.free(k);
            keys.deinit(self.allocator);
        }

        if (resp.value.len > 0) {
            var iter = std.mem.splitSequence(u8, resp.value, ",");
            while (iter.next()) |key| {
                if (key.len > 0) {
                    const key_copy = self.allocator.alloc(u8, key.len) catch {
                        return Error.OutOfMemory;
                    };
                    @memcpy(key_copy, key);
                    keys.append(self.allocator, key_copy) catch {
                        self.allocator.free(key_copy);
                        return Error.OutOfMemory;
                    };
                }
            }
        }

        return KeysResult{
            .allocator = self.allocator,
            .items = keys.toOwnedSlice(self.allocator) catch {
                return Error.OutOfMemory;
            },
        };
    }

    /// Get the configuration for a barrel
    pub fn getBarrelConfig(self: *Self, name: []const u8) Error![]const u8 {
        const req = protocol.Request{
            .command = .get_barrel_config,
            .seq = self.nextSeq(),
            .key = name,
            .value = "",
        };

        var resp = try self.sendRequest(req);
        defer resp.deinit(self.allocator);

        if (resp.status == .barrel_not_found) {
            return Error.BarrelNotFound;
        }
        try checkStatus(resp.status);

        // Copy value
        const value = self.allocator.alloc(u8, resp.value.len) catch {
            return Error.OutOfMemory;
        };
        @memcpy(value, resp.value);
        return value;
    }

    /// Set the configuration for a barrel
    pub fn setBarrelConfig(self: *Self, name: []const u8, config: []const u8) Error!void {
        const req = protocol.Request{
            .command = .set_barrel_config,
            .seq = self.nextSeq(),
            .key = name,
            .value = config,
        };

        var resp = try self.sendRequest(req);
        defer resp.deinit(self.allocator);

        if (resp.status == .barrel_not_found) {
            return Error.BarrelNotFound;
        }
        try checkStatus(resp.status);
    }

    /// Count keys in range [startKey, endKey)
    /// Requires barrel opened in bmCritBit mode
    pub fn rangeCount(self: *Self, start_key: []const u8, end_key: []const u8) Error!i64 {
        const value = protocol.encodeRangeRequest(
            self.allocator,
            start_key,
            end_key,
            0, // limit not used for count
            "",
        ) catch {
            return Error.OutOfMemory;
        };
        defer self.allocator.free(value);

        const req = protocol.Request{
            .command = .range_count,
            .seq = self.nextSeq(),
            .key = "",
            .value = value,
        };

        var resp = try self.sendRequest(req);
        defer resp.deinit(self.allocator);
        try checkStatus(resp.status);

        // Parse count from response value (string or binary)
        if (resp.value.len >= 8) {
            return @bitCast(std.mem.readInt(u64, resp.value[0..8], .big));
        }
        // Try to parse as decimal string
        return std.fmt.parseInt(i64, resp.value, 10) catch 0;
    }

    // ========================================================================
    // Enhanced Pub/Sub operations
    // ========================================================================

    /// Subscribe with options (supports pattern matching)
    pub fn subscribeWithOptions(
        self: *Self,
        topic_or_pattern: []const u8,
        options: SubscribeOptions,
    ) Error![]const u8 {
        // Determine if pattern-based subscription
        const is_pattern = std.mem.indexOf(u8, topic_or_pattern, "*") != null;
        const actual_topic = if (is_pattern) "" else topic_or_pattern;
        const actual_pattern = if (is_pattern) topic_or_pattern else "";

        const value = protocol.encodeSubscribeRequest(
            self.allocator,
            actual_topic,
            actual_pattern,
            options.enable_kv_events,
            options.enable_presence,
            options.replay_history,
        ) catch {
            return Error.OutOfMemory;
        };
        defer self.allocator.free(value);

        const req = protocol.Request{
            .command = .subscribe,
            .seq = self.nextSeq(),
            .key = "",
            .value = value,
        };

        var resp = try self.sendRequest(req);
        defer resp.deinit(self.allocator);
        try checkStatus(resp.status);

        // Response value is the subscription ID
        const sub_id = self.allocator.alloc(u8, resp.value.len) catch {
            return Error.OutOfMemory;
        };
        @memcpy(sub_id, resp.value);
        return sub_id;
    }

    /// Unsubscribe from all subscriptions
    /// Returns number of subscriptions removed
    pub fn unsubscribeAll(self: *Self) Error!usize {
        // For now, this is a no-op as we don't track subscriptions client-side
        // The server handles this with a special command or we need to track locally
        _ = self;
        return 0;
    }

    /// Check if subscription is active (client-side tracking not implemented)
    pub fn isSubscribed(self: *Self, sub_id: []const u8) bool {
        // Would require client-side subscription tracking
        _ = self;
        _ = sub_id;
        return false;
    }

    /// List subscribers for a topic
    pub fn listSubscribers(self: *Self, list_topic: []const u8) Error!SubscriberList {
        const req = protocol.Request{
            .command = .list_subscribers,
            .seq = self.nextSeq(),
            .key = list_topic,
            .value = "",
        };

        var resp = try self.sendRequest(req);
        defer resp.deinit(self.allocator);
        try checkStatus(resp.status);

        // Response is JSON - return raw JSON for now
        const json = self.allocator.alloc(u8, resp.value.len) catch {
            return Error.OutOfMemory;
        };
        @memcpy(json, resp.value);

        return SubscriberList{
            .allocator = self.allocator,
            .json = json,
        };
    }

    /// List all topics
    pub fn listTopics(self: *Self) Error!TopicList {
        const req = protocol.Request{
            .command = .list_topics,
            .seq = self.nextSeq(),
            .key = "",
            .value = "",
        };

        var resp = try self.sendRequest(req);
        defer resp.deinit(self.allocator);
        try checkStatus(resp.status);

        // Response is JSON - return raw JSON for now
        const json = self.allocator.alloc(u8, resp.value.len) catch {
            return Error.OutOfMemory;
        };
        @memcpy(json, resp.value);

        return TopicList{
            .allocator = self.allocator,
            .json = json,
        };
    }

    /// Get message history for topic
    pub fn getHistory(
        self: *Self,
        history_topic: []const u8,
        limit: u32,
        since_seq: u64,
    ) Error!HistoryResult {
        const value = protocol.encodeHistoryRequest(
            self.allocator,
            history_topic,
            limit,
            since_seq,
        ) catch {
            return Error.OutOfMemory;
        };
        defer self.allocator.free(value);

        const req = protocol.Request{
            .command = .history,
            .seq = self.nextSeq(),
            .key = "",
            .value = value,
        };

        var resp = try self.sendRequest(req);
        defer resp.deinit(self.allocator);
        try checkStatus(resp.status);

        // Response is JSON - return raw JSON for now
        const json = self.allocator.alloc(u8, resp.value.len) catch {
            return Error.OutOfMemory;
        };
        @memcpy(json, resp.value);

        return HistoryResult{
            .allocator = self.allocator,
            .json = json,
        };
    }

    /// Get presence info for topic
    pub fn getPresence(self: *Self, presence_topic: []const u8) Error!PresenceResult {
        const value = protocol.encodePresenceRequest(self.allocator, 0) catch {
            return Error.OutOfMemory;
        };
        defer self.allocator.free(value);

        const req = protocol.Request{
            .command = .presence,
            .seq = self.nextSeq(),
            .key = presence_topic,
            .value = value,
        };

        var resp = try self.sendRequest(req);
        defer resp.deinit(self.allocator);
        try checkStatus(resp.status);

        // Response is JSON - return raw JSON for now
        const json = self.allocator.alloc(u8, resp.value.len) catch {
            return Error.OutOfMemory;
        };
        @memcpy(json, resp.value);

        return PresenceResult{
            .allocator = self.allocator,
            .json = json,
        };
    }

    // ========================================================================
    // Enhanced key watching
    // ========================================================================

    /// Watch for changes to keys matching a pattern with options
    /// Returns watch ID for efficient unwatch
    pub fn watchKeyWithOptions(
        self: *Self,
        pattern: []const u8,
        include_values: bool,
    ) Error![]const u8 {
        const barrel_name = self.currentBarrel orelse "";
        const value = protocol.encodeWatchRequest(
            self.allocator,
            barrel_name,
            pattern,
            include_values,
        ) catch {
            return Error.OutOfMemory;
        };
        defer self.allocator.free(value);

        const req = protocol.Request{
            .command = .watch_key,
            .seq = self.nextSeq(),
            .key = "",
            .value = value,
        };

        var resp = try self.sendRequest(req);
        defer resp.deinit(self.allocator);
        try checkStatus(resp.status);

        // Response value is the watch ID
        const watch_id = self.allocator.alloc(u8, resp.value.len) catch {
            return Error.OutOfMemory;
        };
        @memcpy(watch_id, resp.value);
        return watch_id;
    }

    /// Unwatch using a watch ID (more efficient than pattern-based unwatch)
    pub fn unwatchById(self: *Self, watch_id: []const u8) Error!void {
        const req = protocol.Request{
            .command = .unwatch_key,
            .seq = self.nextSeq(),
            .key = watch_id,
            .value = "",
        };

        var resp = try self.sendRequest(req);
        defer resp.deinit(self.allocator);
        try checkStatus(resp.status);
    }

    /// Get barrel statistics
    pub fn getBarrelStats(self: *Self, name: []const u8) Error![]const u8 {
        const req = protocol.Request{
            .command = .get_barrel_stats,
            .seq = self.nextSeq(),
            .key = name,
            .value = "",
        };

        var resp = try self.sendRequest(req);
        defer resp.deinit(self.allocator);

        if (resp.status == .barrel_not_found) {
            return Error.BarrelNotFound;
        }
        try checkStatus(resp.status);

        // Copy value (JSON stats)
        const value = self.allocator.alloc(u8, resp.value.len) catch {
            return Error.OutOfMemory;
        };
        @memcpy(value, resp.value);
        return value;
    }
};

// Barrel list result
pub const BarrelList = struct {
    allocator: std.mem.Allocator,
    items: [][]const u8,

    pub fn deinit(self: *BarrelList) void {
        for (self.items) |item| {
            self.allocator.free(item);
        }
        self.allocator.free(self.items);
    }
};

// Keys list result
pub const KeysResult = struct {
    allocator: std.mem.Allocator,
    items: [][]const u8,

    pub fn deinit(self: *KeysResult) void {
        for (self.items) |item| {
            self.allocator.free(item);
        }
        self.allocator.free(self.items);
    }
};

// Subscribe options
pub const SubscribeOptions = struct {
    enable_kv_events: bool = false,
    enable_presence: bool = false,
    replay_history: bool = false,
};

// Subscriber list result (raw JSON)
pub const SubscriberList = struct {
    allocator: std.mem.Allocator,
    json: []const u8,

    pub fn deinit(self: *SubscriberList) void {
        self.allocator.free(self.json);
    }
};

// Topic list result (raw JSON)
pub const TopicList = struct {
    allocator: std.mem.Allocator,
    json: []const u8,

    pub fn deinit(self: *TopicList) void {
        self.allocator.free(self.json);
    }
};

// History result (raw JSON)
pub const HistoryResult = struct {
    allocator: std.mem.Allocator,
    json: []const u8,

    pub fn deinit(self: *HistoryResult) void {
        self.allocator.free(self.json);
    }
};

// Presence result (raw JSON)
pub const PresenceResult = struct {
    allocator: std.mem.Allocator,
    json: []const u8,

    pub fn deinit(self: *PresenceResult) void {
        self.allocator.free(self.json);
    }
};

// Tests
test "client config" {
    const config = Config{
        .url = "ws://localhost:8080",
        .timeout_ms = 10000,
    };
    try std.testing.expectEqualStrings("ws://localhost:8080", config.url);
    try std.testing.expectEqual(@as(u32, 10000), config.timeout_ms);
}
