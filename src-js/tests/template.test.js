import { test, describe, expect } from "bun:test";
import { readFileSync } from "fs";
import { expandGeneric, expanders, formatValue } from "../template-engine.js";
import { resolve } from "path";

const samplesPath = resolve(import.meta.dir, "../../test/template_samples.json");
const samples = JSON.parse(readFileSync(samplesPath, "utf8"));

function runExpander(expander, template, vars) {
    const parsed = new Map(Object.entries(vars));
    switch (expander) {
        case "curly": return expanders.curly(template, parsed);
        case "js": return expanders.js(template, parsed);
        case "double_curly": return expanders.double_curly(template, parsed);
        case "brackets": return expanders.brackets(template, parsed);
        case "ruby": return expanders.ruby(template, parsed);
        default: throw new Error(`Unknown expander: ${expander}`);
    }
}

describe("Template Engine Parity", () => {
    for (const sample of samples) {
        test(sample.name, () => {
            const actual = runExpander(sample.expander, sample.template, sample.vars);
            expect(actual).toBe(sample.expected);
        });
    }
});
