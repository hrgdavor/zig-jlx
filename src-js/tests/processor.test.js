import { expect, test, describe } from "bun:test";
import { Config } from "../config.js";
import { Processor } from "../processor.js";
import fs from "fs";
import path from "path";

describe("Processor Parity", () => {
    const samplesPath = path.resolve(import.meta.dir, "../../test/processor_samples.json");
    const samples = JSON.parse(fs.readFileSync(samplesPath, "utf-8"));

    for (const sample of samples) {
        test(sample.name, async () => {
            const config = new Config();
            config.parse(sample.config);

            const args = {
                profile: sample.args.profile || null,
                include: sample.args.include || null,
                exclude: sample.args.exclude || null,
                range: sample.args.range || null,
                zone: sample.args.zone || "UTC",
                passthrough: sample.args.passthrough || false
            };

            const processor = new Processor(args, config);
            await processor.buildContext();

            const output = processor.processLine(sample.line);
            expect(output).toBe(sample.expected);
        });
    }
});
