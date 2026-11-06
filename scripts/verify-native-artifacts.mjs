#!/usr/bin/env node
// INPUT: dist/native/manifest.json and its immutable local artifacts.
// OUTPUT: ignored verification receipt; readonly DMG and isolated npm checks.
// POS: Native release verification. Never starts UI, launchd, or account queries.
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { createHash } from 'node:crypto';
import { mkdtemp, mkdir, readFile, writeFile, readdir, lstat, readlink, rename, rm, symlink } from 'node:fs/promises';
import { tmpdir, homedir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const execute = promisify(execFile);
const root = fileURLToPath(new URL('../', import.meta.url));
const out = path.join(root, 'dist/native');
const receiptFile = path.join(root, '.build/native-artifact-verification.json');
const args = process.argv.slice(2);
assert.equal(args.length, 0, 'This verifier takes no arguments.');
assert.equal(process.platform, 'darwin', 'DMG verification requires macOS.');
const manifestBytes = await readFile(path.join(out, 'manifest.json'));
const manifest = JSON.parse(manifestBytes);
assert.match(manifest.version, /^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$/);
assert.equal(typeof manifest.signed, 'boolean');
assert.equal(typeof manifest.notarized, 'boolean');
assert.ok(Array.isArray(manifest.artifacts));
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const command = (file, argv, options = {}) => execute(file, argv, { cwd: root, timeout: 60_000, maxBuffer: 8 * 1024 * 1024, ...options });
const temporary = await mkdtemp(path.join(tmpdir(), 'reset-rune-native-artifacts-'));
const receipt = { checkedAt: new Date().toISOString(), version: manifest.version, signed: manifest.signed,
  notarized: manifest.notarized, manifestSha256: hash(manifestBytes), published: false,
  artifactHashes: [], diskImages: [], npmPlatforms: [], cliChecks: [], cleanup: {}, passed: false };
const activeMounts = new Set();

async function inventory(directory, prefix = '') {
  const result = [];
  for (const name of (await readdir(directory)).sort()) {
    const file = path.join(directory, name), relative = prefix ? `${prefix}/${name}` : name;
    const info = await lstat(file);
    if (info.isSymbolicLink()) result.push({ path: relative, type: 'symlink', target: await readlink(file) });
    else if (info.isDirectory()) result.push(...await inventory(file, relative));
    else { assert.ok(info.isFile(), `Unexpected bundle entry: ${relative}`); const data = await readFile(file); result.push({ path: relative, type: 'file', bytes: data.length, sha256: hash(data), executable: Boolean(info.mode & 0o111) }); }
  }
  return result;
}
async function plist(bundle, key) {
  return (await command('/usr/bin/plutil', ['-extract', key, 'raw', '-o', '-', path.join(bundle, 'Contents/Info.plist')])).stdout.trim();
}
async function signature(file, requireHardened = true) {
  await command('/usr/bin/codesign', ['--verify', '--deep', '--strict', '--verbose=2', file]);
  const details = (await command('/usr/bin/codesign', ['-d', '--verbose=4', file])).stderr;
  const team = details.match(/^TeamIdentifier=(.+)$/m)?.[1] ?? null;
  if (manifest.signed) {
    assert.match(details, /Authority=Developer ID Application:/);
    assert.ok(team && team !== 'not set', 'Developer ID team must be present.');
    if (requireHardened) assert.match(details, /flags=.*runtime/);
  }
  return { valid: true, kind: manifest.signed ? 'developer-id' : 'ad-hoc', team };
}
async function assess(file, kind) {
  if (!manifest.notarized) return { checked: false, reason: 'manifest-not-notarized' };
  await command('/usr/bin/xcrun', ['stapler', 'validate', file]);
  const params = kind === 'dmg'
    ? ['--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=2', file]
    : ['--assess', '--type', 'execute', '--verbose=2', file];
  const result = await command('/usr/sbin/spctl', params);
  assert.match(result.stdout + result.stderr, /source=Notarized Developer ID/);
  return { checked: true, stapledTicketValid: true, gatekeeperAccepted: true };
}
async function verifyApp(app, arch) {
  const helper = path.join(app, 'Contents/Helpers/Bottled Reset Rune Service.app');
  assert.equal(await plist(app, 'CFBundleIdentifier'), 'local.reset-rune.desktop');
  assert.equal(await plist(app, 'CFBundleDisplayName'), 'Bottled Reset Rune');
  assert.equal(await plist(app, 'CFBundleExecutable'), 'Bottled Reset Rune');
  assert.equal(await plist(helper, 'CFBundleExecutable'), 'reset-rune');
  assert.equal(await plist(app, 'BottledResetRuneNative'), 'true');
  assert.equal(await plist(helper, 'CFBundleIdentifier'), 'local.reset-rune.runtime');
  for (const bundle of [app, helper]) assert.equal(await plist(bundle, 'CFBundleShortVersionString'), manifest.version);
  const appSignature = await signature(app), helperSignature = await signature(helper);
  assert.equal(appSignature.team, helperSignature.team);
  const expectedArch = arch === 'x64' ? 'x86_64' : 'arm64';
  const executables = [path.join(app, 'Contents/MacOS/Bottled Reset Rune'), path.join(helper, 'Contents/MacOS/reset-rune')];
  const binaries = [];
  for (const file of executables) {
    assert.equal((await command('/usr/bin/lipo', ['-archs', file])).stdout.trim(), expectedArch);
    assert.ok((await lstat(file)).mode & 0o111, 'Native executable must be executable.');
    const libraries = (await command('/usr/bin/otool', ['-L', file])).stdout;
    assert.doesNotMatch(libraries, /Electron Framework|Chromium Framework|libnode\./i);
    binaries.push({ path: path.relative(app, file), arch: expectedArch, sha256: hash(await readFile(file)) });
  }
  const tree = await inventory(app);
  for (const required of ['bottle.png', 'bottle-empty.png', 'icon.icns', 'trayTemplate.png', 'trayEmptyTemplate.png', 'trayUnknownTemplate.png', 'LICENSE', 'THIRD_PARTY.txt'])
    assert.ok(tree.some(item => item.path === `Contents/Resources/${required}`), `Missing resource ${required}`);
  assert.ok(!tree.some(item => /(?:^|\/)(?:node_modules|Electron Framework\.framework)(?:\/|$)/.test(item.path)));
  return { version: manifest.version, appSignature, helperSignature, binaries,
    notarization: { app: await assess(app, 'app'), helper: await assess(helper, 'app') },
    logicalBytes: tree.filter(item => item.type === 'file').reduce((sum, item) => sum + item.bytes, 0),
    fileCount: tree.length, treeSha256: hash(Buffer.from(JSON.stringify(tree))), tree };
}
async function extract(artifact, directory) {
  await mkdir(directory, { recursive: true });
  const file = path.join(out, artifact.file);
  const names = (await command('/usr/bin/tar', ['-tzf', file])).stdout.trim().split('\n');
  for (const name of names) assert.ok(name.startsWith('package/') && !name.split('/').includes('..') && !path.isAbsolute(name), `Unsafe npm archive entry: ${name}`);
  const listing = (await command('/usr/bin/tar', ['-tvzf', file])).stdout;
  assert.ok(!listing.split('\n').some(line => /^[lh]/.test(line)), 'Native npm archives must not contain symlinks or hard links.');
  await command('/usr/bin/tar', ['-xzf', file, '-C', directory]);
  return path.join(directory, 'package');
}
const cleaned = record => { const { tree, ...summary } = record; return summary; };
async function detach(mountpoint) {
  try { await command('/usr/bin/hdiutil', ['detach', mountpoint]); activeMounts.delete(mountpoint); }
  catch (error) {
    const mounts = (await command('/sbin/mount', [])).stdout;
    if (!mounts.includes(` on ${mountpoint} (`)) activeMounts.delete(mountpoint);
    else throw error;
  }
}

try {
  const names = new Set();
  for (const artifact of manifest.artifacts) {
    assert.equal(path.basename(artifact.file), artifact.file, 'Artifact paths must be basenames.');
    assert.ok(!names.has(artifact.file), 'Duplicate artifact.'); names.add(artifact.file);
    assert.match(artifact.sha256, /^[a-f0-9]{64}$/);
    const bytes = await readFile(path.join(out, artifact.file));
    assert.equal(bytes.length, artifact.bytes, `${artifact.file} bytes`);
    assert.equal(hash(bytes), artifact.sha256, `${artifact.file} SHA-256`);
    receipt.artifactHashes.push({ file: artifact.file, bytes: bytes.length, sha256: artifact.sha256 });
  }
  const expectedSums = manifest.artifacts.map(a => `${a.sha256}  ${a.file}`).join('\n') + '\n';
  assert.equal(await readFile(path.join(out, 'SHA256SUMS.txt'), 'utf8'), expectedSums);
  const dmgs = manifest.artifacts.filter(a => a.file.endsWith('.dmg'));
  const platforms = manifest.artifacts.filter(a => /^reset-rune-darwin-(arm64|x64)-/.test(a.file));
  const mains = manifest.artifacts.filter(a => a.file === `reset-rune-${manifest.version}.tgz`);
  assert.equal(dmgs.length, 2); assert.equal(platforms.length, 2); assert.equal(mains.length, 1); assert.equal(manifest.artifacts.length, 5);
  const unpacked = new Map();
  const snapshots = new Map();
  for (const arch of ['arm64', 'x64']) {
    const artifact = platforms.find(a => a.arch === arch); assert.ok(artifact);
    const pkg = await extract(artifact, path.join(temporary, `npm-${arch}`));
    const metadata = JSON.parse(await readFile(path.join(pkg, 'package.json')));
    assert.equal(metadata.name, `reset-rune-darwin-${arch}`); assert.equal(metadata.version, manifest.version);
    assert.deepEqual(metadata.os, ['darwin']); assert.deepEqual(metadata.cpu, [arch]);
    assert.ok(!metadata.scripts || !Object.keys(metadata.scripts).length, 'Platform package must have no lifecycle hooks.');
    const record = await verifyApp(path.join(pkg, 'Bottled Reset Rune.app'), arch);
    const source = await verifyApp(path.join(out, arch, 'Bottled Reset Rune.app'), arch);
    assert.deepEqual(record.tree, source.tree, `${arch} npm payload must match local signed app including resources.`);
    snapshots.set(arch, record); unpacked.set(arch, pkg);
    receipt.npmPlatforms.push({ file: artifact.file, arch, sourceBundleMatches: true, ...cleaned(record) });
  }
  for (const artifact of dmgs) {
    assert.ok(['arm64', 'x64'].includes(artifact.arch));
    const mountpoint = path.join(temporary, `volume-${artifact.arch}`); await mkdir(mountpoint);
    const image = path.join(out, artifact.file);
    const diskSignature = manifest.signed ? await signature(image, false) : { valid: false, kind: 'unsigned' };
    if (manifest.signed) assert.equal(diskSignature.team, snapshots.get(artifact.arch).appSignature.team);
    const diskAssessment = await assess(image, 'dmg');
    try {
      activeMounts.add(mountpoint); // Track before attach so timeout/error cleanup cannot remove a mounted filesystem.
      await command('/usr/bin/hdiutil', ['attach', '-readonly', '-nobrowse', '-noautoopen', '-mountpoint', mountpoint, image]);
      const record = await verifyApp(path.join(mountpoint, 'Bottled Reset Rune.app'), artifact.arch);
      assert.deepEqual(record.tree, snapshots.get(artifact.arch).tree, `${artifact.arch} DMG/npm bundle mismatch.`);
      receipt.diskImages.push({ file: artifact.file, arch: artifact.arch, mountedReadOnly: true, npmPayloadMatches: true, diskSignature,
        notarization: diskAssessment, ...cleaned(record) });
    } finally {
      if (activeMounts.has(mountpoint)) await detach(mountpoint);
    }
  }
  const mainPackage = await extract(mains[0], path.join(temporary, 'npm-main'));
  const mainMetadata = JSON.parse(await readFile(path.join(mainPackage, 'package.json')));
  assert.equal(mainMetadata.name, 'reset-rune'); assert.equal(mainMetadata.version, manifest.version);
  assert.equal(mainMetadata.repository, 'github:sufferfml/reset-rune');
  assert.deepEqual(mainMetadata.bin, { 'reset-rune': 'cli.cjs' });
  assert.ok(!mainMetadata.dependencies || !Object.keys(mainMetadata.dependencies).length);
  assert.ok(!mainMetadata.scripts || !Object.keys(mainMetadata.scripts).length, 'Thin package must have no install hooks.');
  for (const arch of ['arm64', 'x64']) assert.equal(mainMetadata.optionalDependencies[`reset-rune-darwin-${arch}`], manifest.version);
  assert.equal(hash(await readFile(path.join(mainPackage, 'cli.cjs'))), hash(await readFile(path.join(root, 'distribution/npm/cli.cjs'))));
  assert.deepEqual((await readdir(mainPackage)).sort(), ['LICENSE', 'README.md', 'cli.cjs', 'package.json']);
  const englishReadme = await readFile(path.join(mainPackage, 'README.md'), 'utf8');
  assert.match(englishReadme, /^# Bottled Reset Rune\n/);
  assert.match(englishReadme, /Automatically use spare Codex resets before they expire/);
  assert.ok(englishReadme.includes('https://github.com/sufferfml/reset-rune/blob/main/README.zh-CN.md'));
  assert.doesNotMatch(englishReadme, /\]\((?![a-z]+:|#)[^)]+\)/i, 'npm README links must resolve outside the tarball.');
  const modules = path.join(temporary, 'install/node_modules'); await mkdir(modules, { recursive: true });
  const installedMain = path.join(modules, 'reset-rune'); await rename(mainPackage, installedMain);
  for (const arch of ['arm64', 'x64']) await symlink(unpacked.get(arch), path.join(modules, `reset-rune-darwin-${arch}`), 'dir');
  const isolated = path.join(temporary, 'isolated'); await mkdir(isolated);
  const emptyCodex = path.join(isolated, 'codex-empty'), data = path.join(isolated, 'data-empty');
  await mkdir(emptyCodex); await mkdir(data, { mode: 0o700 });
  const env = { ...process.env, CODEX_HOME: emptyCodex, RESET_RUNE_DATA_DIR: data,
    RESET_RUNE_CODEX_PATH: path.join(isolated, 'codex-must-not-run') };
  delete env.RESET_RUNE_DEVELOPMENT;
  const escapedHome = JSON.stringify(path.join(homedir(), '.codex'));
  const profile = `(version 1)(allow default)(deny network*)(deny file-write*)(deny file-read* (subpath ${escapedHome}))(deny process-exec (literal "/bin/launchctl"))`;
  for (const option of ['--help', '--version']) {
    const result = await command('/usr/bin/sandbox-exec', ['-p', profile, process.execPath, path.join(installedMain, 'cli.cjs'), option], { env });
    assert.match(result.stdout, option === '--help' ? /Bottled Reset Rune/ : new RegExp(`^${manifest.version.replaceAll('.', '\\.')}\\s*$`));
    receipt.cliChecks.push({ channel: 'npm-thin-entry', arch: process.arch, option, passed: true, sandboxed: true });
  }
  for (const arch of ['arm64', 'x64']) {
    const executable = path.join(unpacked.get(arch), 'Bottled Reset Rune.app/Contents/Helpers/Bottled Reset Rune Service.app/Contents/MacOS/reset-rune');
    for (const option of ['--help', '--version']) {
      const params = ['-p', profile];
      if (arch === 'x64' && process.arch === 'arm64') params.push('/usr/bin/arch', '-x86_64');
      params.push(executable, option);
      const result = await command('/usr/bin/sandbox-exec', params, { env });
      assert.match(result.stdout, option === '--help' ? /Bottled Reset Rune/ : new RegExp(`^${manifest.version.replaceAll('.', '\\.')}\\s*$`));
      receipt.cliChecks.push({ channel: 'native-helper', arch, option, passed: true, sandboxed: true,
        execution: arch === 'x64' && process.arch === 'arm64' ? 'rosetta' : 'native' });
    }
  }
  assert.deepEqual(await readdir(emptyCodex), []); assert.deepEqual(await readdir(data), []);
  assert.equal(hash(await readFile(path.join(out, 'manifest.json'))), receipt.manifestSha256, 'Manifest changed during verification; rebuild then retry.');
  receipt.noAccountOrServiceCommands = true; receipt.isolatedDirectoriesUntouched = true; receipt.passed = true;
} catch (error) {
  receipt.error = { name: error.name, message: error.message, ...(error.code ? { code: error.code } : {}) };
  process.exitCode = 1;
} finally {
  const cleanupErrors = [];
  for (const mountpoint of activeMounts) {
    try { await detach(mountpoint); }
    catch (error) { cleanupErrors.push({ mountpoint, message: error.message }); }
  }
  if (!activeMounts.size) await rm(temporary, { recursive: true, force: true });
  receipt.cleanup = { allDiskImagesDetached: activeMounts.size === 0, temporaryDirectoryRemoved: activeMounts.size === 0, errors: cleanupErrors };
  if (activeMounts.size) { receipt.passed = false; process.exitCode = 1; }
  await mkdir(path.dirname(receiptFile), { recursive: true });
  await writeFile(receiptFile, JSON.stringify(receipt, null, 2) + '\n');
}
console.log(JSON.stringify({ passed: receipt.passed, version: receipt.version, artifactCount: receipt.artifactHashes.length,
  dmgCount: receipt.diskImages.length, platformCount: receipt.npmPlatforms.length, cliChecks: receipt.cliChecks.length,
  notarized: receipt.notarized, receipt: receiptFile, ...(receipt.error ? { error: receipt.error } : {}) }, null, 2));
