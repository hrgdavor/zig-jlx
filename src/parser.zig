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

fn skipWhitespace(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c != ' ' and c != '\t' and c != '\r' and c != '\n') break;
    }
    return i;
}

pub fn scanTopLevelJson(allocator: std.mem.Allocator, json_text: []const u8) !?std.StringHashMap([]const u8) {
    if (json_text.len < 2 or json_text[0] != '{') return null;

    var parsed = std.StringHashMap([]const u8).init(allocator);
    errdefer parsed.deinit();

    var i: usize = 1;
    while (i < json_text.len) {
        i = skipWhitespace(json_text, i);
        if (i >= json_text.len or json_text[i] == '}') break;

        if (json_text[i] != '"') return null; // malformed json key
        i += 1;

        const key_start = i;
        var key_end: usize = 0;
        while (i < json_text.len) {
            if (json_text[i] == '"') {
                key_end = i;
                i += 1;
                break;
            } else if (json_text[i] == '\\') {
                i += 2;
            } else {
                i += 1;
            }
        }
        if (key_end == 0) return null; // unclosed key
        const key = json_text[key_start..key_end];

        i = skipWhitespace(json_text, i);
        if (i >= json_text.len or json_text[i] != ':') return null;
        i += 1;

        i = skipWhitespace(json_text, i);
        if (i >= json_text.len) return null;

        const val_start = i;
        var val_end: usize = i;

        if (json_text[i] == '"') { // string
            i += 1;
            while (i < json_text.len) {
                if (json_text[i] == '"') {
                    i += 1;
                    val_end = i;
                    break;
                } else if (json_text[i] == '\\') {
                    i += 2;
                } else {
                    i += 1;
                }
            }
        } else if (json_text[i] == '{' or json_text[i] == '[') { // object or array
            const open_char = json_text[i];
            const close_char: u8 = if (open_char == '{') '}' else ']';
            var depth: usize = 1;
            i += 1;
            var in_string = false;
            while (i < json_text.len) {
                const c = json_text[i];
                if (in_string) {
                    if (c == '"') {
                        in_string = false;
                    } else if (c == '\\') {
                        i += 1;
                    }
                } else {
                    if (c == '"') {
                        in_string = true;
                    } else if (c == open_char) {
                        depth += 1;
                    } else if (c == close_char) {
                        depth -= 1;
                        if (depth == 0) {
                            i += 1;
                            val_end = i;
                            break;
                        }
                    }
                }
                i += 1;
            }
        } else { // primitive (boolean, number, null)
            while (i < json_text.len) {
                const c = json_text[i];
                if (c == ',' or c == '}' or c == ' ' or c == '\r' or c == '\n' or c == '\t') {
                    val_end = i;
                    break;
                }
                i += 1;
            }
        }
        if (val_end == val_start) return null;

        try parsed.put(key, json_text[val_start..val_end]);

        i = skipWhitespace(json_text, i);
        if (i < json_text.len and json_text[i] == ',') i += 1;
    }

    return parsed;
}

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

fn parseTimestamp(val_str: []const u8) ?i64 {
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

test "Parser.scanTopLevelJson basic object parsing" {
    const allocator = std.testing.allocator;
    const json_str =
        \\{ "level": "INFO", "status": 200, "msg": "Request OK", "nested": { "time": 123 }, "arr": [1, 2, 3] }
    ;

    const parsed_opt = try scanTopLevelJson(allocator, json_str);
    try std.testing.expect(parsed_opt != null);
    var parsed = parsed_opt.?;
    defer parsed.deinit();

    try std.testing.expectEqualStrings("\"INFO\"", parsed.get("level").?);
    try std.testing.expectEqualStrings("200", parsed.get("status").?);
    try std.testing.expectEqualStrings("\"Request OK\"", parsed.get("msg").?);
    try std.testing.expectEqualStrings("{ \"time\": 123 }", parsed.get("nested").?);
    try std.testing.expectEqualStrings("[1, 2, 3]", parsed.get("arr").?);
}

test "Parser.scanTopLevelJson correctly bounds strings with escaped quotes" {
    const allocator = std.testing.allocator;
    const json_str =
        \\{ "msg": "A \"nested\" string" }
    ;

    const parsed_opt = try scanTopLevelJson(allocator, json_str);
    try std.testing.expect(parsed_opt != null);
    var parsed = parsed_opt.?;
    defer parsed.deinit();

    try std.testing.expectEqualStrings("\"A \\\"nested\\\" string\"", parsed.get("msg").?);
}

test "Parser.scanTopLevelJson correctly handles escaped json payload inside string" {
    const allocator = std.testing.allocator;
    const json_str =
        \\{ "payload": "{\"inner\": 123, \"complex\": [1,2]}", "other": "ok" }
    ;

    const parsed_opt = try scanTopLevelJson(allocator, json_str);
    try std.testing.expect(parsed_opt != null);
    var parsed = parsed_opt.?;
    defer parsed.deinit();

    try std.testing.expectEqualStrings("\"{\\\"inner\\\": 123, \\\"complex\\\": [1,2]}\"", parsed.get("payload").?);
    try std.testing.expectEqualStrings("\"ok\"", parsed.get("other").?);
}
