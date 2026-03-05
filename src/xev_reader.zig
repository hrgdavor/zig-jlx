const std = @import("std");
const fast_reader = @import("fast_reader.zig");
const builtin = @import("builtin");

// Conditionally import xev only when we aren't on linux
const xev = if (builtin.os.tag != .linux) @import("xev") else struct {
    pub const Loop = struct {
        pub fn init(opts: anytype) !Loop {
            _ = opts;
            return .{};
        }
        pub fn deinit(self: *Loop) void {
            _ = self;
        }
        pub const RunMode = enum { until_done };
        pub fn run(self: *Loop, mode: RunMode) !void {
            _ = self;
            _ = mode;
        }
    };
    pub const Completion = struct {};
    pub const File = struct {
        pub fn init(f: std.fs.File) !File {
            _ = f;
            return .{};
        }
        pub fn read(self: File, loop: *Loop, c: *Completion, buf: anytype, comptime T: type, ud: ?*T, comptime cb: anytype) void {
            _ = self;
            _ = loop;
            _ = c;
            _ = buf;
            _ = ud;
            _ = cb;
        }
    };
    pub const ReadBuffer = struct {};
    pub const ReadError = error{};
    pub const CallbackAction = enum { disarm };
};

pub const XevReader = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,

    // Double-buffered design
    buffers: [2][]u8,
    active_idx: u1,

    read_pos: usize = 0,
    valid_len: usize = 0,

    max_buffer_size: usize,
    eof_reached: bool = false,
    io_pending: bool = false,

    // Overflow/straddle buffer
    side_buffer: std.ArrayListUnmanaged(u8),

    loop: xev.Loop,
    completion: xev.Completion,

    // Keep track of where we submitted the last IO read request
    pending_offset: usize = 0,
    io_bytes_read: usize = 0,
    io_error: ?anyerror = null,

    const PADDING: usize = 16;
    const BUF_SIZE: usize = 64 * 1024;

    pub const Options = struct {
        max_buffer_size: usize = 128 * 1024 * 1024,
    };

    pub fn init(allocator: std.mem.Allocator, file: std.fs.File, options: Options) !*XevReader {
        if (builtin.os.tag == .linux) return error.UnsupportedPlatform;

        const self = try allocator.create(XevReader);
        errdefer allocator.destroy(self);

        const buf0 = try allocator.alloc(u8, BUF_SIZE + PADDING);
        errdefer allocator.free(buf0);
        const buf1 = try allocator.alloc(u8, BUF_SIZE + PADDING);
        errdefer allocator.free(buf1);

        self.* = XevReader{
            .allocator = allocator,
            .file = file,
            .buffers = .{ buf0, buf1 },
            .active_idx = 0,
            .side_buffer = .{},
            .max_buffer_size = options.max_buffer_size,
            .loop = if (builtin.os.tag != .linux) try xev.Loop.init(.{}) else undefined,
            .completion = undefined,
            .pending_offset = 0,
        };

        // Initiate the first read synchronously to jumpstart the pipeline
        self.valid_len = try self.file.read(self.buffers[0][0..BUF_SIZE]);
        if (self.valid_len == 0) self.eof_reached = true;

        if (!self.eof_reached) {
            try self.startAsyncRead(1, 0);
        }

        return self;
    }

    fn readCallback(
        ud: ?*XevReader,
        l: *xev.Loop,
        c: *xev.Completion,
        s: xev.File,
        b: xev.ReadBuffer,
        r: xev.ReadError!usize,
    ) xev.CallbackAction {
        _ = l;
        _ = c;
        _ = s;
        _ = b;
        const self = ud.?;
        if (r) |bytes_read| {
            self.io_bytes_read = bytes_read;
        } else |err| {
            self.io_error = err;
        }
        return .disarm;
    }

    fn startAsyncRead(self: *XevReader, buf_idx: u1, start_offset: usize) !void {
        if (self.eof_reached or self.io_pending) return;

        const target_buf = self.buffers[buf_idx];
        const read_slice = target_buf[start_offset .. target_buf.len - PADDING];
        if (read_slice.len == 0) return;

        self.io_error = null;
        self.io_bytes_read = 0;

        if (builtin.os.tag != .linux) {
            const xev_file = try xev.File.init(self.file);
            xev_file.read(&self.loop, &self.completion, .{ .slice = read_slice }, XevReader, self, readCallback);
        }

        self.pending_offset = start_offset;
        self.io_pending = true;
    }

    fn waitForIO(self: *XevReader) !usize {
        if (!self.io_pending) return 0;
        self.io_pending = false;

        if (builtin.os.tag != .linux) {
            try self.loop.run(.until_done);
            if (self.io_error) |err| return err;

            if (self.io_bytes_read == 0) {
                self.eof_reached = true;
            }
            return self.io_bytes_read;
        } else {
            // Synchronous fallback simulation to unblock tests natively on Linux (which would use io_uring instead)
            const target_buf = self.buffers[~self.active_idx];
            const bytes_read = try self.file.read(target_buf[self.pending_offset .. target_buf.len - PADDING]);

            if (bytes_read == 0) {
                self.eof_reached = true;
            }
            return bytes_read;
        }
    }

    pub fn next(self: *XevReader) !?[]const u8 {
        while (true) {
            const buf = self.buffers[self.active_idx];
            const data = buf[self.read_pos..self.valid_len];

            // 1. Look for the next newline in the current valid data
            if (std.mem.indexOfScalar(u8, data, '\n')) |nl_idx| {
                const fragment = data[0..nl_idx];
                self.read_pos += nl_idx + 1;

                if (self.side_buffer.items.len > 0) {
                    try self.side_buffer.appendSlice(self.allocator, fragment);
                    var line = self.side_buffer.items;
                    if (line.len > 0 and line[line.len - 1] == '\r') {
                        line = line[0 .. line.len - 1];
                    }
                    const result = line;
                    self.side_buffer.clearRetainingCapacity();
                    return result;
                } else {
                    var line = fragment;
                    if (line.len > 0 and line[line.len - 1] == '\r') {
                        line = line[0 .. line.len - 1];
                    }
                    return line;
                }
            }

            // 2. No newline in current buffer. If EOF is reached, yield whatever is remaining in side_buffer + data
            if (self.eof_reached) {
                if (self.side_buffer.items.len > 0 or data.len > 0) {
                    try self.side_buffer.appendSlice(self.allocator, data);
                    self.read_pos = self.valid_len;
                    var line = self.side_buffer.items;
                    if (line.len > 0 and line[line.len - 1] == '\r') {
                        line = line[0 .. line.len - 1];
                    }
                    const result = line;
                    self.side_buffer.clearRetainingCapacity();
                    return result;
                }
                return null;
            }

            // 3. Append the unconsumed "straddle" part to side_buffer
            try self.side_buffer.appendSlice(self.allocator, data);
            if (self.side_buffer.items.len > self.max_buffer_size) return error.MaxBufferSizeReached;

            // 4. Wait for the background I/O to finish
            const new_bytes = try self.waitForIO();

            // Swap buffers: the background buffer becomes active
            self.active_idx = ~self.active_idx;
            self.valid_len = new_bytes;
            self.read_pos = 0;

            // 5. Start a new async read for the buffer that just became free
            if (!self.eof_reached) {
                try self.startAsyncRead(~self.active_idx, 0);
            }
        }
    }

    pub fn reader(self: *XevReader) fast_reader.FastLineReader {
        return .{
            .ptr = self,
            .vtable = &.{
                .next = nextErased,
                .deinit = deinitErased,
            },
        };
    }

    fn nextErased(ptr: *anyopaque) anyerror!?[]const u8 {
        const self: *XevReader = @ptrCast(@alignCast(ptr));
        return self.next();
    }

    fn deinitErased(ptr: *anyopaque) void {
        const self: *XevReader = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    pub fn deinit(self: *XevReader) void {
        if (builtin.os.tag != .linux) {
            self.loop.deinit();
        }
        self.allocator.free(self.buffers[0]);
        self.allocator.free(self.buffers[1]);
        self.side_buffer.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};
