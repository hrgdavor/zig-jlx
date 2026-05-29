/** @jsxImportSource @jsx6 */
import { Config } from './config.js';
import { Processor } from './processor.js';
import { signal } from '@jsx6/signal';
import { JsxW, define } from '@jsx6/w';

let ui = {};
let configEditor, workflowSelect, configSampleSelect, includeFilter, excludeFilter, rangeFilter;
let output, copyBtn, fileInput, autoScrollToggle, liveToggle;

const $workflowDescription = signal('');
const $cliCommand = signal('jlx -c jlx.conf test.log');
const $matchStats = signal('Showing all lines');
const $sseText = signal('CONNECTED');
const $sseStyle = signal('margin: 0; display: none; background: #22c55e;');

class App extends JsxW {
    constructor() {
        super();
    }

    render(_, __, scope) {
        ui = scope;
        return (
            <div>
                <header>
                    <div class="logo">jlx // interactive workbench</div>
                    <div style="display: flex; gap: 1rem; align-items: center;">
                        <input p="fileInput" type="file" id="fileInput" style="display: none;" />
                        <button class="btn-copy" id="loadLogBtn" onClick={() => ui.fileInput.click()} style="float: none; font-size: 0.75rem; padding: 0.4rem 0.8rem; border-color: var(--accent); color: var(--accent);">Load Log File</button>
                        <button class="btn-copy" id="loadDemoBtn" onClick={() => tryAutoLoadSample()} style="float: none; font-size: 0.75rem; padding: 0.4rem 0.8rem; border-color: var(--accent); color: var(--accent);">Load demo log</button>
                    </div>
                </header>
                <main>
                <div class="sidebar">
                    <div class="control-group">
                        <div class="section-title">Ready-Made Workflows</div>
                        <select p="workflowSelect" id="workflowSelect"><option value="">-- Select a Workflow --</option></select>
                        <div p="workflowDescription" style="font-size: 0.7rem; color: var(--text-dim); margin-top: 0.3rem;">{$workflowDescription}</div>
                    </div>
                    <div class="control-group">
                        <div class="section-title">Configuration (jlx.conf)</div>
                        <label>Load Sample Config</label>
                        <select p="configSampleSelect" id="configSampleSelect"><option value="">-- Choose a Sample --</option></select>
                        <label style="margin-top: 0.5rem;">Edit Configuration</label>
                        <textarea p="configEditor" id="configEditor" style="width: 100%; height: 180px; margin-top: 0.2rem; font-size: 0.75rem; line-height: 1.4; white-space: pre; border-color: rgba(247, 164, 29, 0.3);"></textarea>
                    </div>
                    <div class="control-group">
                        <div class="section-title">Current CLI State</div>
                        <div p="cliCommand" class="cli-preview" id="cliCommand">{$cliCommand}</div>
                        <button p="copyBtn" class="btn-copy" id="copyBtn">Copy Command</button>
                    </div>
                    <div class="control-group">
                        <div class="section-title">Filters (Live Edit)</div>
                        <label>Include Only (-i)</label>
                        <input p="includeFilter" type="text" id="includeFilter" placeholder="level:INFO or ~regex" />
                        <label>Exclude (-e)</label>
                        <input p="excludeFilter" type="text" id="excludeFilter" placeholder="logger:db" />
                        <label>Time Range (-r)</label>
                        <input p="rangeFilter" type="text" id="rangeFilter" placeholder="08:00..09:00" />
                    </div>
                    <div style="margin-top: auto; font-size: 0.65rem; color: var(--text-dim); border-top: 1px solid var(--border); padding-top: 1rem;">Tip: Use level:ERROR to find issues quickly, or -r 14:00..15:00 for afternoon analysis. All formatting is handled via -c jlx.conf.</div>
                </div>
                <div class="content">
                    <div class="section-title">
                        <span>Synthetic Log Feed (10,000 Entries Generated)</span>
                        <span p="matchStats" id="matchStats" style="margin-left: auto; color: var(--accent); font-size: 0.75rem;">{$matchStats}</span>
                        <div style="margin-left: 1.5rem; display: flex; align-items: center; gap: 0.5rem; font-size: 0.75rem;">
                            <label class="switch" style="cursor: pointer; display: flex; align-items: center; gap: 0.5rem;">
                                <input p="liveToggle" type="checkbox" id="liveToggle" style="margin: 0;" />
                                <span style="color: var(--accent); font-weight: 600;">LIVE MODE</span>
                            </label>
                            <label class="switch" style="cursor: pointer; display: flex; align-items: center; gap: 0.5rem; margin-left: 1rem;">
                                <input p="autoScrollToggle" type="checkbox" id="autoScrollToggle" style="margin: 0;" checked />
                                <span style="color: var(--accent); font-weight: 600;">AUTO SCROLL</span>
                            </label>
                            <span p="sseStatus" class="pill" id="sseStatus" style={$sseStyle}>{$sseText}</span>
                        </div>
                    </div>
                    <div p="output" class="log-output" id="output"></div>
                </div>
            </main>
        </div>
    );
}
}

function renderShell() {
    const app = document.getElementById('app');
    const component = define(App); 
    app.replaceChildren(component());
}

function hookElements() {
    const scope = ui || {};
    workflowSelect = scope.workflowSelect || document.getElementById('workflowSelect');
    configSampleSelect = scope.configSampleSelect || document.getElementById('configSampleSelect');
    configEditor = scope.configEditor || document.getElementById('configEditor');
    includeFilter = scope.includeFilter || document.getElementById('includeFilter');
    excludeFilter = scope.excludeFilter || document.getElementById('excludeFilter');
    rangeFilter = scope.rangeFilter || document.getElementById('rangeFilter');
    output = scope.output || document.getElementById('output');
    copyBtn = scope.copyBtn || document.getElementById('copyBtn');
    fileInput = scope.fileInput || document.getElementById('fileInput');
    autoScrollToggle = scope.autoScrollToggle || document.getElementById('autoScrollToggle');
    liveToggle = scope.liveToggle || document.getElementById('liveToggle');
}

let loadedLogLines = [];

function setSseUiState(text, display, background) {
    $sseText(text);
    $sseStyle(`margin: 0; display: ${display}; background: ${background};`);
}

// Render static shell using JSX6
function initApp() {
    renderShell();
    hookElements();
    configEditor.value = configSamples[0].content;
    renderUI();
    bindDOMEvents();
    // tryAutoLoadSample();
    update();
}

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

// Default config value is assigned after DOM elements are hooked.
// configEditor is not available until initApp() has rendered the shell.
// Auto-load sample log if running on a server (e.g. GitHub Pages)
globalThis.tryAutoLoadSample = async function tryAutoLoadSample() {
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
    workflowSelect.replaceChildren(
        <option value="">-- Select a Workflow --</option>,
        ...workflows.map((workflow, index) => <option value={String(index)}>{workflow.title}</option>)
    );

    configSampleSelect.replaceChildren(
        <option value="">-- Choose a Sample --</option>,
        ...configSamples.map((sample, index) => <option value={String(index)}>{sample.name}</option>)
    );
}

function bindDOMEvents() {
    workflowSelect.onchange = (e) => {
        const idx = e.target.value;
        if (idx === "") {
            $workflowDescription('');
            return;
        }
        const w = workflows[idx];
        includeFilter.value = w.filters.include || "";
        excludeFilter.value = w.filters.exclude || "";
        rangeFilter.value = w.filters.range || "";
        if (w.config) configEditor.value = w.config;
        $workflowDescription(w.description);
        update();
    };

    configSampleSelect.onchange = (e) => {
        const idx = e.target.value;
        if (idx !== "") {
            configEditor.value = configSamples[idx].content;
            update();
        }
    };

    copyBtn.onclick = () => {
        navigator.clipboard.writeText($cliCommand());
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

    liveToggle.onchange = () => {
        if (liveToggle.checked) {
            connectSSE();
        } else {
            if (eventSource) {
                eventSource.close();
            }
            setSseUiState('CONNECTED', 'none', '#22c55e');
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

    autoScrollToggle.onchange = () => {
        if (autoScrollToggle.checked) {
            output.scrollTop = output.scrollHeight;
        }
    };

    output.addEventListener('scroll', () => {
        const isAtBottom = output.scrollHeight - output.scrollTop <= output.clientHeight + 10;
        autoScrollToggle.checked = isAtBottom;
    }, { passive: true });
}

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
    const levelMatch = processed.match(/\[(INFO|WARN|ERROR|DEBUG|TRACE)\]/);
    let content = [processed];

    if (levelMatch) {
        const level = levelMatch[1];
        const marker = `[${level}]`;
        const markerIndex = processed.indexOf(marker);
        content = [
            processed.slice(0, markerIndex),
            <span class={`pill pill-${level}`}>{level}</span>,
            processed.slice(markerIndex + marker.length)
        ];
    }

    return (
        <div class="log-line" onclick={() => {
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
        }}>
            {content}
        </div>
    );
}

async function update() {
    const processor = await getProcessor();

    const rangeText = rangeFilter.value;
    const rangeVal = rangeText ? parseInt(rangeText) : null;
    const isNumericRange = rangeVal !== null && !isNaN(rangeVal) && !rangeText.includes('..');

    let matches = [];
    output.innerHTML = '';

    for (const line of loadedLogLines) {
        const processed = processor.processLine(line);
        if (processed !== null) {
            matches.push({ processed, raw: line });
            if (isNumericRange && rangeVal > 0 && matches.length >= rangeVal) break;
        }
    }

    let displayMatches = matches;
    if (isNumericRange && rangeVal < 0) {
        displayMatches = matches.slice(rangeVal);
    }

    for (const m of displayMatches) {
        output.appendChild(createLogLineElement(m.processed, m.raw));
    }

    $matchStats(`Matched ${displayMatches.length} of ${loadedLogLines.length} lines`);

    // CLI update
    let cmd = 'jlx -c jlx.conf';
    if (includeFilter.value) cmd += ` -i "${includeFilter.value}"`;
    if (excludeFilter.value) cmd += ` -e "${excludeFilter.value}"`;
    if (rangeFilter.value) cmd += ` -r "${rangeFilter.value}"`;

    $cliCommand(cmd + ' logfile.json');
}

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
    setSseUiState('CONNECTING...', 'inline-block', '#f7a41d');

    eventSource.onopen = () => {
        setSseUiState('LIVE', 'inline-block', '#22c55e');
        output.innerHTML = '';
        $matchStats('Live stream active');
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
        setSseUiState('DISCONNECTED', 'inline-block', '#ef4444');
        eventSource.close();
    };
}

initApp();
