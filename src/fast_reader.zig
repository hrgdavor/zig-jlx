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
    const V = @Vector(32, u8);
    const nl_vec: V = @splat('\n');

    var i: usize = bytes.len;
    while (i >= 32) {
        i -= 32;
        const chunk: V = bytes[i .. i + 32][0..32].*;
        const mask: u32 = @bitCast(chunk == nl_vec);
        if (mask != 0) {
            // Count leading zeros will give us the index from the MSB.
            // In little-endian, MSB corresponds to higher index.
            const lz = @clz(mask);
            return i + (31 - lz);
        }
    }

    // Scalar fallback for the remainder
    while (i > 0) {
        i -= 1;
        if (bytes[i] == '\n') return i;
    }

    return null;
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
