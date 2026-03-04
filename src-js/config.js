/**
 * Simple INI-style configuration parser for jlx.
 * Ported from src/config.zig
 */

export class Profile {
    constructor(name) {
        this.name = name;
        this.output_format = null;
        this.timestamp_key = null;
        this.level_key = null;
        this.message_key = null;
        this.thread_key = null;
        this.logger_key = null;
        this.trace_key = null;
        this.message_expand = null;
        this.include_filters = [];
        this.exclude_filters = [];
    }
}

export class FolderConfig {
    constructor() {
        this.paths = [];
        this.timestamp_key = "ts";
        this.level_key = "level";
        this.message_key = "message";
        this.thread_key = "thread";
        this.logger_key = "logger";
        this.trace_key = "trace";
        this.message_expand = null;
        this.output_format = "{timestamp} {level} {message}";
        this.profiles = new Map();
        this.include_filters = [];
        this.exclude_filters = [];
    }
}

export class Config {
    constructor() {
        this.folders = [];
    }

    /**
     * Parses the configuration from a string content.
     */
    parse(content) {
        const lines = content.split('\n');
        let currentFolder = null;
        let currentProfile = null;

        for (const line of lines) {
            const trimmed = line.trim();
            if (trimmed.length === 0 || trimmed[0] === ';') continue;

            if (trimmed === "[folders]") {
                currentFolder = new FolderConfig();
                this.folders.push(currentFolder);
                currentProfile = null;
            } else if (trimmed.startsWith("[profile.") && trimmed.endsWith("]")) {
                if (currentFolder) {
                    const pname = trimmed.substring(9, trimmed.length - 1);
                    currentProfile = new Profile(pname);
                    currentFolder.profiles.set(pname, currentProfile);
                }
            } else if (currentFolder) {
                const idx = trimmed.indexOf('=');
                if (idx !== -1) {
                    const key = trimmed.substring(0, idx).trim();
                    const val = trimmed.substring(idx + 1).trim();

                    const target = currentProfile || currentFolder;

                    if (key === "paths") {
                        currentFolder.paths = val.split(',').map(s => s.trim());
                    } else if (key === "timestamp") {
                        target.timestamp_key = val;
                    } else if (key === "level") {
                        target.level_key = val;
                    } else if (key === "message") {
                        target.message_key = val;
                    } else if (key === "message_expand") {
                        target.message_expand = val;
                    } else if (key === "output") {
                        target.output_format = val;
                    } else if (key === "include") {
                        target.include_filters = val.split(',').map(s => s.trim()).filter(s => s.length > 0);
                    } else if (key === "exclude") {
                        target.exclude_filters = val.split(',').map(s => s.trim()).filter(s => s.length > 0);
                    }
                }
            }
        }
    }
}
