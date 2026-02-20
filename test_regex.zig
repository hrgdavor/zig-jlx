const std = @import("std");
const regex = @import("regex");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var re = try regex.Regex.compile(allocator, "he.*world");
    defer re.deinit();

    const m = try re.match("hello world");
    std.debug.print("Matches: {}\n", .{m});
}
