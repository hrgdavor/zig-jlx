import { expect, test, describe } from "bun:test";
import { scanTopLevelJson } from "../json-scanner.js";
import fs from "fs";
import path from "path";

describe("JSON Scanner Parity", () => {
    const samplesPath = path.resolve(import.meta.dir, "../../test/parser_samples.json");
    const samples = JSON.parse(fs.readFileSync(samplesPath, "utf-8"));

    for (const sample of samples) {
        test(sample.name, () => {
            const line = sample.line;
            const jsonStart = line.indexOf('{');
            const jsonText = line.substring(jsonStart).trim();

            const parsed = scanTopLevelJson(jsonText);
            expect(parsed).not.toBeNull();

            for (const [key, expectedVal] of Object.entries(sample.expected)) {
                expect(parsed.get(key)).toBe(expectedVal);
            }
        });
    }
});
