const std = @import("std");

pub const LogEntry = struct {
    parsed: std.StringHashMap([]const u8),
    raw_line: []const u8,
    timestamp: ?i64 = null, // Cache for formatting convenience

    pub fn deinit(self: *LogEntry, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.parsed.deinit();
    }
};

const scanTopLevelJson = @import("json_scanner.zig").scanTopLevelJson;
pub fn parseLine(allocator: std.mem.Allocator, line: []const u8, ts_key: []const u8) !?LogEntry {
    const json_start = std.mem.indexOfScalar(u8, line, '{') orelse return null;
    const json_text = std.mem.trim(u8, line[json_start..], " \r\t");

    const parsed_opt = try scanTopLevelJson(allocator, json_text);
    if (parsed_opt == null) return null;
    var parsed = parsed_opt.?;

    var entry = LogEntry{
        .parsed = parsed,
        .raw_line = line,
    };

    if (parsed.get(ts_key)) |ts_val| {
        entry.timestamp = parseTimestamp(ts_val);
    }

    return entry;
}

pub fn parseTimestamp(val_str: []const u8) ?i64 {
    // Strip quotes if it was a string
    const str = if (val_str.len >= 2 and val_str[0] == '"') val_str[1 .. val_str.len - 1] else val_str;
    var ts: i64 = 0;
    if (std.fmt.parseInt(i64, str, 10)) |num| {
        ts = num;
    } else |_| {
        if (std.fmt.parseFloat(f64, str)) |fnum| {
            ts = @intFromFloat(fnum);
        } else |_| {
            return null;
        }
    }

    if (ts != 0 and @abs(ts) < 10_000_000_000) {
        ts *= 1000;
    }
    return ts;
}

test "Parser.parseLine with shared samples" {
    const allocator = std.testing.allocator;
    const fs = std.fs.cwd();

    const file = try fs.openFile("test/parser_samples.json", .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    const Sample = struct {
        name: []const u8,
        line: []const u8,
        expected: std.json.Value,
    };

    const parsed_json = try std.json.parseFromSlice([]Sample, allocator, content, .{ .ignore_unknown_fields = true });
    defer parsed_json.deinit();

    for (parsed_json.value) |sample| {
        const entry_opt = try parseLine(allocator, sample.line, "ts");
        if (entry_opt == null) {
            std.debug.print("Failed to parse sample: {s}\n", .{sample.name});
            try std.testing.expect(false);
        }
        var entry = entry_opt.?;
        defer entry.deinit(allocator);

        const expected_obj = sample.expected.object;
        var it = expected_obj.iterator();
        while (it.next()) |kv| {
            const key = kv.key_ptr.*;
            const expected_val = kv.value_ptr.string;
            const actual_val = entry.parsed.get(key) orelse {
                std.debug.print("Key '{s}' not found in sample: {s}\n", .{ key, sample.name });
                return error.KeyNotFound;
            };
            try std.testing.expectEqualStrings(expected_val, actual_val);
        }
    }
}
