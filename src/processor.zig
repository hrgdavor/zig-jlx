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
    range_filter: ?filter_mod.RangeFilter,
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
    config: config_mod.Config,
    /// Track seen values for the -v option.
    seen_values: std.StringHashMap(void),
    /// Unique keys found during --keys run
    all_found_keys: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator, args: args_mod.Args, config: config_mod.Config) Processor {
        return .{
            .allocator = allocator,
            .args = args,
            .config = config,
            .seen_values = std.StringHashMap(void).init(allocator),
            .all_found_keys = std.StringHashMap(void).init(allocator),
        };
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

    /// Resolve folder config, apply profile overrides, and build filter lists.
    /// The returned LineContext owns the filter slices; call deinit when done.
    pub fn buildContext(self: *Processor) !LineContext {
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
            .message_expand_fn = msg_expand_fn,
            .include = try include_list.toOwnedSlice(self.allocator),
            .exclude = try exclude_list.toOwnedSlice(self.allocator),
            .range_filter = range_filter,
            .zone_offset_secs = zone_offset_secs,
            .values_config = values_config,
        };
    }

    pub fn processStream(self: *Processor, file: std.fs.File, writer: anytype, ctx: *const LineContext, limit: ?usize) !void {
        var buf = try self.allocator.alloc(u8, 1024 * 1024);
        defer self.allocator.free(buf);

        var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();

        var read_pos: usize = 0;
        var write_pos: usize = 0;
        var eof = false;
        var matched_count: usize = 0;

        while (true) {
            if (limit) |l| if (matched_count >= l) break;

            while (std.mem.indexOfScalarPos(u8, buf[0..write_pos], read_pos, '\n')) |nl_offset| {
                if (limit) |l| if (matched_count >= l) break;

                _ = arena_instance.reset(.retain_capacity);
                var line = buf[read_pos..nl_offset];
                if (line.len > 0 and line[line.len - 1] == '\r') {
                    line = line[0 .. line.len - 1];
                }
                if (try self.processLine(arena, line, writer, ctx)) {
                    matched_count += 1;
                }
                read_pos = nl_offset + 1;
            }
            if (limit) |l| if (matched_count >= l) break;

            if (eof) {
                if (read_pos < write_pos) {
                    if (limit == null or matched_count < limit.?) {
                        _ = arena_instance.reset(.retain_capacity);
                        var line = buf[read_pos..write_pos];
                        if (line.len > 0 and line[line.len - 1] == '\r') {
                            line = line[0 .. line.len - 1];
                        }
                        if (try self.processLine(arena, line, writer, ctx)) {
                            matched_count += 1;
                        }
                    }
                }
                break;
            }

            const unread_len = write_pos - read_pos;
            if (read_pos > 0 and unread_len > 0) {
                std.mem.copyForwards(u8, buf[0..unread_len], buf[read_pos..write_pos]);
                read_pos = 0;
                write_pos = unread_len;
            } else if (read_pos > 0) {
                read_pos = 0;
                write_pos = 0;
            }

            if (write_pos == buf.len) {
                const max_buf_size = 16 * 1024 * 1024;
                if (buf.len >= max_buf_size) {
                    if (self.args.verbose) {
                        try writer.writeAll("[Error: Line exceeded maximum buffer size of 16MB. Skipping...]\n");
                    }

                    var skipped = false;
                    while (true) {
                        const n = try file.read(buf[0..buf.len]);
                        if (n == 0) {
                            eof = true;
                            break;
                        }
                        if (std.mem.indexOfScalar(u8, buf[0..n], '\n')) |nl_idx| {
                            const remaining = n - (nl_idx + 1);
                            if (remaining > 0) {
                                std.mem.copyForwards(u8, buf[0..remaining], buf[nl_idx + 1 .. n]);
                            }
                            read_pos = 0;
                            write_pos = remaining;
                            skipped = true;
                            break;
                        }
                    }
                    if (eof and !skipped) break;
                    continue;
                }

                var new_cap = buf.len * 2;
                if (new_cap > max_buf_size) new_cap = max_buf_size;
                buf = try self.allocator.realloc(buf, new_cap);
            }

            const n = try file.read(buf[write_pos..]);
            if (n == 0) {
                eof = true;
            } else {
                write_pos += n;
            }
        }
    }

    pub fn followFile(self: *Processor, file: std.fs.File, writer: anytype, ctx: *const LineContext) !void {
        var pos = try file.getPos();

        var buf = try self.allocator.alloc(u8, 1024 * 1024);
        defer self.allocator.free(buf);

        var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();

        var read_pos: usize = 0;
        var write_pos: usize = 0;

        while (true) {
            while (std.mem.indexOfScalarPos(u8, buf[0..write_pos], read_pos, '\n')) |nl_offset| {
                _ = arena_instance.reset(.retain_capacity);
                var line = buf[read_pos..nl_offset];
                if (line.len > 0 and line[line.len - 1] == '\r') {
                    line = line[0 .. line.len - 1];
                }
                _ = try self.processLine(arena, line, writer, ctx);
                read_pos = nl_offset + 1;
            }

            // Flush after each batch of lines for live-view responsiveness
            if (comptime std.meta.hasMethod(@TypeOf(writer), "flush")) {
                try writer.flush();
            }

            const unread_len = write_pos - read_pos;
            if (read_pos > 0 and unread_len > 0) {
                std.mem.copyForwards(u8, buf[0..unread_len], buf[read_pos..write_pos]);
                read_pos = 0;
                write_pos = unread_len;
            } else if (read_pos > 0) {
                read_pos = 0;
                write_pos = 0;
            }

            if (write_pos == buf.len) {
                const max_buf_size = 16 * 1024 * 1024;
                if (buf.len >= max_buf_size) {
                    if (self.args.verbose) {
                        try writer.writeAll("[Error: Line exceeded maximum buffer size of 16MB. Skipping...]\n");
                    }

                    var skipped = false;
                    while (!skipped) {
                        const n = try file.read(buf[0..buf.len]);
                        if (n == 0) {
                            std.Thread.sleep(100 * std.time.ns_per_ms);
                            pos = file.getPos() catch pos;
                            continue;
                        }
                        pos += n;
                        if (std.mem.indexOfScalar(u8, buf[0..n], '\n')) |nl_idx| {
                            const remaining = n - (nl_idx + 1);
                            if (remaining > 0) {
                                std.mem.copyForwards(u8, buf[0..remaining], buf[nl_idx + 1 .. n]);
                            }
                            read_pos = 0;
                            write_pos = remaining;
                            skipped = true;
                        }
                    }
                    continue;
                }

                var new_cap = buf.len * 2;
                if (new_cap > max_buf_size) new_cap = max_buf_size;
                buf = try self.allocator.realloc(buf, new_cap);
            }

            const n = try file.read(buf[write_pos..]);
            if (n == 0) {
                std.Thread.sleep(100 * std.time.ns_per_ms);
                pos = file.getPos() catch pos;
            } else {
                write_pos += n;
                pos += n;
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
            return try allocator.dupe(u8, val_slice[1 .. val_slice.len - 1]);
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
};
