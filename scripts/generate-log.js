const fs = require('fs');

const levels = ["INFO", "WARN", "ERROR", "DEBUG", "TRACE"];
const loggers = ["ticket-service", "user-api", "db-handler", "auth-provider", "notification-manager"];
const ticketMessages = [
    "Fetching ticket {ticketId}",
    "Updated status for ticket {ticketId}: {status}",
    "User {userId} commented on ticket {ticketId}",
    "Assigned ticket {ticketId} to agent {agentId}",
    "Ticket {ticketId} validation failed: {error}",
    "Sending notification for ticket {ticketId} to {userId}",
    "Archive operation started for ticket {ticketId}",
];

const statuses = ["Open", "In Progress", "Pending", "Resolved", "Closed"];
const errors = ["Invalid format", "Permission denied", "Database timeout", "Missing required field"];
const agents = ["agent-1", "agent-2", "agent-3", "agent-4"];

const isLive = process.argv.includes("live");
const outputFile = process.argv.find(a => a.endsWith(".log"));
const countParam = process.argv.find(a => /^\d+$/.test(a));
const count = countParam ? parseInt(countParam, 10) : (isLive ? 0 : 10000);

if (isLive && !outputFile) {
    console.error("\x1b[31m[WARNING] You are using 'live' mode without specifying an output file argument.\x1b[0m");
    console.error("\x1b[31m[WARNING] If you are redirecting output in PowerShell (e.g., '>> test.log'),\x1b[0m");
    console.error("\x1b[31m[WARNING] the file will likely be corrupted with UTF-16 encoding.\x1b[0m");
    console.error("\x1b[31m[ADVICE] Use: node scripts/generate-log.js live test.log\x1b[0m\n");
}

const sessionIdPrefix = "sess-";
const sessionCount = 50;
const sessions = Array.from({ length: sessionCount }, (_, i) => `${sessionIdPrefix}${Math.floor(Math.random() * 1000000)}`);

function generateEntry(ts) {
    const sessionId = sessions[Math.floor(Math.random() * sessions.length)];
    const level = levels[Math.floor(Math.random() * levels.length)];
    const logger = loggers[Math.floor(Math.random() * loggers.length)];
    let msg = ticketMessages[Math.floor(Math.random() * ticketMessages.length)];

    const ticketId = `TKT-${1000 + Math.floor(Math.random() * 9000)}`;
    const userId = `USR-${100 + Math.floor(Math.random() * 900)}`;

    msg = msg.replace("{ticketId}", ticketId);
    msg = msg.replace("{userId}", userId);
    msg = msg.replace("{status}", statuses[Math.floor(Math.random() * statuses.length)]);
    msg = msg.replace("{agentId}", agents[Math.floor(Math.random() * agents.length)]);
    msg = msg.replace("{error}", errors[Math.floor(Math.random() * errors.length)]);

    return {
        ts,
        level,
        logger,
        message: msg,
        sessionId,
        ticketId,
        userId,
        thread: `pool-${Math.floor(Math.random() * 4)}`,
    };
}

function writeEntry(entry) {
    const line = JSON.stringify(entry) + '\n';
    if (outputFile) {
        try {
            fs.appendFileSync(outputFile, line, 'utf8');
        } catch (e) {
            console.error(`Error writing to ${outputFile}: ${e.message}`);
        }
    } else {
        process.stdout.write(line);
    }
}

// Check for UTF-16 corruption in existing file
if (outputFile && fs.existsSync(outputFile)) {
    const buf = Buffer.alloc(100);
    const fd = fs.openSync(outputFile, 'r');
    fs.readSync(fd, buf, 0, 100, 0);
    fs.closeSync(fd);

    // Check for BOM or interleaved nulls
    if (buf[0] === 0xFF && buf[1] === 0xFE || buf[0] === 0xFE && buf[1] === 0xFF || buf.includes(0x00)) {
        console.error(`\x1b[33m[WARNING] ${outputFile} seems to have null bytes or UTF-16 encoding.\x1b[0m`);
        console.error(`\x1b[33m[WARNING] This is usually caused by PowerShell '>>' redirection.\x1b[0m`);
        console.error(`\x1b[33m[WARNING] jlx will NOT be able to parse this file correctly.\x1b[0m`);
        console.error(`\x1b[33m[ADVICE] Run 'Clear-Content ${outputFile}' and restart.\x1b[0m\n`);
    }
}

// Single day: 2026-03-04
const baseTime = new Date("2026-03-04T00:00:00Z").getTime();
const dayMs = 24 * 60 * 60 * 1000;

for (let i = 0; i < count; i++) {
    const ts = baseTime + Math.floor((i / count) * dayMs);
    const entry = generateEntry(ts);
    writeEntry(entry);
}

if (isLive) {
    console.error(`Live mode started. Appending to ${outputFile || 'stdout'} every second...`);
    setInterval(() => {
        const lineCount = 1 + Math.floor(Math.random() * 2);
        for (let j = 0; j < lineCount; j++) {
            const entry = generateEntry(Date.now());
            writeEntry(entry);
        }
    }, 1000);
}
