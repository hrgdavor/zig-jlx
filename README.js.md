# jlx JavaScript Implementation

This folder contains a JavaScript port of the `jlx` core logic with full feature parity.

## 🚀 Interactive Demo

You can practice using `jlx` and see live formatting in the interactive demo:

- **Refresh Test Data**: 
    1. Run `bun run generate-test-log` to recreate the 3000-line sample.
    2. Build the artifacts: `bun run build-demo`
    2. Run a local server to enable `fetch` features:
       ```bash
       bun x serve site
       ```
    3. Open the provided `localhost` URL in your browser.

## 📦 Deployment & Bundling

The demo is now a standalone HTML file with all JS logic inlined, suitable for GitHub Pages.

```bash
# Build the standalone demo (generates site/index.html)
bun run build-demo
```

## 🧪 Testing

We use `bun` for testing the JS implementation against the Zig version.

```bash
# Install dependencies
bun install

# Run parity tests
bun test
```

## 🛠️ Log Generation

Generate large, realistic test logs with sessions, ticket IDs, and randomized messages:

```bash
# Generate 10,000 lines of session-based ticket logs
bun scripts/generate-log.js 10000 > test.log
```

The generator creates logs for a single day (`2026-03-04`) with fields like `sessionId`, `ticketId`, and `userId`, perfect for practicing complex filters in the demo workbench.

## Project Setup

This project was created using `bun init` in bun v1.3.10. [Bun](https://bun.com) is a fast all-in-one JavaScript runtime.
