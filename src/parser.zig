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
