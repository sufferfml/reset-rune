import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { createCodexSource, normalizeSnapshot } from './index.js';

const fixture = fileURLToPath(new URL('./fixtures/app-server.mjs', import.meta.url));
const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";

const expiry = 1_794_000_000_000;
const identity = {
  accountId: 'mock-account', email: 'mock@example.test',
  scope: 'codex:' + createHash('sha256').update('mock@example.test').digest('hex'),
};
const operation = {
  id: 'mock-credit', key: '8ae96ff3-3425-4f4c-8772-b6fd61502868', identity,
  expiresAt: expiry, startsAt: expiry - 600_000, maySend: () => true,
};

async function fakeRuntime(t, mode, options) {
  const home = await mkdtemp(join(tmpdir(), 'reset-rune-fake-'));
  t.after(() => rm(home, { recursive: true, force: true }));
  const executable = join(home, 'codex');
  await writeFile(executable, `#!/bin/sh\nexec ${quote(process.execPath)} ${quote(fixture)} "$@"\n`, { mode: 0o700 });
  const source = createCodexSource({ executable, ...options, env: {
    HOME: home,
    CODEX_HOME: join(home, mode),
    OPENAI_API_KEY: 'fake-key-must-not-be-passed',
    CODEX_API_KEY: 'fake-key-must-not-be-passed',
  } });
  return {
    source,
    requests: async () => (await readFile(join(home, 'rpc.jsonl'), 'utf8')).trim().split('\n').map(JSON.parse),
  };
}

async function fakeSource(t, mode = 'normal', timeoutMs = 3000) {
  return (await fakeRuntime(t, mode, { timeoutMs })).source;
}

function liveRuntime(t, mode, now = () => expiry - 1000) {
  return fakeRuntime(t, 'live-' + mode, { timeoutMs: 3000, allowConsume: true, now });
}

test('read-only transport negotiates the pinned protocol and coalesces concurrent callers', async t => {
  const source = await fakeSource(t);
  assert.equal(source.mode, 'readonly');
  assert.deepEqual(Object.keys(source), ['mode', 'read']);
  const pending = source.read();
  assert.equal(source.read(), pending);
  const snapshot = await pending;
  assert.deepEqual(snapshot.identity, identity);
  assert.equal(snapshot.availableCount, 2);
  assert.deepEqual(snapshot.credits, [{ id: 'mock-credit', expiresAt: 1_794_000_000_000 }]);
  assert.equal(snapshot.remainingPercent, 90);
  assert.equal(snapshot.redeemablePercent, 90);
});

test('signed out skips quota reads and represents unknown inventory', async t => {
  const snapshot = await (await fakeSource(t, 'signed-out')).read();
  assert.equal(snapshot.identity, null);
  assert.equal(snapshot.availableCount, null);
  assert.deepEqual(snapshot.credits, []);
});

test('unsupported runtime, deadlines, huge frames and unsolicited RPCs fail safely', async t => {
  for (const [mode, code, timeout] of [
    ['wrong-version', 'runtime-incompatible', 3000],
    ['stall', 'timed-out', 150],
    ['oversized', 'protocol-error', 3000],
    ['server-request', 'protocol-error', 3000],
  ]) {
    const source = await fakeSource(t, mode, timeout);
    await assert.rejects(source.read(), { name: 'CodexSourceError', code, message: code });
  }
});

test('inventory normalizes missing details, invalid dates and ambiguous rows without inventing account scope', () => {
  const account = { type: 'chatgpt', email: 'mock@example.test', accountId: 'unsupported', workspaceId: 'unsupported' };
  const first = normalizeSnapshot(account, { rateLimitResetCredits: { availableCount: 3, credits: null } });
  assert.deepEqual(first.identity, { accountId: null, scope: null, email: 'mock@example.test' });
  assert.equal(first.availableCount, 3);
  assert.equal(first.creditsKnown, false);

  const credit = { status: 'available', resetType: 'codexRateLimits' };
  const second = normalizeSnapshot(account, {
    rateLimits: { limitId: 'unrelated', primary: { usedPercent: 50 } },
    rateLimitResetCredits: { availableCount: 7, credits: [
      { ...credit, id: 'unknown-expiry', expiresAt: '1794000000' },
      { ...credit, id: 'duplicate', expiresAt: 1_794_000_000 },
      { ...credit, id: 'duplicate', status: 'redeeming' },
      { ...credit, id: 'redeemed', status: 'redeemed' },
      { ...credit, id: 'not-codex', resetType: 'unknown' },
      { ...credit, id: 'control\u0000character' },
    ] },
  });
  assert.equal(second.creditsKnown, true);
  assert.equal(second.availableCount, 7);
  assert.equal(second.remainingPercent, null);
  assert.deepEqual(second.credits, [{ id: 'unknown-expiry', expiresAt: null }]);
});

test('live transport rechecks identity and sends exactly one explicit credit ID and key in the same session', async t => {
  for (const [wire, result] of [
    ['reset', 'reset'], ['alreadyRedeemed', 'already-redeemed'],
    ['nothingToReset', 'nothing-to-reset'], ['noCredit', 'no-credit'],
    ['secondary', 'reset'],
  ]) {
    const { source, requests } = await liveRuntime(t, wire);
    assert.equal(source.mode, 'live');
    assert.equal(await source.consume({ ...operation, recovering: wire === 'alreadyRedeemed' }), result);
    const rpc = await requests();
    assert.deepEqual(rpc.map(row => row.method), [
      'initialize', 'initialized', 'account/read', 'account/rateLimits/read', 'account/read',
      'account/rateLimitResetCredit/consume',
    ]);
    assert.deepEqual(rpc.at(-1).params, { creditId: operation.id, idempotencyKey: operation.key });
  }
});

test('live preflight blocks workspace/member changes, missing targets, expiry, quota recovery and pause', async t => {
  for (const [mode, code, overrides, now] of [
    ['other-workspace', 'identity-changed'],
    ['member-changed', 'identity-changed'],
    ['notified', 'identity-changed'],
    ['missing-credit', 'credit-unavailable'],
    ['missing-credit', 'credit-unavailable', { recovering: true }],
    ['reset', 'credit-unavailable', { id: 'wrong-id' }],
    ['full', 'preflight-ineligible'],
    ['reset', 'expired', {}, () => expiry],
    ['reset', 'preflight-ineligible', {}, () => operation.startsAt - 1],
    ['reset', 'cancelled', { maySend: () => false }],
  ]) {
    const { source, requests } = await liveRuntime(t, mode, now);
    await assert.rejects(source.consume({ ...operation, ...overrides }), { code, notSent: true });
    assert.ok(!(await requests()).some(row => row.method === 'account/rateLimitResetCredit/consume'));
  }
});

test('a failed response after send is ambiguous and exposes no raw RPC text', async t => {
  const { source, requests } = await liveRuntime(t, 'ambiguous');
  await assert.rejects(source.consume(operation), error =>
    error.code === 'read-failed' && error.notSent !== true && error.message === 'read-failed'
  );
  assert.equal((await requests()).at(-1).method, 'account/rateLimitResetCredit/consume');
});
