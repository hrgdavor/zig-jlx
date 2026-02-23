const std = @import("std");

/// A high-performance IO buffered file reader that manages its own memory bounds.
/// Features:
/// - 1MB base array slice for direct `file.read()` interactions (zero-syscall overhead).
/// - Dynamic realloc doubling up to `max_buffer_size` to prevent Out-Of-Memory (OOM) crashes on bad payloads.
/// - Gracefully extracts newlines via slice referencing instead of allocating memory per String chunk.
pub const FastLineReader = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    buf: []u8,
    read_pos: usize = 0,
    write_pos: usize = 0,
    eof: bool = false,
    max_buffer_size: usize = 16 * 1024 * 1024,

    pub const Options = struct {
        initial_buffer_size: usize = 1024 * 1024,
        max_buffer_size: usize = 16 * 1024 * 1024,
    };

    pub fn init(allocator: std.mem.Allocator, file: std.fs.File, options: Options) !FastLineReader {
        return .{
            .allocator = allocator,
            .file = file,
            .buf = try allocator.alloc(u8, options.initial_buffer_size),
            .max_buffer_size = options.max_buffer_size,
        };
    }

    pub fn deinit(self: *FastLineReader) void {
        self.allocator.free(self.buf);
    }

    /// Read the next \n separated line. The returned slice is strictly valid only until
    /// the NEXT `.next()` call, as it maps directly onto the internal array shifting mechanism.
    pub fn next(self: *FastLineReader) !?[]const u8 {
        while (true) {
            // Check for complete lines in the current chunk first
            if (std.mem.indexOfScalarPos(u8, self.buf[0..self.write_pos], self.read_pos, '\n')) |nl_idx| {
                var line = self.buf[self.read_pos..nl_idx];
                if (line.len > 0 and line[line.len - 1] == '\r') {
                    line = line[0 .. line.len - 1]; // Strip Windows carriage returns naturally
                }
                self.read_pos = nl_idx + 1;
                return line;
            }

            if (self.eof) {
                // Yield the final trailing string blob if file ended without newline
                if (self.read_pos < self.write_pos) {
                    var line = self.buf[self.read_pos..self.write_pos];
                    if (line.len > 0 and line[line.len - 1] == '\r') {
                        line = line[0 .. line.len - 1];
                    }
                    self.read_pos = self.write_pos;
                    return line;
                }
                return null;
            }

            // Shift incomplete remainder sequence backwards to buffer index 0
            const unread_len = self.write_pos - self.read_pos;
            if (self.read_pos > 0 and unread_len > 0) {
                std.mem.copyForwards(u8, self.buf[0..unread_len], self.buf[self.read_pos..self.write_pos]);
                self.read_pos = 0;
                self.write_pos = unread_len;
            } else if (self.read_pos > 0) {
                self.read_pos = 0;
                self.write_pos = 0;
            }

            // If we've hit the buffer wall without finding a newline...
            if (self.write_pos == self.buf.len) {
                if (self.buf.len >= self.max_buffer_size) {
                    // Safety Release: To prevent explosive alloc payloads, we skip lines natively.
                    var skipped = false;
                    while (true) {
                        const n = try self.file.read(self.buf[0..self.buf.len]);
                        if (n == 0) {
                            self.eof = true;
                            break;
                        }
                        if (std.mem.indexOfScalar(u8, self.buf[0..n], '\n')) |nl_idx| {
                            const remaining = n - (nl_idx + 1);
                            if (remaining > 0) {
                                std.mem.copyForwards(u8, self.buf[0..remaining], self.buf[nl_idx + 1 .. n]);
                            }
                            self.read_pos = 0;
                            self.write_pos = remaining;
                            skipped = true;
                            break;
                        }
                    }
                    if (self.eof and !skipped) return null;
                    continue; // Re-evaluate the new line we just salvaged
                }

                // Double capacity and retry
                var new_cap = self.buf.len * 2;
                if (new_cap > self.max_buffer_size) new_cap = self.max_buffer_size;
                self.buf = try self.allocator.realloc(self.buf, new_cap);
            }

            // Pull fresh data directly from OS descriptors
            const n = try self.file.read(self.buf[self.write_pos..]);
            if (n == 0) {
                self.eof = true;
            } else {
                self.write_pos += n;
            }
        }
    }
};
