// Configuration, account binding, and the durable execution journal.
export const defaults = Object.freeze({
  enabled: false, lead: 10, language: 'en', appearance: 'system', startup: false, notify: true
});

export function initialState() {
  return { version: 1, config: { ...defaults }, binding: null, plan: null, operations: [], events: [] };
}

const rules = {
  enabled: value => typeof value === 'boolean',
  lead: value => [5, 10, 30, 60].includes(value),
  language: value => ['en', 'zh'].includes(value),
  appearance: value => ['system', 'light', 'dark'].includes(value),
  startup: value => typeof value === 'boolean',
  notify: value => typeof value === 'boolean'
};

export function validateConfig(patch) {
  if (!patch || typeof patch !== 'object' || Array.isArray(patch)) throw fault('invalid-config', 400);
  for (const [key, value] of Object.entries(patch)) {
    if (!Object.hasOwn(rules, key) || !rules[key](value)) throw fault('invalid-config', 400);
  }
}

export function fault(code, httpStatus = 409) {
  return Object.assign(new Error(code), { code, httpStatus });
}

export function verified(identity) {
  return typeof identity?.accountId === 'string' && identity.accountId.length > 0
    && typeof identity.scope === 'string' && identity.scope.length > 0;
}

export function sameIdentity(left, right) {
  return verified(left) && verified(right)
    && left.accountId === right.accountId && left.scope === right.scope;
}

export function addEvent(state, type, at) {
  state.events.unshift({ at, type });
  state.events.length = Math.min(state.events.length, 100);
}
