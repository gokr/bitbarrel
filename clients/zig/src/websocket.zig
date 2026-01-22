const std = @import("std");

// libwebsockets C bindings
const c = @cImport({
    @cInclude("libwebsockets.h");
});

// LWS_PRE is typically 16 bytes for websocket frame header
pub const LWS_PRE: usize = 16;

// Callback reasons we care about
pub const CallbackReason = enum(c_int) {
    client_connection_error = c.LWS_CALLBACK_CLIENT_CONNECTION_ERROR,
    client_established = c.LWS_CALLBACK_CLIENT_ESTABLISHED,
    client_receive = c.LWS_CALLBACK_CLIENT_RECEIVE,
    client_writeable = c.LWS_CALLBACK_CLIENT_WRITEABLE,
    closed = c.LWS_CALLBACK_CLOSED,
    _,
};

// Write protocol types
pub const WriteProtocol = enum(c_int) {
    text = c.LWS_WRITE_TEXT,
    binary = c.LWS_WRITE_BINARY,
    continuation = c.LWS_WRITE_CONTINUATION,
    ping = c.LWS_WRITE_PING,
    pong = c.LWS_WRITE_PONG,
    close = c.LWS_WRITE_CLOSE,
};

// Connection state
pub const ConnectionState = enum {
    disconnected,
    connecting,
    connected,
    error_state,
};

// Error types
pub const WebSocketError = error{
    ContextCreationFailed,
    ConnectionFailed,
    NotConnected,
    SendFailed,
    Timeout,
    ProtocolError,
    OutOfMemory,
};

// Message received callback type
pub const MessageCallback = *const fn (data: []const u8, user_data: ?*anyopaque) void;

// Connection established callback type
pub const ConnectedCallback = *const fn (user_data: ?*anyopaque) void;

// Error callback type
pub const ErrorCallback = *const fn (message: []const u8, user_data: ?*anyopaque) void;

// WebSocket client
pub const WebSocket = struct {
    allocator: std.mem.Allocator,
    context: ?*c.struct_lws_context = null,
    wsi: ?*c.struct_lws = null,
    state: ConnectionState = .disconnected,

    // Configuration
    host: [:0]const u8,
    port: u16,
    path: [:0]const u8,
    use_ssl: bool,

    // Callbacks
    on_message: ?MessageCallback = null,
    on_connected: ?ConnectedCallback = null,
    on_error: ?ErrorCallback = null,
    user_data: ?*anyopaque = null,

    // Send queue
    send_queue: std.ArrayListUnmanaged([]u8) = .empty,
    send_mutex: std.Thread.Mutex = .{},

    // Receive buffer
    recv_buffer: std.ArrayListUnmanaged(u8) = .empty,

    // Protocol definition (must persist for lifetime of context)
    protocols: [2]c.struct_lws_protocols = undefined,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        host: [:0]const u8,
        port: u16,
        path: [:0]const u8,
        use_ssl: bool,
    ) Self {
        return Self{
            .allocator = allocator,
            .context = null,
            .wsi = null,
            .state = .disconnected,
            .host = host,
            .port = port,
            .path = path,
            .use_ssl = use_ssl,
            .on_message = null,
            .on_connected = null,
            .on_error = null,
            .user_data = null,
            .send_queue = .empty,
            .send_mutex = .{},
            .recv_buffer = .empty,
            .protocols = undefined,
        };
    }

    pub fn deinit(self: *Self) void {
        self.disconnect();

        // Free any remaining send queue items (check capacity to avoid double-free)
        if (self.send_queue.capacity > 0) {
            for (self.send_queue.items) |item| {
                self.allocator.free(item);
            }
            self.send_queue.deinit(self.allocator);
        }
        if (self.recv_buffer.capacity > 0) {
            self.recv_buffer.deinit(self.allocator);
        }
    }

    pub fn connect(self: *Self) WebSocketError!void {
        if (self.state == .connected) {
            return;
        }

        // Set up protocols
        self.protocols[0] = c.struct_lws_protocols{
            .name = "bitbarrel",
            .callback = &wsCallback,
            .per_session_data_size = @sizeOf(*Self),
            .rx_buffer_size = 65536,
            .id = 0,
            .user = @ptrCast(self),
            .tx_packet_size = 0,
        };
        self.protocols[1] = std.mem.zeroes(c.struct_lws_protocols);

        // Create context
        var info = std.mem.zeroes(c.struct_lws_context_creation_info);
        info.port = c.CONTEXT_PORT_NO_LISTEN;
        info.protocols = &self.protocols;
        info.options = c.LWS_SERVER_OPTION_DO_SSL_GLOBAL_INIT;
        info.user = @ptrCast(self);

        self.context = c.lws_create_context(&info);
        if (self.context == null) {
            return WebSocketError.ContextCreationFailed;
        }

        // Connect to server
        var ccinfo = std.mem.zeroes(c.struct_lws_client_connect_info);
        ccinfo.context = self.context;
        ccinfo.address = self.host.ptr;
        ccinfo.port = self.port;
        ccinfo.path = self.path.ptr;
        ccinfo.host = self.host.ptr;
        ccinfo.origin = self.host.ptr;
        ccinfo.protocol = "bitbarrel";
        ccinfo.pwsi = &self.wsi;
        ccinfo.userdata = @ptrCast(self);

        if (self.use_ssl) {
            ccinfo.ssl_connection = c.LCCSCF_USE_SSL |
                c.LCCSCF_ALLOW_SELFSIGNED |
                c.LCCSCF_SKIP_SERVER_CERT_HOSTNAME_CHECK;
        }

        self.state = .connecting;
        const wsi = c.lws_client_connect_via_info(&ccinfo);
        if (wsi == null) {
            self.state = .error_state;
            c.lws_context_destroy(self.context);
            self.context = null;
            return WebSocketError.ConnectionFailed;
        }

        self.wsi = wsi;
    }

    pub fn disconnect(self: *Self) void {
        if (self.context) |ctx| {
            c.lws_context_destroy(ctx);
            self.context = null;
        }
        self.wsi = null;
        self.state = .disconnected;
    }

    pub fn isConnected(self: *Self) bool {
        return self.state == .connected and self.wsi != null;
    }

    // Send binary data
    pub fn send(self: *Self, data: []const u8) WebSocketError!void {
        if (!self.isConnected()) {
            return WebSocketError.NotConnected;
        }

        // Allocate buffer with LWS_PRE padding
        const buf = self.allocator.alloc(u8, LWS_PRE + data.len) catch {
            return WebSocketError.OutOfMemory;
        };
        @memcpy(buf[LWS_PRE..][0..data.len], data);

        // Add to send queue
        self.send_mutex.lock();
        defer self.send_mutex.unlock();
        self.send_queue.append(self.allocator, buf) catch {
            self.allocator.free(buf);
            return WebSocketError.OutOfMemory;
        };

        // Request callback to send
        if (self.wsi) |wsi| {
            _ = c.lws_callback_on_writable(wsi);
        }
    }

    // Service the connection (call this in a loop or from event loop)
    pub fn service(self: *Self, timeout_ms: i32) void {
        if (self.context) |ctx| {
            _ = c.lws_service(ctx, timeout_ms);
        }
    }

    // Service until connected or timeout
    pub fn waitForConnection(self: *Self, timeout_ms: u32) WebSocketError!void {
        var timer = std.time.Timer.start() catch return WebSocketError.Timeout;
        while (self.state == .connecting) {
            self.service(10);
            const elapsed_ns = timer.read();
            const elapsed_ms = elapsed_ns / std.time.ns_per_ms;
            if (elapsed_ms > timeout_ms) {
                return WebSocketError.Timeout;
            }
        }

        if (self.state != .connected) {
            return WebSocketError.ConnectionFailed;
        }
    }

    // Wait for a response with timeout
    pub fn waitForMessage(self: *Self, timeout_ms: u32, buffer: *std.ArrayListUnmanaged(u8)) WebSocketError!void {
        var timer = std.time.Timer.start() catch return WebSocketError.Timeout;
        const initial_len = self.recv_buffer.items.len;

        while (self.recv_buffer.items.len == initial_len) {
            if (!self.isConnected()) {
                return WebSocketError.NotConnected;
            }
            self.service(10);
            const elapsed_ns = timer.read();
            const elapsed_ms = elapsed_ns / std.time.ns_per_ms;
            if (elapsed_ms > timeout_ms) {
                return WebSocketError.Timeout;
            }
        }

        // Copy received data and clear buffer
        buffer.appendSlice(self.allocator, self.recv_buffer.items) catch {
            return WebSocketError.OutOfMemory;
        };
        self.recv_buffer.clearRetainingCapacity();
    }

    // Internal: handle writing queued data
    fn handleWriteable(self: *Self) void {
        self.send_mutex.lock();
        defer self.send_mutex.unlock();

        if (self.send_queue.items.len > 0) {
            const buf = self.send_queue.orderedRemove(0);
            defer self.allocator.free(buf);

            if (self.wsi) |wsi| {
                const data_len = buf.len - LWS_PRE;
                const written = c.lws_write(wsi, buf.ptr + LWS_PRE, data_len, c.LWS_WRITE_BINARY);
                if (written < 0) {
                    // Write error
                    if (self.on_error) |cb| {
                        cb("Write failed", self.user_data);
                    }
                }

                // If more data in queue, request another callback
                if (self.send_queue.items.len > 0) {
                    _ = c.lws_callback_on_writable(wsi);
                }
            }
        }
    }

    // Internal: handle received data
    fn handleReceive(self: *Self, data: []const u8) void {
        // Append to receive buffer
        self.recv_buffer.appendSlice(self.allocator, data) catch {
            if (self.on_error) |cb| {
                cb("Out of memory in receive", self.user_data);
            }
            return;
        };

        // Call message callback if set
        if (self.on_message) |cb| {
            cb(data, self.user_data);
        }
    }

    // WebSocket callback function
    fn wsCallback(
        wsi: ?*c.struct_lws,
        reason: c.enum_lws_callback_reasons,
        user: ?*anyopaque,
        in: ?*anyopaque,
        len: usize,
    ) callconv(.c) c_int {
        // Get self from user data
        var self: ?*Self = null;

        if (user) |u| {
            self = @ptrCast(@alignCast(u));
        }

        if (self == null) {
            // Try to get from wsi user data
            if (wsi) |w| {
                const ctx = c.lws_get_context(w);
                if (ctx) |cx| {
                    const ctx_user = c.lws_context_user(cx);
                    if (ctx_user) |cu| {
                        self = @ptrCast(@alignCast(cu));
                    }
                }
            }
        }

        if (self == null) {
            return 0;
        }

        const s = self.?;

        switch (@as(CallbackReason, @enumFromInt(reason))) {
            .client_established => {
                s.state = .connected;
                if (s.on_connected) |cb| {
                    cb(s.user_data);
                }
            },
            .client_receive => {
                if (in) |data_ptr| {
                    const data: [*]const u8 = @ptrCast(data_ptr);
                    s.handleReceive(data[0..len]);
                }
            },
            .client_writeable => {
                s.handleWriteable();
            },
            .closed => {
                s.state = .disconnected;
                s.wsi = null;
            },
            .client_connection_error => {
                s.state = .error_state;
                s.wsi = null;
                if (s.on_error) |cb| {
                    if (in) |msg_ptr| {
                        const msg: [*]const u8 = @ptrCast(msg_ptr);
                        cb(msg[0..len], s.user_data);
                    } else {
                        cb("Connection error", s.user_data);
                    }
                }
            },
            _ => {},
        }

        return 0;
    }
};

// Helper to parse URL into components
pub const UrlComponents = struct {
    host: [:0]const u8,
    port: u16,
    path: [:0]const u8,
    use_ssl: bool,

    pub fn parse(allocator: std.mem.Allocator, url: []const u8) !UrlComponents {
        var use_ssl = false;
        var start: usize = 0;

        // Check protocol
        if (std.mem.startsWith(u8, url, "wss://")) {
            use_ssl = true;
            start = 6;
        } else if (std.mem.startsWith(u8, url, "ws://")) {
            start = 5;
        } else {
            return error.InvalidUrl;
        }

        // Find port separator or path
        var host_end = start;
        var port_start: ?usize = null;
        var path_start: usize = url.len;

        while (host_end < url.len) : (host_end += 1) {
            if (url[host_end] == ':') {
                port_start = host_end + 1;
            } else if (url[host_end] == '/') {
                path_start = host_end;
                break;
            }
        }

        // Extract host
        const host_slice = if (port_start) |ps|
            url[start .. ps - 1]
        else
            url[start..path_start];

        const host = try allocator.allocSentinel(u8, host_slice.len, 0);
        @memcpy(host, host_slice);

        // Extract port
        var port: u16 = if (use_ssl) 443 else 80;
        if (port_start) |ps| {
            const port_end = path_start;
            if (port_end > ps) {
                port = std.fmt.parseInt(u16, url[ps..port_end], 10) catch {
                    allocator.free(host);
                    return error.InvalidPort;
                };
            }
        }

        // Extract path
        const path_slice = if (path_start < url.len) url[path_start..] else "/";
        const path = try allocator.allocSentinel(u8, path_slice.len, 0);
        @memcpy(path, path_slice);

        return UrlComponents{
            .host = host,
            .port = port,
            .path = path,
            .use_ssl = use_ssl,
        };
    }

    pub fn deinit(self: *UrlComponents, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.path);
    }
};

// Tests
test "url parse ws" {
    const allocator = std.testing.allocator;
    var components = try UrlComponents.parse(allocator, "ws://localhost:9876/ws");
    defer components.deinit(allocator);

    try std.testing.expectEqualStrings("localhost", components.host);
    try std.testing.expectEqual(@as(u16, 9876), components.port);
    try std.testing.expectEqualStrings("/ws", components.path);
    try std.testing.expect(!components.use_ssl);
}

test "url parse wss" {
    const allocator = std.testing.allocator;
    var components = try UrlComponents.parse(allocator, "wss://example.com:8443/api");
    defer components.deinit(allocator);

    try std.testing.expectEqualStrings("example.com", components.host);
    try std.testing.expectEqual(@as(u16, 8443), components.port);
    try std.testing.expectEqualStrings("/api", components.path);
    try std.testing.expect(components.use_ssl);
}

test "url parse default port" {
    const allocator = std.testing.allocator;
    var components = try UrlComponents.parse(allocator, "ws://localhost/");
    defer components.deinit(allocator);

    try std.testing.expectEqualStrings("localhost", components.host);
    try std.testing.expectEqual(@as(u16, 80), components.port);
    try std.testing.expectEqualStrings("/", components.path);
}
