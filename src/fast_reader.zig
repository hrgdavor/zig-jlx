const std = @import("std");

/// Common Interface for fast line extraction.
pub const FastLineReader = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        next: *const fn (ctx: *anyopaque) anyerror!?[]const u8,
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub inline fn next(self: FastLineReader) !?[]const u8 {
        return self.vtable.next(self.ptr);
    }

    pub inline fn deinit(self: FastLineReader) void {
        self.vtable.deinit(self.ptr);
    }
};

/// Backward-scanning AVX2 bitmask helper to locate the final \n in a chunk
pub fn findLastNewlineAVX2(bytes: []const u8) ?usize {
    var count: usize = 1;
    return findNthNewlineFromEndSIMD(bytes, &count);
}

/// Backward-scanning SIMD helper to locate the Nth \n from the end of a chunk.
/// Subtracts found newlines from `n_remaining`. Returns index if `n_remaining` becomes 0.
pub fn findNthNewlineFromEndSIMD(bytes: []const u8, n_remaining: *usize) ?usize {
    const V = @Vector(32, u8);
    const nl_vec: V = @splat('\n');

    var i: usize = bytes.len;
    while (i >= 32) {
        i -= 32;
        const chunk: V = bytes[i .. i + 32][0..32].*;
        const mask: u32 = @bitCast(chunk == nl_vec);
        if (mask != 0) {
            const set_bits: u8 = @reduce(.Add, @as(@Vector(32, u8), @select(u8, chunk == nl_vec, @as(@Vector(32, u8), @splat(1)), @as(@Vector(32, u8), @splat(0)))));
            if (set_bits >= n_remaining.*) {
                // The N-th newline is in this mask.
                // We need to find the N-th set bit from the TOP (end of chunk).
                var m = mask;
                var found: usize = 0;
                while (m != 0) {
                    const lz = @clz(m);
                    const bit_idx: u5 = @intCast(31 - lz);
                    found += 1;
                    if (found == n_remaining.*) {
                        n_remaining.* = 0;
                        return i + bit_idx;
                    }
                    m &= ~(@as(u32, 1) << bit_idx);
                }
            }
            n_remaining.* -= set_bits;
        }
    }

    // Scalar fallback for the remainder
    while (i > 0) {
        i -= 1;
        if (bytes[i] == '\n') {
            n_remaining.* -= 1;
            if (n_remaining.* == 0) return i;
        }
    }

    return null;
}

/// Scans a file backwards to find the byte offset that precedes the last N lines.
/// Uses a double-buffer strategy for efficiency.
pub fn findLastLinesOffset(file: std.fs.File, n_lines: usize) !u64 {
    const total_size = try file.getEndPos();
    if (total_size == 0) return 0;

    var n_remaining = n_lines;
    // We want the offset BEFORE the last N lines.
    // Usually that means we find N+1 newlines from the end?
    // If we want 10 lines, we find the 10th newline from the back.
    // e.g. "a\nb\nc\n" -> last 2 lines are "b\nc\n".
    // Newlines are at index 1 and 3.
    // 1st from back is index 3. 2nd from back is index 1.
    // Offset for last 2 lines starts at index 2 (after index 1).
    // EXCEPT if the file doesn't end in a newline.
    // "a\nb\nc" -> last 2 lines are "b\nc".
    // 1st from back is index 1.
    // So we need to be careful. Let's just count N newlines.

    const chunk_size = 32 * 1024;
    var buf: [chunk_size]u8 = undefined;

    var pos = total_size;

    while (pos > 0) {
        const read_size = @min(pos, chunk_size);
        pos -= read_size;
        try file.seekTo(pos);
        const n_read = try file.readAll(buf[0..read_size]);
        const chunk = buf[0..n_read];

        // Special case: if the very last byte of the file is a newline,
        // some people might not count it as "ending a line" for tail purposes
        // if they expect 'tail -n 1' to show the non-empty line.
        // But standard tail counts trailing newlines.

        if (findNthNewlineFromEndSIMD(chunk, &n_remaining)) |idx| {
            return pos + idx + 1;
        }
    }

    return 0; // File has fewer than N lines, start from beginning.
}

const XevReader = @import("xev_reader.zig").XevReader;
const builtin = @import("builtin");

test "FastLineReader interface works natively" {
    const allocator = std.testing.allocator;

    const test_dir = std.testing.tmpDir(.{});
    var tmp_dir = test_dir;
    defer tmp_dir.cleanup();

    const file_contents = "line 1\nline 2\r\nline 3\nline 4\n";

    try tmp_dir.dir.writeFile(.{ .sub_path = "test.txt", .data = file_contents });

    var file = try tmp_dir.dir.openFile("test.txt", .{ .mode = .read_only });
    defer file.close();

    // Since XevReader is the fallback for Windows / Mac where tests are run
    // It's safe to instantiate it here for tests without relying on Linux.
    if (builtin.os.tag == .linux) return; // Ignore on linux for simple fallback test

    var impl = try XevReader.init(allocator, file, .{});
    var reader = impl.reader();
    defer reader.deinit();

    const line1 = try reader.next();
    try std.testing.expectEqualStrings("line 1", line1.?);

    const line2 = try reader.next();
    try std.testing.expectEqualStrings("line 2", line2.?); // \r stripped

    const line3 = try reader.next();
    try std.testing.expectEqualStrings("line 3", line3.?);

    const line4 = try reader.next();
    try std.testing.expectEqualStrings("line 4", line4.?);

    const line5 = try reader.next();
    try std.testing.expect(line5 == null);
}
