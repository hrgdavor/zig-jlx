const std = @import("std");
const builtin = @import("builtin");

const w = std.os.windows;
const TZI = if (builtin.os.tag == .windows) extern struct {
    Bias: i32,
    StandardName: [32]u16,
    StandardDate: [8]u16,
    StandardBias: i32,
    DaylightName: [32]u16,
    DaylightDate: [8]u16,
    DaylightBias: i32,
} else struct {};

const kernel32 = if (builtin.os.tag == .windows) struct {
    pub extern "kernel32" fn GetTimeZoneInformation(lpTimeZoneInformation: *TZI) callconv(.c) u32;
} else struct {};

const Tm = extern struct {
    sec: i32,
    min: i32,
    hour: i32,
    mday: i32,
    mon: i32,
    year: i32,
    wday: i32,
    yday: i32,
    isdst: i32,
    gmtoff: i64 = 0,
    zone: ?[*]const u8 = null,
};

const posix = if (builtin.os.tag != .windows) struct {
    pub extern "c" fn time(?[*]i64) i64;
    pub extern "c" fn localtime_r(*const i64, *Tm) ?*Tm;
    pub extern "c" fn gmtime_r(*const i64, *Tm) ?*Tm;
    pub extern "c" fn mktime(*Tm) i64;
} else struct {};

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
    is_time_only: bool = false,
    base_date_secs: ?i64 = null,
    debug: bool = false,
    debug_printed: bool = false,

    /// Parse "from..to", "from..", or "..to".
    /// zone_offset_secs is the user's local zone in seconds east of UTC.
    pub fn parse(text: []const u8, zone_offset_secs: i64) !RangeFilter {
        var input = text;
        var debug = false;
        if (input.len > 0 and input[0] == '?') {
            debug = true;
            input = input[1..];
        }

        const sep = std.mem.indexOf(u8, input, "..") orelse return error.InvalidRangeSyntax;
        const from_str = std.mem.trim(u8, input[0..sep], " ");
        const to_str = std.mem.trim(u8, input[sep + 2 ..], " ");
        const from = if (from_str.len > 0) try parseBound(from_str, zone_offset_secs) else null;
        const to = if (to_str.len > 0) try parseBound(to_str, zone_offset_secs) else null;

        var is_time_only = true;
        if (from) |b| if (b == .utc_secs) {
            is_time_only = false;
        };
        if (to) |b| if (b == .utc_secs) {
            is_time_only = false;
        };

        return .{
            .from = from,
            .to = to,
            .zone_offset_secs = zone_offset_secs,
            .is_time_only = is_time_only,
            .debug = debug,
        };
    }

    /// Returns true when the given UTC unix timestamp (seconds) falls in the range.
    pub fn matches(self: *const RangeFilter, ts_secs: i64) bool {
        if (self.from) |b| if (!self.checkBound(b, ts_secs, .from)) return false;
        if (self.to) |b| if (!self.checkBound(b, ts_secs, .to)) return false;
        return true;
    }

    /// Set the base date for time-only ranges based on an absolute timestamp.
    pub fn initBaseDate(self: *RangeFilter, ts_secs: i64) void {
        const local = ts_secs + self.zone_offset_secs;
        const day_sec = @mod(local, 86400);
        self.base_date_secs = local - day_sec - self.zone_offset_secs;
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
        if (h > 23) return error.InvalidTimestamp;
        const m = try std.fmt.parseInt(u8, it.next() orelse return error.InvalidTime, 10);
        if (m > 59) return error.InvalidTimestamp;
        const s: u8 = if (it.next()) |sv| try std.fmt.parseInt(u8, sv, 10) else 0;
        if (s > 59) return error.InvalidTimestamp;
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

    fn checkBound(self: *const RangeFilter, bound: TimeBound, ts_secs: i64, side: BoundSide) bool {
        switch (bound) {
            .utc_secs => |b| return if (side == .from) ts_secs >= b else ts_secs <= b,
            .time_only => |t| {
                if (self.base_date_secs) |base| {
                    const bound_utc = base + @as(i64, t.hour) * 3600 + @as(i64, t.minute) * 60 + t.second;
                    return if (side == .from) ts_secs >= bound_utc else ts_secs <= bound_utc;
                } else {
                    // Shift log timestamp to local time, then take time-of-day
                    const local = ts_secs + self.zone_offset_secs;
                    const day_sec = @mod(local, 86400);
                    const bound_sec: i64 = @as(i64, t.hour) * 3600 + @as(i64, t.minute) * 60 + t.second;
                    return if (side == .from) day_sec >= bound_sec else day_sec <= bound_sec;
                }
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

/// Detect local timezone offset in seconds east of UTC.
pub fn getLocalZoneOffset() i64 {
    if (builtin.os.tag == .windows) {
        var tzi: TZI = undefined;
        const res = kernel32.GetTimeZoneInformation(&tzi);
        if (res == 0xFFFFFFFF) return 0;
        const bias: i32 = if (res == 2) tzi.Bias + tzi.DaylightBias else tzi.Bias + tzi.StandardBias;
        return @as(i64, -bias) * 60;
    } else if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        var t = posix.time(null);
        var tm: Tm = undefined;
        _ = posix.gmtime_r(&t, &tm);
        tm.isdst = -1; // Let mktime determine if DST applies to this UTC component treated as local
        const t_utc_as_local = posix.mktime(&tm);
        return t - t_utc_as_local;
    }
    return 0;
}

test "RangeFilter time-only resolution" {
    // Use 12:00..13:00 range
    var rf = try RangeFilter.parse("12:00..13:00", 0);
    try std.testing.expect(rf.is_time_only);
    try std.testing.expect(rf.base_date_secs == null);

    // First line at 2024-03-05 10:00:00 UTC (1709632800)
    const first_ts: i64 = 1709632800;
    rf.initBaseDate(first_ts);

    // Base date should be 2024-03-05 00:00:00 UTC (1709596800)
    try std.testing.expectEqual(@as(?i64, 1709596800), rf.base_date_secs);

    // 12:30:00 on the same day should match
    const same_day_match = 1709596800 + 12 * 3600 + 30 * 60;
    try std.testing.expect(rf.matches(same_day_match));

    // 12:30:00 on the NEXT day should NOT match (because it is locked to the first day)
    const next_day_no_match = same_day_match + 86400;
    try std.testing.expect(!rf.matches(next_day_no_match));
}

test "RangeFilter absolute datetime" {
    // 2024-03-05 12:00:00 to 2024-03-05 13:00:00 UTC
    // 1709640000 to 1709643600
    const rf = try RangeFilter.parse("2024-03-05 12:00:00..2024-03-05 13:00:00", 0);
    try std.testing.expect(!rf.is_time_only);

    try std.testing.expect(rf.matches(1709640000)); // Exact start
    try std.testing.expect(rf.matches(1709641800)); // Middle (12:30)
    try std.testing.expect(rf.matches(1709643600)); // Exact end
    try std.testing.expect(!rf.matches(1709639999)); // Just before
    try std.testing.expect(!rf.matches(1709643601)); // Just after
}

test "RangeFilter open-ended" {
    // 1. Open start: ..2024-03-05 12:00:00
    const rf_to = try RangeFilter.parse("..2024-03-05 12:00:00", 0);
    try std.testing.expect(rf_to.matches(0)); // Far past
    try std.testing.expect(rf_to.matches(1709640000)); // Exact end
    try std.testing.expect(!rf_to.matches(1709640001)); // Just after

    // 2. Open end: 2024-03-05 12:00:00..
    const rf_from = try RangeFilter.parse("2024-03-05 12:00:00..", 0);
    try std.testing.expect(!rf_from.matches(1709639999));
    try std.testing.expect(rf_from.matches(1709640000));
    try std.testing.expect(rf_from.matches(2000000000)); // Far future

    // 3. Time-only open end: 12:00..
    var rf_time = try RangeFilter.parse("12:00..", 0);
    rf_time.initBaseDate(1709632800); // March 5th
    try std.testing.expect(rf_time.matches(1709640000)); // 12:00 matches
    try std.testing.expect(rf_time.matches(1709643600)); // 13:00 matches
    try std.testing.expect(!rf_time.matches(1709639999)); // 11:59 fails

    // 4. Regression: jlx -r "?10:12:59..10:13:01"
    // First line: 2026-02-10 07:27:51 UTC (timestamp: 1770708471)
    // Range expected: 10:12:59..10:13:01 UTC
    var rf_bug = try RangeFilter.parse("10:12:59..10:13:01", 0);
    rf_bug.initBaseDate(1770708471);

    // Expecting:
    // midnight = 1770681600
    // start = 1770681600 + 10*3600 + 12*60 + 59 = 1770718379
    // end   = 1770681600 + 10*3600 + 13*60 + 1  = 1770718381

    try std.testing.expect(!rf_bug.matches(1770708471)); // 07:27 is before 10:12
    try std.testing.expect(rf_bug.matches(1770718379)); // 10:12:59 exact match
    try std.testing.expect(rf_bug.matches(1770718380)); // 10:13:00 in range
    try std.testing.expect(rf_bug.matches(1770718381)); // 10:13:01 exact match
    try std.testing.expect(!rf_bug.matches(1770718382)); // 10:13:02 out of range
}

test "RangeFilter timezone awareness" {
    // Range 12:00..13:00 in UTC+2 (7200s)
    // Local 12:00..13:00 is UTC 10:00..11:00
    // UTC 10:00 = 1709632800
    // UTC 11:00 = 1709636400
    const rf = try RangeFilter.parse("2024-03-05 12:00:00..2024-03-05 13:00:00", 7200);

    try std.testing.expect(rf.matches(1709632800)); // UTC 10:00
    try std.testing.expect(rf.matches(1709634600)); // UTC 10:30
    try std.testing.expect(rf.matches(1709636400)); // UTC 11:00
    try std.testing.expect(!rf.matches(1709640000)); // UTC 12:00 (which is local 14:00)
}

test "RangeFilter parse debug flag" {
    const rf = try RangeFilter.parse("?12:00..13:00", 0);
    try std.testing.expect(rf.debug);
    try std.testing.expect(rf.is_time_only);

    const rf2 = try RangeFilter.parse("12:00..13:00", 0);
    try std.testing.expect(!rf2.debug);
}

test "RangeFilter base date calculation logic" {
    // 1. UTC+1 (3600s)
    var rf1 = RangeFilter{ .zone_offset_secs = 3600 };
    // ts_secs = 1770708471 (2026-02-10 07:27:51 UTC, 08:27:51 local)
    rf1.initBaseDate(1770708471);
    // local midnight = 2026-02-10 00:00:00 local = 2026-02-09 23:00:00 UTC = 1770678000
    try std.testing.expectEqual(@as(i64, 1770678000), rf1.base_date_secs.?);

    // 2. UTC-5 (-18000s)
    var rf2 = RangeFilter{ .zone_offset_secs = -18000 };
    rf2.initBaseDate(1770708471); // Feb 10 07:27 UTC -> Feb 10 02:27 local
    // local midnight = 2026-02-10 00:00:00 local = 2026-02-10 05:00:00 UTC = 1770699600
    try std.testing.expectEqual(@as(i64, 1770699600), rf2.base_date_secs.?);
}

test "RangeFilter complex time-only ranges" {
    // 1. Range spanning midnight: 23:00..01:00
    // If base date is 2024-03-05 (midnight = 1709596800 UTC)
    // 23:00 = 1709596800 + 23*3600 = 1709679600
    // 01:00 = 1709596800 + 1*3600 = 1709600400 (Wait, 01:00 is technically "next day" if it follows 23:00)
    // Actually, our current implementation just adds seconds to midnight.
    // So 01:00 is indeed 1709600400 (BEFORE 23:00).
    // If start > end, it's an empty range in current logic unless we handle wrap-around.
    // Let's verify what happens.
    var rf = try RangeFilter.parse("23:00..01:00", 0);
    rf.initBaseDate(1709632800);

    // In our current implementation:
    // start_secs = 23 * 3600 = 82800
    // end_secs = 1 * 3600 = 3600
    // matches(ts) -> (ts >= base + 82800) and (ts <= base + 3600) -> impossible for same base.
    try std.testing.expect(!rf.matches(1709679600)); // 23:00
    try std.testing.expect(!rf.matches(1709600400)); // 01:00 (today)
}

test "RangeFilter invalid strings" {
    try std.testing.expectError(error.InvalidRangeSyntax, RangeFilter.parse("abc", 0));
    try std.testing.expectError(error.InvalidRangeSyntax, RangeFilter.parse("10:00", 0)); // No separator
    try std.testing.expectError(error.InvalidTimestamp, RangeFilter.parse("10:00..25:00", 0)); // Invalid time
}

test "RangeFilter datetime with timezone shift" {
    // 2024-03-05 10:00 UTC+0 = 1709632800
    // 2024-03-05 10:00 UTC+2 = 1709625600
    const rf = try RangeFilter.parse("2024-03-05 10:00:00..2024-03-05 12:00:00", 7200); // UTC+2

    try std.testing.expect(rf.matches(1709625600)); // 10:00 local
    try std.testing.expect(rf.matches(1709632800)); // 12:00 local is UTC 10:00 -> 1709632800
    try std.testing.expect(!rf.matches(1709632801));
}
