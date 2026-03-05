import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'fs';
import { join } from 'path';

async function build() {
    console.log('Building standalone demo...');

    const srcDir = 'src-js';
    const rootDir = join(srcDir, '..');
    const siteDir = join(rootDir, 'site');

    if (!existsSync(siteDir)) {
        mkdirSync(siteDir);
    }

    // 1. Bundle the client script using Bun
    console.log('Bundling client script...');
    const result = await Bun.build({
        entrypoints: [join(srcDir, 'demo-client.js')],
        outdir: siteDir,
        minify: true,
        target: 'browser',
        sourcemap: 'inline',
    });

    if (!result.success) {
        console.error('Build failed:', result.logs);
        process.exit(1);
    }

    // 2. Refresh the sample log in site/ from the test suite
    console.log('Copying test log from test suite to site/...');
    const testLogPath = join(srcDir, 'tests', 'test_session_tickets.log');
    const destLogPath = join(siteDir, 'test_session_tickets.log');
    if (existsSync(testLogPath)) {
        writeFileSync(destLogPath, readFileSync(testLogPath));
    } else {
        console.warn('Warning: test_session_tickets.log not found in tests folder, generating one now...');
        const generateLog = join(rootDir, 'scripts', 'generate-log.js');
        const { stdout } = Bun.spawnSync(['bun', generateLog, '3000']);
        writeFileSync(destLogPath, stdout);
    }

    // 4. Mirror assets to zig-out/web for Zig embedding
    console.log('Mirroring assets to zig-out/web/ for Zig embedding...');
    const webDistDir = join(rootDir, 'zig-out', 'web');
    if (!existsSync(webDistDir)) mkdirSync(webDistDir, { recursive: true });

    const html = readFileSync(join(srcDir, 'demo.html'), 'utf8');
    writeFileSync(join(siteDir, 'index.html'), html);
    writeFileSync(join(webDistDir, 'index.html'), html);

    const bundledJs = readFileSync(join(siteDir, 'demo-client.js'));
    writeFileSync(join(webDistDir, 'demo-client.js'), bundledJs);

    console.log(`Standalone demo build complete!`);
    console.log(`Main entry: ${join(siteDir, 'index.html')}`);
    console.log(`Bundled script: ${join(siteDir, 'demo-client.js')}`);
    console.log(`Log sample: ${destLogPath}`);
    console.log(`Assets mirrored to: ${webDistDir}`);
}

build().catch(console.error);
