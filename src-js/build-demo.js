import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'fs';
import { join } from 'path';

async function build() {
    console.log('Building standalone demo...');

    const srcDir = import.meta.dir;
    const rootDir = join(srcDir, '..');
    const docsDir = join(rootDir, 'docs');

    if (!existsSync(docsDir)) {
        mkdirSync(docsDir);
    }

    // 1. Bundle the client script using Bun
    console.log('Bundling client script...');
    const result = await Bun.build({
        entrypoints: [join(srcDir, 'demo-client.js')],
        outdir: docsDir,
        minify: true,
        target: 'browser',
        sourcemap: 'inline',
    });

    if (!result.success) {
        console.error('Build failed:', result.logs);
        process.exit(1);
    }

    // 2. Refresh the sample log in docs/ from the test suite
    console.log('Copying test log from test suite to docs/...');
    const testLogPath = join(srcDir, 'tests', 'test_session_tickets.log');
    const destLogPath = join(docsDir, 'test_session_tickets.log');
    if (existsSync(testLogPath)) {
        writeFileSync(destLogPath, readFileSync(testLogPath));
    } else {
        console.warn('Warning: test_session_tickets.log not found in tests folder, generating one now...');
        const generateLog = join(rootDir, 'scripts', 'generate-log.js');
        const { stdout } = Bun.spawnSync(['bun', generateLog, '3000']);
        writeFileSync(destLogPath, stdout);
    }

    // 3. Copy demo.html to docs/index.html
    console.log('Copying demo.html to docs/index.html...');
    const html = readFileSync(join(srcDir, 'demo.html'), 'utf8');
    writeFileSync(join(docsDir, 'index.html'), html);

    console.log(`Standalone demo build complete!`);
    console.log(`Main entry: ${join(docsDir, 'index.html')}`);
    console.log(`Bundled script: ${join(docsDir, 'demo-client.js')}`);
    console.log(`Log sample: ${destLogPath}`);
}

build().catch(console.error);
