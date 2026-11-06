import assert from 'node:assert/strict';
import { appendFileSync, readFileSync } from 'node:fs';
import { basename, dirname, join } from 'node:path';
import { createInterface } from 'node:readline';

const mode = basename(process.env.CODEX_HOME);
const fixtureDir = dirname(process.env.CODEX_HOME);
const args = process.argv.slice(2);
if (args.length === 1 && args[0] === '--version') {
  process.stdout.write(`codex-cli ${mode === 'wrong-version' ? '99.0.0' : '0.153.0'}\n`);
} else {
  assert.deepEqual(args.slice(0, 3), ['app-server', '--listen', 'stdio://']);
  assert.ok(args.includes('chatgpt_base_url="https://chatgpt.com/backend-api/"'));
  assert.equal(process.env.OPENAI_API_KEY, undefined);
  assert.equal(process.env.CODEX_API_KEY, undefined);
  const methods = ['initialize', 'initialized', 'account/read', 'account/rateLimits/read'];
  if (mode.startsWith('live-')) methods.push('account/read', 'account/rateLimitResetCredit/consume');
  const input = createInterface({ input: process.stdin });
  const send = message => process.stdout.write(JSON.stringify(message) + '\n');
  for await (const line of input) {
    const request = JSON.parse(line);
    appendFileSync(join(fixtureDir, 'rpc.jsonl'), line + '\n');
    assert.equal(request.method, methods.shift());
    if (request.method === 'initialize') {
      assert.equal(request.params.capabilities.experimentalApi, true);
      if (mode === 'stall') continue;
      if (mode === 'oversized') {
        process.stdout.write('x'.repeat(1024 * 1024 + 1));
        continue;
      }
      if (mode === 'server-request') {
        send({ id: 'server-1', method: 'account/chatgptAuthTokens/refresh', params: { hidden: 'sensitive' } });
        continue;
      }
      process.stdout.write(`{"id":${request.id},`);
      await new Promise(resolve => setImmediate(resolve));
      process.stdout.write('"result":{}}\n');
      send({ method: 'account/updated', params: {} });
    } else if (request.method === 'account/read') {
      assert.deepEqual(request.params, { refreshToken: false });
      const confirming = request.id === 4;
      const email = mode === 'live-member-changed' && confirming ? 'another@example.test' : 'mock@example.test';
      const account = mode === 'signed-out' ? null : { type: 'chatgpt', email };
      const reply = { id: request.id, result: { account, requiresOpenaiAuth: true } };
      if (mode === 'live-notified' && confirming) {
        process.stdout.write(JSON.stringify(reply) + '\n' + JSON.stringify({ method: 'account/updated' }) + '\n');
      } else send(reply);
    } else if (request.method === 'account/rateLimits/read') {
      assert.notEqual(mode, 'signed-out');
      send({ id: request.id, result: {
        accountId: mode === 'live-other-workspace' ? 'other-account' : 'mock-account',
        rateLimits: {
          limitId: 'codex',
          primary: { usedPercent: ['live-full', 'live-secondary'].includes(mode) ? 0 : 10, windowDurationMins: 300 },
          secondary: { usedPercent: mode === 'live-secondary' ? 12 : 0, windowDurationMins: 10080 },
        },
        rateLimitResetCredits: { availableCount: 2, credits: mode === 'live-missing-credit' ? [] : [
          {
            id: 'mock-credit', status: 'available', resetType: 'codexRateLimits',
            expiresAt: mode === 'live-dynamic'
              ? Number(readFileSync(join(fixtureDir, 'expiry.txt'), 'utf8')) : 1_794_000_000,
          },
        ] },
      } });
    } else if (request.method === 'account/rateLimitResetCredit/consume') {
      if (mode === 'live-ambiguous') {
        send({ id: request.id, error: { code: -32603, message: 'fixture private payload' } });
      } else {
        const outcome = ['live-secondary', 'live-dynamic'].includes(mode) ? 'reset' : mode.slice('live-'.length);
        send({ id: request.id, result: { outcome } });
      }
    }
  }
}
