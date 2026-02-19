const std = @import("std");

/// A single filter. The string representation will be parsed
/// to determine the filter kind. Currently only `exact` is
/// implemented; `regex` and other variants will be added later.
///
/// String syntax (for future parsing):
///   "hello world"      → exact match (substring)
///   "/pattern/"        → regex  (to be implemented)
pub const Filter = union(enum) {
    /// Substring / exact match: line must contain this string.
    exact: []const u8,

    /// Parse a filter from its string representation.
    /// Ownership: the returned Filter borrows the given slice; the
    /// caller must ensure it lives long enough.
    pub fn parse(text: []const u8) Filter {
        // Future: detect "/…/" as regex, etc.
        return .{ .exact = text };
    }

    /// Returns true when this filter matches the given line.
    pub fn matches(self: Filter, line: []const u8) bool {
        return switch (self) {
            .exact => |s| std.mem.indexOf(u8, line, s) != null,
        };
    }
};

/// Returns true if the line should be included in the output.
///
/// Rules:
///  - If `include` is non-empty the line must match at least one include filter.
///  - If `exclude` is non-empty the line must not match any exclude filter.
///  - An empty `include` list means "include everything".
pub fn passesFilter(line: []const u8, include: []const Filter, exclude: []const Filter) bool {
    // Exclude check — takes precedence
    for (exclude) |f| {
        if (f.matches(line)) return false;
    }

    // Include check
    if (include.len == 0) return true;
    for (include) |f| {
        if (f.matches(line)) return true;
    }
    return false;
}
