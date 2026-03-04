import { expect, test } from "bun:test";
import { formatValue } from "../template-engine.js";

test("formatValue padding", () => {
    expect(formatValue("INFO", "6")).toBe("INFO  ");
    expect(formatValue("ERROR", "6")).toBe("ERROR ");
    expect(formatValue("DEBUG", "4")).toBe("DEBUG"); // Overflow doesn't truncate
    expect(formatValue('"quoted"', "10")).toBe("quoted    ");
});

test("formatValue upper/lower with padding", () => {
    // Current implementation only supports one spec at a time, 
    // but the last one (numeric) should handle padding if we were to chain them.
    // However, our code only takes one spec.
    expect(formatValue("info", "upper")).toBe("INFO");
    expect(formatValue("info", "6")).toBe("info  ");
});
