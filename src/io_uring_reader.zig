const std = @import("std");
const builtin = @import("builtin");
const fast_reader = @import("fast_reader.zig");

pub const IoUringReader = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    ring: std.os.linux.IoUring,

    // Double-buffered design
    buffers: [2][]u8,
    active_idx: u1,

    // State of the current buffer
    read_pos: usize = 0,
    valid_len: usize = 0,

    // Limits
    max_buffer_size: usize,
    eof_reached: bool = false,
    io_pending: bool = false,

    const PADDING: usize = 64;
    const INITIAL_SIZE: usize = 1024 * 1024; // 1MB

    pub const Options = struct {
        initial_buffer_size: usize = INITIAL_SIZE,
        max_buffer_size: usize = 128 * 1024 * 1024, // Hard cap of 128MB
    };

    pub fn init(allocator: std.mem.Allocator, file: std.fs.File, options: Options) !*IoUringReader {
        if (builtin.os.tag != .linux) return error.UnsupportedPlatform;

        const self = try allocator.create(IoUringReader);
        errdefer allocator.destroy(self);

        const init_size = options.initial_buffer_size;

        const buf0 = try allocator.alloc(u8, init_size + PADDING);
        errdefer allocator.free(buf0);
        const buf1 = try allocator.alloc(u8, init_size + PADDING);
        errdefer allocator.free(buf1);

        // Use a 0 block for struct init then set the ring
        self.* = IoUringReader{
            .allocator = allocator,
            .file = file,
            .ring = undefined,
            .buffers = .{ buf0, buf1 },
            .active_idx = 0,
            .max_buffer_size = options.max_buffer_size,
        };

        if (builtin.os.tag == .linux) {
            self.ring = try std.os.linux.IoUring.init(2, 0);
            try self.registerBuffers();
        }

        // Initiate the first read synchronously to jumpstart the pipeline
        self.valid_len = try self.file.read(self.buffers[0][0..init_size]);
        if (self.valid_len == 0) self.eof_reached = true;

        if (!self.eof_reached) {
            try self.startAsyncRead(1, 0);
        }

        return self;
    }

    fn registerBuffers(self: *IoUringReader) !void {
        if (builtin.os.tag != .linux) return;
        const iovecs = [_]std.posix.iovec{
            .{ .base = self.buffers[0].ptr, .len = self.buffers[0].len },
            .{ .base = self.buffers[1].ptr, .len = self.buffers[1].len },
        };
        _ = std.os.linux.io_uring_register(self.ring.fd, std.os.linux.IORING.REGISTER_BUFFERS, @ptrCast(&iovecs), iovecs.len);
    }

    fn unregisterBuffers(self: *IoUringReader) void {
        if (builtin.os.tag != .linux) return;
        _ = std.os.linux.io_uring_unregister(self.ring.fd, std.os.linux.IORING.UNREGISTER_BUFFERS, null, 0);
    }

    pub fn deinit(self: *IoUringReader) void {
        if (builtin.os.tag == .linux) {
            self.unregisterBuffers();
            self.ring.deinit();
        }
        self.allocator.free(self.buffers[0]);
        self.allocator.free(self.buffers[1]);
        self.allocator.destroy(self);
    }

    fn startAsyncRead(self: *IoUringReader, buf_idx: u1, start_offset: usize) !void {
        if (self.eof_reached or self.io_pending) return;
        if (builtin.os.tag != .linux) return;

        const target_buf = self.buffers[buf_idx];
        const read_slice = target_buf[start_offset .. target_buf.len - PADDING];
        if (read_slice.len == 0) return;

        _ = try self.ring.read_fixed(
            @intCast(self.file.handle),
            read_slice,
            0,
            buf_idx,
        );
        _ = try self.ring.submit();

        self.io_pending = true;
    }

    fn waitForIO(self: *IoUringReader) !usize {
        if (!self.io_pending) return 0;
        self.io_pending = false;

        var bytes_read: usize = 0;
        if (builtin.os.tag == .linux) {
            var cqe: std.os.linux.io_uring_cqe = undefined;
            _ = try self.ring.copy_cqe(&cqe);
            bytes_read = @intCast(cqe.res);
        }

        if (bytes_read == 0) {
            self.eof_reached = true;
        }
        return bytes_read;
    }

    pub fn next(self: *IoUringReader) !?[]const u8 {
        while (true) {
            const buf = self.buffers[self.active_idx];
            const data = buf[self.read_pos..self.valid_len];

            // 1. Look for the next newline in the current valid data
            if (std.mem.indexOfScalar(u8, data, '\n')) |nl_idx| {
                var line = data[0..nl_idx];
                self.read_pos += nl_idx + 1;

                // Strip Windows carriage return
                if (line.len > 0 and line[line.len - 1] == '\r') {
                    line = line[0 .. line.len - 1];
                }
                return line;
            }

            // 2. If EOF is reached, yield whatever is remaining
            if (self.eof_reached) {
                if (data.len > 0) {
                    self.read_pos = self.valid_len;
                    var line = data;
                    if (line.len > 0 and line[line.len - 1] == '\r') {
                        line = line[0 .. line.len - 1];
                    }
                    return line;
                }
                return null;
            }

            // 3. We didn't find a newline in the current active buffer. Wait for the inactive buffer to fill.
            const new_bytes = try self.waitForIO();

            const frag_len = self.valid_len - self.read_pos;
            const next_idx = ~self.active_idx;

            if (frag_len > 0) {
                std.mem.copyForwards(u8, self.buffers[next_idx][0..frag_len], buf[self.read_pos..self.valid_len]);
            }

            const new_valid_len = frag_len + new_bytes;

            if (new_valid_len >= self.buffers[next_idx].len - PADDING) {
                const new_cap = self.buffers[0].len * 2;
                if (new_cap > self.max_buffer_size) {
                    return error.MaxBufferSizeReached; // Hard cap
                }

                self.unregisterBuffers();

                self.buffers[0] = try self.allocator.realloc(self.buffers[0], new_cap);
                self.buffers[1] = try self.allocator.realloc(self.buffers[1], new_cap);

                try self.registerBuffers();

                const extra_read = try self.file.read(self.buffers[next_idx][new_valid_len .. self.buffers[next_idx].len - PADDING]);
                self.valid_len = new_valid_len + extra_read;
                if (extra_read == 0) self.eof_reached = true;
            } else {
                self.valid_len = new_valid_len;
            }

            self.active_idx = next_idx;
            self.read_pos = 0;

            if (!self.eof_reached) {
                const last_nl = fast_reader.findLastNewlineAVX2(self.buffers[self.active_idx][0..self.valid_len]);
                var carry_offset: usize = 0;
                if (last_nl) |idx| {
                    carry_offset = self.valid_len - (idx + 1);
                    std.mem.copyForwards(u8, self.buffers[~self.active_idx][0..carry_offset], self.buffers[self.active_idx][idx + 1 .. self.valid_len]);
                    self.valid_len = idx + 1;
                } else {
                    carry_offset = self.valid_len;
                    std.mem.copyForwards(u8, self.buffers[~self.active_idx][0..carry_offset], self.buffers[self.active_idx][0..self.valid_len]);
                    self.valid_len = 0;
                }

                try self.startAsyncRead(~self.active_idx, carry_offset);
            }
        }
    }

    pub fn reader(self: *IoUringReader) fast_reader.FastLineReader {
        return .{
            .ptr = self,
            .vtable = &.{
                .next = nextErased,
                .deinit = deinitErased,
            },
        };
    }

    fn nextErased(ptr: *anyopaque) anyerror!?[]const u8 {
        const self: *IoUringReader = @ptrCast(@alignCast(ptr));
        return self.next();
    }

    fn deinitErased(ptr: *anyopaque) void {
        const self: *IoUringReader = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};
