const std = @import("std");
const args_mod = @import("args.zig");
const config_mod = @import("config.zig");
const parser_mod = @import("parser.zig");
const filter_mod = @import("filter.zig");
const fast_reader_mod = @import("fast_reader.zig");

const DUMMY_CFG = config_mod.FolderConfig{
    .paths = &[_][]const u8{},
    .profiles = std.StringHashMap(config_mod.Profile).init(std.heap.page_allocator), // unused
};

const TimestampFormat = enum { datetime, time, timems };

/// Everything resolved once per run: matched config, output format, key mappings, filters.
pub const LineContext = struct {
    const ValuesConfig = struct {
        prefix: enum { none, datetime, time, timems, line },
        key: []const u8,
    };

    cfg: *const config_mod.FolderConfig,
    ts_key: []const u8,
    out_fmt: []const u8,
    message_expand_fn: ?*const fn (*Processor, std.mem.Allocator, []const u8, *const std.StringHashMap([]const u8), i64) anyerror![]const u8,
    include: []const filter_mod.Filter,
    exclude: []const filter_mod.Filter,
    /// Optional time/date range filter (from -r flag)
    range_filter: ?*filter_mod.RangeFilter,
    /// Seconds east of UTC for display and range matching (from -z flag)
    zone_offset_secs: i64,
    /// Optional value inspection configuration (from -v flag)
    values_config: ?ValuesConfig,

    pub fn deinit(self: *LineContext, allocator: std.mem.Allocator) void {
        for (self.include) |*f| @constCast(f).deinit(allocator);
        for (self.exclude) |*f| @constCast(f).deinit(allocator);
        allocator.free(self.include);
        allocator.free(self.exclude);
    }
};

pub const Processor = struct {
    allocator: std.mem.Allocator,
    args: args_mod.Args,
    config: *const config_mod.Config,
    /// Track seen values for the -v option.
    seen_values: std.StringHashMap(void),
    /// Unique keys found during --keys run
    all_found_keys: std.StringHashMap(void),
    /// Persistent buffer for lines that straddle I/O boundaries or exceed 64KB.
    side_buffer: std.ArrayListUnmanaged(u8),
    /// Single canonical timezone offset for the entire run.
    zone_offset_secs: i64,
    /// Optional range filter stored here so it can be mutated (e.g. for time-only resolution)
    range_filter: ?filter_mod.RangeFilter = null,

    pub fn init(allocator: std.mem.Allocator, args: args_mod.Args, config: *const config_mod.Config) Processor {
        var self = Processor{
            .allocator = allocator,
            .args = args,
            .config = config,
            .seen_values = std.StringHashMap(void).init(allocator),
            .all_found_keys = std.StringHashMap(void).init(allocator),
            .side_buffer = .{},
            .zone_offset_secs = 0,
        };

        const folder = self.findFolderConfig();
        const zone_str: ?[]const u8 = args.zone orelse blk: {
            if (args.profile) |pname| {
                if (folder.profiles.get(pname)) |p| {
                    if (p.zone) |z| break :blk z;
                }
            }
            if (folder.zone) |z| break :blk z;
            break :blk config.zone;
        };

        self.zone_offset_secs = if (zone_str) |zs|
            filter_mod.parseZoneOffset(zs) catch filter_mod.getLocalZoneOffset()
        else
            filter_mod.getLocalZoneOffset();

        if (args.range) |rs| {
            self.range_filter = filter_mod.RangeFilter.parse(rs, self.zone_offset_secs) catch null;
        }

        return self;
    }

    pub fn deinit(self: *Processor) void {
        var sit = self.seen_values.keyIterator();
        while (sit.next()) |k| {
            self.allocator.free(k.*);
        }
        self.seen_values.deinit();

        var it = self.all_found_keys.keyIterator();
        while (it.next()) |k| {
            self.allocator.free(k.*);
        }
        self.all_found_keys.deinit();
        self.side_buffer.deinit(self.allocator);
    }

    pub fn run(self: *Processor) !void {
        var stdout_buffer: [16384]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);

        try self.runInternal(&stdout_writer.interface);
        try stdout_writer.interface.flush();
    }

    pub fn runInternal(self: *Processor, writer: anytype) !void {
        // Resolve config, keys, and filters once — before any line is processed.
        var ctx = try self.buildContext();
        defer ctx.deinit(self.allocator);

        if (self.args.file_path) |path| {
            const file = try std.fs.cwd().openFile(path, .{});
            defer file.close();

            var limit: ?usize = null;
            if (self.args.range) |rs| {
                if (std.fmt.parseInt(i64, rs, 10)) |val| {
                    if (val > 0) {
                        limit = @intCast(val);
                    } else if (val < 0) {
                        const offset = try fast_reader_mod.findLastLinesOffset(file, @intCast(-val));
                        try file.seekTo(offset);
                    }
                } else |_| {}
            }

            if (self.args.follow) {
                try self.followFile(file, writer, &ctx);
            } else {
                try self.processStream(file, writer, &ctx, limit);
            }
        } else {
            // No file specified — read from stdin
            var limit: ?usize = null;
            if (self.args.range) |rs| {
                if (std.fmt.parseInt(i64, rs, 10)) |val| {
                    if (val > 0) limit = @intCast(val);
                    // Tail not supported for stdin (cannot seek)
                } else |_| {}
            }
            try self.processStream(std.fs.File.stdin(), writer, &ctx, limit);
        }

        if (self.args.keys) {
            try self.reportDiscoveredKeys(writer);
        }
    }

    fn reportDiscoveredKeys(self: *Processor, writer: anytype) !void {
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

        _ = try writer.write("\nDiscovered keys:\n");
        for (keys_list.items) |k| {
            _ = try writer.write("  ");
            _ = try writer.write(k);
            _ = try writer.write("\n");
        }
    }

    fn findFolderConfig(self: *const Processor) *const config_mod.FolderConfig {
        if (self.args.file_path) |fp| {
            var file_real_buf: [4096]u8 = undefined;
            const file_real = std.fs.cwd().realpath(fp, &file_real_buf) catch fp;
            const file_dir = std.fs.path.dirname(file_real) orelse file_real;

            var matched: ?*const config_mod.FolderConfig = null;
            for (self.config.folders.items) |*f| {
                if (f.paths.len == 0) {
                    if (matched == null) matched = f;
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
            return matched orelse &DUMMY_CFG;
        } else {
            if (self.config.folders.items.len > 0) return &self.config.folders.items[0];
            return &DUMMY_CFG;
        }
    }

    /// Resolve folder config, apply profile overrides, and build filter lists.
    /// The returned LineContext owns the filter slices; call deinit when done.
    pub fn buildContext(self: *Processor) !LineContext {
        const cfg = self.findFolderConfig();

        // Key and format resolution (profile overrides folder defaults)
        var ts_key = cfg.timestamp_key;
        var out_fmt = cfg.output_format;
        var msg_expand = cfg.message_expand;

        if (self.args.profile) |pname| {
            if (cfg.profiles.get(pname)) |p| {
                if (p.output_format) |o| out_fmt = o;
                if (p.timestamp_key) |o| ts_key = o;
                if (p.message_expand) |e| msg_expand = e;
            }
        }

        var msg_expand_fn: ?*const fn (*Processor, std.mem.Allocator, []const u8, *const std.StringHashMap([]const u8), i64) anyerror![]const u8 = null;
        if (msg_expand) |syntax| {
            if (std.mem.eql(u8, syntax, "curly")) {
                msg_expand_fn = Processor.expandCurly;
            } else if (std.mem.eql(u8, syntax, "js")) {
                msg_expand_fn = Processor.expandJs;
            } else if (std.mem.eql(u8, syntax, "brackets")) {
                msg_expand_fn = Processor.expandBrackets;
            } else if (std.mem.eql(u8, syntax, "parens")) {
                msg_expand_fn = Processor.expandParens;
            } else if (std.mem.eql(u8, syntax, "printf")) {
                msg_expand_fn = Processor.expandPrintf;
            } else if (std.mem.eql(u8, syntax, "ruby")) {
                msg_expand_fn = Processor.expandRuby;
            } else if (std.mem.eql(u8, syntax, "double_curly")) {
                msg_expand_fn = Processor.expandDoubleCurly;
            } else if (std.mem.eql(u8, syntax, "env")) {
                msg_expand_fn = Processor.expandEnv;
            } else if (std.mem.eql(u8, syntax, "colon")) {
                msg_expand_fn = Processor.expandColon;
            }
        }

        // Build Filter lists: folder config → profile → CLI args
        var include_list: std.ArrayListUnmanaged(filter_mod.Filter) = .{};
        errdefer include_list.deinit(self.allocator);
        var exclude_list: std.ArrayListUnmanaged(filter_mod.Filter) = .{};
        errdefer exclude_list.deinit(self.allocator);

        for (cfg.include_filters) |s| try include_list.append(self.allocator, try filter_mod.Filter.parse(self.allocator, s));
        for (cfg.exclude_filters) |s| try exclude_list.append(self.allocator, try filter_mod.Filter.parse(self.allocator, s));

        if (self.args.profile) |pname| {
            if (cfg.profiles.get(pname)) |p| {
                for (p.include_filters) |s| try include_list.append(self.allocator, try filter_mod.Filter.parse(self.allocator, s));
                for (p.exclude_filters) |s| try exclude_list.append(self.allocator, try filter_mod.Filter.parse(self.allocator, s));
            }
        }

        if (self.args.include) |s| try include_list.append(self.allocator, try filter_mod.Filter.parse(self.allocator, s));
        if (self.args.exclude) |s| try exclude_list.append(self.allocator, try filter_mod.Filter.parse(self.allocator, s));

        // Zone offset resolution: CLI -> Profile -> Folder -> Global -> Local
        // Already resolved in init()

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

        return LineContext{
            .cfg = cfg,
            .ts_key = ts_key,
            .out_fmt = out_fmt,
            .message_expand_fn = msg_expand_fn,
            .include = try include_list.toOwnedSlice(self.allocator),
            .exclude = try exclude_list.toOwnedSlice(self.allocator),
            .range_filter = if (self.range_filter != null) &self.range_filter.? else null,
            .zone_offset_secs = self.zone_offset_secs,
            .values_config = values_config,
        };
    }

    pub fn processStream(self: *Processor, file: std.fs.File, writer: anytype, ctx: *const LineContext, limit: ?usize) !void {
        var buf = try self.allocator.alloc(u8, 32 * 1024);
        defer self.allocator.free(buf);

        var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();

        var matched_count: usize = 0;
        var eof = false;

        while (true) {
            if (limit) |l| if (matched_count >= l) break;

            const n = try file.read(buf);
            if (n == 0) {
                eof = true;
            }

            var read_pos: usize = 0;
            const data = buf[0..n];

            while (std.mem.indexOfScalarPos(u8, data, read_pos, '\n')) |nl_idx| {
                if (limit) |l| if (matched_count >= l) break;

                const fragment = data[read_pos..nl_idx];
                read_pos = nl_idx + 1;

                _ = arena_instance.reset(.retain_capacity);

                if (self.side_buffer.items.len > 0) {
                    try self.side_buffer.appendSlice(self.allocator, fragment);
                    var line = self.side_buffer.items;
                    if (line.len > 0 and line[line.len - 1] == '\r') {
                        line = line[0 .. line.len - 1];
                    }
                    if (try self.processLine(arena, line, writer, ctx)) {
                        matched_count += 1;
                    }
                    self.side_buffer.clearRetainingCapacity();
                } else {
                    var line = fragment;
                    if (line.len > 0 and line[line.len - 1] == '\r') {
                        line = line[0 .. line.len - 1];
                    }
                    if (try self.processLine(arena, line, writer, ctx)) {
                        matched_count += 1;
                    }
                }
            }

            if (eof) {
                const fragment = data[read_pos..];
                if (self.side_buffer.items.len > 0 or fragment.len > 0) {
                    _ = arena_instance.reset(.retain_capacity);
                    try self.side_buffer.appendSlice(self.allocator, fragment);
                    var line = self.side_buffer.items;
                    if (line.len > 0 and line[line.len - 1] == '\r') {
                        line = line[0 .. line.len - 1];
                    }
                    if (try self.processLine(arena, line, writer, ctx)) {
                        matched_count += 1;
                    }
                    self.side_buffer.clearRetainingCapacity();
                }
                break;
            }

            // Straddle: append remaining to side_buffer
            const straddle = data[read_pos..];
            try self.side_buffer.appendSlice(self.allocator, straddle);

            const max_side_buf = 16 * 1024 * 1024;
            if (self.side_buffer.items.len > max_side_buf) {
                return error.MaxBufferSizeReached;
            }
        }
    }

    pub fn followFile(self: *Processor, file: std.fs.File, writer: anytype, ctx: *const LineContext) !void {
        var pos = try file.getPos();

        var buf = try self.allocator.alloc(u8, 32 * 1024);
        defer self.allocator.free(buf);

        var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();

        while (true) {
            const n = try file.read(buf);
            if (n == 0) {
                // Flush before sleeping to show progress
                if (comptime std.meta.hasMethod(@TypeOf(writer), "flush")) {
                    try writer.flush();
                }
                std.Thread.sleep(100 * std.time.ns_per_ms);
                pos = file.getPos() catch pos;
                continue;
            }
            pos += n;

            var read_pos: usize = 0;
            const data = buf[0..n];

            while (std.mem.indexOfScalarPos(u8, data, read_pos, '\n')) |nl_idx| {
                const fragment = data[read_pos..nl_idx];
                read_pos = nl_idx + 1;

                _ = arena_instance.reset(.retain_capacity);

                if (self.side_buffer.items.len > 0) {
                    try self.side_buffer.appendSlice(self.allocator, fragment);
                    var line = self.side_buffer.items;
                    if (line.len > 0 and line[line.len - 1] == '\r') {
                        line = line[0 .. line.len - 1];
                    }
                    _ = try self.processLine(arena, line, writer, ctx);
                    self.side_buffer.clearRetainingCapacity();
                } else {
                    var line = fragment;
                    if (line.len > 0 and line[line.len - 1] == '\r') {
                        line = line[0 .. line.len - 1];
                    }
                    _ = try self.processLine(arena, line, writer, ctx);
                }
            }

            // Straddle: append remaining to side_buffer
            const straddle = data[read_pos..];
            try self.side_buffer.appendSlice(self.allocator, straddle);

            const max_side_buf = 16 * 1024 * 1024;
            if (self.side_buffer.items.len > max_side_buf) {
                return error.MaxBufferSizeReached;
            }
        }
    }

    /// Returns true if the line was matched and written to output.
    fn processLine(self: *Processor, arena: std.mem.Allocator, line: []const u8, writer: anytype, ctx: *const LineContext) !bool {
        // Phase 1 Filtering: Global Raw String Check
        // If the line fails the global raw excludes or global raw includes, we can drop it immediately.
        if (!try filter_mod.passesRawExcludes(line, ctx.exclude)) return false;
        if (!try filter_mod.passesRawIncludes(line, ctx.include)) return false;

        var entry = (try parser_mod.parseLine(arena, line, ctx.ts_key)) orelse return false;

        // Range filter: checked first against the raw timestamp
        if (ctx.range_filter) |rf| {
            if (entry.timestamp) |ts| {
                // Normalise ms timestamps to seconds
                const ts_secs: i64 = if (ts > 10_000_000_000) @divTrunc(ts, 1000) else ts;

                if (rf.is_time_only and rf.base_date_secs == null) {
                    rf.initBaseDate(ts_secs);
                }

                if (rf.debug and !rf.debug_printed) {
                    rf.debug_printed = true;
                    try self.dumpRangeInfo(arena, ts, rf);
                }

                if (!rf.matches(ts_secs)) return false;
            }
            // If no timestamp field, skip line — we cannot determine if it's in range
            else return false;
        }

        if (self.args.keys) {
            var it = entry.parsed.iterator();
            while (it.next()) |kv| {
                if (!self.all_found_keys.contains(kv.key_ptr.*)) {
                    const k = try self.allocator.dupe(u8, kv.key_ptr.*);
                    try self.all_found_keys.put(k, {});
                }
            }
            return true;
        }

        if (self.args.passthrough) {
            // Phase 2 Filtering: Key-Specific JSON Check
            if (!try filter_mod.passesParsed(line, &entry.parsed, ctx.include, ctx.exclude)) return false;

            // Value inspection overrides regular output
            if (ctx.values_config) |vc| {
                if (entry.parsed.get(vc.key)) |val| {
                    if (try self.handleValue(arena, val, line, &entry, ctx, writer)) return true;
                }
                return true;
            }
            try writer.writeAll(line);
            try writer.writeAll("\n");
            return true;
        }

        // Phase 2 Filtering: Key-Specific JSON Check
        if (!try filter_mod.passesParsed(line, &entry.parsed, ctx.include, ctx.exclude)) return false;

        if (self.formatEntry(arena, &entry, ctx)) |formatted| {
            // No defer free needed due to arena

            // Value inspection overrides regular output
            if (ctx.values_config) |vc| {
                if (entry.parsed.get(vc.key)) |val| {
                    _ = try self.handleValue(arena, val, formatted, &entry, ctx, writer);
                }
                return true;
            }

            try writer.writeAll(formatted);
            try writer.writeAll("\n");
            return true;
        } else |err| {
            try writer.writeAll(line);
            try writer.writeAll("\n");
            if (self.args.verbose) {
                const err_msg = try std.fmt.allocPrint(arena, "[Formatting Error: {}]\n", .{err});
                try writer.writeAll(err_msg);
            }
            return true;
        }
    }

    fn handleValue(self: *Processor, arena: std.mem.Allocator, val_slice: []const u8, formatted: []const u8, entry: *const parser_mod.LogEntry, ctx: *const LineContext, writer: anytype) !bool {
        const val_str = try valueToString(arena, val_slice);

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
                    const dt = try formatTimestamp(arena, ts, ctx.zone_offset_secs, .datetime);
                    try writer.writeAll(dt);
                    try writer.writeAll(" ");
                }
                try writer.writeAll(val_str);
                try writer.writeAll("\n");
            },
            .time => {
                if (entry.timestamp) |ts| {
                    const dt = try formatTimestamp(arena, ts, ctx.zone_offset_secs, .time);
                    try writer.writeAll(dt);
                    try writer.writeAll(" ");
                }
                try writer.writeAll(val_str);
                try writer.writeAll("\n");
            },
            .timems => {
                if (entry.timestamp) |ts| {
                    const dt = try formatTimestamp(arena, ts, ctx.zone_offset_secs, .timems);
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

    fn formatEntry(self: *Processor, arena: std.mem.Allocator, entry: *const parser_mod.LogEntry, ctx: *const LineContext) ![]const u8 {
        var res: []u8 = try arena.dupe(u8, ctx.out_fmt);

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

            var print_kv = false;
            if (key.len > 0 and key[key.len - 1] == '=') {
                print_kv = true;
                key = key[0 .. key.len - 1];
            }

            var actual_key: []const u8 = key;
            if (std.mem.eql(u8, key, "timestamp")) {
                actual_key = if (self.args.profile) |pn| p: {
                    if (ctx.cfg.profiles.get(pn)) |prof| break :p prof.timestamp_key orelse ctx.cfg.timestamp_key;
                    break :p ctx.cfg.timestamp_key;
                } else ctx.cfg.timestamp_key;
            } else if (std.mem.eql(u8, key, "level")) {
                actual_key = if (self.args.profile) |pn| p: {
                    if (ctx.cfg.profiles.get(pn)) |prof| break :p prof.level_key orelse ctx.cfg.level_key;
                    break :p ctx.cfg.level_key;
                } else ctx.cfg.level_key;
            } else if (std.mem.eql(u8, key, "message")) {
                actual_key = if (self.args.profile) |pn| p: {
                    if (ctx.cfg.profiles.get(pn)) |prof| break :p prof.message_key orelse ctx.cfg.message_key;
                    break :p ctx.cfg.message_key;
                } else ctx.cfg.message_key;
            } else if (std.mem.eql(u8, key, "thread")) {
                actual_key = if (self.args.profile) |pn| p: {
                    if (ctx.cfg.profiles.get(pn)) |prof| break :p prof.thread_key orelse ctx.cfg.thread_key;
                    break :p ctx.cfg.thread_key;
                } else ctx.cfg.thread_key;
            } else if (std.mem.eql(u8, key, "logger")) {
                actual_key = if (self.args.profile) |pn| p: {
                    if (ctx.cfg.profiles.get(pn)) |prof| break :p prof.logger_key orelse ctx.cfg.logger_key;
                    break :p ctx.cfg.logger_key;
                } else ctx.cfg.logger_key;
            } else if (std.mem.eql(u8, key, "trace")) {
                actual_key = if (self.args.profile) |pn| p: {
                    if (ctx.cfg.profiles.get(pn)) |prof| break :p prof.trace_key orelse ctx.cfg.trace_key;
                    break :p ctx.cfg.trace_key;
                } else ctx.cfg.trace_key;
            }

            const is_message = std.mem.eql(u8, key, "message");

            var replacement: []const u8 = "";

            if (entry.parsed.get(actual_key)) |val| {
                if (is_message) {
                    if (ctx.message_expand_fn) |expand_fn| {
                        const raw_str = try valueToString(arena, val);
                        replacement = try expand_fn(self, arena, raw_str, &entry.parsed, ctx.zone_offset_secs);
                    } else {
                        replacement = try formatValue(arena, val, spec, ctx.zone_offset_secs);
                    }
                } else {
                    replacement = try formatValue(arena, val, spec, ctx.zone_offset_secs);
                }
            } else if (std.mem.eql(u8, key, "timestamp") and entry.timestamp != null) {
                // Special case: "timestamp" key might have been parsed from a different JSON field
                if (spec) |s| {
                    if (std.mem.eql(u8, s, "datetime") or std.mem.eql(u8, s, "time") or std.mem.eql(u8, s, "timems")) {
                        const fmt_type: TimestampFormat = if (std.mem.eql(u8, s, "datetime")) .datetime else if (std.mem.eql(u8, s, "time")) .time else .timems;
                        replacement = try formatTimestamp(arena, entry.timestamp.?, ctx.zone_offset_secs, fmt_type);
                    } else {
                        const base = try formatTimestamp(arena, entry.timestamp.?, ctx.zone_offset_secs, .timems);
                        replacement = try formatValue(arena, base, spec, ctx.zone_offset_secs);
                    }
                } else {
                    replacement = try formatTimestamp(arena, entry.timestamp.?, ctx.zone_offset_secs, .timems);
                }
            } else if (!std.mem.eql(u8, actual_key, key)) {
                if (entry.parsed.get(key)) |val| {
                    replacement = try formatValue(arena, val, spec, ctx.zone_offset_secs);
                }
            }

            if (print_kv and replacement.len > 0) {
                replacement = try std.fmt.allocPrint(arena, "{s}={s}", .{ key, replacement });
            }

            // Dupe needle
            const needle = try arena.dupe(u8, res[open_idx .. close_idx + 1]);

            const new_res = try replace(arena, res, needle, replacement);
            res = new_res;
            start = open_idx + replacement.len;
        }

        return res;
    }

    fn expandCurly(self: *Processor, arena: std.mem.Allocator, message: []const u8, parsed: *const std.StringHashMap([]const u8), zone_offset_secs: i64) ![]const u8 {
        return self.expandGeneric(arena, message, parsed, "{", "}", zone_offset_secs);
    }

    fn expandJs(self: *Processor, arena: std.mem.Allocator, message: []const u8, parsed: *const std.StringHashMap([]const u8), zone_offset_secs: i64) ![]const u8 {
        return self.expandGeneric(arena, message, parsed, "${", "}", zone_offset_secs);
    }

    fn expandBrackets(self: *Processor, arena: std.mem.Allocator, message: []const u8, parsed: *const std.StringHashMap([]const u8), zone_offset_secs: i64) ![]const u8 {
        return self.expandGeneric(arena, message, parsed, "[", "]", zone_offset_secs);
    }

    fn expandParens(self: *Processor, arena: std.mem.Allocator, message: []const u8, parsed: *const std.StringHashMap([]const u8), zone_offset_secs: i64) ![]const u8 {
        return self.expandGeneric(arena, message, parsed, "(", ")", zone_offset_secs);
    }

    fn expandRuby(self: *Processor, arena: std.mem.Allocator, message: []const u8, parsed: *const std.StringHashMap([]const u8), zone_offset_secs: i64) ![]const u8 {
        return self.expandGeneric(arena, message, parsed, "#{", "}", zone_offset_secs);
    }

    fn expandDoubleCurly(self: *Processor, arena: std.mem.Allocator, message: []const u8, parsed: *const std.StringHashMap([]const u8), zone_offset_secs: i64) ![]const u8 {
        return self.expandGeneric(arena, message, parsed, "{{", "}}", zone_offset_secs);
    }

    fn expandGeneric(self: *Processor, arena: std.mem.Allocator, message: []const u8, parsed: *const std.StringHashMap([]const u8), open_seq: []const u8, close_seq: []const u8, zone_offset_secs: i64) ![]const u8 {
        _ = self;
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
                    const replacement = try formatValue(arena, val, spec, zone_offset_secs);
                    const needle = try arena.dupe(u8, res[open_idx .. close_idx + close_seq.len]);

                    const new_res = try replace(arena, res, needle, replacement);
                    res = new_res;
                    start = open_idx + replacement.len;
                } else {
                    start = close_idx + close_seq.len;
                }
            } else {
                break;
            }
        }
        return res;
    }

    fn expandPrintf(self: *Processor, arena: std.mem.Allocator, message: []const u8, parsed: *const std.StringHashMap([]const u8), zone_offset_secs: i64) ![]const u8 {
        return self.expandAlphanum(arena, message, parsed, '%', zone_offset_secs);
    }

    fn expandEnv(self: *Processor, arena: std.mem.Allocator, message: []const u8, parsed: *const std.StringHashMap([]const u8), zone_offset_secs: i64) ![]const u8 {
        return self.expandAlphanum(arena, message, parsed, '$', zone_offset_secs);
    }

    fn expandColon(self: *Processor, arena: std.mem.Allocator, message: []const u8, parsed: *const std.StringHashMap([]const u8), zone_offset_secs: i64) ![]const u8 {
        return self.expandAlphanum(arena, message, parsed, ':', zone_offset_secs);
    }

    fn expandAlphanum(self: *Processor, arena: std.mem.Allocator, message: []const u8, parsed: *const std.StringHashMap([]const u8), leading_char: u8, zone_offset_secs: i64) ![]const u8 {
        _ = self;
        var res = try arena.dupe(u8, message);

        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, res, start, leading_char)) |open_idx| {
            var i: usize = open_idx + 1;
            while (i < res.len) : (i += 1) {
                const c = res[i];
                if (!std.ascii.isAlphanumeric(c) and c != '_') break;
            }
            if (i > open_idx + 1) {
                const key = res[open_idx + 1 .. i];
                var end_idx = i;
                var spec: ?[]const u8 = null;

                if (i < res.len and res[i] == ':') {
                    var j = i + 1;
                    while (j < res.len) : (j += 1) {
                        const c = res[j];
                        if (!std.ascii.isAlphanumeric(c) and c != '_') break;
                    }
                    if (j > i + 1) {
                        spec = res[i + 1 .. j];
                        end_idx = j;
                    }
                }

                if (parsed.get(key)) |val| {
                    const replacement = try formatValue(arena, val, spec, zone_offset_secs);
                    const needle = try arena.dupe(u8, res[open_idx..end_idx]);
                    const new_res = try replace(arena, res, needle, replacement);
                    res = new_res;
                    start = open_idx + replacement.len;
                } else {
                    start = i;
                }
            } else {
                start = open_idx + 1;
            }
        }
        return res;
    }

    fn formatValue(allocator: std.mem.Allocator, val_slice: []const u8, spec: ?[]const u8, zone_offset_secs: i64) ![]const u8 {
        if (spec) |s| {
            if (std.mem.eql(u8, s, "datetime") or std.mem.eql(u8, s, "time") or std.mem.eql(u8, s, "timems")) {
                if (parser_mod.parseTimestamp(val_slice)) |ts| {
                    const fmt_type: TimestampFormat = if (std.mem.eql(u8, s, "datetime")) .datetime else if (std.mem.eql(u8, s, "time")) .time else .timems;
                    return formatTimestamp(allocator, ts, zone_offset_secs, fmt_type);
                }
            }

            if (std.mem.eql(u8, s, "hex") or std.mem.eql(u8, s, "HEX")) {
                if (std.fmt.parseInt(i64, val_slice, 10)) |num| {
                    if (std.mem.eql(u8, s, "hex")) return std.fmt.allocPrint(allocator, "{x}", .{num});
                    return std.fmt.allocPrint(allocator, "{X}", .{num});
                } else |_| {}
            }
            if (std.mem.eql(u8, s, "2") or std.mem.eql(u8, s, "4")) {
                if (std.fmt.parseFloat(f64, val_slice)) |fnum| {
                    if (std.mem.eql(u8, s, "2")) return std.fmt.allocPrint(allocator, "{d:.2}", .{fnum});
                    return std.fmt.allocPrint(allocator, "{d:.4}", .{fnum});
                } else |_| {}
            }
            if (std.mem.eql(u8, s, "upper")) {
                const str = @constCast(try valueToString(allocator, val_slice));
                for (str) |*c| c.* = std.ascii.toUpper(c.*);
                return str;
            }
            if (std.mem.eql(u8, s, "lower")) {
                const str = @constCast(try valueToString(allocator, val_slice));
                for (str) |*c| c.* = std.ascii.toLower(c.*);
                return str;
            }

            // Fallback: treat numeric spec as right-padding width
            if (std.fmt.parseInt(usize, s, 10)) |width| {
                const base = try valueToString(allocator, val_slice);
                if (base.len < width) {
                    const padded = try allocator.alloc(u8, width);
                    @memcpy(padded[0..base.len], base);
                    @memset(padded[base.len..], ' ');
                    return padded;
                }
                return base;
            } else |_| {}
        }
        return valueToString(allocator, val_slice);
    }

    fn valueToString(allocator: std.mem.Allocator, val_slice: []const u8) ![]const u8 {
        if (val_slice.len >= 2 and val_slice[0] == '"' and val_slice[val_slice.len - 1] == '"') {
            const inner = val_slice[1 .. val_slice.len - 1];
            // Fast path: no backslash → nothing to unescape
            if (std.mem.indexOfScalar(u8, inner, '\\') == null) {
                return try allocator.dupe(u8, inner);
            }
            // Slow path: unescape JSON string escape sequences
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
                            // \uXXXX — emit the 6 chars as-is (UTF-8 handling not needed for stack traces)
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

    fn replace(allocator: std.mem.Allocator, input: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
        const count = std.mem.count(u8, input, needle);
        if (count == 0) return try allocator.dupe(u8, input);

        const new_len = if (replacement.len >= needle.len)
            input.len + (replacement.len - needle.len) * count
        else
            input.len - (needle.len - replacement.len) * count;
        const new_buf = try allocator.alloc(u8, new_len);
        _ = std.mem.replace(u8, input, needle, replacement, new_buf);

        return new_buf;
    }

    fn dumpRangeInfo(self: *Processor, arena: std.mem.Allocator, ts_ms: i64, rf: *const filter_mod.RangeFilter) !void {
        _ = self;
        std.debug.print("\r\x1b[2K", .{}); // Clear current line (in case of progress bar)
        std.debug.print("--- Range Filter Diagnostics (Offset: {d}s) ---\n", .{rf.zone_offset_secs});

        const first_line_fmt = try Processor.formatTimestamp(arena, ts_ms, rf.zone_offset_secs, .datetime);
        const ts_secs = if (ts_ms > 10_000_000_000) @divTrunc(ts_ms, 1000) else ts_ms;
        std.debug.print("First line:  {s} (timestamp: {d})\n", .{ first_line_fmt, ts_secs });

        if (rf.from) |from| {
            const start_secs = switch (from) {
                .utc_secs => |s| s,
                .time_only => |t| if (rf.base_date_secs) |base| base + @as(i64, t.hour) * 3600 + @as(i64, t.minute) * 60 + t.second else ts_secs,
            };
            const start_fmt = try Processor.formatTimestamp(arena, start_secs * 1000, rf.zone_offset_secs, .datetime);
            std.debug.print("Range Start: {s} (timestamp: {d})\n", .{ start_fmt, start_secs });
        } else {
            std.debug.print("Range Start: [open]\n", .{});
        }

        if (rf.to) |to| {
            const end_secs = switch (to) {
                .utc_secs => |s| s,
                .time_only => |t| if (rf.base_date_secs) |base| base + @as(i64, t.hour) * 3600 + @as(i64, t.minute) * 60 + t.second else ts_secs,
            };
            const end_fmt = try Processor.formatTimestamp(arena, end_secs * 1000, rf.zone_offset_secs, .datetime);
            std.debug.print("Range End:   {s} (timestamp: {d})\n", .{ end_fmt, end_secs });
        } else {
            std.debug.print("Range End:   [open]\n", .{});
        }
        std.debug.print("-------------------------------\n", .{});
    }
};

test "Processor.processLine with shared samples" {
    const allocator = std.testing.allocator;
    const fs = std.fs.cwd();

    const file = try fs.openFile("test/processor_samples.json", .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    const Sample = struct {
        name: []const u8,
        config: []const u8,
        args: struct {
            profile: ?[]const u8 = null,
            include: ?[]const u8 = null,
            exclude: ?[]const u8 = null,
            range: ?[]const u8 = null,
            zone: ?[]const u8 = null,
            passthrough: bool = false,
        },
        line: []const u8,
        expected: ?[]const u8,
    };

    const parsed_json = try std.json.parseFromSlice([]Sample, allocator, content, .{ .ignore_unknown_fields = true });
    defer parsed_json.deinit();

    for (parsed_json.value) |sample| {
        var config_arena = std.heap.ArenaAllocator.init(allocator);
        defer config_arena.deinit();
        var cfg = config_mod.Config.init(config_arena.allocator());
        try cfg.parse(sample.config);

        const args = args_mod.Args{
            .profile = sample.args.profile,
            .include = sample.args.include,
            .exclude = sample.args.exclude,
            .range = sample.args.range,
            .zone = sample.args.zone,
            .passthrough = sample.args.passthrough,
        };

        var processor = Processor.init(allocator, args, &cfg);
        defer processor.deinit();
        // Note: buildContext expects self.args.file_path to be null for stdin mode (first folders section)
        var ctx = try processor.buildContext();
        defer ctx.deinit(allocator);

        var arena_instance = std.heap.ArenaAllocator.init(allocator);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();

        var out_buf: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&out_buf);
        const writer = fbs.writer();

        const matched = try processor.processLine(arena, sample.line, writer, &ctx);

        if (sample.expected) |expected| {
            if (!matched) {
                std.debug.print("Sample '{s}' expected match but got none\n", .{sample.name});
                return error.ExpectedMatch;
            }
            // Output includes newline
            const actual = std.mem.trimRight(u8, fbs.getWritten(), "\n\r");
            try std.testing.expectEqualStrings(expected, actual);
        } else {
            if (matched) {
                std.debug.print("Sample '{s}' expected no match but got one: {s}\n", .{ sample.name, fbs.getWritten() });
                return error.ExpectedNoMatch;
            }
        }
    }
}

test "Processor straddle and overflow" {
    const allocator = std.testing.allocator;

    const test_dir = std.testing.tmpDir(.{});
    var tmp_dir = test_dir;
    defer tmp_dir.cleanup();

    // 1. Create a 150KB "line" (no newlines until end)
    const large_line = try allocator.alloc(u8, 150 * 1024);
    defer allocator.free(large_line);
    @memset(large_line, 'A');
    // Make it valid JSON at the beginning and end
    large_line[0] = '{';
    large_line[1] = '"';
    large_line[2] = 'a';
    large_line[3] = '"';
    large_line[4] = ':';
    large_line[5] = '"';
    large_line[large_line.len - 2] = '"';
    large_line[large_line.len - 1] = '}';

    var file = try tmp_dir.dir.createFile("large.txt", .{ .read = true });
    try file.writeAll("{\"msg\":\"short\"}\n");
    try file.writeAll(large_line);
    try file.writeAll("\n{\"msg\":\"end\"}");
    file.close();

    file = try tmp_dir.dir.openFile("large.txt", .{ .mode = .read_only });
    defer file.close();

    var args = @import("args.zig").Args{};
    args.passthrough = true;
    var config = @import("config.zig").Config.init(allocator);
    defer config.deinit();
    try config.folders.append(allocator, .{
        .paths = &[_][]const u8{},
        .profiles = std.StringHashMap(@import("config.zig").Profile).init(allocator),
    });

    var processor = Processor.init(allocator, args, &config);
    defer processor.deinit();

    var out_buf = std.ArrayListUnmanaged(u8){};
    defer out_buf.deinit(allocator);

    var ctx = try processor.buildContext();
    defer ctx.deinit(allocator);

    try processor.processStream(file, out_buf.writer(allocator), &ctx, null);

    try std.testing.expect(out_buf.items.len > 150 * 1024);
}
