const std = @import("std");

/// Unescape a JSON string value ("alice\n" → alice<newline>).
fn unescapeJsonString(allocator: std.mem.Allocator, val_slice: []const u8) ![]const u8 {
    if (val_slice.len >= 2 and val_slice[0] == '"' and val_slice[val_slice.len - 1] == '"') {
        const inner = val_slice[1 .. val_slice.len - 1];
        // Fast path
        if (std.mem.indexOfScalar(u8, inner, '\\') == null) {
            return try allocator.dupe(u8, inner);
        }
        // Unescape logic
        var buf = try allocator.alloc(u8, inner.len);
        var out: usize = 0;
        var i: usize = 0;
        while (i < inner.len) {
            if (inner[i] == '\\' and i + 1 < inner.len) {
                i += 1;
                switch (inner[i]) {
                    'n' => {
                        buf[out] = '\n';
                        out += 1;
                    },
                    't' => {
                        buf[out] = '\t';
                        out += 1;
                    },
                    'r' => {
                        buf[out] = '\r';
                        out += 1;
                    },
                    '\\' => {
                        buf[out] = '\\';
                        out += 1;
                    },
                    '"' => {
                        buf[out] = '"';
                        out += 1;
                    },
                    '/' => {
                        buf[out] = '/';
                        out += 1;
                    },
                    'b' => {
                        buf[out] = 0x08;
                        out += 1;
                    },
                    'f' => {
                        buf[out] = 0x0C;
                        out += 1;
                    },
                    'u' => {
                        buf[out] = '\\';
                        out += 1;
                        buf[out] = 'u';
                        out += 1;
                        const remaining = @min(4, inner.len - i - 1);
                        @memcpy(buf[out .. out + remaining], inner[i + 1 .. i + 1 + remaining]);
                        out += remaining;
                        i += remaining;
                    },
                    else => {
                        buf[out] = '\\';
                        out += 1;
                        buf[out] = inner[i];
                        out += 1;
                    },
                }
            } else {
                buf[out] = inner[i];
                out += 1;
            }
            i += 1;
        }
        return buf[0..out];
    }
    return try allocator.dupe(u8, val_slice);
}

/// Apply a spec modifier to a bare (unquoted) value string.
/// Returned slice is either a sub-slice of `val` or arena-allocated.
pub fn formatValue(arena: std.mem.Allocator, val_raw: []const u8, spec: ?[]const u8) ![]const u8 {
    const val = try unescapeJsonString(arena, val_raw);
    const s = spec orelse return val;
    if (s.len == 0) return val;

    if (std.mem.eql(u8, s, "upper")) {
        const buf = try arena.alloc(u8, val.len);
        for (val, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
        return buf;
    }
    if (std.mem.eql(u8, s, "lower")) {
        const buf = try arena.alloc(u8, val.len);
        for (val, 0..) |c, i| buf[i] = std.ascii.toLower(c);
        return buf;
    }
    if (std.mem.eql(u8, s, "hex") or std.mem.eql(u8, s, "HEX")) {
        const num = std.fmt.parseInt(i64, val, 10) catch return val;
        if (std.mem.eql(u8, s, "hex")) {
            return std.fmt.allocPrint(arena, "{x}", .{num});
        } else {
            return std.fmt.allocPrint(arena, "{X}", .{num});
        }
    }
    if (std.mem.eql(u8, s, "2") or std.mem.eql(u8, s, "4")) {
        const decimals = std.fmt.parseInt(u8, s, 10) catch return val;
        const num = std.fmt.parseFloat(f64, val) catch return val;
        return switch (decimals) {
            2 => std.fmt.allocPrint(arena, "{d:.2}", .{num}),
            4 => std.fmt.allocPrint(arena, "{d:.4}", .{num}),
            else => val,
        };
    }
    // Integer width: right-pad with spaces
    const width = std.fmt.parseInt(usize, s, 10) catch return val;
    if (val.len >= width) return val;
    const buf = try arena.alloc(u8, width);
    @memcpy(buf[0..val.len], val);
    @memset(buf[val.len..], ' ');
    return buf;
}

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
/// matching the defined lookup table (Map). Supports `{key:spec}` — spec is passed to formatValue.
pub fn expandGeneric(arena: std.mem.Allocator, message: []const u8, parsed: *const std.StringHashMap([]const u8), open_seq: []const u8, close_seq: []const u8) ![]const u8 {
    var res = try arena.dupe(u8, message);

    var start: usize = 0;
    while (std.mem.indexOfPos(u8, res, start, open_seq)) |open_idx| {
        if (std.mem.indexOfPos(u8, res, open_idx + open_seq.len, close_seq)) |close_idx| {
            const raw_key = res[open_idx + open_seq.len .. close_idx];
            var key = raw_key;
            var spec: ?[]const u8 = null;
            if (std.mem.indexOfScalar(u8, raw_key, ':')) |colon_idx| {
                key = raw_key[0..colon_idx];
                spec = raw_key[colon_idx + 1 ..];
            }

            if (parsed.get(key)) |val| {
                const formatted = try formatValue(arena, val, spec);
                const needle = try arena.dupe(u8, res[open_idx .. close_idx + close_seq.len]);
                const new_res = try replace(arena, res, needle, formatted);
                res = new_res;
                start = open_idx + formatted.len;
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "template_engine shared samples" {
    const allocator = std.testing.allocator;

    const file = try std.fs.cwd().openFile("test/template_samples.json", .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 512 * 1024);
    defer allocator.free(content);

    const Sample = struct {
        name: []const u8,
        expander: []const u8,
        template: []const u8,
        vars: std.json.Value,
        expected: []const u8,
    };

    const parsed_json = try std.json.parseFromSlice([]Sample, allocator, content, .{ .ignore_unknown_fields = true });
    defer parsed_json.deinit();

    var arena_inst = std.heap.ArenaAllocator.init(allocator);
    defer arena_inst.deinit();

    for (parsed_json.value) |sample| {
        _ = arena_inst.reset(.retain_capacity);
        const arena = arena_inst.allocator();

        // Build StringHashMap from sample.vars (a JSON object).
        // Values are stored the same way the log parser stores them:
        // - strings: surrounded by double-quotes  e.g. "\"alice\""
        // - numbers / booleans: raw text           e.g. "3.14"
        // The sample JSON should already encode string vars with surrounding quotes
        // when it wants stripQuotes to strip them (e.g. `"name": "\"alice\""` → stored as `"alice"`).
        // Plain string values like `"name": "alice"` are stored as `alice` (no extra quotes).
        var vars = std.StringHashMap([]const u8).init(arena);
        if (sample.vars == .object) {
            var it = sample.vars.object.iterator();
            while (it.next()) |kv| {
                const v: []const u8 = switch (kv.value_ptr.*) {
                    .string => |s| s, // already unquoted by JSON parser; use as-is
                    .integer => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
                    .float => |f| try std.fmt.allocPrint(arena, "{d}", .{f}),
                    else => continue,
                };
                try vars.put(kv.key_ptr.*, v);
            }
        }

        const result: []const u8 = if (std.mem.eql(u8, sample.expander, "curly"))
            try expandCurly(arena, sample.template, &vars)
        else if (std.mem.eql(u8, sample.expander, "js"))
            try expandJs(arena, sample.template, &vars)
        else if (std.mem.eql(u8, sample.expander, "double_curly"))
            try expandDoubleCurly(arena, sample.template, &vars)
        else if (std.mem.eql(u8, sample.expander, "brackets"))
            try expandBrackets(arena, sample.template, &vars)
        else if (std.mem.eql(u8, sample.expander, "ruby"))
            try expandRuby(arena, sample.template, &vars)
        else
            return error.UnknownExpander;

        std.testing.expectEqualStrings(sample.expected, result) catch |err| {
            std.debug.print("FAIL [{s}]: expected '{s}' got '{s}'\n", .{ sample.name, sample.expected, result });
            return err;
        };
    }
}
