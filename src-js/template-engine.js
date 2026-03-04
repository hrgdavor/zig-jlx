/**
 * Core string interpolation and formatting.
 * Ported from src/template_engine.zig and processor.zig (formatting section)
 */

export function replaceAll(payload, needle, replacement) {
    if (!needle) return payload;
    return payload.split(needle).join(replacement);
}

export function expandGeneric(message, parsed, openSeq, closeSeq) {
    let res = message;
    let start = 0;
    while (true) {
        const openIdx = res.indexOf(openSeq, start);
        if (openIdx === -1) break;

        const closeIdx = res.indexOf(closeSeq, openIdx + openSeq.length);
        if (closeIdx === -1) {
            start = openIdx + 1;
            continue;
        }

        const rawKey = res.substring(openIdx + openSeq.length, closeIdx);
        const parts = rawKey.split(':');
        const key = parts[0];
        const spec = parts[1] || null;

        if (parsed.has(key)) {
            const val = parsed.get(key);
            const replacement = formatValue(val, spec);
            const needle = res.substring(openIdx, closeIdx + closeSeq.length);
            res = replaceAll(res, needle, replacement);
            start = openIdx + replacement.length;
        } else {
            start = closeIdx + closeSeq.length;
        }
    }
    return res;
}

export function formatValue(valSlice, spec) {
    let val = valSlice;
    // Strip quotes if it's a string
    if (val.length >= 2 && val[0] === '"' && val[val.length - 1] === '"') {
        val = val.substring(1, val.length - 1);
    }

    if (spec) {
        if (spec === "hex" || spec === "HEX") {
            const num = parseInt(val, 10);
            if (!isNaN(num)) {
                return spec === "hex" ? num.toString(16) : num.toString(16).toUpperCase();
            }
        }
        if (spec === "2" || spec === "4") {
            const num = parseFloat(val);
            if (!isNaN(num)) {
                return num.toFixed(parseInt(spec, 10));
            }
        }
        if (spec === "datetime" || spec === "time" || spec === "timems") {
            let num = parseInt(val, 10);
            if (!isNaN(num)) {
                // 10-digit = seconds, 13-digit = milliseconds
                if (num > 0 && num < 10000000000) num *= 1000;
                const d = new Date(num);
                if (spec === "datetime") {
                    return d.getFullYear() + "-" +
                        String(d.getMonth() + 1).padStart(2, '0') + "-" +
                        String(d.getDate()).padStart(2, '0') + " " +
                        String(d.getHours()).padStart(2, '0') + ":" +
                        String(d.getMinutes()).padStart(2, '0') + ":" +
                        String(d.getSeconds()).padStart(2, '0');
                } else if (spec === "time") {
                    return String(d.getHours()).padStart(2, '0') + ":" +
                        String(d.getMinutes()).padStart(2, '0') + ":" +
                        String(d.getSeconds()).padStart(2, '0');
                } else {
                    return String(d.getHours()).padStart(2, '0') + ":" +
                        String(d.getMinutes()).padStart(2, '0') + ":" +
                        String(d.getSeconds()).padStart(2, '0') + "." +
                        String(d.getMilliseconds()).padStart(3, '0');
                }
            }
        }
        if (spec === "upper") return val.toUpperCase();
        if (spec === "lower") return val.toLowerCase();

        const width = parseInt(spec, 10);
        if (!isNaN(width)) {
            return val.padEnd(width);
        }
    }
    return val;
}

export const expanders = {
    curly: (msg, parsed) => expandGeneric(msg, parsed, "{", "}"),
    js: (msg, parsed) => expandGeneric(msg, parsed, "${", "}"),
    brackets: (msg, parsed) => expandGeneric(msg, parsed, "[", "]"),
    parens: (msg, parsed) => expandGeneric(msg, parsed, "(", ")"),
    printf: (msg, parsed) => expandAlphanum(msg, parsed, "%"),
    ruby: (msg, parsed) => expandGeneric(msg, parsed, "#{", "}"),
    double_curly: (msg, parsed) => expandGeneric(msg, parsed, "{{", "}}"),
    env: (msg, parsed) => expandAlphanum(msg, parsed, "$"),
    colon: (msg, parsed) => expandAlphanum(msg, parsed, ":"),
};

function expandAlphanum(message, parsed, leadingChar) {
    let res = message;
    let start = 0;
    while (true) {
        const openIdx = res.indexOf(leadingChar, start);
        if (openIdx === -1) break;

        let i = openIdx + 1;
        while (i < res.length) {
            const c = res[i];
            if (!(/[a-zA-Z0-9_]/.test(c))) break;
            i++;
        }

        if (i > openIdx + 1) {
            const key = res.substring(openIdx + 1, i);
            let endIdx = i;
            let spec = null;

            if (i < res.length && res[i] === ':') {
                let j = i + 1;
                while (j < res.length) {
                    if (!(/[a-zA-Z0-9_]/.test(res[j]))) break;
                    j++;
                }
                if (j > i + 1) {
                    spec = res.substring(i + 1, j);
                    endIdx = j;
                }
            }

            if (parsed.has(key)) {
                const val = parsed.get(key);
                const replacement = formatValue(val, spec);
                const needle = res.substring(openIdx, endIdx);
                res = replaceAll(res, needle, replacement);
                start = openIdx + replacement.length;
            } else {
                start = i;
            }
        } else {
            start = openIdx + 1;
        }
    }
    return res;
}
