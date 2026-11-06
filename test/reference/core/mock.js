// Uses a persistent synthetic inventory for deterministic crash/restart behavior.
export function createMockSource({ load, save, now = Date.now, decision = () => 'reset' }) {
  let model = load();
  if (!model) {
    const start = now();
    model = {
      identity: { accountId: 'sample-account', scope: 'sample-workspace', email: 'demo@example.com' },
      credits: [
        { id: 'sample-1', expiresAt: start + 20 * 60_000 },
        { id: 'sample-2', expiresAt: start + 7 * 86400_000 }
      ],
      remainingPercent: 90,
      redeemed: {}
    };
  }
  return {
    mode: 'mock',
    async read() {
      await save(model);
      const credits = model.credits.filter(item => now() < item.expiresAt);
      return structuredClone({
        identity: model.identity, credits, availableCount: credits.length,
        remainingPercent: model.remainingPercent
      });
    },
    async consume({ id, key }) {
      if (Object.hasOwn(model.redeemed, key)) {
        return model.redeemed[key] === id ? 'already-redeemed' : 'no-credit';
      }
      if (!model.credits.some(item => item.id === id && now() < item.expiresAt)) return 'no-credit';
      const result = decision({ id, key, remainingPercent: model.remainingPercent });
      if (result !== 'reset') return result;
      const next = {
        ...model, credits: model.credits.filter(item => item.id !== id),
        remainingPercent: 100, redeemed: { ...model.redeemed, [key]: id }
      };
      await save(next);
      model = next;
      return 'reset';
    }
  };
}
