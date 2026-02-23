const std = @import("std");

/// Replace occurrences of `needle` with `replacement` in a given payload string safely stringifying to an Arena allocator.
/// This acts as a foundation for string interpolation, freeing original slices transparently to pool memory.
pub fn replace(arena: std.mem.Allocator, payload: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    const changes = std.mem.count(u8, payload, needle);
    if (changes == 0) return try arena.dupe(u8, payload);
    const new_size = payload.len + changes * replacement.len - changes * needle.len;
    const new_buf = try arena.alloc(u8, new_size);
    _ = std.mem.replace(u8, payload, needle, replacement, new_buf);
    return new_buf;
}

/// A core string interpolator that maps tokens exactly formatted within `open_seq` and `close_seq`
/// matching the defined lookup table (Map).
pub fn expandGeneric(arena: std.mem.Allocator, message: []const u8, parsed: *const std.StringHashMap([]const u8), open_seq: []const u8, close_seq: []const u8) ![]const u8 {
    var res = try arena.dupe(u8, message);

    var start: usize = 0;
    while (std.mem.indexOfPos(u8, res, start, open_seq)) |open_idx| {
        if (std.mem.indexOfPos(u8, res, open_idx + open_seq.len, close_seq)) |close_idx| {
            // Found a token key instance. Support fallback specifiers via ":" delimiter
            const raw_key = res[open_idx + open_seq.len .. close_idx];
            var key = raw_key;
            if (std.mem.indexOfScalar(u8, raw_key, ':')) |colon_idx| {
                key = raw_key[0..colon_idx];
            }

            // Attempt substitution directly via Map
            if (parsed.get(key)) |val| {
                // Ignore nested formatting or timestamps for template logic, map natively
                const needle = try arena.dupe(u8, res[open_idx .. close_idx + close_seq.len]);
                const new_res = try replace(arena, res, needle, val);
                res = new_res;

                // Recalculate pointer indexes
                start = open_idx + val.len;
            } else {
                start = close_idx + close_seq.len;
            }
        } else {
            break;
        }
    }
    return res;
}

/// Popular string interpolators implemented seamlessly.
pub fn expandCurly(arena: std.mem.Allocator, message: []const u8, parsed: *const std.StringHashMap([]const u8)) ![]const u8 {
    return expandGeneric(arena, message, parsed, "{", "}");
}

pub fn expandJs(arena: std.mem.Allocator, message: []const u8, parsed: *const std.StringHashMap([]const u8)) ![]const u8 {
    return expandGeneric(arena, message, parsed, "${", "}");
}

pub fn expandBrackets(arena: std.mem.Allocator, message: []const u8, parsed: *const std.StringHashMap([]const u8)) ![]const u8 {
    return expandGeneric(arena, message, parsed, "[", "]");
}

pub fn expandDoubleCurly(arena: std.mem.Allocator, message: []const u8, parsed: *const std.StringHashMap([]const u8)) ![]const u8 {
    return expandGeneric(arena, message, parsed, "{{", "}}");
}

pub fn expandRuby(arena: std.mem.Allocator, message: []const u8, parsed: *const std.StringHashMap([]const u8)) ![]const u8 {
    return expandGeneric(arena, message, parsed, "#{", "}");
}
