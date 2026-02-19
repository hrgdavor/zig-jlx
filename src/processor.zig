const std = @import("std");
const args_mod = @import("args.zig");
const config_mod = @import("config.zig");
const parser_mod = @import("parser.zig");

pub const Processor = struct {
    allocator: std.mem.Allocator,
    args: args_mod.Args,
    config: config_mod.Config,
    parser: parser_mod.Parser,

    pub fn init(allocator: std.mem.Allocator, args: args_mod.Args, config: config_mod.Config) Processor {
        return .{
            .allocator = allocator,
            .args = args,
            .config = config,
            .parser = parser_mod.Parser.init(allocator),
        };
    }

    pub fn run(self: *Processor) !void {
        var stdout_buf: [4096]u8 = undefined;
        const stdout = std.fs.File.stdout().writer(&stdout_buf);

        var stdin_buf: [1024]u8 = undefined;
        if (self.args.use_stdin) {
            var stdin_reader = std.io.getStdIn().reader(&stdin_buf);
            try self.processStream(&stdin_reader.interface, stdout);
        } else if (self.args.file_path) |path| {
            const file = try std.fs.cwd().openFile(path, .{});
            defer file.close();

            if (self.args.tail) {
                try self.tailFile(file, stdout);
            } else {
                try self.processStream(file.reader(), stdout);
            }
        }
    }

    fn processStream(self: *Processor, reader: anytype, writer: anytype) !void {
        while (true) {
            const line = (try reader.takeDelimiter('\n')) orelse break;
            try self.processLine(line, writer);
        }
    }

    fn tailFile(self: *Processor, file: std.fs.File, writer: anytype) !void {
        // Move to end of file
        try file.seekTo(try file.getEndPos());

        var tail_read_buf: [4096]u8 = undefined;
        var reader = file.reader(&tail_read_buf);

        while (true) {
            const line = (try reader.interface.takeDelimiter('\n'));
            if (line) |l| {
                try self.processLine(l, writer);
            } else {
                std.time.sleep(100 * std.time.ns_per_ms);
            }
        }
    }

    fn processLine(self: *Processor, line: []const u8, writer: anytype) !void {
        if (self.args.raw) {
            _ = try writer.write(line);
            _ = try writer.write("\n");
            return;
        }

        // Find active folder config (default to first for now, or match paths)
        const cfg = if (self.config.folders.items.len > 0) self.config.folders.items[0] else config_mod.FolderConfig{
            .paths = &[_][]const u8{},
        };

        if (try self.parser.parseLine(line, cfg.timestamp_key, cfg.level_key, cfg.message_key, cfg.thread_key, cfg.logger_key, cfg.trace_key)) |entry| {
            // Basic formatting based on FolderConfig.output_format
            // For now, just a simple string replacement or fixed format
            const formatted = try self.formatEntry(entry, cfg.output_format);
            defer self.allocator.free(formatted);

            _ = try writer.write(formatted);
            _ = try writer.write("\n");
        }
    }

    fn formatEntry(self: *Processor, entry: parser_mod.LogEntry, format: []const u8) ![]const u8 {
        // Very basic placeholder replacement
        var result = try self.allocator.dupe(u8, format);

        const ts_str = if (entry.timestamp) |ts| try std.fmt.allocPrint(self.allocator, "{}", .{ts}) else try self.allocator.dupe(u8, "-");
        defer self.allocator.free(ts_str);

        result = try replace(self.allocator, result, "{timestamp}", ts_str);
        result = try replace(self.allocator, result, "{level}", entry.level orelse "-");
        result = try replace(self.allocator, result, "{message}", entry.message orelse "-");

        return result;
    }

    fn replace(allocator: std.mem.Allocator, input: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
        const count = std.mem.countSequence(u8, input, needle);
        if (count == 0) return input;

        const new_len = input.len + (replacement.len - needle.len) * count;
        const new_buf = try allocator.alloc(u8, new_len);
        _ = std.mem.replaceSequence(u8, input, needle, replacement, new_buf);

        allocator.free(input);
        return new_buf;
    }
};
