const std = @import("std");

pub fn skipWhitespace(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c != ' ' and c != '\t' and c != '\r' and c != '\n') break;
    }
    return i;
}

/// Finds the end index of a JSON string literal starting at `start`.
/// `start` must point to the opening quote `"` character.
/// Returns the index immediately following the closing quote.
pub fn scanStringEnd(text: []const u8, start: usize) usize {
    var i = start + 1;
    while (i < text.len) {
        if (text[i] == '"') {
            return i + 1;
        } else if (text[i] == '\\') {
            i += 2;
        } else {
            i += 1;
        }
    }
    return i;
}

/// Finds the end index of a JSON object or array starting at `start`.
/// `start` must point to the opening `{` or `[` character.
/// Returns the index immediately following the closing `}` or `]`.
pub fn scanObjectOrArrayEnd(text: []const u8, start: usize) usize {
    const open_char = text[start];
    const close_char: u8 = if (open_char == '{') '}' else ']';
    var depth: usize = 1;
    var i = start + 1;

    while (i < text.len) {
        const c = text[i];
        if (c == '"') {
            // Instantly delegate string skipping to our optimized string bounds checker
            i = scanStringEnd(text, i);
        } else if (c == open_char) {
            depth += 1;
            i += 1;
        } else if (c == close_char) {
            depth -= 1;
            if (depth == 0) {
                return i + 1;
            }
            i += 1;
        } else {
            i += 1;
        }
    }
    return i;
}

/// Finds the end index of a JSON primitive (number, boolean, null) starting at `start`.
/// Returns the index of the first character that delimits the primitive.
pub fn scanPrimitiveEnd(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len) {
        const c = text[i];
        if (c == ',' or c == '}' or c == ' ' or c == '\r' or c == '\n' or c == '\t') {
            return i;
        }
        i += 1;
    }
    return i;
}

/// A zero-allocation JSON scanner that identifies top-level key-value pairs
/// in a JSON object without building a full AST or performing deep parsing.
pub fn scanTopLevelJson(allocator: std.mem.Allocator, json_text: []const u8) !?std.StringHashMap([]const u8) {
    if (json_text.len < 2 or json_text[0] != '{') return null;

    var parsed = std.StringHashMap([]const u8).init(allocator);
    errdefer parsed.deinit();

    var i: usize = 1;
    while (i < json_text.len) {
        i = skipWhitespace(json_text, i);
        if (i >= json_text.len or json_text[i] == '}') break;

        if (json_text[i] != '"') return null; // malformed json key

        const key_raw_start = i;
        const key_raw_end = scanStringEnd(json_text, key_raw_start);
        if (key_raw_end <= key_raw_start + 1 or json_text[key_raw_end - 1] != '"') return null; // unclosed key

        const key = json_text[key_raw_start + 1 .. key_raw_end - 1]; // strip quotes
        i = key_raw_end;

        i = skipWhitespace(json_text, i);
        if (i >= json_text.len or json_text[i] != ':') return null;
        i += 1;

        i = skipWhitespace(json_text, i);
        if (i >= json_text.len) return null;

        const val_start = i;
        var val_end: usize = i;

        if (json_text[i] == '"') { // string
            val_end = scanStringEnd(json_text, val_start);
        } else if (json_text[i] == '{' or json_text[i] == '[') { // object or array
            val_end = scanObjectOrArrayEnd(json_text, val_start);
        } else { // primitive (boolean, number, null)
            val_end = scanPrimitiveEnd(json_text, val_start);
        }
        if (val_end == val_start) return null;
        i = val_end;

        try parsed.put(key, json_text[val_start..val_end]);

        i = skipWhitespace(json_text, i);
        if (i < json_text.len and json_text[i] == ',') i += 1;
    }

    return parsed;
}

test "Scanner.scanTopLevelJson basic object parsing" {
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

test "Scanner.scanTopLevelJson correctly bounds strings with escaped quotes" {
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

test "Scanner.scanTopLevelJson correctly handles escaped json payload inside string" {
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
