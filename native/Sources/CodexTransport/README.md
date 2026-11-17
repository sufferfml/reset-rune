# CodexTransport

The transport uses the official Codex App Server stable account/reset protocol,
with **Codex CLI 0.153.0 or later** as the supported range. `0.153.0` also remains
the optional private-installation baseline. Newer CLI versions are accepted by
protocol compatibility instead of exact version equality; versions below the
minimum, including its prereleases, are rejected before starting an account session.
Sessions set `experimentalApi: false` and ignore unrelated additional fields.
An application-private installation can be selected with `RESET_RUNE_CODEX_PATH`,
independently of global Codex updates. See the [runtime maintenance guide](../../../docs/codex-runtime-compatibility.md)
for verified installation and compatibility behavior across CLI versions.
`CodexSource` implements `RuneCore.ResetSource`. Initialize with
`allowConsume: true` only in the single execution service; the default is
read-only. Codex owns login files and tokens, which this project never parses.

- `Snapshot.swift` normalizes account, quota and inventory responses. Unknown
  count and expiry remain null; duplicate IDs are excluded by raw UTF-16
  identity. Quota revisions use a stable field order shared with the contract
  reference implementation.
- `CodexSource.swift` discovers a compatible executable, caches its resolved
  path and file fingerprint, and merges concurrent reads. Each operation uses
  a bounded stdio App Server session and releases it when finished. A read
  session is never reused later as implicit authorization to consume.
- `ProtocolCapabilities.swift` checks the stable redemption schema in an isolated
  temporary HOME/CODEX_HOME before a non-baseline runtime can consume. Required
  methods, explicit `creditId`, `idempotencyKey` and outcome structure must remain
  compatible; additive schema changes are allowed. Successful capability checks
  are cached against the resolved binary fingerprint. Reads do not perform schema
  generation, and failed checks never send or try a different consume endpoint.
- Consumption validates the explicit credit ID, fixed UUID, identity, expiry
  and caller gate, reads current account and quota in the same session,
  rechecks identity, then calls `account/rateLimitResetCredit/consume`.
- `RuneError(code, notSent:)` distinguishes a definitely unsent request from
  an ambiguous outcome after the consume write. Raw child stderr, RPC error
  bodies, process environments and authentication URLs are not exposed.
- Output reads are nonblocking and bounded. Frames are limited to 1 MiB,
  deadlines cover both preflight and send, and the owned process is terminated
  and reaped after completion.

Run `swift test --package-path native --filter ProtocolTests`. Tests use a
synthetic Node App Server, an isolated executable and temporary `HOME` and
`CODEX_HOME`. They never discover the real installed Codex executable.
Protocol success with synthetic data does not establish live redemption
eligibility.
