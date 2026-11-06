import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createEngine } from './reference/core/engine.js';
import { initialState } from './reference/core/state.js';

const minute = 60_000;
function harness({ result = 'reset', mode = 'mock', startState = initialState() } = {}) {
  const identity = { accountId: 'account-a', scope: 'workspace-a', email: 'example@example.test' };
  let at = 100 * minute;
  let durable = structuredClone(startState);
  let rejectWrite = () => false;
  let failRead = false;
  let afterWrite = () => {};
  let beforeSend = () => {};
  let onConsume = () => result;
  const snapshot = {
    identity, availableCount: 2, remainingPercent: 90,
    credits: [{ id: 'a', expiresAt: 120 * minute }, { id: 'b', expiresAt: 125 * minute }]
  };
  const requests = [];
  const dispatches = [];
  const source = {
    mode,
    async read() {
      if (failRead) throw new Error('offline');
      return structuredClone(snapshot);
    },
    async consume(request) {
      assert.ok(durable.operations.some(item => item.key === request.key && item.stage === 'intent'));
      await beforeSend(request);
      if (!request.maySend()) throw Object.assign(new Error('send cancelled'), { notSent: true, code: 'deferred' });
      const { id, key } = request;
      requests.push({ id, key });
      dispatches.push(request);
      return onConsume(request);
    }
  };
  const options = {
    source, now: () => at, key: () => 'key-' + (++counter),
    store: {
      read: () => structuredClone(durable),
      async write(next) {
        if (rejectWrite(next)) throw new Error('disk error');
        durable = structuredClone(next);
        afterWrite(durable);
      }
    }
  };
  let counter = 0;
  return {
    create: () => createEngine(options), requests, dispatches, snapshot,
    at: value => { at = value * minute; },
    failWrite: value => { rejectWrite = typeof value === 'function' ? value : () => value; },
    failRead: value => { failRead = value; },
    respond: handler => { onConsume = handler; },
    afterWrite: handler => { afterWrite = handler; },
    beforeSend: handler => { beforeSend = handler; }
  };
}

test('default and manual refresh never consume, earliest becomes eligible at the exact lead boundary', async () => {
  const h = harness();
  const engine = h.create();
  h.at(110);
  assert.equal((await engine.tick()).status, 'disabled');
  await engine.configure({ enabled: true });
  await engine.tick({ manual: true });
  h.at(109.99);
  assert.equal((await engine.tick()).status, 'outside-window');
  assert.equal(h.requests.length, 0);
  h.at(110);
  assert.equal((await engine.tick()).status, 'reset');
  assert.deepEqual(h.requests, [{ id: 'a', key: 'key-1' }]);
});

test('resuming at expiration after inventory disappears records missed and never sends the expired target', async () => {
  const h = harness();
  const engine = h.create();
  await engine.configure({ enabled: true });
  await engine.tick();
  h.at(120);
  h.snapshot.credits.shift();
  h.snapshot.availableCount = 1;
  assert.equal((await engine.tick()).status, 'missed');
  assert.deepEqual(h.requests, []);
});

test('first intent finishing at expiry records a miss without an ambiguous request', async () => {
  const h = harness();
  const engine = h.create();
  await engine.configure({ enabled: true });
  h.at(119);
  h.afterWrite(state => {
    if (state.operations.some(item => item.stage === 'intent')) h.at(120);
  });
  assert.equal((await engine.tick()).status, 'missed');
  assert.deepEqual(h.requests, []);
});

test('write failure, unknown metadata and read failure cannot send a request', async () => {
  const h = harness();
  const engine = h.create();
  await engine.configure({ enabled: true });
  h.at(110);
  h.failWrite(true);
  assert.equal((await engine.tick()).status, 'error');
  h.failWrite(false);
  h.failRead(true);
  assert.equal((await engine.tick()).status, 'error');
  h.failRead(false);
  h.snapshot.credits.forEach(item => { item.expiresAt = null; });
  assert.equal((await engine.tick()).status, 'missing-expiry');
  assert.deepEqual(h.requests, []);
});

test('lost response resumes after restart with same key and ID, never swaps to the next credit', async () => {
  const h = harness();
  let engine = h.create();
  await engine.configure({ enabled: true });
  h.at(110);
  h.respond(() => { throw new Error('response lost'); });
  assert.equal((await engine.tick()).status, 'pending');
  engine = h.create();
  h.at(111);
  h.snapshot.credits.shift();
  h.snapshot.availableCount = 1;
  h.respond(() => 'already-redeemed');
  assert.equal((await engine.tick()).status, 'reset');
  assert.deepEqual(h.requests, [{ id: 'a', key: 'key-1' }, { id: 'a', key: 'key-1' }]);
});

test('unconfirmed attempt blocks following credits after expiration', async () => {
  const h = harness();
  const engine = h.create();
  await engine.configure({ enabled: true });
  h.at(110);
  h.respond(() => { throw new Error('unknown outcome'); });
  await engine.tick();
  assert.equal((await engine.tick({ manual: true })).status, 'pending');
  h.at(120);
  assert.equal((await engine.tick()).status, 'unconfirmed');
  h.at(121);
  assert.equal((await engine.tick()).status, 'blocked');
  assert.equal(h.requests.length, 1);
});

test('90% remaining can be rejected by the simulated provider and only retried on new usage', async () => {
  const h = harness({ result: 'nothing-to-reset' });
  const engine = h.create();
  await engine.configure({ enabled: true });
  h.at(110);
  assert.equal((await engine.tick()).status, 'nothing-to-reset');
  assert.equal((await engine.tick()).status, 'rejected');
  assert.equal(h.requests.length, 1);
  h.snapshot.remainingPercent = 89;
  h.respond(() => 'reset');
  assert.equal((await engine.tick()).status, 'reset');
  assert.deepEqual(h.requests[0], h.requests[1]);
});

test('simultaneous candidates use the earliest ID, and a full refreshed allowance stops the next one', async () => {
  const h = harness();
  const engine = h.create();
  h.at(116);
  await engine.configure({ enabled: true });
  h.respond(() => {
    h.snapshot.remainingPercent = 100;
    return 'reset';
  });
  await engine.tick();
  h.at(115.5);
  assert.equal((await engine.tick()).status, 'waiting');
  assert.deepEqual(h.requests, [{ id: 'a', key: 'key-1' }]);
});

test('no-credit never falls through to a second target during the same scheduled check', async () => {
  const h = harness({ result: 'no-credit' });
  const engine = h.create();
  h.at(116);
  await engine.configure({ enabled: true });
  assert.equal((await engine.tick()).status, 'no-credit');
  assert.deepEqual(h.requests, [{ id: 'a', key: 'key-1' }]);
});

test('confirmed receipt survives failed readback, and recovers without consuming again', async () => {
  const h = harness();
  const engine = h.create();
  await engine.configure({ enabled: true });
  h.at(110);
  h.respond(() => { h.failRead(true); return 'reset'; });
  assert.equal((await engine.tick()).status, 'reset-unverified');
  h.failRead(false);
  assert.equal((await h.create().tick()).status, 'reset');
  assert.equal(h.requests.length, 1);
});

test('workspace switch requires pause and explicit binding, and mock preference changes do not dispatch', async () => {
  const h = harness();
  const engine = h.create();
  await engine.configure({ enabled: true });
  h.at(110);
  h.snapshot.identity.scope = 'other';
  assert.equal((await engine.tick()).status, 'identity-changed');
  await assert.rejects(engine.configure({ enabled: true }), { code: 'binding-required' });
  await engine.configure({ enabled: false, lead: 30, appearance: 'dark', language: 'zh' });
  await engine.bind();
  await engine.configure({ enabled: true });
  assert.deepEqual(h.requests, []);
});

test('a readonly provider can never consume or arm the scheduler', async () => {
  const h = harness({ mode: 'readonly' });
  const engine = h.create();
  h.at(110);
  await assert.rejects(engine.configure({ enabled: true }), { code: 'readonly' });
  assert.equal((await engine.tick()).status, 'readonly');
  assert.deepEqual(h.requests, []);
});

async function enableLive(engine) {
  const { consent } = await engine.tick({ manual: true });
  assert.match(consent, /^[a-f0-9]{64}$/);
  return engine.configure({ enabled: true, consent });
}

test('enabled preferences without authorization do not grant live consent and stale confirmations are rejected', async () => {
  const old = initialState();
  old.config = { ...old.config, enabled: true, lead: 30, language: 'zh' };
  old.binding = { accountId: 'account-a', scope: 'workspace-a' };
  const h = harness({ mode: 'live', startState: old });
  const engine = h.create();
  h.at(110);
  const initial = await engine.tick();
  assert.equal(initial.config.enabled, false);
  assert.equal(initial.config.language, 'zh');
  assert.equal(initial.config.lead, 30);
  await assert.rejects(engine.configure({ enabled: true }), { code: 'consent-required' });
  await engine.configure({ lead: 10 });
  await assert.rejects(engine.configure({ enabled: true, consent: initial.consent }), { code: 'consent-required' });
  const current = engine.view().consent;
  h.snapshot.identity.scope = 'workspace-b';
  await assert.rejects(engine.configure({ enabled: true, consent: current }), { code: 'binding-required' });
  await assert.rejects(engine.bind(current), { code: 'consent-required' });
  assert.deepEqual(h.requests, []);
});

test('live consent applies to an exact target only during the lead window', async () => {
  const h = harness({ mode: 'live' });
  const engine = h.create();
  h.at(109.99);
  assert.equal((await enableLive(engine)).config.enabled, true);
  assert.equal((await engine.tick()).status, 'outside-window');
  h.at(110);
  h.snapshot.redeemablePercent = 100;
  assert.equal((await engine.tick()).status, 'waiting');
  h.snapshot.remainingPercent = 100;
  h.snapshot.redeemablePercent = 90;
  await engine.tick({ manual: true });
  assert.deepEqual(h.requests, []);
  assert.equal((await engine.tick()).status, 'reset');
  await engine.tick();
  assert.deepEqual(h.requests, [{ id: 'a', key: 'key-1' }]);
  const { id, identity, expiresAt, startsAt, recovering } = h.dispatches[0];
  assert.deepEqual({ id, identity, expiresAt, startsAt, recovering }, {
    id: 'a', identity: h.snapshot.identity, expiresAt: 120 * minute, startsAt: 110 * minute, recovering: false
  });
});

test('live binding revocation survives an account round trip and rebind still requires opt-in', async () => {
  const h = harness({ mode: 'live' });
  const engine = h.create();
  await enableLive(engine);
  h.at(110);
  h.snapshot.identity.scope = 'workspace-b';
  const changed = await engine.tick();
  assert.equal(changed.status, 'identity-changed');
  assert.equal(changed.config.enabled, false);
  h.snapshot.identity.scope = 'workspace-a';
  const restarted = h.create();
  assert.equal((await restarted.tick()).status, 'disabled');
  h.snapshot.identity.scope = 'workspace-b';
  const { consent } = await restarted.tick({ manual: true });
  assert.equal((await restarted.bind(consent)).config.enabled, false);
  assert.equal((await restarted.tick()).status, 'disabled');
  assert.deepEqual(h.requests, []);
});

test('a negative live response after a lost result stays ambiguous and blocks later targets', async () => {
  const h = harness({ mode: 'live' });
  let engine = h.create();
  await enableLive(engine);
  h.at(115);
  h.respond(() => { throw new Error('response lost'); });
  assert.equal((await engine.tick()).status, 'pending');
  engine = h.create();
  h.at(116);
  h.respond(() => 'no-credit');
  assert.equal((await engine.tick()).status, 'unconfirmed');
  assert.equal((await engine.tick()).status, 'blocked');
  assert.deepEqual(h.requests, [{ id: 'a', key: 'key-1' }, { id: 'a', key: 'key-1' }]);
  assert.equal(h.dispatches[1].recovering, true);
});

test('a disappeared live target after a lost result is blocked without sending a second request', async () => {
  const h = harness({ mode: 'live' });
  let engine = h.create();
  await enableLive(engine);
  h.at(115);
  h.respond(() => { throw new Error('response lost'); });
  assert.equal((await engine.tick()).status, 'pending');
  engine = h.create();
  h.at(116);
  h.snapshot.credits.shift();
  h.snapshot.availableCount = 1;
  h.beforeSend(({ id, recovering }) => {
    assert.equal(id, 'a');
    assert.equal(recovering, true);
    throw Object.assign(new Error('target missing'), { notSent: true, code: 'credit-unavailable' });
  });
  assert.equal((await engine.tick()).status, 'unconfirmed');
  assert.equal((await engine.tick()).status, 'blocked');
  assert.deepEqual(h.requests, [{ id: 'a', key: 'key-1' }]);
});

test('live no-credit stops subsequent targets until inventory changes', async () => {
  const h = harness({ mode: 'live', result: 'no-credit' });
  const engine = h.create();
  await enableLive(engine);
  h.at(116);
  assert.equal((await engine.tick()).status, 'no-credit');
  assert.equal((await engine.tick()).status, 'no-credit');
  assert.deepEqual(h.requests, [{ id: 'a', key: 'key-1' }]);
  h.snapshot.credits.shift();
  h.snapshot.availableCount = 1;
  h.respond(() => 'reset');
  assert.equal((await engine.tick()).status, 'reset');
  assert.deepEqual(h.requests, [{ id: 'a', key: 'key-1' }, { id: 'b', key: 'key-2' }]);
});

for (const action of ['pause', 'close']) {
  test(`live ${action} prevents sending an in-progress preflight`, { timeout: 3000 }, async () => {
    const h = harness({ mode: 'live' });
    const engine = h.create();
    await enableLive(engine);
    h.at(110);
    const ready = Promise.withResolvers();
    const proceed = Promise.withResolvers();
    h.beforeSend(() => {
      ready.resolve();
      return proceed.promise;
    });
    const poll = engine.tick();
    await ready.promise;
    const stop = action === 'pause' ? engine.configure({ enabled: false }) : engine.close();
    proceed.resolve();
    await Promise.all([poll, stop]);
    assert.deepEqual(h.requests, []);
  });
}

test('live dispatch is withheld if the intent cannot be persisted', async () => {
  const h = harness({ mode: 'live' });
  const engine = h.create();
  await enableLive(engine);
  h.at(110);
  h.failWrite(next => next.operations.some(item => item.stage === 'intent'));
  assert.equal((await engine.tick()).status, 'error');
  assert.deepEqual(h.requests, []);
});
