const std = @import("std");
const args_mod = @import("args.zig");
const config_mod = @import("config.zig");
const parser_mod = @import("parser.zig");
const filter_mod = @import("filter.zig");

const DUMMY_CFG = config_mod.FolderConfig{
    .paths = &[_][]const u8{},
    .profiles = std.StringHashMap(config_mod.Profile).init(std.heap.page_allocator), // unused
};

const TimestampFormat = enum { datetime, time, timems };

/// Everything resolved once per run: matched config, output format, key mappings, filters.
const LineContext = struct {
    const ValuesConfig = struct {
        prefix: enum { none, datetime, time, timems, line },
        key: []const u8,
    };

    cfg: *const config_mod.FolderConfig,
    ts_key: []const u8,
    out_fmt: []const u8,
    include: []const filter_mod.Filter,
    exclude: []const filter_mod.Filter,
    /// Optional time/date range filter (from -r flag)
    range_filter: ?filter_mod.RangeFilter,
    /// Seconds east of UTC for display and range matching (from -z flag)
    zone_offset_secs: i64,
    /// Optional value inspection configuration (from -v flag)
    values_config: ?ValuesConfig,

    fn deinit(self: *LineContext, allocator: std.mem.Allocator) void {
        allocator.free(self.include);
        allocator.free(self.exclude);
    }
};

pub const Processor = struct {
    allocator: std.mem.Allocator,
    args: args_mod.Args,
    config: config_mod.Config,
    parser: parser_mod.Parser,
    /// Track seen values for the -v option.
    seen_values: std.StringHashMap(void),
    /// Unique keys found during --keys run
    all_found_keys: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator, args: args_mod.Args, config: config_mod.Config) Processor {
        return .{
            .allocator = allocator,
            .args = args,
            .config = config,
            .parser = parser_mod.Parser.init(allocator),
            .seen_values = std.StringHashMap(void).init(allocator),
            .all_found_keys = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn run(self: *Processor) !void {
        const stdout = std.fs.File.stdout();

        // Resolve config, keys, and filters once — before any line is processed.
        var ctx = try self.buildContext();
        defer ctx.deinit(self.allocator);
        defer {
            var it = self.seen_values.keyIterator();
            while (it.next()) |key| {
                self.allocator.free(key.*);
            }
            self.seen_values.deinit();
            var kit = self.all_found_keys.keyIterator();
            while (kit.next()) |key| {
                self.allocator.free(key.*);
            }
            self.all_found_keys.deinit();
        }

        if (self.args.file_path) |path| {
            const file = try std.fs.cwd().openFile(path, .{});
            defer file.close();

            if (self.args.tail) {
                try self.tailFile(file, stdout, &ctx);
            } else {
                const read_buf = try self.allocator.alloc(u8, 1024 * 1024);
                defer self.allocator.free(read_buf);
                var r = file.reader(read_buf);
                try self.processStream(&r.interface, stdout, &ctx);
            }
        } else {
            // No file specified — read from stdin
            const stdin_buf = try self.allocator.alloc(u8, 1024 * 1024);
            defer self.allocator.free(stdin_buf);
            var stdin_reader = std.fs.File.stdin().reader(stdin_buf);
            try self.processStream(&stdin_reader.interface, stdout, &ctx);
        }

        if (self.args.keys) {
            try self.reportDiscoveredKeys(stdout);
        }
    }

    fn reportDiscoveredKeys(self: *Processor, stdout: std.fs.File) !void {
        var keys_list: std.ArrayListUnmanaged([]const u8) = .{};
        defer keys_list.deinit(self.allocator);

        var it = self.all_found_keys.keyIterator();
        while (it.next()) |k| {
            try keys_list.append(self.allocator, k.*);
        }

        if (keys_list.items.len == 0) return;

        std.mem.sort([]const u8, keys_list.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);

        _ = try stdout.write("\nDiscovered keys:\n");
        for (keys_list.items) |k| {
            _ = try stdout.write("  ");
            _ = try stdout.write(k);
            _ = try stdout.write("\n");
        }
    }

    /// Resolve folder config, apply profile overrides, and build filter lists.
    /// The returned LineContext owns the filter slices; call deinit when done.
    fn buildContext(self: *Processor) !LineContext {
        const cfg: *const config_mod.FolderConfig = if (self.args.file_path) |fp| blk: {
            // File mode: resolve the log file's parent directory and match it against configured paths
            var file_real_buf: [4096]u8 = undefined;
            const file_real = std.fs.cwd().realpath(fp, &file_real_buf) catch fp;
            const file_dir = std.fs.path.dirname(file_real) orelse file_real;

            var matched: ?*const config_mod.FolderConfig = null;
            for (self.config.folders.items) |*f| {
                if (f.paths.len == 0) {
                    if (matched == null) matched = f; // first pathless section = fallback
                    continue;
                }
                for (f.paths) |path| {
                    if (file_dir.len >= path.len and std.ascii.eqlIgnoreCase(file_dir[0..path.len], path)) {
                        matched = f;
                        break;
                    }
                }
                if (matched != null and matched.? == f) break;
            }
            if (matched == null and self.args.keys) {
                // If --keys is used, we can proceed without a folder match
                break :blk &DUMMY_CFG;
            }
            break :blk matched orelse return error.NoMatchingFolderConfig;
        } else blk: {
            // Stdin mode: no file path — use the first [folders] section unconditionally
            if (self.config.folders.items.len == 0) {
                if (self.args.keys) break :blk &DUMMY_CFG;
                return error.NoFolderConfigDefined;
            }
            break :blk &self.config.folders.items[0];
        };

        // Key and format resolution (profile overrides folder defaults)
        var ts_key = cfg.timestamp_key;
        var out_fmt = cfg.output_format;

        if (self.args.profile) |pname| {
            if (cfg.profiles.get(pname)) |p| {
                if (p.output_format) |o| out_fmt = o;
                if (p.timestamp_key) |o| ts_key = o;
            }
        }

        // Build Filter lists: folder config → profile → CLI args
        var include_list: std.ArrayListUnmanaged(filter_mod.Filter) = .{};
        errdefer include_list.deinit(self.allocator);
        var exclude_list: std.ArrayListUnmanaged(filter_mod.Filter) = .{};
        errdefer exclude_list.deinit(self.allocator);

        for (cfg.include_filters) |s| try include_list.append(self.allocator, filter_mod.Filter.parse(s));
        for (cfg.exclude_filters) |s| try exclude_list.append(self.allocator, filter_mod.Filter.parse(s));

        if (self.args.profile) |pname| {
            if (cfg.profiles.get(pname)) |p| {
                for (p.include_filters) |s| try include_list.append(self.allocator, filter_mod.Filter.parse(s));
                for (p.exclude_filters) |s| try exclude_list.append(self.allocator, filter_mod.Filter.parse(s));
            }
        }

        for (self.args.include_filters.items) |s| try include_list.append(self.allocator, filter_mod.Filter.parse(s));
        for (self.args.exclude_filters.items) |s| try exclude_list.append(self.allocator, filter_mod.Filter.parse(s));

        // Zone offset — parsed once, used for range matching and datetime formatting
        const zone_offset_secs = filter_mod.parseZoneOffset(self.args.zone) catch 0;

        // Optional range filter
        const range_filter: ?filter_mod.RangeFilter = if (self.args.range) |rs|
            filter_mod.RangeFilter.parse(rs, zone_offset_secs) catch null
        else
            null;

        // Optional value inspection config
        var values_config: ?LineContext.ValuesConfig = null;
        if (self.args.values) |vs| {
            if (std.mem.indexOf(u8, vs, ":")) |idx| {
                const prefix_str = vs[0..idx];
                const key = vs[idx + 1 ..];
                if (std.mem.eql(u8, prefix_str, "datetime")) {
                    values_config = .{ .prefix = .datetime, .key = key };
                } else if (std.mem.eql(u8, prefix_str, "time")) {
                    values_config = .{ .prefix = .time, .key = key };
                } else if (std.mem.eql(u8, prefix_str, "timems")) {
                    values_config = .{ .prefix = .timems, .key = key };
                } else if (std.mem.eql(u8, prefix_str, "line")) {
                    values_config = .{ .prefix = .line, .key = key };
                } else {
                    // prefix not recognized, treat as key with no prefix
                    values_config = .{ .prefix = .none, .key = vs };
                }
            } else {
                values_config = .{ .prefix = .none, .key = vs };
            }
        }

        return .{
            .cfg = cfg,
            .ts_key = ts_key,
            .out_fmt = out_fmt,
            .include = try include_list.toOwnedSlice(self.allocator),
            .exclude = try exclude_list.toOwnedSlice(self.allocator),
            .range_filter = range_filter,
            .zone_offset_secs = zone_offset_secs,
            .values_config = values_config,
        };
    }

    fn processStream(self: *Processor, reader: *std.io.Reader, writer: anytype, ctx: *const LineContext) !void {
        while (true) {
            var line = (try reader.takeDelimiter('\n')) orelse break;
            if (line.len > 0 and line[line.len - 1] == '\r') {
                line = line[0 .. line.len - 1];
            }
            try self.processLine(line, writer, ctx);
        }
    }

    fn tailFile(self: *Processor, file: std.fs.File, writer: anytype, ctx: *const LineContext) !void {
        // Start from end of file, so we only see NEW lines
        var pos = try file.getEndPos();
        try file.seekTo(pos);

        // Line accumulation buffer
        var line_buf: std.ArrayListUnmanaged(u8) = .{};
        defer line_buf.deinit(self.allocator);

        var raw_buf: [4096]u8 = undefined;

        while (true) {
            const n = try file.read(raw_buf[0..]);
            if (n == 0) {
                // No new data – wait and retry
                std.Thread.sleep(100 * std.time.ns_per_ms);
                // Keep pos in sync in case of truncation/rotation
                pos = file.getPos() catch pos;
                continue;
            }

            pos += n;
            for (raw_buf[0..n]) |byte| {
                if (byte == '\n') {
                    var line: []const u8 = line_buf.items;
                    if (line.len > 0 and line[line.len - 1] == '\r') {
                        line = line[0 .. line.len - 1];
                    }
                    try self.processLine(line, writer, ctx);
                    line_buf.clearRetainingCapacity();
                } else {
                    try line_buf.append(self.allocator, byte);
                }
            }
        }
    }

    fn processLine(self: *Processor, line: []const u8, writer: anytype, ctx: *const LineContext) !void {
        const entry_const = (try self.parser.parseLine(line, ctx.ts_key)) orelse return;
        var entry = entry_const;
        defer entry.deinit(self.allocator);

        // Range filter: checked first against the raw timestamp
        if (ctx.range_filter) |rf| {
            if (entry.timestamp) |ts| {
                // Normalise ms timestamps to seconds
                const ts_secs: i64 = if (ts > 10_000_000_000) @divTrunc(ts, 1000) else ts;
                if (!rf.matches(ts_secs)) return;
            }
            // If no timestamp field, skip line — we cannot determine if it's in range
            else return;
        }

        if (self.args.keys) {
            var it = entry.parsed.value.object.iterator();
            while (it.next()) |kv| {
                if (!self.all_found_keys.contains(kv.key_ptr.*)) {
                    const k = try self.allocator.dupe(u8, kv.key_ptr.*);
                    try self.all_found_keys.put(k, {});
                }
            }
            return;
        }

        if (self.args.passthrough) {
            if (!filter_mod.passesFilter(line, ctx.include, ctx.exclude)) return;
            // Value inspection overrides regular output
            if (ctx.values_config) |vc| {
                if (entry.parsed.value.object.get(vc.key)) |val| {
                    if (try self.handleValue(val, line, &entry, ctx, writer)) return;
                }
                return;
            }
            try writer.writeAll(line);
            try writer.writeAll("\n");
            return;
        }

        const formatted = try self.formatEntry(&entry, ctx.out_fmt, ctx.cfg, ctx.zone_offset_secs);
        defer self.allocator.free(@constCast(formatted));

        if (!filter_mod.passesFilter(formatted, ctx.include, ctx.exclude)) return;

        // Value inspection overrides regular output
        if (ctx.values_config) |vc| {
            if (entry.parsed.value.object.get(vc.key)) |val| {
                _ = try self.handleValue(val, formatted, &entry, ctx, writer);
            }
            return;
        }

        try writer.writeAll(formatted);
        try writer.writeAll("\n");
    }

    fn handleValue(self: *Processor, val: std.json.Value, formatted: []const u8, entry: *const parser_mod.LogEntry, ctx: *const LineContext, writer: anytype) !bool {
        const val_str = switch (val) {
            .string => |s| s,
            .integer => |n| try std.fmt.allocPrint(self.allocator, "{d}", .{n}),
            .float => |f| try std.fmt.allocPrint(self.allocator, "{d}", .{f}),
            .bool => |b| if (b) "true" else "false",
            .null => "null",
            else => "complex",
        };
        defer if (val != .string) self.allocator.free(val_str);

        if (self.seen_values.contains(val_str)) return true;

        const key = try self.allocator.dupe(u8, val_str);
        try self.seen_values.put(key, {});

        switch (ctx.values_config.?.prefix) {
            .none => {
                try writer.writeAll(val_str);
                try writer.writeAll("\n");
            },
            .datetime => {
                if (entry.timestamp) |ts| {
                    const dt = try formatTimestamp(self.allocator, ts, ctx.zone_offset_secs, .datetime);
                    defer self.allocator.free(dt);
                    try writer.writeAll(dt);
                    try writer.writeAll(" ");
                }
                try writer.writeAll(val_str);
                try writer.writeAll("\n");
            },
            .time => {
                if (entry.timestamp) |ts| {
                    const dt = try formatTimestamp(self.allocator, ts, ctx.zone_offset_secs, .time);
                    defer self.allocator.free(dt);
                    try writer.writeAll(dt);
                    try writer.writeAll(" ");
                }
                try writer.writeAll(val_str);
                try writer.writeAll("\n");
            },
            .timems => {
                if (entry.timestamp) |ts| {
                    const dt = try formatTimestamp(self.allocator, ts, ctx.zone_offset_secs, .timems);
                    defer self.allocator.free(dt);
                    try writer.writeAll(dt);
                    try writer.writeAll(" ");
                }
                try writer.writeAll(val_str);
                try writer.writeAll("\n");
            },
            .line => {
                try writer.writeAll(formatted);
                try writer.writeAll("\n");
                try writer.writeAll(val_str);
                try writer.writeAll("\n\n");
            },
        }
        return true;
    }

    fn formatEntry(self: *Processor, entry: *const parser_mod.LogEntry, format: []const u8, cfg: *const config_mod.FolderConfig, zone_offset_secs: i64) ![]const u8 {
        var res: []const u8 = try self.allocator.dupe(u8, format);
        errdefer self.allocator.free(@constCast(res));

        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, res, start, '{')) |open_idx| {
            const close_idx = std.mem.indexOfScalarPos(u8, res, open_idx, '}') orelse {
                start = open_idx + 1;
                continue;
            };

            const placeholder = res[open_idx + 1 .. close_idx];
            var key: []const u8 = placeholder;
            var spec: ?[]const u8 = null;

            if (std.mem.indexOfScalar(u8, placeholder, ':')) |colon_idx| {
                key = placeholder[0..colon_idx];
                spec = placeholder[colon_idx + 1 ..];
            }

            var actual_key: []const u8 = key;
            if (std.mem.eql(u8, key, "timestamp")) {
                actual_key = if (self.args.profile) |pn| p: {
                    if (cfg.profiles.get(pn)) |prof| break :p prof.timestamp_key orelse cfg.timestamp_key;
                    break :p cfg.timestamp_key;
                } else cfg.timestamp_key;
            } else if (std.mem.eql(u8, key, "level")) {
                actual_key = if (self.args.profile) |pn| p: {
                    if (cfg.profiles.get(pn)) |prof| break :p prof.level_key orelse cfg.level_key;
                    break :p cfg.level_key;
                } else cfg.level_key;
            } else if (std.mem.eql(u8, key, "message")) {
                actual_key = if (self.args.profile) |pn| p: {
                    if (cfg.profiles.get(pn)) |prof| break :p prof.message_key orelse cfg.message_key;
                    break :p cfg.message_key;
                } else cfg.message_key;
            } else if (std.mem.eql(u8, key, "thread")) {
                actual_key = if (self.args.profile) |pn| p: {
                    if (cfg.profiles.get(pn)) |prof| break :p prof.thread_key orelse cfg.thread_key;
                    break :p cfg.thread_key;
                } else cfg.thread_key;
            } else if (std.mem.eql(u8, key, "logger")) {
                actual_key = if (self.args.profile) |pn| p: {
                    if (cfg.profiles.get(pn)) |prof| break :p prof.logger_key orelse cfg.logger_key;
                    break :p cfg.logger_key;
                } else cfg.logger_key;
            } else if (std.mem.eql(u8, key, "trace")) {
                actual_key = if (self.args.profile) |pn| p: {
                    if (cfg.profiles.get(pn)) |prof| break :p prof.trace_key orelse cfg.trace_key;
                    break :p cfg.trace_key;
                } else cfg.trace_key;
            }

            var replacement: []const u8 = "";
            var free_replacement = false;

            if (std.mem.eql(u8, key, "timestamp") and spec != null) {
                const fmt_type: TimestampFormat = if (std.mem.eql(u8, spec.?, "datetime"))
                    .datetime
                else if (std.mem.eql(u8, spec.?, "time"))
                    .time
                else if (std.mem.eql(u8, spec.?, "timems"))
                    .timems
                else
                    continue; // unrecognized spec, fall through to regular key logic

                if (entry.timestamp) |ts| {
                    replacement = try formatTimestamp(self.allocator, ts, zone_offset_secs, fmt_type);
                    free_replacement = true;
                }
            } else {
                if (entry.parsed.value.object.get(actual_key)) |val| {
                    replacement = try valueToString(self.allocator, val);
                    free_replacement = true;
                } else if (!std.mem.eql(u8, actual_key, key)) {
                    if (entry.parsed.value.object.get(key)) |val| {
                        replacement = try valueToString(self.allocator, val);
                        free_replacement = true;
                    }
                }
            }

            // Dupe needle because replace() frees and re-allocates res
            const needle = try self.allocator.dupe(u8, res[open_idx .. close_idx + 1]);
            defer self.allocator.free(needle);

            const new_res = try replace(self.allocator, res, needle, replacement);
            if (free_replacement) self.allocator.free(replacement);
            res = new_res;
            start = open_idx + replacement.len;
        }

        return res;
    }

    fn valueToString(allocator: std.mem.Allocator, val: std.json.Value) ![]const u8 {
        return switch (val) {
            .string => try allocator.dupe(u8, val.string),
            .integer => try std.fmt.allocPrint(allocator, "{d}", .{val.integer}),
            .float => try std.fmt.allocPrint(allocator, "{d}", .{val.float}),
            .bool => try allocator.dupe(u8, if (val.bool) "true" else "false"),
            .null => try allocator.dupe(u8, ""),
            else => try allocator.dupe(u8, "..."),
        };
    }

    fn formatTimestamp(allocator: std.mem.Allocator, timestamp: i64, zone_offset_secs: i64, fmt: TimestampFormat) ![]const u8 {
        const ms = @mod(timestamp, 1000);
        const ts = @divTrunc(timestamp, 1000) + zone_offset_secs;

        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
        const day_seconds = epoch_seconds.getDaySeconds();

        switch (fmt) {
            .datetime => {
                const epoch_day = epoch_seconds.getEpochDay();
                const year_day = epoch_day.calculateYearDay();
                const month_day = year_day.calculateMonthDay();
                return try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
                    year_day.year,
                    month_day.month.numeric(),
                    month_day.day_index + 1,
                    day_seconds.getHoursIntoDay(),
                    day_seconds.getMinutesIntoHour(),
                    day_seconds.getSecondsIntoMinute(),
                });
            },
            .time => {
                return try std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{d:0>2}", .{
                    day_seconds.getHoursIntoDay(),
                    day_seconds.getMinutesIntoHour(),
                    day_seconds.getSecondsIntoMinute(),
                });
            },
            .timems => {
                return try std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
                    day_seconds.getHoursIntoDay(),
                    day_seconds.getMinutesIntoHour(),
                    day_seconds.getSecondsIntoMinute(),
                    @abs(ms),
                });
            },
        }
    }

    fn replace(allocator: std.mem.Allocator, input: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
        const count = std.mem.count(u8, input, needle);
        if (count == 0) return input;

        const new_len = if (replacement.len >= needle.len)
            input.len + (replacement.len - needle.len) * count
        else
            input.len - (needle.len - replacement.len) * count;
        const new_buf = try allocator.alloc(u8, new_len);
        _ = std.mem.replace(u8, input, needle, replacement, new_buf);

        allocator.free(input);
        return new_buf;
    }
};
