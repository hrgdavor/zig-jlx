/**
 * Generates session-based ticket logs for a single day.
 */

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

const count = parseInt(process.argv[2], 10) || 10000;
const sessionIdPrefix = "sess-";
const sessionCount = 50;
const sessions = Array.from({ length: sessionCount }, (_, i) => `${sessionIdPrefix}${Math.floor(Math.random() * 1000000)}`);

// Single day: 2026-03-04
const baseTime = new Date("2026-03-04T00:00:00Z").getTime();
const dayMs = 24 * 60 * 60 * 1000;

for (let i = 0; i < count; i++) {
    const ts = baseTime + Math.floor((i / count) * dayMs);
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

    const entry = {
        ts,
        level,
        logger,
        message: msg,
        sessionId,
        ticketId,
        userId,
        thread: `pool-${Math.floor(Math.random() * 4)}`,
    };

    process.stdout.write(JSON.stringify(entry) + '\n');
}
