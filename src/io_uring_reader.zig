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

    // Overflow/straddle buffer
    side_buffer: std.ArrayListUnmanaged(u8),

    // Limits
    max_buffer_size: usize,
    eof_reached: bool = false,
    io_pending: bool = false,

    const PADDING: usize = 16;
    const BUF_SIZE: usize = 32 * 1024;

    pub const Options = struct {
        max_buffer_size: usize = 128 * 1024 * 1024, // Hard cap of 128MB
    };

    pub fn init(allocator: std.mem.Allocator, file: std.fs.File, options: Options) !*IoUringReader {
        if (builtin.os.tag != .linux) return error.UnsupportedPlatform;

        const self = try allocator.create(IoUringReader);
        errdefer allocator.destroy(self);

        const buf0 = try allocator.alloc(u8, BUF_SIZE + PADDING);
        errdefer allocator.free(buf0);
        const buf1 = try allocator.alloc(u8, BUF_SIZE + PADDING);
        errdefer allocator.free(buf1);

        // Use a 0 block for struct init then set the ring
        self.* = IoUringReader{
            .allocator = allocator,
            .file = file,
            .ring = undefined,
            .buffers = .{ buf0, buf1 },
            .active_idx = 0,
            .side_buffer = .{},
            .max_buffer_size = options.max_buffer_size,
        };

        if (builtin.os.tag == .linux) {
            self.ring = try std.os.linux.IoUring.init(2, 0);
            try self.registerBuffers();
        }

        // Initiate the first read synchronously to jumpstart the pipeline
        self.valid_len = try self.file.read(self.buffers[0][0..BUF_SIZE]);
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

    // --- housekeeping ---

    pub fn deinit(self: *IoUringReader) void {
        if (builtin.os.tag == .linux) {
            self.unregisterBuffers();
            self.ring.deinit();
        }
        self.allocator.free(self.buffers[0]);
        self.allocator.free(self.buffers[1]);
        self.side_buffer.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};
