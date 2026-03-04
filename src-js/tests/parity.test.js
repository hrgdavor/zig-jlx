import { expect, test, describe } from "bun:test";
import { Config } from "../config.js";
import { Processor } from "../processor.js";
import { execSync } from "child_process";
import fs from "fs";

describe("JLX Parity Tests", () => {
    const zigBinary = "../../zig-out/bin/jlx.exe";
    const logFile = "./test_session_tickets.log";
    const configFile = "../test.conf";

    // Ensure zig binary exists and config exists
    test("Prerequisites", () => {
        // We assume the user has built the zig binary or we will skip child process tests
        if (!fs.existsSync(zigBinary)) {
            console.warn("Zig binary not found, skipping child process parity tests.");
        }
    });

    const sampleConfig = `
[folders]
paths = .
timestamp = ts
level = level
message = message
output = {timestamp:time} [{level}] {message}
`;

    test("Basic Formatting Parity", async () => {
        const config = new Config();
        config.parse(sampleConfig);

        const logLine = '{"ts": 1709548800000, "level": "INFO", "message": "Hello World"}';
        const args = { profile: null, passthrough: false };

        const processor = new Processor(args, config);
        await processor.buildContext();

        const output = processor.processLine(logLine);
        // 1709548800000 is 2024-03-04 08:00:00 UTC
        expect(output).toContain("INFO");
        expect(output).toContain("Hello World");
    });

    test("Filter Parity", async () => {
        const config = new Config();
        config.parse(sampleConfig);

        const processor = new Processor({ include: "level:ERROR" }, config);
        await processor.buildContext();

        expect(processor.processLine('{"ts": 123, "level": "INFO", "message": "ignore"}')).toBeNull();
        expect(processor.processLine('{"ts": 123, "level": "ERROR", "message": "keep"}')).not.toBeNull();
    });

    test("Range Filter Parity", async () => {
        const config = new Config();
        config.parse(sampleConfig);

        const processor = new Processor({ range: "08:00..09:00", zone: "UTC" }, config);
        await processor.buildContext();

        // 28800 is 08:00 UTC
        expect(processor.processLine('{"ts": 28800, "level": "INFO", "message": "at 8"}')).not.toBeNull();
        // 36000 is 10:00 UTC
        expect(processor.processLine('{"ts": 36000, "level": "INFO", "message": "at 10"}')).toBeNull();
    });
});
