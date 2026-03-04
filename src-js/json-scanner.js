/**
 * A fast, zero-allocation JSON scanner for top-level key-value extraction.
 * Ported from src/json_scanner.zig
 */

export function skipWhitespace(text, start) {
    let i = start;
    while (i < text.length) {
        const c = text[i];
        if (c !== ' ' && c !== '\t' && c !== '\r' && c !== '\n') break;
        i++;
    }
    return i;
}

/**
 * Finds the end index of a JSON string literal starting at `start`.
 * `start` must point to the opening quote `"` character.
 */
export function scanStringEnd(text, start) {
    let i = start + 1;
    while (i < text.length) {
        if (text[i] === '"') {
            return i + 1;
        } else if (text[i] === '\\') {
            i += 2;
        } else {
            i += 1;
        }
    }
    return i;
}

/**
 * Finds the end index of a JSON object or array starting at `start`.
 */
export function scanObjectOrArrayEnd(text, start) {
    const openChar = text[start];
    const closeChar = openChar === '{' ? '}' : ']';
    let depth = 1;
    let i = start + 1;

    while (i < text.length) {
        const c = text[i];
        if (c === '"') {
            i = scanStringEnd(text, i);
        } else if (c === openChar) {
            depth += 1;
            i += 1;
        } else if (c === closeChar) {
            depth -= 1;
            if (depth === 0) {
                return i + 1;
            }
            i += 1;
        } else {
            i += 1;
        }
    }
    return i;
}

/**
 * Finds the end index of a JSON primitive (number, boolean, null).
 */
export function scanPrimitiveEnd(text, start) {
    let i = start;
    while (i < text.length) {
        const c = text[i];
        if (c === ',' || c === '}' || c === ' ' || c === '\r' || c === '\n' || c === '\t') {
            return i;
        }
        i++;
    }
    return i;
}

/**
 * Identifies top-level key-value pairs in a JSON object.
 * Returns a Map of raw string values.
 */
export function scanTopLevelJson(jsonText) {
    if (jsonText.length < 2 || jsonText[0] !== '{') return null;

    const parsed = new Map();
    let i = 1;
    while (i < jsonText.length) {
        i = skipWhitespace(jsonText, i);
        if (i >= jsonText.length || jsonText[i] === '}') break;

        if (jsonText[i] !== '"') return null;

        const keyRawStart = i;
        const keyRawEnd = scanStringEnd(jsonText, keyRawStart);
        if (keyRawEnd <= keyRawStart + 1 || jsonText[keyRawEnd - 1] !== '"') return null;

        const key = jsonText.substring(keyRawStart + 1, keyRawEnd - 1);
        i = keyRawEnd;

        i = skipWhitespace(jsonText, i);
        if (i >= jsonText.length || jsonText[i] !== ':') return null;
        i += 1;

        i = skipWhitespace(jsonText, i);
        if (i >= jsonText.length) return null;

        const valStart = i;
        let valEnd = i;

        if (jsonText[i] === '"') {
            valEnd = scanStringEnd(jsonText, valStart);
        } else if (jsonText[i] === '{' || jsonText[i] === '[') {
            valEnd = scanObjectOrArrayEnd(jsonText, valStart);
        } else {
            valEnd = scanPrimitiveEnd(jsonText, valStart);
        }

        if (valEnd === valStart) return null;
        i = valEnd;

        parsed.set(key, jsonText.substring(valStart, valEnd));

        i = skipWhitespace(jsonText, i);
        if (i < jsonText.length && jsonText[i] === ',') i += 1;
    }

    return parsed;
}
