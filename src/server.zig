const std = @import("std");
const processor_mod = @import("processor.zig");
const fast_reader_mod = @import("fast_reader.zig");
const args_mod = @import("args.zig");
const config_mod = @import("config.zig");

const web_assets = @import("web_assets");
const index_html = web_assets.index_html;
const demo_client_js = web_assets.demo_js;

const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

// C socket API for 0.17
extern "c" fn socket(af: c_int, typ: c_int, protocol: c_int) std.posix.socket_t;
extern "c" fn bind(sockfd: std.posix.socket_t, addr: *anyopaque, addrlen: c_ushort) c_int;
extern "c" fn listen(sockfd: std.posix.socket_t, backlog: c_int) c_int;
extern "c" fn accept(sockfd: std.posix.socket_t, addr: *anyopaque, addrlen: *c_ushort) std.posix.socket_t;
extern "c" fn setsockopt(sockfd: std.posix.socket_t, level: c_int, optname: c_int, optval: *const anyopaque, optlen: c_uint) c_int;
extern "c" fn recv(sockfd: std.posix.socket_t, buf: *anyopaque, len: c_int, flags: c_int) c_int;
extern "c" fn send(sockfd: std.posix.socket_t, buf: *const anyopaque, len: c_int, flags: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn _close(fd: c_int) c_int;
extern "c" fn closesocket(s: std.posix.socket_t) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) i32;
extern "c" fn lseek(fd: i32, offset: i64, whence: c_int) i64;
extern "c" fn read(fd: i32, buf: *anyopaque, count: usize) i64;
extern "c" fn WSAStartup(wVersionRequested: u16, lpWSAData: *anyopaque) c_int;

/// Winsock needs `closesocket`; POSIX uses `close` for sockets too.
fn closeSocket(handle: std.posix.socket_t) void {
    if (is_windows) {
        _ = closesocket(handle);
    } else {
        _ = close(handle);
    }
}

/// Plain file descriptors: Windows CRT spells it `_close`, POSIX `close`.
fn closeFile(fd: i32) void {
    if (is_windows) {
        _ = _close(fd);
    } else {
        _ = close(fd);
    }
}

fn socketRecv(handle: std.posix.socket_t, buf: []u8) !usize {
    const n = recv(handle, @ptrCast(buf.ptr), @intCast(buf.len), 0);
    if (n < 0) {
        std.log.err("recv error", .{});
        return error.Unexpected;
    }
    return @intCast(n);
}

fn socketSend(handle: std.posix.socket_t, buf: []const u8) !void {
    var sent: usize = 0;
    while (sent < buf.len) {
        const n = send(handle, @ptrCast(buf.ptr + sent), @intCast(buf.len - sent), 0);
        if (n < 0) {
            std.log.err("send error", .{});
            return error.Unexpected;
        }
        if (n == 0) return error.Unexpected;
        sent += @intCast(n);
    }
}

pub const Server = struct {
    allocator: std.mem.Allocator,
    args: args_mod.Args,
    config: *const config_mod.Config,

    pub fn init(allocator: std.mem.Allocator, args: args_mod.Args, config: *const config_mod.Config) Server {
        return .{
            .allocator = allocator,
            .args = args,
            .config = config,
        };
    }

    pub fn run(self: *Server) !void {
        const port: u16 = if (self.args.port) |p| std.fmt.parseInt(u16, p, 10) catch 3000 else 3000;

        // Windows: initialize Winsock
        if (is_windows) {
            var wsa_data: [128]u8 = undefined;
            _ = WSAStartup(2, @ptrCast(&wsa_data));
        }

        // Create socket
        const AF_INET: c_int = 2;
        const SOCK_STREAM: c_int = 1;
        const IPPROTO_TCP: c_int = 6;
        const fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (is_windows) {
            const INVALID_SOCKET: std.posix.socket_t = @ptrFromInt(~@as(usize, 0));
            if (fd == INVALID_SOCKET) {
                std.log.err("socket() failed", .{});
                return;
            }
        } else {
            if (fd < 0) {
                std.log.err("socket() failed", .{});
                return;
            }
        }

        // SO_REUSEADDR
        const one: [4]u8 = @bitCast(@as(u32, 1));
        const SOL_SOCKET: c_int = 1;
        const SO_REUSEADDR: c_int = 2;
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, @ptrCast(&one), 4);

        // Bind to 0.0.0.0:port
        const sin: [16]u8 = blk: {
            var s: [16]u8 = undefined;
            @memset(&s, 0);
            // sin_family = AF_INET (2)
            s[0] = 2;
            // sin_port = htons(port)
            s[2] = @intCast((port >> 8) & 0xFF);
            s[3] = @intCast(port & 0xFF);
            break :blk s;
        };
        const sin_len: c_ushort = 16;
        _ = bind(fd, @constCast(&sin), sin_len);

        // Listen
        _ = listen(fd, 128);

        std.log.info("jlx server listening on http://0.0.0.0:{d}", .{port});

        while (true) {
            var client_addr: [16]u8 = undefined;
            var client_len: c_ushort = 16;
            const conn_fd = accept(fd, @constCast(&client_addr), &client_len);
            if (is_windows) {
                const INVALID_SOCKET: std.posix.socket_t = @ptrFromInt(~@as(usize, 0));
                if (conn_fd == INVALID_SOCKET) continue;
            } else {
                if (conn_fd < 0) continue;
            }

            std.log.info("Client connected", .{});
            const thread = try std.Thread.spawn(.{}, handleConnectionThreadFd, .{ self, conn_fd });
            thread.detach();
        }
    }

    fn handleConnectionThreadFd(self: *Server, conn_fd: std.posix.socket_t) void {
        self.handleConnectionFd(conn_fd) catch |err| {
            std.log.err("Error handling connection: {}", .{err});
        };
    }

    fn handleConnectionFd(self: *Server, conn_fd: std.posix.socket_t) !void {
        defer closeSocket(conn_fd);

        var buf: [4096]u8 = undefined;
        const n = try socketRecv(conn_fd, &buf);
        if (n == 0) return;

        const request = buf[0..n];
        var lines_it = std.mem.tokenizeAny(u8, request, "\r\n");
        const first_line = lines_it.next() orelse return;
        std.log.info("{s}", .{first_line});

        var parts_it = std.mem.tokenizeScalar(u8, first_line, ' ');
        const method = parts_it.next() orelse return;
        const path = parts_it.next() orelse "/";

        if (!std.mem.eql(u8, method, "GET")) {
            std.log.info("Method not allowed: {s}", .{method});
            const msg = "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n";
            try socketSend(conn_fd, msg);
            return;
        }

        if (std.mem.eql(u8, path, "/")) {
            try self.sendStatic(conn_fd, "text/html", index_html);
        } else if (std.mem.eql(u8, path, "/demo-client.js")) {
            try self.sendStatic(conn_fd, "application/javascript", demo_client_js);
        } else if (std.mem.startsWith(u8, path, "/sse")) {
            try self.handleSSE(conn_fd, path);
        } else {
            // Try serving from --www if specified
            if (self.args.www) |www_path| {
                const relative_path = if (std.mem.startsWith(u8, path, "/")) path[1..] else path;
                // Build full path: www_path + "/" + relative_path
                var full_path = try self.allocator.alloc(u8, www_path.len + 1 + relative_path.len + 1);
                defer self.allocator.free(full_path);
                @memcpy(full_path[0..www_path.len], www_path);
                full_path[www_path.len] = '/';
                @memcpy(full_path[www_path.len + 1 .. full_path.len - 1], relative_path);
                full_path[full_path.len - 1] = 0;

                const fd = open(full_path[0..full_path.len - 1 :0], 0, 0);
                if (fd < 0) {
                    const msg = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
                    try socketSend(conn_fd, msg);
                    return;
                }
                defer closeFile(fd);

                const file_size: i64 = lseek(fd, 0, 2);
                _ = lseek(fd, 0, 0);
                if (file_size < 0 or file_size > 10 * 1024 * 1024) {
                    const msg = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
                    try socketSend(conn_fd, msg);
                    return;
                }
                const content = try self.allocator.alloc(u8, @intCast(file_size));
                defer self.allocator.free(content);
                const n_read = read(fd, content.ptr, content.len);
                const data = content[0..@intCast(n_read)];
                const mime = if (std.mem.endsWith(u8, path, ".js")) "application/javascript" else "text/plain";
                try self.sendStatic(conn_fd, mime, data);
            } else {
                const msg = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
                try socketSend(conn_fd, msg);
            }
        }
    }

    fn sendStatic(_: *Server, handle: std.posix.socket_t, content_type: []const u8, content: []const u8) !void {
        var header_buf: [256]u8 = undefined;
        const headers = try std.fmt.bufPrint(&header_buf, "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            "\r\n", .{ content_type, content.len });
        try socketSend(handle, headers);
        try socketSend(handle, content);
    }

    pub fn handleSSE(self: *Server, handle: std.posix.socket_t, path: []const u8) !void {
        const head = "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/event-stream\r\n" ++
            "Cache-Control: no-cache\r\n" ++
            "Connection: keep-alive\r\n" ++
            "\r\n";
        try socketSend(handle, head);

        // Parse query params to override args
        var sse_args = self.args;
        if (std.mem.indexOfScalar(u8, path, '?')) |q_idx| {
            const query = path[q_idx + 1 ..];
            var it = std.mem.tokenizeScalar(u8, query, '&');
            while (it.next()) |pair| {
                var kv = std.mem.tokenizeScalar(u8, pair, '=');
                const k = kv.next() orelse continue;
                const v_raw = kv.next() orelse "";

                // Simple URL decoding
                var v_buf = try self.allocator.alloc(u8, v_raw.len);
                errdefer self.allocator.free(v_buf);

                var di: usize = 0;
                var si: usize = 0;
                while (si < v_raw.len) {
                    if (v_raw[si] == '%' and si + 2 < v_raw.len) {
                        const hex = v_raw[si + 1 .. si + 3];
                        v_buf[di] = std.fmt.parseInt(u8, hex, 16) catch v_raw[si];
                        si += 3;
                    } else if (v_raw[si] == '+') {
                        v_buf[di] = ' ';
                        si += 1;
                    } else {
                        v_buf[di] = v_raw[si];
                        si += 1;
                    }
                    di += 1;
                }
                const v = v_buf[0..di];

                if (std.mem.eql(u8, k, "include")) sse_args.include = try self.allocator.dupe(u8, v);
                if (std.mem.eql(u8, k, "exclude")) sse_args.exclude = try self.allocator.dupe(u8, v);
                if (std.mem.eql(u8, k, "range")) sse_args.range = try self.allocator.dupe(u8, v);
                if (std.mem.eql(u8, k, "follow")) sse_args.follow = std.mem.eql(u8, v, "true");

                self.allocator.free(v_buf);
            }
        }
        sse_args.passthrough = true;

        var processor = processor_mod.Processor.init(self.allocator, sse_args, self.config);
        var ctx = try processor.buildContext();
        defer ctx.deinit(self.allocator);

        const SseWriter = struct {
            handle: std.posix.socket_t,

            pub fn write(rw: @This(), b: []const u8) !usize {
                try socketSend(rw.handle, "data: ");
                try socketSend(rw.handle, b);
                try socketSend(rw.handle, "\n\n");
                return b.len;
            }
            pub fn writeAll(rw: @This(), b: []const u8) !void {
                _ = try rw.write(b);
            }
            pub fn flush(_: @This()) !void {}
            pub fn writer(rw: @This()) std.io.Writer(@This(), anyerror, writeFn) {
                return .{ .context = rw };
            }
            fn writeFn(rw: @This(), b: []const u8) anyerror!usize {
                return try rw.write(b);
            }
        };

        const sse_writer = SseWriter{ .handle = handle };

        if (sse_args.file_path) |fpath| {
            var io_threaded = std.Io.Threaded.init(self.allocator, .{});
            const io = (&io_threaded).io();

            var reader_buf: [32 * 1024]u8 = undefined;

            const file = processor_mod.Processor.openFileIo(io, fpath) catch {
                std.log.err("could not open {s}", .{fpath});
                return;
            };
            defer file.close(io);

            var tail_offset: ?u64 = null;
            if (sse_args.range) |rs| {
                if (std.fmt.parseInt(i64, rs, 10)) |val| {
                    if (val < 0) {
                        tail_offset = try fast_reader_mod.findLastLinesOffsetIo(file, io, @intCast(-val));
                    }
                } else |_| {}
            }

            var reader = file.reader(io, &reader_buf);
            if (tail_offset) |off| {
                _ = reader.seekTo(off) catch {};
            }

            if (sse_args.follow) {
                try processor.followFile(&reader, sse_writer, &ctx);
            } else {
                var limit: ?usize = null;
                if (sse_args.range) |rs| {
                    if (std.fmt.parseInt(i64, rs, 10)) |val| {
                        if (val > 0) limit = @intCast(val);
                    } else |_| {}
                }
                try processor.processStream(&reader, sse_writer, &ctx, limit);
            }
        }
    }
};
