const std = @import("std");

/// A single substring/regex filter.  Only `exact` (substring) implemented today.
pub const Filter = union(enum) {
    exact: []const u8,

    pub fn parse(text: []const u8) Filter {
        return .{ .exact = text };
    }

    pub fn matches(self: Filter, line: []const u8) bool {
        return switch (self) {
            .exact => |s| std.mem.indexOf(u8, line, s) != null,
        };
    }
};

/// Returns true if the line should be included based on include/exclude lists.
/// - Empty include list → include everything.
/// - Exclude takes precedence over include.
pub fn passesFilter(line: []const u8, include: []const Filter, exclude: []const Filter) bool {
    for (exclude) |f| if (f.matches(line)) return false;
    if (include.len == 0) return true;
    for (include) |f| if (f.matches(line)) return true;
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
