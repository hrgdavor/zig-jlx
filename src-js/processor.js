import { scanTopLevelJson } from './json-scanner.js';
import { passesRawExcludes, passesRawIncludes, passesParsed, RangeFilter, parseZoneOffset, Filter } from './filter.js';
import { expanders, formatValue, replaceAll } from './template-engine.js';

export class Processor {
    constructor(args, config) {
        this.args = args;
        this.config = config;
        this.ctx = null;
    }

    /**
     * Builds the processing context (filters, formatters, etc.)
     */
    async buildContext() {
        // Porting buildContext from processor.zig
        const folders = this.config.folders;
        let cfg = folders.length > 0 ? folders[0] : null;

        // Simplification for JS version: use the first folder config if available.
        // In a real CLI would match path, but here we focus on logic.

        let ts_key = cfg?.timestamp_key || "ts";
        let out_fmt = cfg?.output_format || "{timestamp} {level} {message}";
        let msg_expand = cfg?.message_expand || null;

        if (this.args.profile && cfg) {
            const p = cfg.profiles.get(this.args.profile);
            if (p) {
                if (p.output_format) out_fmt = p.output_format;
                if (p.timestamp_key) ts_key = p.timestamp_key;
                if (p.message_expand) msg_expand = p.message_expand;
            }
        }

        const msg_expand_fn = msg_expand ? expanders[msg_expand] : null;

        const includes = [];
        const excludes = [];

        if (cfg) {
            cfg.include_filters.forEach(s => includes.push(Filter.parse(s)));
            cfg.exclude_filters.forEach(s => excludes.push(Filter.parse(s)));

            if (this.args.profile) {
                const p = cfg.profiles.get(this.args.profile);
                if (p) {
                    p.include_filters.forEach(s => includes.push(Filter.parse(s)));
                    p.exclude_filters.forEach(s => excludes.push(Filter.parse(s)));
                }
            }
        }

        if (this.args.include) includes.push(Filter.parse(this.args.include));
        if (this.args.exclude) excludes.push(Filter.parse(this.args.exclude));

        const zone_offset_secs = parseZoneOffset(this.args.zone);
        const range_filter = this.args.range ? RangeFilter.parse(this.args.range, zone_offset_secs) : null;

        this.ctx = {
            cfg,
            ts_key,
            out_fmt,
            msg_expand_fn,
            includes,
            excludes,
            zone_offset_secs,
            range_filter,
        };
    }

    /**
     * Processes a single log line.
     * Returns the formatted string or null if filtered.
     */
    processLine(line) {
        if (!this.ctx) throw new Error("Context not built. Call buildContext() first.");

        // Phase 1 Filtering
        if (!passesRawExcludes(line, this.ctx.excludes)) return null;
        if (!passesRawIncludes(line, this.ctx.includes)) return null;

        const parsed = scanTopLevelJson(line);
        if (!parsed) return line; // Not JSON or malformed, return as-is

        // Range Filter
        if (this.ctx.range_filter) {
            const tsVal = parsed.get(this.ctx.ts_key);
            if (tsVal) {
                let tsRaw = tsVal;
                if (tsRaw[0] === '"') tsRaw = tsRaw.substring(1, tsRaw.length - 1);
                let tsNum = parseFloat(tsRaw);
                if (!isNaN(tsNum)) {
                    // Normalize ms to s
                    if (tsNum > 10000000000) tsNum = Math.floor(tsNum / 1000);
                    if (!this.ctx.range_filter.matches(tsNum)) return null;
                }
            } else {
                return null; // Cannot determine range
            }
        }

        // Phase 2 Filtering
        if (!passesParsed(line, parsed, this.ctx.includes, this.ctx.excludes)) return null;

        if (this.args.passthrough) return line;

        // Formatting
        try {
            return this.formatEntry(parsed);
        } catch (e) {
            if (this.args.verbose) {
                return `${line}\n[Formatting Error: ${e.message}]`;
            }
            return line;
        }
    }

    formatEntry(parsed) {
        let res = this.ctx.out_fmt;
        let start = 0;

        while (true) {
            const openIdx = res.indexOf('{', start);
            if (openIdx === -1) break;

            const closeIdx = res.indexOf('}', openIdx + 1);
            if (closeIdx === -1) {
                start = openIdx + 1;
                continue;
            }

            const placeholder = res.substring(openIdx + 1, closeIdx);
            let parts = placeholder.split(':');
            let key = parts[0];
            let spec = parts[1] || null;

            let printKv = false;
            if (key.endsWith('=')) {
                printKv = true;
                key = key.substring(0, key.length - 1);
            }

            let actualKey = key;
            // Handle special keys mapping back to config-defined keys
            if (["timestamp", "level", "message", "thread", "logger", "trace"].includes(key)) {
                const cfg = this.ctx.cfg;
                const profile = this.args.profile ? cfg?.profiles.get(this.args.profile) : null;

                const fallbackKey = cfg ? cfg[`${key}_key`] : null;
                actualKey = profile ? (profile[`${key}_key`] || fallbackKey) : (fallbackKey || key);
            }

            const isMessage = key === "message";
            let replacement = "";

            if (key === "timestamp" && spec && ["datetime", "time", "timems"].includes(spec)) {
                const tsVal = parsed.get(actualKey);
                if (tsVal) {
                    let tsRaw = tsVal;
                    if (tsRaw[0] === '"') tsRaw = tsRaw.substring(1, tsRaw.length - 1);
                    let tsNum = parseFloat(tsRaw);
                    if (!isNaN(tsNum)) {
                        replacement = this.formatTimestamp(tsNum, spec);
                    }
                }
            } else {
                if (parsed.has(actualKey)) {
                    let val = parsed.get(actualKey);
                    if (isMessage && this.ctx.msg_expand_fn) {
                        const rawStr = formatValue(val, null);
                        replacement = this.ctx.msg_expand_fn(rawStr, parsed);
                    } else {
                        replacement = formatValue(val, null); // No spec here, spec is for template expansion maybe?
                        // Actually, the Zig version uses spec in template engine but here we use it in formatEntry too.
                        if (spec) replacement = formatValue(val, spec);
                    }
                } else if (actualKey !== key && parsed.has(key)) {
                    replacement = formatValue(parsed.get(key), spec);
                }
            }

            if (printKv && replacement !== "") {
                replacement = `${key}=${replacement}`;
            }

            const needle = res.substring(openIdx, closeIdx + 1);
            res = replaceAll(res, needle, replacement);
            start = openIdx + replacement.length;
        }

        return res;
    }

    formatTimestamp(ts, type) {
        // Simple mock formatting for now, can be expanded with Intl.DateTimeFormat
        const date = new Date(ts > 10000000000 ? ts : ts * 1000);
        // Applying zone offset (approximate)
        const localTime = date.getTime() + (this.ctx.zone_offset_secs * 1000);
        const d = new Date(localTime);

        const iso = d.toISOString().replace('Z', '');
        if (type === 'datetime') return iso.split('.')[0].replace('T', ' ');
        if (type === 'time') return iso.split('T')[1].split('.')[0];
        if (type === 'timems') return iso.split('T')[1];
        return iso;
    }
}
