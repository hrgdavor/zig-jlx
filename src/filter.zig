const std = @import("std");

const mvzr = @import("mvzr");

pub const FilterType = enum {
    global_literal,
    global_regex,
    key_literal,
    key_regex,
};

/// A filter that supports literals, regex, and key-specific matching.
pub const Filter = struct {
    filter_type: FilterType,
    key: ?[]const u8 = null,
    text: ?[]const u8 = null,
    re: ?mvzr.Regex = null,

    pub fn parse(allocator: std.mem.Allocator, input: []const u8) !Filter {
        var is_re = false;
        var key_part: ?[]const u8 = null;
        var filter_part: []const u8 = input;

        // Check for 'key:value'
        if (std.mem.indexOf(u8, filter_part, ":")) |colon_idx| {
            const possible_key = filter_part[0..colon_idx];
            const possible_val = filter_part[colon_idx + 1 ..];

            if (std.mem.eql(u8, possible_key, "re")) {
                is_re = true;
                filter_part = possible_val;
            } else {
                key_part = possible_key;
                filter_part = possible_val;
                if (std.mem.startsWith(u8, filter_part, "re:")) {
                    is_re = true;
                    filter_part = filter_part[3..];
                }
            }
        }

        // Check for ~ prefix
        if (!is_re and filter_part.len > 0 and filter_part[0] == '~') {
            is_re = true;
            filter_part = filter_part[1..];
        }

        const ftype: FilterType = if (key_part) |_| (if (is_re) .key_regex else .key_literal) else (if (is_re) .global_regex else .global_literal);

        var f = Filter{
            .filter_type = ftype,
        };

        if (key_part) |k| {
            f.key = try allocator.dupe(u8, k);
        }

        if (is_re) {
            f.re = mvzr.compile(filter_part);
            if (f.re == null) {
                return error.InvalidRegex;
            }
        } else {
            f.text = try allocator.dupe(u8, filter_part);
        }

        return f;
    }

    pub fn deinit(self: *Filter, allocator: std.mem.Allocator) void {
        if (self.key) |k| allocator.free(k);
        if (self.text) |t| allocator.free(t);
        // mvzr.Regex uses no allocation so doesn't need deinit.
    }

    /// Match Phase 1: fast global raw string check
    pub fn matchesRaw(self: *const Filter, line: []const u8) !bool {
        return switch (self.filter_type) {
            .global_literal => std.mem.indexOf(u8, line, self.text.?) != null,
            .global_regex => {
                var self_mut = @constCast(self);
                return self_mut.re.?.isMatch(line);
            },
            else => true, // Ignore key filters in raw pass
        };
    }

    /// Match Phase 2: key-specific parsed JSON check
    pub fn matchesParsed(self: *const Filter, parsed: *const std.StringHashMap([]const u8)) !bool {
        return switch (self.filter_type) {
            .global_literal, .global_regex => true, // Already handled in phase 1 conceptually
            .key_literal, .key_regex => {
                if (parsed.get(self.key.?)) |val| {
                    const val_str = if (val.len >= 2 and val[0] == '"') val[1 .. val.len - 1] else val;
                    if (self.filter_type == .key_literal) {
                        return std.mem.indexOf(u8, val_str, self.text.?) != null;
                    } else {
                        var self_mut = @constCast(self);
                        return self_mut.re.?.isMatch(val_str);
                    }
                }
                return false;
            },
        };
    }
};

/// Phase 1: Check Global Excludes
pub fn passesRawExcludes(line: []const u8, exclude: []const Filter) !bool {
    for (exclude) |f| {
        if (f.filter_type == .global_literal or f.filter_type == .global_regex) {
            if (try f.matchesRaw(line)) return false;
        }
    }
    return true;
}

/// Phase 1: Check Global Includes (only if no key-includes exist)
pub fn passesRawIncludes(line: []const u8, include: []const Filter) !bool {
    var has_global_include = false;
    var has_key_include = false;
    for (include) |f| {
        if (f.filter_type == .global_literal or f.filter_type == .global_regex) {
            has_global_include = true;
        } else {
            has_key_include = true;
        }
    }

    if (has_key_include) return true; // We must parse JSON to determine if it passes
    if (!has_global_include) return true; // No includes, so everything passes

    for (include) |f| {
        if (f.filter_type == .global_literal or f.filter_type == .global_regex) {
            if (try f.matchesRaw(line)) return true;
        }
    }
    return false; // None matched
}

/// Phase 2: Check Parsed Excludes and evaluate final Include status
pub fn passesParsed(line: []const u8, parsed: *const std.StringHashMap([]const u8), include: []const Filter, exclude: []const Filter) !bool {
    // 1. Check Key-specific Excludes
    for (exclude) |f| {
        if (f.filter_type == .key_literal or f.filter_type == .key_regex) {
            if (try f.matchesParsed(parsed)) return false;
        }
    }

    if (include.len == 0) return true;

    // 2. Check Includes (at least one must match)
    for (include) |f| {
        switch (f.filter_type) {
            .global_literal, .global_regex => {
                if (try f.matchesRaw(line)) return true;
            },
            .key_literal, .key_regex => {
                if (try f.matchesParsed(parsed)) return true;
            },
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// Range filtering
// ---------------------------------------------------------------------------

/// Time-of-day component used in time_only range bounds.
pub const TimeOfDay = struct { hour: u8, minute: u8, second: u8 };

/// One bound of a date/time range.  Two subtypes:
///   time_only  — user gave only HH:MM[:SS]; matched against time-of-day in local time.
///   utc_secs   — user gave YYYY-MM-DD HH:MM[:SS]; stored as UTC unix seconds.
pub const TimeBound = union(enum) {
    time_only: TimeOfDay,
    utc_secs: i64,
};

/// A from..to range filter (either bound may be null = open).
/// Created once before processing starts; the zone offset is baked in.
pub const RangeFilter = struct {
    from: ?TimeBound = null,
    to: ?TimeBound = null,
    zone_offset_secs: i64 = 0,

    /// Parse "from..to", "from..", or "..to".
    /// zone_offset_secs is the user's local zone in seconds east of UTC.
    pub fn parse(text: []const u8, zone_offset_secs: i64) !RangeFilter {
        const sep = std.mem.indexOf(u8, text, "..") orelse return error.InvalidRangeSyntax;
        const from_str = std.mem.trim(u8, text[0..sep], " ");
        const to_str = std.mem.trim(u8, text[sep + 2 ..], " ");
        return .{
            .from = if (from_str.len > 0) try parseBound(from_str, zone_offset_secs) else null,
            .to = if (to_str.len > 0) try parseBound(to_str, zone_offset_secs) else null,
            .zone_offset_secs = zone_offset_secs,
        };
    }

    /// Returns true when the given UTC unix timestamp (seconds) falls in the range.
    pub fn matches(self: RangeFilter, ts_secs: i64) bool {
        if (self.from) |b| if (!checkBound(b, ts_secs, self.zone_offset_secs, .from)) return false;
        if (self.to) |b| if (!checkBound(b, ts_secs, self.zone_offset_secs, .to)) return false;
        return true;
    }

    // -- private helpers ----------------------------------------------------

    fn parseBound(text: []const u8, zone_offset_secs: i64) !TimeBound {
        // If char[4] == '-' we have a date component (YYYY-…)
        if (text.len >= 8 and text[4] == '-') {
            return .{ .utc_secs = try parseDatetime(text, zone_offset_secs) };
        }
        return .{ .time_only = try parseTimeOnly(text) };
    }

    fn parseTimeOnly(text: []const u8) !TimeOfDay {
        var it = std.mem.splitScalar(u8, text, ':');
        const h = try std.fmt.parseInt(u8, it.next() orelse return error.InvalidTime, 10);
        const m = try std.fmt.parseInt(u8, it.next() orelse return error.InvalidTime, 10);
        const s: u8 = if (it.next()) |sv| try std.fmt.parseInt(u8, sv, 10) else 0;
        return .{ .hour = h, .minute = m, .second = s };
    }

    fn parseDatetime(text: []const u8, zone_offset_secs: i64) !i64 {
        // Accepts: YYYY-MM-DD HH:MM[:SS]  or  YYYY-MM-DDTHH:MM[:SS]
        const sep: usize = for (text, 0..) |c, i| {
            if (c == ' ' or c == 'T') break i;
        } else return error.InvalidDatetime;

        const date_part = text[0..sep];
        const time_part = text[sep + 1 ..];

        var di = std.mem.splitScalar(u8, date_part, '-');
        const year = try std.fmt.parseInt(u16, di.next() orelse return error.InvalidDate, 10);
        const month = try std.fmt.parseInt(u8, di.next() orelse return error.InvalidDate, 10);
        const day = try std.fmt.parseInt(u8, di.next() orelse return error.InvalidDate, 10);

        var ti = std.mem.splitScalar(u8, time_part, ':');
        const hour = try std.fmt.parseInt(u8, ti.next() orelse return error.InvalidTime, 10);
        const minute = try std.fmt.parseInt(u8, ti.next() orelse return error.InvalidTime, 10);
        const second: u8 = if (ti.next()) |sv| try std.fmt.parseInt(u8, sv, 10) else 0;

        const days = civilDays(year, month, day);
        const local_secs: i64 = days * 86400 +
            @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second;
        // Subtract zone offset to convert local → UTC
        return local_secs - zone_offset_secs;
    }

    /// Days since Unix epoch for a civil (proleptic Gregorian) date.
    /// Algorithm: http://howardhinnant.github.io/date_algorithms.html
    fn civilDays(year: u16, month: u8, day: u8) i64 {
        var y: i64 = year;
        const m: i64 = month;
        const d: i64 = day;
        if (m <= 2) y -= 1;
        const era = @divFloor(y, 400);
        const yoe = y - era * 400; // [0, 399]
        const doy = @divFloor(153 * (m + (if (m > 2) @as(i64, -3) else 9)) + 2, 5) + d - 1;
        const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
        return era * 146097 + doe - 719468;
    }

    const BoundSide = enum { from, to };

    fn checkBound(bound: TimeBound, ts_secs: i64, zone_offset_secs: i64, side: BoundSide) bool {
        switch (bound) {
            .utc_secs => |b| return if (side == .from) ts_secs >= b else ts_secs <= b,
            .time_only => |t| {
                // Shift log timestamp to local time, then take time-of-day
                const local = ts_secs + zone_offset_secs;
                const day_sec = @mod(local, 86400);
                const bound_sec: i64 = @as(i64, t.hour) * 3600 + @as(i64, t.minute) * 60 + t.second;
                return if (side == .from) day_sec >= bound_sec else day_sec <= bound_sec;
            },
        }
    }
};

// ---------------------------------------------------------------------------
// Timezone offset parsing
// ---------------------------------------------------------------------------

/// Parse a zone string into seconds east of UTC.
/// Accepts: "+HH:MM", "-HH:MM", "+HH", "-HH", "UTC", "Z", or null → 0 (UTC).
pub fn parseZoneOffset(zone: ?[]const u8) !i64 {
    const z = zone orelse return 0;
    const s = std.mem.trim(u8, z, " ");
    if (s.len == 0 or std.mem.eql(u8, s, "UTC") or std.mem.eql(u8, s, "Z")) return 0;
    if (s[0] != '+' and s[0] != '-') return error.InvalidZone;
    const sign: i64 = if (s[0] == '+') 1 else -1;
    var it = std.mem.splitScalar(u8, s[1..], ':');
    const h = try std.fmt.parseInt(i64, it.next() orelse return error.InvalidZone, 10);
    const m: i64 = if (it.next()) |mv| try std.fmt.parseInt(i64, mv, 10) else 0;
    return sign * (h * 3600 + m * 60);
}
