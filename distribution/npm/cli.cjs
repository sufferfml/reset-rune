#!/usr/bin/env node
'use strict';
// npm is a transport only. All commands and background work run in the signed native executable.
const { spawn } = require('node:child_process');
const path = require('node:path');
const fs = require('node:fs');
if (process.platform !== 'darwin' || !['arm64', 'x64'].includes(process.arch)) {
  console.error('Bottled Reset Rune requires macOS arm64 or x64.'); process.exit(1);
}
let root;
try { root = path.dirname(require.resolve(`reset-rune-darwin-${process.arch}/package.json`)); }
catch {
  const dev = path.resolve(__dirname, '../../dist/native', process.arch);
  if (process.env.RESET_RUNE_DEVELOPMENT === '1' && fs.existsSync(path.join(dev, 'Bottled Reset Rune.app'))) root = dev;
  else { console.error('The native platform package is missing. Reinstall reset-rune with optional dependencies enabled.'); process.exit(1); }
}
const app = path.join(root, 'Bottled Reset Rune.app');
const executable = path.join(app, 'Contents/Helpers/Bottled Reset Rune Service.app/Contents/MacOS/reset-rune');
const child = spawn(executable, process.argv.slice(2), { stdio: 'inherit', env: { ...process.env, RESET_RUNE_APP_PATH: app } });
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => child.kill(signal));
child.on('error', () => { console.error('Could not launch the native Bottled Reset Rune program.'); process.exitCode = 1; });
child.on('exit', (code, signal) => { process.exitCode = code ?? (signal ? 1 : 0); });
