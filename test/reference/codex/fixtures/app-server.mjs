import assert from 'node:assert/strict';
import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { basename, dirname, join } from 'node:path';
import { createInterface } from 'node:readline';

const args = process.argv.slice(2);
const metadataAt = args.indexOf('--fixture-mode');
const mode = metadataAt >= 0 ? args[metadataAt + 1] : basename(process.env.CODEX_HOME);
const fixtureDir = metadataAt >= 0 ? args[metadataAt + 3] : dirname(process.env.CODEX_HOME);
if (metadataAt >= 0) {
  assert.equal(args[metadataAt + 2], '--fixture-dir');
  args.splice(metadataAt, 4);
}
const scenario = mode.startsWith('live-') ? mode.slice('live-'.length) : mode;
if (args.length === 1 && args[0] === '--version') {
  const versions = {
    'wrong-version': 'other-cli 99.0.0',
    'newer-version': 'codex-cli 0.169.0',
    'future-version': 'codex-cli 99.0.0',
    'older-version': 'codex-cli 0.100.0',
    'lexically-newer-old-version': 'codex-cli 0.99.999',
    'minimum-version': 'codex-cli 0.153.0',
    'below-minimum': 'codex-cli 0.152.999',
    'minimum-prerelease': 'codex-cli 0.153.0-alpha.1',
    'minimum-build': 'codex-cli 0.153.0+build.2',
    'next-prerelease': 'codex-cli 0.153.1-alpha.1',
    'invalid-prerelease': 'codex-cli 0.169.0-alpha.01',
    'prerelease-version': 'codex-cli 0.169.0-alpha.11.1+build.2',
    'multiline-version': 'codex-cli 0.169.0\nother-cli 1.0.0',
  };
  process.stdout.write(`${versions[scenario] ?? (scenario.startsWith('newer-version-') ? 'codex-cli 0.169.0' : 'codex-cli 0.153.0')}\n`);
} else if (args[0] === 'app-server' && args[1] === 'generate-json-schema') {
  assert.deepEqual(args.slice(0, 3), ['app-server', 'generate-json-schema', '--out']);
  assert.equal(args.length, 4);
  assert.notEqual(basename(process.env.CODEX_HOME), mode, 'Schema generation must not reuse account storage');
  appendFileSync(join(fixtureDir, 'schema-probes.txt'), `${JSON.stringify({ home: process.env.HOME, codexHome: process.env.CODEX_HOME })}\n`);
  if (scenario === 'newer-version-no-schema') process.exit(1);
  const params = { type: 'object', properties: { creditId: { type: ['string', 'null'] }, idempotencyKey: { type: 'string' } }, required: ['idempotencyKey'] };
  if (scenario === 'newer-version-missing-credit-schema') delete params.properties.creditId;
  const request = { oneOf: [{ properties: { method: { type: 'string', enum: ['account/rateLimitResetCredit/consume'] }, params: { $ref: '#/definitions/ConsumeParams' } } }], definitions: { ConsumeParams: params } };
  const response = { type: 'object', properties: { outcome: { type: 'string', enum: ['reset', 'nothingToReset', 'noCredit', 'alreadyRedeemed'] } }, required: ['outcome'] };
  mkdirSync(join(args[3], 'v2'), { recursive: true });
  writeFileSync(join(args[3], 'ClientRequest.json'), JSON.stringify(request));
  writeFileSync(join(args[3], 'v2', 'ConsumeAccountRateLimitResetCreditResponse.json'), JSON.stringify(response));
  if (scenario === 'newer-version-changes-during-probe') appendFileSync(join(fixtureDir, 'codex'), '\n');
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
      assert.equal(request.params.capabilities.experimentalApi, false);
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
      if (scenario === 'extra-fields' && account) account.futureAccountField = { enabled: true };
      const result = { account, requiresOpenaiAuth: true };
      if (scenario === 'missing-account') delete result.account;
      const reply = { id: request.id, result };
      if (mode === 'live-notified' && confirming) {
        process.stdout.write(JSON.stringify(reply) + '\n' + JSON.stringify({ method: 'account/updated' }) + '\n');
      } else send(reply);
    } else if (request.method === 'account/rateLimits/read') {
      assert.notEqual(mode, 'signed-out');
      if (['method-missing', 'read-method-missing', 'invalid-params', 'read-invalid-params'].includes(scenario)) {
        send({ id: request.id, error: { code: scenario.includes('method-missing') ? -32601 : -32602, message: 'fixture private incompatibility' } });
        continue;
      }
      const result = {
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
      };
      if (scenario === 'missing-rate-limits') delete result.rateLimits;
      if (scenario === 'extra-fields') {
        result.futureQuotaField = { remaining: 42 };
        result.rateLimits.futureBucketField = 'ignored';
        result.rateLimitResetCredits.futureInventoryField = 1;
      }
      send({ id: request.id, result });
    } else if (request.method === 'account/rateLimitResetCredit/consume') {
      if (mode === 'live-ambiguous') {
        send({ id: request.id, error: { code: -32603, message: 'fixture private payload' } });
      } else if (mode === 'live-consume-method-missing') {
        send({ id: request.id, error: { code: -32601, message: 'fixture private changed consume method' } });
      } else {
        const outcome = ['secondary', 'dynamic', 'newer-version', 'extra-fields'].includes(scenario) ? 'reset' : scenario;
        send({ id: request.id, result: { outcome } });
      }
    }
  }
}
