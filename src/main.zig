const std = @import("std");
const args_mod = @import("args.zig");
const config_mod = @import("config.zig");
const processor_mod = @import("processor.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try args_mod.Args.parse(allocator);
    var args_copy = args;
    defer args_copy.deinit(allocator);

    var config = config_mod.Config.init(allocator);
    defer config.deinit();

    if (args.config_path) |path| {
        try config.load(path);
    }

    var processor = processor_mod.Processor.init(allocator, args, config);
    try processor.run();
}
