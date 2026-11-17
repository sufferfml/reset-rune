import { execFile, spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { constants } from 'node:fs';
import { access, lstat, mkdir, mkdtemp, readFile, readdir, realpath, rm, stat } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { homedir, tmpdir } from 'node:os';
import { delimiter, dirname, isAbsolute, join } from 'node:path';
import { promisify } from 'node:util';
import { sameIdentity, verified } from '../core/state.js';

export const BASELINE_CODEX_VERSION = '0.153.0';
export const MINIMUM_CODEX_VERSION = '0.153.0';
const MINIMUM_COMPONENTS = MINIMUM_CODEX_VERSION.split('.').map(BigInt);
const CODEX_VERSION = /^codex-cli (0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/;
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

/** Normalize the documented stable fields; preserve unknown values and ignore additions. */
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

function meetsMinimumCodexVersion(text) {
  const version = CODEX_VERSION.exec(text);
  if (version === null || version[4]?.split('.').some(part => /^0[0-9]+$/.test(part))) return false;
  const components = version.slice(1, 4).map(BigInt);
  for (let index = 0; index < components.length; index += 1) {
    if (components[index] !== MINIMUM_COMPONENTS[index]) return components[index] > MINIMUM_COMPONENTS[index];
  }
  // Build metadata does not affect precedence; a prerelease precedes this stable minimum.
  return version[4] === undefined;
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
      // The minimum defines the supported range; actual protocol guards still apply above it.
      if (meetsMinimumCodexVersion(stdout.trim())) {
        const info = await stat(path);
        if (!info.isFile()) continue;
        return { path, version: stdout.trim().slice('codex-cli '.length),
          fingerprint: [path, info.dev, info.ino, info.size, info.mtimeMs].join('\0') };
      }
    } catch {
      // Probe failures may contain local paths or raw CLI output.
    }
  }
  throw new CodexSourceError(inspected.size ? 'runtime-incompatible' : 'runtime-missing');
}

function schemaNode(node, document, depth = 0) {
  if (depth > 12 || !isObject(node)) throw new CodexSourceError('runtime-incompatible');
  if (!Object.hasOwn(node, '$ref')) return node;
  if (typeof node.$ref !== 'string' || !node.$ref.startsWith('#/')) throw new CodexSourceError('runtime-incompatible');
  let target = document;
  for (const part of node.$ref.slice(2).split('/')) {
    const key = part.replaceAll('~1', '/').replaceAll('~0', '~');
    if (!isObject(target) || !Object.hasOwn(target, key)) throw new CodexSourceError('runtime-incompatible');
    target = target[key];
  }
  return schemaNode(target, document, depth + 1);
}

function schemaAcceptsString(input, document, depth = 0) {
  const node = schemaNode(input, document, depth);
  if (node.type === 'string' || (Array.isArray(node.type) && node.type.includes('string'))) return true;
  return ['oneOf', 'anyOf'].some(key => Array.isArray(node[key])
    && node[key].some(value => schemaAcceptsString(value, document, depth + 1)));
}

function schemaEnum(input, document, depth = 0) {
  const node = schemaNode(input, document, depth);
  if (Array.isArray(node.enum) && node.enum.every(value => typeof value === 'string')) return node.enum;
  const variants = node.oneOf ?? node.anyOf;
  if (!Array.isArray(variants)) throw new CodexSourceError('runtime-incompatible');
  return variants.flatMap(value => schemaEnum(value, document, depth + 1));
}

async function verifyConsumeCapability(executable) {
  let temporary;
  try {
    temporary = await mkdtemp(join(tmpdir(), 'reset-rune-consume-schema-'));
    const home = join(temporary, 'home'), codexHome = join(temporary, 'codex'), output = join(temporary, 'schema');
    await Promise.all([home, codexHome, output].map(path => mkdir(path, { mode: 0o700 })));
    await execFileAsync(executable, ['app-server', 'generate-json-schema', '--out', output], {
      cwd: temporary, timeout: 5000, killSignal: 'SIGKILL', maxBuffer: 8192,
      env: { HOME: home, CODEX_HOME: codexHome, PATH: '/usr/bin:/bin', TMPDIR: temporary },
    });
    let entries = 0, bytes = 0;
    async function inspect(directory, depth = 0) {
      if (depth > 12) throw new CodexSourceError('runtime-incompatible');
      for (const entry of await readdir(directory)) {
        if (++entries > 1024) throw new CodexSourceError('runtime-incompatible');
        const path = join(directory, entry), info = await lstat(path);
        if (info.isDirectory()) await inspect(path, depth + 1);
        else {
          if (!info.isFile() || info.size > 4 * 1024 * 1024) throw new CodexSourceError('runtime-incompatible');
          bytes += info.size;
          if (bytes > 16 * 1024 * 1024) throw new CodexSourceError('runtime-incompatible');
        }
      }
    }
    if (!(await lstat(output)).isDirectory()) throw new CodexSourceError('runtime-incompatible');
    await inspect(output);
    const request = JSON.parse(await readFile(join(output, 'ClientRequest.json'), 'utf8'));
    const variants = schemaNode(request, request).oneOf;
    if (!Array.isArray(variants)) throw new CodexSourceError('runtime-incompatible');
    const consume = variants.map(value => schemaNode(value, request)).find(value =>
      Array.isArray(value.properties?.method?.enum)
      && value.properties.method.enum.includes('account/rateLimitResetCredit/consume'));
    const params = schemaNode(consume?.properties?.params, request);
    if (!Array.isArray(params.required) || !params.required.includes('idempotencyKey')
      || params.required.some(key => !['creditId', 'idempotencyKey'].includes(key))
      || !schemaAcceptsString(params.properties?.creditId, request)
      || !schemaAcceptsString(params.properties?.idempotencyKey, request)) {
      throw new CodexSourceError('runtime-incompatible');
    }
    const response = JSON.parse(await readFile(join(output, 'v2/ConsumeAccountRateLimitResetCreditResponse.json'), 'utf8'));
    const result = schemaNode(response, response);
    if (!Array.isArray(result.required) || !result.required.includes('outcome')) throw new CodexSourceError('runtime-incompatible');
    const supported = new Set(schemaEnum(result.properties?.outcome, response));
    if (![...outcomes.keys()].every(outcome => supported.has(outcome))) throw new CodexSourceError('runtime-incompatible');
  } catch {
    throw new CodexSourceError('runtime-incompatible');
  } finally {
    if (temporary) await rm(temporary, { recursive: true, force: true }).catch(() => {});
  }
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
      if (Object.hasOwn(message, 'error')) {
        const incompatible = !sent && [-32601, -32602].includes(message.error?.code);
        return finish(incompatible ? 'runtime-incompatible' : 'read-failed');
      }
      if (!isObject(message.result)) return finish('protocol-error');

      if (expectedId === 1) {
        expectedId = 2;
        send({ method: 'initialized' });
        send({ id: 2, method: READ_ACCOUNT, params: { refreshToken: false } });
      } else if (expectedId === 2) {
        if (!Object.hasOwn(message.result, 'account')) return finish('protocol-error');
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
      clientInfo: { name: 'reset-rune', title: 'Bottled Reset Rune', version: '0.1.2' },
      capabilities: { experimentalApi: false },
    } });
  });
}

export function createCodexSource({
  executable = process.env.RESET_RUNE_CODEX_PATH,
  timeoutMs = 15_000, env = process.env, allowConsume = false, now = Date.now,
} = {}) {
  const safeEnv = childEnvironment(env);
  let inFlight;
  const capabilityChecks = new Map();
  const source = {
    mode: allowConsume ? 'live' : 'readonly',
    read() {
      if (!inFlight) {
        inFlight = resolveRuntime(executable, safeEnv)
          .then(runtime => runAppServer(runtime.path, safeEnv, timeoutMs))
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
      const runtime = await resolveRuntime(executable, safeEnv).catch(error => { throw beforeSend(error); });
      if (runtime.version !== BASELINE_CODEX_VERSION) {
        if (!capabilityChecks.has(runtime.fingerprint)) {
          const pending = verifyConsumeCapability(runtime.path).catch(error => {
            capabilityChecks.delete(runtime.fingerprint);
            throw error;
          });
          capabilityChecks.set(runtime.fingerprint, pending);
        }
        await capabilityChecks.get(runtime.fingerprint).catch(error => { throw beforeSend(error); });
      }
      return runAppServer(runtime.path, safeEnv, timeoutMs, { operation, now });
    };
  }
  return source;
}
