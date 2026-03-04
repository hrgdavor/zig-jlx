import { Config } from './config.js';
import { Processor } from './processor.js';

const logInput = document.getElementById('logInput');
const configEditor = document.getElementById('configEditor');
const workflowSelect = document.getElementById('workflowSelect');
const configSampleSelect = document.getElementById('configSampleSelect');
const workflowDescription = document.getElementById('workflowDescription');
const includeFilter = document.getElementById('includeFilter');
const excludeFilter = document.getElementById('excludeFilter');
const rangeFilter = document.getElementById('rangeFilter');
const output = document.getElementById('output');
const cliCommand = document.getElementById('cliCommand');
const matchStats = document.getElementById('matchStats');
const copyBtn = document.getElementById('copyBtn');
const fileInput = document.getElementById('fileInput');

// Configuration Samples
const configSamples = [
    {
        name: "Standard JSON",
        content: "[folders]\ntimestamp = ts\nlevel = level\nmessage = message\noutput = {timestamp:time} [{level}] {message}"
    },
    {
        name: "Compact Trace",
        content: "[folders]\ntimestamp = ts\nlevel = level\nmessage = message\noutput = {ts:timems} | {level} | {logger} | {message}\nmessage_expand = curly"
    },
    {
        name: "Security Audit",
        content: "[folders]\ntimestamp = ts\nlevel = level\nmessage = message\noutput = {ts:datetime} [AUDIT] {userId} {sessionId} {message}"
    },
    {
        name: "Development (JS Exp)",
        content: "[folders]\ntimestamp = ts\nlevel = level\nmessage = message\noutput = {ts:time} > {thread} > {message}\nmessage_expand = js"
    }
];

// Ready-made workflows
const workflows = [
    {
        title: "Morning Errors",
        description: "Find ERROR level logs between 8am and 10am UTC",
        filters: { include: "level:ERROR", range: "08:00..10:00" },
        config: configSamples[0].content
    },
    {
        title: "Session Inspector",
        description: "Watch activity for User USR-100 with Audit template",
        filters: { include: "userId:USR-100" },
        config: configSamples[2].content
    },
    {
        title: "DB Performance",
        description: "Database handler logs excluding DEBUG noise",
        filters: { include: "logger:db-handler", exclude: "DEBUG" },
        config: configSamples[1].content
    },
    {
        title: "Ticket Status Updates",
        description: "All status changes matching Regex for 'status.*ticket'",
        filters: { include: "message:re:status.*ticket" },
        config: configSamples[1].content
    }
];

// Seed data (truncated for browser memory)
const generateTicketLog = (count) => {
    const logs = [];
    const levels = ["INFO", "WARN", "ERROR", "DEBUG"];
    const loggers = ["ticket-service", "user-api", "db-handler"];
    const baseTime = new Date("2026-03-04T08:00:00Z").getTime();

    for (let i = 0; i < count; i++) {
        const ts = baseTime + i * 10000; // 10s intervals
        logs.push(JSON.stringify({
            ts,
            level: levels[Math.floor(Math.random() * levels.length)],
            logger: loggers[Math.floor(Math.random() * loggers.length)],
            message: i % 5 === 0 ? "Updated status for ticket TKT-1234: Resolved" : "Fetching ticket data...",
            sessionId: "sess-9988223",
            userId: "USR-100",
            thread: "pool-1"
        }));
    }
    return logs.join('\n');
};

const defaultSeedLogs = generateTicketLog(200);
logInput.value = defaultSeedLogs;
configEditor.value = configSamples[0].content;

// Auto-load sample log if running on a server (e.g. GitHub Pages)
async function tryAutoLoadSample() {
    try {
        const resp = await fetch('./test_session_tickets.log');
        if (resp.ok) {
            const text = await resp.text();
            if (text.trim()) {
                logInput.value = text;
                update();
            }
        }
    } catch (e) {
        update();
    }
}

function renderUI() {
    // Render Workflows
    workflowSelect.innerHTML = '<option value="">-- Select a Workflow --</option>' +
        workflows.map((w, idx) => `<option value="${idx}">${w.title}</option>`).join('');

    // Render Config Samples
    configSampleSelect.innerHTML = '<option value="">-- Choose a Sample --</option>' +
        configSamples.map((s, idx) => `<option value="${idx}">${s.name}</option>`).join('');
}

workflowSelect.onchange = (e) => {
    const idx = e.target.value;
    if (idx === "") {
        workflowDescription.textContent = "";
        return;
    }
    const w = workflows[idx];
    includeFilter.value = w.filters.include || "";
    excludeFilter.value = w.filters.exclude || "";
    rangeFilter.value = w.filters.range || "";
    if (w.config) configEditor.value = w.config;
    workflowDescription.textContent = w.description;
    update();
};

configSampleSelect.onchange = (e) => {
    const idx = e.target.value;
    if (idx !== "") {
        configEditor.value = configSamples[idx].content;
        update();
    }
};

async function update() {
    const lines = logInput.value.split('\n');
    const config = new Config();

    try {
        config.parse(configEditor.value);
    } catch (e) {
        console.error("Config parse error:", e);
    }

    const args = {
        include: includeFilter.value || null,
        exclude: excludeFilter.value || null,
        range: rangeFilter.value || null,
        zone: "UTC"
    };

    const processor = new Processor(args, config);
    await processor.buildContext();

    let matches = 0;
    output.innerHTML = '';

    for (const line of lines) {
        if (!line.trim()) continue;
        const processed = processor.processLine(line);
        if (processed !== null) {
            matches++;
            const lineDiv = document.createElement('div');
            const levelMatch = processed.match(/\[(INFO|WARN|ERROR|DEBUG|TRACE)\]/);
            if (levelMatch) {
                const level = levelMatch[1];
                lineDiv.innerHTML = processed.replace(`[${level}]`, `<span class="pill pill-${level}">${level}</span>`);
            } else {
                lineDiv.textContent = processed;
            }
            output.appendChild(lineDiv);
        }
    }

    matchStats.textContent = `Matched ${matches} of ${lines.length} lines`;

    // CLI update
    let cmd = 'jlx -c jlx.conf';
    if (args.include) cmd += ` -i "${args.include}"`;
    if (args.exclude) cmd += ` -e "${args.exclude}"`;
    if (args.range) cmd += ` -r "${args.range}"`;

    cliCommand.textContent = cmd + ' logfile.json';
}

copyBtn.onclick = () => {
    navigator.clipboard.writeText(cliCommand.textContent);
    copyBtn.textContent = 'Copied!';
    setTimeout(() => copyBtn.textContent = 'Copy Command', 2000);
};

fileInput.onchange = (e) => {
    const file = e.target.files[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = (e) => {
        logInput.value = e.target.result;
        update();
    };
    reader.readAsText(file);
};

[logInput, configEditor, includeFilter, excludeFilter, rangeFilter].forEach(el => {
    el.addEventListener('input', update);
});

renderUI();
tryAutoLoadSample();
update();
