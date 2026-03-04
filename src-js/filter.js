/**
 * Regex and literal filtering for jlx.
 * Ported from src/filter.zig
 */

export const FilterType = {
    GLOBAL_LITERAL: 'global_literal',
    GLOBAL_REGEX: 'global_regex',
    KEY_LITERAL: 'key_literal',
    KEY_REGEX: 'key_regex',
};

export class Filter {
    constructor(type, key, text, re) {
        this.type = type;
        this.key = key;
        this.text = text;
        this.re = re;
    }

    static parse(input) {
        let isRe = false;
        let keyPart = null;
        let filterPart = input;

        // Check for "key:value" or "re:value"
        const colonIdx = filterPart.indexOf(':');
        if (colonIdx !== -1) {
            const possibleKey = filterPart.substring(0, colonIdx);
            const possibleVal = filterPart.substring(colonIdx + 1);

            if (possibleKey === "re") {
                isRe = true;
                filterPart = possibleVal;
            } else {
                keyPart = possibleKey;
                filterPart = possibleVal;
                if (filterPart.startsWith("re:")) {
                    isRe = true;
                    filterPart = filterPart.substring(3);
                }
            }
        }

        // Check for ~ prefix
        if (!isRe && filterPart.length > 0 && filterPart[0] === '~') {
            isRe = true;
            filterPart = filterPart.substring(1);
        }

        let type;
        if (keyPart) {
            type = isRe ? FilterType.KEY_REGEX : FilterType.KEY_LITERAL;
        } else {
            type = isRe ? FilterType.GLOBAL_REGEX : FilterType.GLOBAL_LITERAL;
        }

        let re = null;
        if (isRe) {
            try {
                re = new RegExp(filterPart);
            } catch (e) {
                throw new Error(`Invalid regex: ${filterPart}`);
            }
        }

        return new Filter(type, keyPart, isRe ? null : filterPart, re);
    }

    matchesRaw(line) {
        if (this.type === FilterType.GLOBAL_LITERAL) {
            return line.includes(this.text);
        } else if (this.type === FilterType.GLOBAL_REGEX) {
            return this.re.test(line);
        }
        return true; // Ignore key filters in raw pass
    }

    matchesParsed(parsed) {
        if (this.type === FilterType.KEY_LITERAL || this.type === FilterType.KEY_REGEX) {
            if (parsed.has(this.key)) {
                let val = parsed.get(this.key);
                // Strip quotes if it's a string
                if (val.length >= 2 && val[0] === '"' && val[val.length - 1] === '"') {
                    val = val.substring(1, val.length - 1);
                }

                if (this.type === FilterType.KEY_LITERAL) {
                    return val.includes(this.text);
                } else {
                    return this.re.test(val);
                }
            }
            return false;
        }
        return true; // Global filters handled in phase 1
    }
}

export function passesRawExcludes(line, excludes) {
    for (const f of excludes) {
        if (f.type === FilterType.GLOBAL_LITERAL || f.type === FilterType.GLOBAL_REGEX) {
            if (f.matchesRaw(line)) return false;
        }
    }
    return true;
}

export function passesRawIncludes(line, includes) {
    let hasGlobalInclude = false;
    let hasKeyInclude = false;
    for (const f of includes) {
        if (f.type === FilterType.GLOBAL_LITERAL || f.type === FilterType.GLOBAL_REGEX) {
            hasGlobalInclude = true;
        } else {
            hasKeyInclude = true;
        }
    }

    if (hasKeyInclude) return true; // Must parse JSON to determine if it passes
    if (!hasGlobalInclude) return true; // No includes, so everything passes

    for (const f of includes) {
        if (f.type === FilterType.GLOBAL_LITERAL || f.type === FilterType.GLOBAL_REGEX) {
            if (f.matchesRaw(line)) return true;
        }
    }
    return false;
}

export function passesParsed(line, parsed, includes, excludes) {
    // Check key-specific excludes
    for (const f of excludes) {
        if (f.type === FilterType.KEY_LITERAL || f.type === FilterType.KEY_REGEX) {
            if (f.matchesParsed(parsed)) return false;
        }
    }

    if (includes.length === 0) return true;

    // Check includes (at least one must match)
    for (const f of includes) {
        if (f.type === FilterType.GLOBAL_LITERAL || f.type === FilterType.GLOBAL_REGEX) {
            if (f.matchesRaw(line)) return true;
        } else if (f.type === FilterType.KEY_LITERAL || f.type === FilterType.KEY_REGEX) {
            if (f.matchesParsed(parsed)) return true;
        }
    }
    return false;
}

// Range filtering logic
export class RangeFilter {
    constructor(from, to, zoneOffsetSecs) {
        this.from = from;
        this.to = to;
        this.zoneOffsetSecs = zoneOffsetSecs;
    }

    static parse(text, zoneOffsetSecs) {
        if (!text.includes("..")) return null;
        const parts = text.split("..");

        const fromStr = parts[0].trim();
        const toStr = parts[1].trim();

        return new RangeFilter(
            fromStr ? parseBound(fromStr, zoneOffsetSecs) : null,
            toStr ? parseBound(toStr, zoneOffsetSecs) : null,
            zoneOffsetSecs
        );
    }

    matches(tsSecs) {
        if (this.from && !checkBound(this.from, tsSecs, this.zoneOffsetSecs, "from")) return false;
        if (this.to && !checkBound(this.to, tsSecs, this.zoneOffsetSecs, "to")) return false;
        return true;
    }
}

function parseBound(text, zoneOffsetSecs) {
    if (text.length >= 8 && text[4] === '-') {
        return { type: 'utc_secs', val: parseDatetime(text, zoneOffsetSecs) };
    }
    return { type: 'time_only', val: parseTimeOnly(text) };
}

function parseTimeOnly(text) {
    const parts = text.split(':');
    return {
        hour: parseInt(parts[0], 10),
        minute: parseInt(parts[1], 10),
        second: parts[2] ? parseInt(parts[2], 10) : 0
    };
}

function parseDatetime(text, zoneOffsetSecs) {
    const dateStr = text.replace('T', ' ');
    const d = new Date(dateStr + "Z"); // Treat as UTC first
    if (isNaN(d.getTime())) throw new Error(`Invalid datetime: ${text}`);

    // Convert from local (as parsed) to UTC by subtracting zone offset
    return Math.floor(d.getTime() / 1000) - zoneOffsetSecs;
}

function checkBound(bound, tsSecs, zoneOffsetSecs, side) {
    if (bound.type === 'utc_secs') {
        const res = side === 'from' ? tsSecs >= bound.val : tsSecs <= bound.val;
        return res;
    } else {
        // Shift log timestamp to local time
        const local = Number(tsSecs) + Number(zoneOffsetSecs);
        const daySec = ((local % 86400) + 86400) % 86400;
        const boundSec = bound.val.hour * 3600 + bound.val.minute * 60 + bound.val.second;
        const res = side === 'from' ? daySec >= boundSec : daySec <= boundSec;
        return res;
    }
}

export function parseZoneOffset(zone) {
    if (!zone) return 0;
    const s = zone.trim();
    if (s === "" || s === "UTC" || s === "Z") return 0;
    if (s[0] !== '+' && s[0] !== '-') throw new Error("Invalid zone");

    const sign = s[0] === '+' ? 1 : -1;
    const parts = s.substring(1).split(':');
    const h = parseInt(parts[0], 10);
    const m = parts[1] ? parseInt(parts[1], 10) : 0;
    return sign * (h * 3600 + m * 60);
}
