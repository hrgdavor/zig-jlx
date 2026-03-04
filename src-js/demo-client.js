import { Config } from './config.js';
import { Processor } from './processor.js';

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
const autoScrollToggle = document.getElementById('autoScrollToggle');

let loadedLogLines = [];

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

configEditor.value = configSamples[0].content;

// Auto-load sample log if running on a server (e.g. GitHub Pages)
async function tryAutoLoadSample() {
    try {
        const resp = await fetch('./test_session_tickets.log');
        if (resp.ok) {
            const text = await resp.text();
            if (text.trim()) {
                loadedLogLines = text.split('\n').filter(l => l.trim());
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

async function getProcessor() {
    const config = new Config();
    try {
        config.parse(configEditor.value || "");
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
    return processor;
}

function createLogLineElement(processed, raw) {
    const lineDiv = document.createElement('div');
    lineDiv.className = 'log-line';

    const levelMatch = processed.match(/\[(INFO|WARN|ERROR|DEBUG|TRACE)\]/);
    if (levelMatch) {
        const level = levelMatch[1];
        lineDiv.innerHTML = processed.replace(`[${level}]`, `<span class="pill pill-${level}">${level}</span>`);
    } else {
        lineDiv.textContent = processed;
    }

    lineDiv.onclick = () => {
        let parsed = null;
        try {
            parsed = JSON.parse(raw);
        } catch (e) { }

        const prefix = raw.substring(0, 100) + (raw.length > 100 ? "..." : "");
        console.log(`%cRaw Log:%c ${prefix}`, "font-weight:bold; color:#f7a41d", "color:inherit");
        if (parsed) {
            console.log(parsed);
        } else {
            console.log(raw);
        }
    };

    return lineDiv;
}

async function update() {
    const processor = await getProcessor();

    let matches = 0;
    output.innerHTML = '';

    for (const line of loadedLogLines) {
        const processed = processor.processLine(line);
        if (processed !== null) {
            matches++;
            output.appendChild(createLogLineElement(processed, line));
        }
    }

    matchStats.textContent = `Matched ${matches} of ${loadedLogLines.length} lines`;

    // CLI update
    let cmd = 'jlx -c jlx.conf';
    if (includeFilter.value) cmd += ` -i "${includeFilter.value}"`;
    if (excludeFilter.value) cmd += ` -e "${excludeFilter.value}"`;
    if (rangeFilter.value) cmd += ` -r "${rangeFilter.value}"`;

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
        loadedLogLines = e.target.result.split('\n').filter(l => l.trim());
        update();
    };
    reader.readAsText(file);
};

const liveToggle = document.getElementById('liveToggle');
const sseStatus = document.getElementById('sseStatus');
let eventSource = null;

function connectSSE() {
    if (eventSource) {
        eventSource.close();
    }

    const params = new URLSearchParams();
    if (includeFilter.value) params.append('include', includeFilter.value);
    if (excludeFilter.value) params.append('exclude', excludeFilter.value);
    if (rangeFilter.value) {
        params.append('range', rangeFilter.value);
    } else {
        params.append('range', '-50');
    }
    params.append('follow', 'true');

    const url = `/sse?${params.toString()}`;
    console.log('Connecting to SSE:', url);

    eventSource = new EventSource(url);
    sseStatus.style.display = 'inline-block';
    sseStatus.textContent = 'CONNECTING...';
    sseStatus.style.background = '#f7a41d';

    eventSource.onopen = () => {
        sseStatus.textContent = 'LIVE';
        sseStatus.style.background = '#22c55e';
        output.innerHTML = '';
        matchStats.textContent = 'Live stream active';
    };

    eventSource.onmessage = async (e) => {
        const line = e.data;
        if (!line.trim()) return;

        const processor = await getProcessor();
        const processed = processor.processLine(line);
        if (processed === null) return;

        output.appendChild(createLogLineElement(processed, line));
        if (autoScrollToggle.checked) {
            output.scrollTop = output.scrollHeight;
        }
    };

    eventSource.onerror = (err) => {
        console.error('SSE Error:', err);
        sseStatus.textContent = 'DISCONNECTED';
        sseStatus.style.background = '#ef4444';
        eventSource.close();
    };
}

liveToggle.onchange = () => {
    if (liveToggle.checked) {
        connectSSE();
    } else {
        if (eventSource) {
            eventSource.close();
        }
        sseStatus.style.display = 'none';
        update();
    }
};

[configEditor, includeFilter, excludeFilter, rangeFilter].forEach(el => {
    el.addEventListener('input', () => {
        if (liveToggle.checked) {
            connectSSE();
        } else {
            update();
        }
    });
});

// Auto-scroll toggle manual control
autoScrollToggle.onchange = () => {
    if (autoScrollToggle.checked) {
        output.scrollTop = output.scrollHeight;
    }
};

// Handle auto-scroll state based on scroll position
output.addEventListener('scroll', () => {
    // Check if user is at the bottom (with 10px margin for subpixel issues)
    const isAtBottom = output.scrollHeight - output.scrollTop <= output.clientHeight + 10;
    autoScrollToggle.checked = isAtBottom;
}, { passive: true });

renderUI();
// tryAutoLoadSample();
update();
