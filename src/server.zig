const std = @import("std");
const processor_mod = @import("processor.zig");
const fast_reader_mod = @import("fast_reader.zig");
const args_mod = @import("args.zig");
const config_mod = @import("config.zig");

const web_assets = @import("web_assets");
const index_html = web_assets.index_html;
const demo_client_js = web_assets.demo_js;

pub const Server = struct {
    allocator: std.mem.Allocator,
    args: args_mod.Args,
    config: config_mod.Config,

    pub fn init(allocator: std.mem.Allocator, args: args_mod.Args, config: config_mod.Config) Server {
        return .{
            .allocator = allocator,
            .args = args,
            .config = config,
        };
    }

    pub fn run(self: *Server) !void {
        const port = self.args.port orelse 3000;
        const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
        var server = try address.listen(.{ .reuse_address = true });
        defer server.deinit();

        std.log.info("jlx server listening on http://0.0.0.0:{d}", .{port});

        while (true) {
            const conn = try server.accept();
            std.log.info("Client connected", .{});
            const thread = try std.Thread.spawn(.{}, handleConnectionThread, .{ self, conn });
            thread.detach();
        }
    }

    fn handleConnectionThread(self: *Server, conn: std.net.Server.Connection) void {
        self.handleConnection(conn) catch |err| {
            std.log.err("Error handling connection: {}", .{err});
        };
    }

    fn handleConnection(self: *Server, conn: std.net.Server.Connection) !void {
        defer conn.stream.close();

        const ws2_32 = std.os.windows.ws2_32;
        var buf: [4096]u8 = undefined;
        const n_signed = ws2_32.recv(conn.stream.handle, @ptrCast(&buf), @intCast(buf.len), 0);
        if (n_signed == ws2_32.SOCKET_ERROR) {
            std.log.err("recv error: {d}", .{ws2_32.WSAGetLastError()});
            return;
        }
        const n = @as(usize, @intCast(n_signed));
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
            _ = ws2_32.send(conn.stream.handle, @ptrCast(msg), @intCast(msg.len), 0);
            return;
        }

        if (std.mem.eql(u8, path, "/")) {
            try self.sendStatic(conn.stream.handle, "text/html", index_html);
        } else if (std.mem.eql(u8, path, "/demo-client.js")) {
            try self.sendStatic(conn.stream.handle, "application/javascript", demo_client_js);
        } else if (std.mem.startsWith(u8, path, "/sse")) {
            try self.handleSSE(conn.stream.handle, path);
        } else {
            // Try serving from --www if specified
            if (self.args.www) |www_path| {
                const relative_path = if (std.mem.startsWith(u8, path, "/")) path[1..] else path;
                var dir = try std.fs.cwd().openDir(www_path, .{});
                defer dir.close();
                const file = dir.openFile(relative_path, .{}) catch {
                    const msg = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
                    _ = ws2_32.send(conn.stream.handle, @ptrCast(msg), @intCast(msg.len), 0);
                    return;
                };
                defer file.close();
                const content = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
                defer self.allocator.free(content);
                const mime = if (std.mem.endsWith(u8, path, ".js")) "application/javascript" else "text/plain";
                try self.sendStatic(conn.stream.handle, mime, content);
            } else {
                const msg = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
                _ = ws2_32.send(conn.stream.handle, @ptrCast(msg), @intCast(msg.len), 0);
            }
        }
    }

    fn sendStatic(_: *Server, handle: std.os.windows.ws2_32.SOCKET, content_type: []const u8, content: []const u8) !void {
        const ws2_32 = std.os.windows.ws2_32;
        var header_buf: [256]u8 = undefined;
        const headers = try std.fmt.bufPrint(&header_buf, "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            "\r\n", .{ content_type, content.len });
        _ = ws2_32.send(handle, @ptrCast(headers), @intCast(headers.len), 0);
        _ = ws2_32.send(handle, @ptrCast(content), @intCast(content.len), 0);
    }

    pub fn handleSSE(self: *Server, handle: anytype, path: []const u8) !void {
        const w32 = std.os.windows.ws2_32;
        const head = "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/event-stream\r\n" ++
            "Cache-Control: no-cache\r\n" ++
            "Connection: keep-alive\r\n" ++
            "\r\n";
        _ = w32.send(handle, @ptrCast(head), @intCast(head.len), 0);

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

        const RawSseWriter = struct {
            h: std.os.windows.ws2_32.SOCKET,
            p: *processor_mod.Processor,
            c: *const @import("processor.zig").LineContext,

            pub fn write(rw: @This(), b: []const u8) !usize {
                const w = std.os.windows.ws2_32;
                _ = w.send(rw.h, "data: ", 6, 0);
                _ = w.send(rw.h, @ptrCast(b.ptr), @intCast(b.len), 0);
                _ = w.send(rw.h, "\n\n", 2, 0);
                return b.len;
            }
            pub fn writeAll(rw: @This(), b: []const u8) !void {
                _ = try rw.write(b);
            }
            pub fn flush(_: @This()) !void {}
        };

        const raw_writer = RawSseWriter{ .h = handle, .p = &processor, .c = &ctx };

        if (sse_args.file_path) |fpath| {
            const file = try std.fs.cwd().openFile(fpath, .{});
            defer file.close();

            if (sse_args.range) |rs| {
                if (std.fmt.parseInt(i64, rs, 10)) |val| {
                    if (val < 0) {
                        const offset = try fast_reader_mod.findLastLinesOffset(file, @intCast(-val));
                        try file.seekTo(offset);
                    }
                } else |_| {}
            }

            if (sse_args.follow) {
                try processor.followFile(file, raw_writer, &ctx);
            } else {
                var limit: ?usize = null;
                if (sse_args.range) |rs| {
                    if (std.fmt.parseInt(i64, rs, 10)) |val| {
                        if (val > 0) limit = @intCast(val);
                    } else |_| {}
                }
                try processor.processStream(file, raw_writer, &ctx, limit);
            }
        }
    }
};

const SseContext = struct {
    socket: std.os.windows.ws2_32.SOCKET,

    pub fn writeFn(self: *const SseContext, b: []const u8) anyerror!usize {
        const ws2_32_inner = std.os.windows.ws2_32;
        _ = ws2_32_inner.send(self.socket, "data: ", 6, 0);
        _ = ws2_32_inner.send(self.socket, @ptrCast(b.ptr), @intCast(b.len), 0);
        _ = ws2_32_inner.send(self.socket, "\n\n", 2, 0);
        return b.len;
    }

    pub fn writer(self: *const SseContext) std.io.Writer(*const SseContext, anyerror, SseContext.writeFn) {
        return .{ .context = self };
    }
};
