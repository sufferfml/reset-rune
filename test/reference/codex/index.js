import { execFile, spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { constants } from 'node:fs';
import { access, realpath } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { homedir } from 'node:os';
import { delimiter, dirname, isAbsolute, join } from 'node:path';
import { promisify } from 'node:util';
import { sameIdentity, verified } from '../core/state.js';

export const SUPPORTED_CODEX_VERSION = '0.153.0';
const execFileAsync = promisify(execFile);
const MAX_LINE_BYTES = 1024 * 1024;
const OFFICIAL_BACKEND = 'chatgpt_base_url="https://chatgpt.com/backend-api/"';
const READ_ACCOUNT = 'account/read';
const outcomes = new Map([
  ['reset', 'reset'],
  ['alreadyRedeemed', 'already-redeemed'],
  ['nothingToReset', 'nothing-to-reset'],
  ['noCredit', 'no-credit'],
]);

export class CodexSourceError extends Error {
  constructor(code) {
    super(code);
    this.name = 'CodexSourceError';
    this.code = code;
  }
}

function beforeSend(error) {
  return Object.assign(error, { notSent: true });
}

const isObject = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const whole = (value, min, max = Number.MAX_SAFE_INTEGER) => Number.isSafeInteger(value) && value >= min && value <= max ? value : null;
const epochMs = value => whole(value, 1, 8_640_000_000_000) === null ? null : value * 1000;

function safeText(value) {
  if (typeof value !== 'string' || value.length === 0 || value.length > 512) return null;
  if (value.trim() !== value || /[\p{Cc}\p{Cf}]/u.test(value)) return null;
  return value;
}

function normalizeWindow(value) {
  if (!isObject(value)) return null;
  const usedPercent = whole(value.usedPercent, 0, 100);
  return {
    remainingPercent: usedPercent === null ? null : 100 - usedPercent,
    durationMinutes: whole(value.windowDurationMins, 1),
    resetsAt: epochMs(value.resetsAt),
  };
}

function normalizeCredits(summary) {
  const availableCount = whole(summary?.availableCount, 0);
  const creditsKnown = Array.isArray(summary?.credits);
  const credits = new Map();
  const duplicates = new Set();
  if (creditsKnown && availableCount !== 0) {
    for (const row of summary.credits) {
      const id = safeText(row?.id);
      if (id === null) continue;
      if (credits.has(id)) duplicates.add(id);
      credits.set(id, row);
    }
  }
  const available = [];
  for (const [id, row] of credits) {
    if (!duplicates.has(id) && row.status === 'available' && row.resetType === 'codexRateLimits') {
      available.push({ id, expiresAt: epochMs(row.expiresAt) });
    }
  }
  return { availableCount, creditsKnown, credits: available };
}

/** Normalize only fields from the documented 0.153.0 responses. */
export function normalizeSnapshot(account, usage) {
  if (account?.type !== 'chatgpt') {
    return {
      identity: null, ...normalizeCredits(null), remainingPercent: null,
      limitId: null, primary: null, secondary: null, redeemablePercent: null, quotaRevision: null,
    };
  }
  const legacy = usage?.rateLimits;
  const codexBucket = usage?.rateLimitsByLimitId?.codex;
  const codexOrUnspecified = value => isObject(value) && (value.limitId == null || value.limitId === 'codex');
  const bucket = codexOrUnspecified(codexBucket) ? codexBucket : codexOrUnspecified(legacy) ? legacy : null;
  const primary = normalizeWindow(bucket?.primary);
  const secondary = normalizeWindow(bucket?.secondary);
  const email = safeText(account.email);
  const accountId = safeText(usage?.accountId);
  // 0.153.0 associates the usage response accountId with the backend workspace
  // header. The ChatGPT email distinguishes members of that same workspace.
  const codexVerified = bucket !== null && (bucket === codexBucket || bucket.limitId === 'codex');
  const scope = codexVerified && accountId && email
    ? 'codex:' + createHash('sha256').update(email).digest('hex') : null;
  const windows = [primary, secondary];
  const remaining = windows.map(window => window?.remainingPercent).filter(Number.isFinite);
  return {
    identity: { accountId, scope, email },
    ...normalizeCredits(usage?.rateLimitResetCredits),
    remainingPercent: primary?.remainingPercent ?? null,
    limitId: safeText(bucket?.limitId),
    primary,
    secondary,
    redeemablePercent: codexVerified && remaining.length > 0 ? Math.min(...remaining) : null,
    quotaRevision: codexVerified ? JSON.stringify(windows) : null,
  };
}

function childEnvironment(source) {
  const keys = ['HOME', 'USER', 'LOGNAME', 'PATH', 'TMPDIR', 'LANG', 'LC_ALL', 'CODEX_HOME',
    'HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY', 'NO_PROXY', 'https_proxy', 'http_proxy', 'all_proxy', 'no_proxy',
    'SSL_CERT_FILE', 'SSL_CERT_DIR'];
  const env = {};
  for (const key of keys) {
    if (typeof source[key] === 'string') env[key] = source[key];
  }
  env.HOME ??= homedir();
  env.PATH = [env.PATH, '/opt/homebrew/bin', '/usr/local/bin', '/usr/bin', '/bin'].filter(Boolean).join(delimiter);
  return env;
}

function nativeNpmExecutable(path) {
  if (process.platform !== 'darwin' || !path.endsWith('/@openai/codex/bin/codex.js')) return path;
  const target = { arm64: 'aarch64-apple-darwin', x64: 'x86_64-apple-darwin' }[process.arch];
  if (!target) return path;
  try {
    const packageJson = createRequire(path).resolve(`@openai/codex-darwin-${process.arch}/package.json`);
    return join(dirname(packageJson), 'vendor', target, 'bin', 'codex');
  } catch {
    return path;
  }
}

async function resolveRuntime(explicit, env) {
  if (explicit && !isAbsolute(explicit)) throw new CodexSourceError('runtime-missing');
  const candidates = explicit ? [explicit] : [
    ...env.PATH.split(delimiter).filter(isAbsolute).map(path => join(path, 'codex')),
    join(env.HOME, '.local', 'bin', 'codex'),
    '/opt/homebrew/bin/codex',
    '/usr/local/bin/codex',
  ];
  const inspected = new Set();
  for (const candidate of new Set(candidates)) {
    let path;
    try {
      path = await realpath(nativeNpmExecutable(await realpath(candidate)));
      await access(path, constants.X_OK);
    } catch {
      continue;
    }
    if (inspected.has(path)) continue;
    inspected.add(path);
    try {
      const { stdout } = await execFileAsync(path, ['--version'], { env, cwd: '/', timeout: 3000, maxBuffer: 8192 });
      if (stdout.trim() === `codex-cli ${SUPPORTED_CODEX_VERSION}`) return path;
    } catch {
      // Probe failures may contain local paths or raw CLI output.
    }
  }
  throw new CodexSourceError(inspected.size ? 'runtime-incompatible' : 'runtime-missing');
}

function redemptionGuard(snapshot, operation, at) {
  if (!verified(snapshot.identity)) return 'identity-unavailable';
  if (!sameIdentity(snapshot.identity, operation.identity)) return 'identity-changed';
  if (at >= operation.expiresAt) return 'expired';
  if (at < operation.startsAt) return 'preflight-ineligible';
  if (!(snapshot.availableCount > 0) || !snapshot.credits.some(credit =>
    credit.id === operation.id && credit.expiresAt === operation.expiresAt
  )) return 'credit-unavailable';
  if (snapshot.redeemablePercent === null || snapshot.redeemablePercent >= 100) return 'preflight-ineligible';
  if (operation.maySend() !== true) return 'cancelled';
  return null;
}

function runAppServer(executable, env, timeoutMs, { operation, now = Date.now } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, ['app-server', '--listen', 'stdio://',
      '-c', OFFICIAL_BACKEND, '-c', 'analytics.enabled=false', '-c', 'mcp_servers={}'], {
      cwd: '/', env, stdio: ['pipe', 'pipe', 'ignore'], shell: false,
    });
    let expectedId = 1;
    let account = null;
    let quota;
    let sent = false;
    let pending = Buffer.alloc(0);
    let settled = false;
    let timer = setTimeout(() => finish('timed-out'), timeoutMs);

    function finish(code, result) {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      child.stdin.destroy();
      child.stdout.destroy();
      child.kill('SIGKILL');
      if (code) {
        const error = new CodexSourceError(code);
        reject(operation && !sent ? beforeSend(error) : error);
      } else resolve(result);
    }

    function send(message) {
      child.stdin.write(JSON.stringify(message) + '\n', error => {
        if (error) finish('read-failed');
      });
    }

    function receive(message) {
      if (!isObject(message)) return finish('protocol-error');
      if (typeof message.method === 'string') {
        // Notifications never cause outbound RPCs, and server requests cannot widen this client’s capabilities.
        if (Object.hasOwn(message, 'id')) return finish('protocol-error');
        if (expectedId >= 3 && message.method === 'account/updated') {
          return finish(operation ? 'identity-changed' : 'read-failed');
        }
        return;
      }
      if (message.id !== expectedId || (expectedId === 5 && !sent)) return finish('protocol-error');
      if (Object.hasOwn(message, 'error')) return finish('read-failed');
      if (!isObject(message.result)) return finish('protocol-error');

      if (expectedId === 1) {
        expectedId = 2;
        send({ method: 'initialized' });
        send({ id: 2, method: READ_ACCOUNT, params: { refreshToken: false } });
      } else if (expectedId === 2) {
        account = message.result.account ?? null;
        if (account !== null && (!isObject(account) || typeof account.type !== 'string')) {
          return finish('protocol-error');
        }
        if (account?.type !== 'chatgpt') {
          return operation ? finish('identity-unavailable') : finish(null, normalizeSnapshot(account, null));
        }
        expectedId = 3;
        send({ id: 3, method: 'account/rateLimits/read' });
      } else if (expectedId === 3) {
        if (!isObject(message.result.rateLimits)) return finish('protocol-error');
        if (!operation) return finish(null, normalizeSnapshot(account, message.result));
        quota = message.result;
        expectedId = 4;
        // A quota read can cause a proactive refresh inside the official
        // process. Recheck its current account before using the quota snapshot.
        send({ id: 4, method: READ_ACCOUNT, params: { refreshToken: false } });
      } else if (expectedId === 4) {
        const current = message.result.account;
        if (current?.type !== 'chatgpt' || !safeText(current.email)) return finish('identity-unavailable');
        if (current.email !== account.email) return finish('identity-changed');
        const snapshot = normalizeSnapshot(current, quota);
        // Process any account-change notification already in this output batch
        // before sending. The expiry and pause gates are checked at dispatch.
        expectedId = 5;
        setImmediate(() => {
          if (settled) return;
          try {
            const failure = redemptionGuard(snapshot, operation, now());
            if (failure) return finish(failure);
          } catch {
            return finish('cancelled');
          }
          sent = true;
          clearTimeout(timer);
          timer = setTimeout(() => finish('timed-out'), timeoutMs);
          send({ id: 5, method: 'account/rateLimitResetCredit/consume', params: {
            creditId: operation.id, idempotencyKey: operation.key,
          } });
        });
      } else {
        const outcome = outcomes.get(message.result.outcome);
        if (!outcome) return finish('protocol-error');
        finish(null, outcome);
      }
    }

    child.on('error', () => finish('read-failed'));
    child.on('close', () => finish('read-failed'));
    child.stdin.on('error', () => finish('read-failed'));
    child.stdout.on('error', () => finish('read-failed'));
    child.stdout.on('data', chunk => {
      if (settled) return;
      const bytes = Buffer.concat([pending, chunk]);
      let start = 0;
      let end;
      while (!settled && (end = bytes.indexOf(0x0a, start)) !== -1) {
        if (end - start > MAX_LINE_BYTES) return finish('protocol-error');
        try {
          receive(JSON.parse(bytes.toString('utf8', start, end)));
        } catch {
          return finish('protocol-error');
        }
        start = end + 1;
      }
      if (!settled) {
        pending = bytes.subarray(start);
        if (pending.length > MAX_LINE_BYTES) finish('protocol-error');
      }
    });

    send({ id: 1, method: 'initialize', params: {
      clientInfo: { name: 'reset-rune', title: 'Bottled Reset Rune', version: '0.1.1' },
      capabilities: { experimentalApi: true },
    } });
  });
}

export function createCodexSource({
  executable = process.env.RESET_RUNE_CODEX_PATH,
  timeoutMs = 15_000, env = process.env, allowConsume = false, now = Date.now,
} = {}) {
  const safeEnv = childEnvironment(env);
  let inFlight;
  const source = {
    mode: allowConsume ? 'live' : 'readonly',
    read() {
      if (!inFlight) {
        inFlight = resolveRuntime(executable, safeEnv)
          .then(path => runAppServer(path, safeEnv, timeoutMs))
          .finally(() => { inFlight = null; });
      }
      return inFlight;
    },
  };
  if (allowConsume) {
    source.consume = async operation => {
      if (!safeText(operation?.id)
        || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(operation?.key ?? '')
        || !verified(operation?.identity) || !Number.isSafeInteger(operation?.expiresAt)
        || !Number.isSafeInteger(operation?.startsAt) || operation.startsAt >= operation.expiresAt
        || typeof operation.maySend !== 'function') {
        throw beforeSend(new CodexSourceError('preflight-ineligible'));
      }
      const path = await resolveRuntime(executable, safeEnv).catch(error => { throw beforeSend(error); });
      return runAppServer(path, safeEnv, timeoutMs, { operation, now });
    };
  }
  return source;
}
