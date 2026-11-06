# CodexTransport

The transport uses the official Codex CLI `0.153.0` App Server protocol.
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
