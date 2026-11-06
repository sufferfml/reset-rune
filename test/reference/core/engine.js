// Serializes reads and mutations. Live dispatch requires consent for the bound identity.
import { createHash, randomUUID } from 'node:crypto';
import { addEvent, fault, sameIdentity, validateConfig, verified } from './state.js';

const terminal = new Set(['reset', 'reset-unverified', 'no-credit', 'missed']);
const unsettled = new Set(['intent', 'unconfirmed']);
const retryMs = 30_000;
const digest = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
const authorization = identity => verified(identity)
  ? digest(['reset-rune-live-v1', identity.accountId, identity.scope]) : null;

export function createEngine({ source, store, now = Date.now, key = randomUUID, onConfig, onEvent }) {
  let state = store.read();
  let snapshot = null;
  let lastCheckedAt = null;
  let status = 'idle';
  let readError = null;
  let queue = Promise.resolve();
  const live = source.mode === 'live';
  const canConsume = (live || source.mode === 'mock') && typeof source.consume === 'function';
  let closing = false;
  let pausing = 0;
  let bindingRevoked = false;

  function enabled() {
    return canConsume && state.config.enabled && (!live || (!bindingRevoked
      && Boolean(state.liveAuthorization) && state.liveAuthorization === authorization(state.binding)));
  }

  function consentFor(lead) {
    const binding = authorization(snapshot?.identity);
    return live && binding ? digest([binding, lead]) : null;
  }

  function serialize(job) {
    const result = queue.then(job);
    queue = result.catch(() => {});
    return result;
  }

  async function commit(edit) {
    const next = structuredClone(state);
    edit(next);
    await store.write(next);
    state = next;
  }

  function view() {
    return {
      config: { ...state.config, enabled: enabled() }, mode: source.mode, snapshot: structuredClone(snapshot),
      consent: consentFor(state.config.lead),
      status, error: readError, events: structuredClone(state.events), lastCheckedAt
    };
  }

  async function revokeBinding() {
    // Inhibit immediately, even if the journal cannot be written.
    bindingRevoked = true;
    await commit(next => {
      next.config.enabled = false;
      next.liveAuthorization = null;
      addEvent(next, 'paused', now());
    });
  }

  async function read() {
    status = 'checking';
    try {
      snapshot = await source.read();
      if (live && enabled() && verified(snapshot?.identity) && !sameIdentity(state.binding, snapshot.identity)) {
        await revokeBinding();
      }
      readError = null;
      lastCheckedAt = now();
      return true;
    } catch (error) {
      snapshot = null;
      status = 'error';
      readError = ['runtime-missing', 'runtime-incompatible', 'timed-out', 'read-failed', 'protocol-error']
        .includes(error.code) ? error.code : 'read-failed';
      return false;
    }
  }

  function bindingStatus() {
    if (!canConsume) return 'readonly';
    if (!verified(snapshot?.identity)) return 'identity-unknown';
    if (state.binding && !sameIdentity(state.binding, snapshot.identity)) return 'identity-changed';
    if (enabled() && !state.binding) return 'identity-unknown';
    return enabled() ? 'ready' : 'disabled';
  }

  function observedStatus() {
    const binding = bindingStatus();
    if (binding !== 'ready') return binding;
    const operation = state.operations.find(item =>
      unsettled.has(item.stage) && sameIdentity(item.identity, snapshot.identity)
    );
    if (!operation) return binding;
    return operation.stage === 'unconfirmed' ? 'blocked' : 'pending';
  }

  async function finish(operation, result) {
    await commit(next => {
      next.operations.find(item => item.key === operation.key).stage = result;
      if (next.plan?.id === operation.id) next.plan = null;
      addEvent(next, result, now());
    });
    if (state.config.notify && result === 'reset') {
      try { await onEvent?.(result, state.config.language); } catch { /* The receipt is already durable. */ }
    }
    return result;
  }

  async function dispatch(operation, recovering = false) {
    // Check the clock after the durable write as well as before it.
    if (now() >= operation.expiresAt) return finish(operation, recovering ? 'unconfirmed' : 'missed');
    const startsAt = operation.expiresAt - state.config.lead * 60_000;
    const maySend = () => !closing && pausing === 0 && enabled() && now() >= startsAt && now() < operation.expiresAt;
    if (!maySend()) {
      if (recovering) return 'pending';
      await finish(operation, 'deferred');
      return 'blocked';
    }
    let result;
    try {
      result = await source.consume({ id: operation.id, key: operation.key, identity: operation.identity,
        expiresAt: operation.expiresAt, startsAt, recovering, maySend });
    } catch (error) {
      if (error?.notSent) {
        if (live && error.code === 'identity-changed') await revokeBinding();
        if (recovering) {
          if (['expired', 'credit-unavailable'].includes(error.code)) return finish(operation, 'unconfirmed');
          return 'pending';
        }
        if (error.code === 'expired') return finish(operation, 'missed');
        await finish(operation, 'deferred');
        return error.code === 'identity-changed' ? 'identity-changed' : 'blocked';
      }
      return 'pending';
    }
    if (live && recovering && ['nothing-to-reset', 'no-credit'].includes(result)) return finish(operation, 'unconfirmed');
    if (result === 'nothing-to-reset' || result === 'no-credit') return finish(operation, result);
    if (result !== 'reset' && result !== 'already-redeemed') return 'pending';
    // Persist the confirmed response first. A failed refresh cannot undo it.
    await finish(operation, 'reset-unverified');
    if (await read() && sameIdentity(operation.identity, snapshot.identity)) return finish(operation, 'reset');
    return 'reset-unverified';
  }

  async function evaluate() {
    status = bindingStatus();
    if (status !== 'ready' || closing || pausing > 0) return;
    const forAccount = state.operations.filter(item => sameIdentity(item.identity, snapshot.identity));
    const pending = forAccount.find(item => unsettled.has(item.stage));
    if (pending) {
      if (pending.stage === 'unconfirmed') { status = 'blocked'; return; }
      if (now() >= pending.expiresAt) { status = await finish(pending, 'unconfirmed'); return; }
      if (now() - pending.attemptedAt < retryMs) { status = 'pending'; return; }
      await commit(next => {
        next.operations.find(item => item.key === pending.key).attemptedAt = now();
      });
      status = await dispatch(pending, true);
      return;
    }
    const acknowledged = forAccount.find(item => item.stage === 'reset-unverified');
    if (acknowledged) {
      status = await finish(acknowledged, 'reset');
      return;
    }
    const savedPlan = state.plan;
    if (savedPlan && sameIdentity(savedPlan.identity, snapshot.identity) && now() >= savedPlan.expiresAt) {
      await commit(next => {
        next.plan = null;
        next.operations.push({ ...savedPlan, key: key(), stage: 'missed' });
        addEvent(next, 'missed', now());
      });
      status = 'missed';
      return;
    }

    if (!Number.isSafeInteger(snapshot.availableCount) || snapshot.availableCount < 0) { status = 'error'; return; }
    if (!(snapshot.availableCount > 0)) { status = 'no-credits'; return; }
    const remaining = Object.hasOwn(snapshot, 'redeemablePercent') ? snapshot.redeemablePercent : snapshot.remainingPercent;
    if (!Number.isFinite(remaining) || remaining < 0 || remaining > 100) { status = 'blocked'; return; }
    const known = snapshot.credits.filter(item =>
      typeof item.id === 'string' && item.id.length > 0 && Number.isSafeInteger(item.expiresAt)
    );
    const inventoryRevision = digest([snapshot.availableCount,
      known.map(item => [item.id, item.expiresAt]).sort(([left], [right]) => left.localeCompare(right))]);
    if (live && forAccount.some(item => item.stage === 'no-credit' && item.inventoryRevision === inventoryRevision)) {
      status = 'no-credit'; return;
    }
    const at = now();
    const eligible = known.filter(item => !forAccount.some(operation =>
      operation.id === item.id && terminal.has(operation.stage)
    )).sort((a, b) => a.expiresAt - b.expiresAt);
    const expired = eligible.find(item => item.expiresAt <= at);
    if (expired) {
      await commit(next => {
        next.operations.push({ ...expired, identity: state.binding, key: key(), stage: 'missed' });
        addEvent(next, 'missed', at);
      });
      status = 'missed';
      return;
    }
    const candidate = eligible[0];
    if (!candidate) { status = known.length ? 'waiting' : 'missing-expiry'; return; }
    if (state.plan?.id !== candidate.id || state.plan.expiresAt !== candidate.expiresAt
      || !sameIdentity(state.plan.identity, snapshot.identity)) {
      await commit(next => { next.plan = { ...candidate, identity: state.binding }; });
    }
    if (at < candidate.expiresAt - state.config.lead * 60_000) { status = 'outside-window'; return; }
    if (remaining >= 100) { status = 'waiting'; return; }
    const prior = forAccount.find(item => item.id === candidate.id && ['nothing-to-reset', 'deferred'].includes(item.stage));
    const revision = snapshot.quotaRevision ?? String(remaining);
    if (prior?.stage === 'nothing-to-reset' && prior.revision === revision) { status = 'rejected'; return; }

    const operation = {
      ...candidate, identity: state.binding, key: prior?.key ?? key(), stage: 'intent',
      revision, inventoryRevision, attemptedAt: at
    };
    await commit(next => {
      next.operations = next.operations.filter(item => item.key !== operation.key);
      next.operations.push(operation);
      addEvent(next, 'intent', at);
    });
    status = await dispatch(operation);
  }

  return {
    view,
    tick: ({ manual = false } = {}) => serialize(async () => {
      if (await read()) {
        if (manual) {
          // A manual refresh never initiates a redemption.
          status = observedStatus();
          await commit(next => addEvent(next, 'checked', now()));
        } else {
          try { await evaluate(); }
          catch { status = 'error'; }
        }
      }
      return view();
    }),
    configure: async request => {
      if (!request || typeof request !== 'object' || Array.isArray(request)) throw fault('invalid-config', 400);
      const { consent, ...patch } = request;
      validateConfig(patch);
      const pause = patch.enabled === false;
      if (pause) pausing++;
      try {
        return await serialize(async () => {
          if (patch.enabled === true) {
            if (!canConsume) throw fault('readonly');
            if (!(await read()) || !verified(snapshot.identity)) throw fault('identity-unavailable');
            if (state.binding && !sameIdentity(state.binding, snapshot.identity)) {
              status = 'identity-changed';
              throw fault('binding-required');
            }
            if (live && consent !== consentFor(patch.lead ?? state.config.lead)) throw fault('consent-required');
          }
          if (Object.hasOwn(patch, 'startup') && patch.startup !== state.config.startup) {
            await onConfig?.(patch.startup);
          }
          const wasEnabled = enabled();
          try {
            await commit(next => {
              if (patch.enabled === true && !next.binding) {
                next.binding = snapshot.identity;
                addEvent(next, 'bound', now());
              }
              if (live && Object.hasOwn(patch, 'enabled')) {
                next.liveAuthorization = patch.enabled ? authorization(next.binding) : null;
              }
              if (Object.hasOwn(patch, 'enabled') && wasEnabled !== patch.enabled) {
                addEvent(next, patch.enabled ? 'enabled' : 'paused', now());
              }
              Object.assign(next.config, patch);
            });
          } catch (error) {
            if (Object.hasOwn(patch, 'startup')) {
              try { await onConfig?.(state.config.startup); } catch { /* Preserve the original write error. */ }
            }
            throw error;
          }
          if (patch.enabled === true) bindingRevoked = false;
          if (Object.hasOwn(patch, 'enabled')) status = observedStatus();
          return view();
        });
      } finally {
        if (pause) pausing--;
      }
    },
    bind: consent => serialize(async () => {
      if (!canConsume) throw fault('readonly');
      if (enabled()) throw fault('pause-first');
      if (!(await read()) || !verified(snapshot.identity)) throw fault('identity-unavailable');
      if (live && consent !== consentFor(state.config.lead)) throw fault('consent-required');
      await commit(next => {
        next.binding = snapshot.identity;
        next.plan = null;
        next.config.enabled = false;
        if (live) next.liveAuthorization = null;
        addEvent(next, 'bound', now());
      });
      status = 'disabled';
      return view();
    }),
    close: () => {
      closing = true;
      return serialize(() => source.close?.());
    }
  };
}
