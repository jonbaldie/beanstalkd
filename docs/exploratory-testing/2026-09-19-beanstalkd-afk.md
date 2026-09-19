# Exploratory testing — beanstalkd AFK pass

Date: 2026-09-19

## Build and starting state

- Repository: `jonbaldie/beanstalkd`, commit `9c5ed37` (`v1.0.3`)
- Image: `jonbaldie/beanstalkd:latest`, rebuilt with `make test`
- Docker Server: 29.4.0 (OrbStack, aarch64)
- Service version from `stats`: beanstalkd 1.13
- The repository integration suite (`make test`) passed completely.
- Live tests used fresh uniquely named containers and random loopback-only host
  ports. Probe containers and temporary volumes were removed after each journey.
- Existing untracked exploratory reports and evidence were preserved.

## Journeys exercised

### 1. Tube lifecycle, custom tube naming rules, and watch/ignore state management

Goal: exercise creation of tubes with various allowed characters (`+-+/;.$_()`),
the 200-byte tube name boundary, rejection of invalid names (leading hyphen,
invalid characters, empty name), watch and ignore behavior, idempotent watching,
and automatic deletion of unreferenced empty tubes.

Observed:

- Tube names containing allowed punctuation (`tube.1`, `tube+2`, `tube$3`,
  `tube(4)`, `tube;5`, `tube_6`, `tube/7`) and 200-character tube names were
  accepted and returned in `list-tubes` and `list-tubes-watched`.
- 201-character tube names and names starting with a hyphen (`-bad`) or
  containing whitespace/colons/at-signs (`bad tube`, `bad:tube`, `bad@tube`)
  were rejected with `BAD_FORMAT\r\n`.
- Redundant `watch` commands on an already watched tube were idempotent and did
  not duplicate entries in the watch list.
- Attempting to ignore the sole tube in a watch list returned `NOT_IGNORED\r\n`,
  while ignoring an unwatched tube was a no-op returning `WATCHING <count>\r\n`.
- Dynamic tube lifecycle: unreferenced empty tubes created during a session were
  automatically deleted upon client disconnection and no longer appeared in
  subsequent `list-tubes` queries.

### 2. Worker job state manipulation, scheduling, and multi-state operations

Goal: verify strict priority scheduling (0 to 4,294,967,295), FIFO tie-breaking
across identical priorities, reservation, touch deadline extension, release
with delay and priority update, direct deletion across ready/delayed/buried
states, kick and kick-job across buried and delayed states, and unpausing via
`pause-tube <tube> 0`.

Observed:

- Priority ordering strictly scheduled jobs from most urgent (pri 0) to least
  urgent (pri 4,294,967,295). Jobs with identical priorities were dispatched in
  FIFO order.
- `touch` on a reserved job successfully postponed TTR expiry and refreshed
  `time-left` in `stats-job`. Calling `touch` from a non-owner connection or on
  an unreserved job returned `NOT_FOUND\r\n`.
- `release <id> <pri> <delay>` transferred reserved jobs to delayed state and
  applied the updated priority.
- Direct deletion with `delete <id>` succeeded for ready, delayed, and buried
  jobs without requiring prior reservation. Other workers could not delete jobs
  currently reserved by an active connection.
- `kick-job <id>` moved individual buried or delayed jobs directly into the
  ready queue of their tube. Calling `kick-job` on ready, reserved, or
  nonexistent jobs returned `NOT_FOUND\r\n`.
- `kick <bound>` prioritized buried jobs over delayed jobs, kicking buried jobs
  first and only kicking delayed jobs when buried jobs were exhausted.
- `pause-tube <tube> 0` immediately unpaused a paused tube and allowed pending
  or subsequent reservations to proceed.

### 3. Protocol command grammar, boundaries, and malformed input handling

Goal: probe protocol boundary conditions, zero-byte bodies, ttr=0 coercion,
opaque binary bodies with embedded nulls and CRLFs, EXPECTED_CRLF handling,
integer bounds, trailing garbage guards across commands, pipelined command
streams, and body length parsing.

Observed:

- Zero-byte job bodies were accepted, reserved, and deleted cleanly.
- Setting `ttr: 0` was silently coerced to minimum allowed `ttr: 1`, visible in
  `stats-job`.
- Binary payloads containing embedded nulls, raw binary bytes, and internal
  `\r\n` sequences were stored and retrieved verbatim.
- Body length mismatches (declared length shorter than actual payload before
  CRLF) returned `EXPECTED_CRLF\r\n`.
- Multiple pipelined commands sent in a single socket write were executed
  serially and accurately without desynchronization.
- Trailing garbage validation: single-word commands (`peek-ready`, `stats`,
  `list-tubes`) and multi-word commands (`delete`, `release`, `bury`, `kick`,
  `stats-job`) rejected trailing arguments with `BAD_FORMAT\r\n`.
- **Bug identified**: When `put` specifies a body size greater than
  `max-job-size` (default 65,535 bytes) and has trailing whitespace or extra
  arguments on the command line, beanstalkd enters bit-bucket mode
  (`STATE_BITBUCKET`) instead of returning `BAD_FORMAT\r\n`. The daemon hangs
  waiting for 70,000+ non-existent body bytes, swallowing subsequent pipelined
  commands and desynchronizing the session.

## Confirmed bug filed

### Beanstalkd hangs in bitbucket mode for malformed put commands with oversize body

- User impact: A client that sends a malformed `put` command line with an
  oversize body size (such as accidental trailing whitespace or extra arguments)
  does not receive `BAD_FORMAT\r\n`. Instead, the daemon enters bit-bucket mode
  and hangs indefinitely waiting for tens of thousands of body bytes that the
  client never sends. Any subsequent commands in the pipelined stream are
  silently swallowed and discarded, permanently locking up the session.
- Reproducer: Send `put 0 0 0 70000 \r\n` (trailing space) or
  `put 0 0 0 70000 foo\r\n` (trailing argument) to a fresh instance and read.
- Expected: Immediate `BAD_FORMAT\r\n` error response without entering
  bit-bucket mode, matching the behavior when `body_size <= 65535`
  (`put 0 0 0 5 \r\n`).
- Actual: Daemon enters `STATE_BITBUCKET` waiting for 70,002 bytes and hangs.
  Reproduced 100% reliably in three clean trials from fresh containers.
- Evidence: [2026-09-19-put-oversize-trailing-garbage.txt](evidence/2026-09-19-put-oversize-trailing-garbage.txt).
- Issue: [#48 — beanstalkd hangs in bitbucket mode for malformed put commands with oversize body](https://github.com/jonbaldie/beanstalkd/issues/48).

## Existing confirmed findings not duplicated

The repository already addressed earlier findings in release `v1.0.3`:

- [#36 — beanstalkd accepts malformed kick bounds](https://github.com/jonbaldie/beanstalkd/issues/36)
- [#39 — beanstalkd accepts malformed reserve-with-timeout bounds](https://github.com/jonbaldie/beanstalkd/issues/39)
- [#40 — beanstalkd hangs when command lines split \r\n across buffer boundary](https://github.com/jonbaldie/beanstalkd/issues/40)
- [#41 — beanstalkd accepts pause-tube commands lacking space delimiter](https://github.com/jonbaldie/beanstalkd/issues/41)
- [#42 — beanstalkd closes the connection for malformed quit prefixes](https://github.com/jonbaldie/beanstalkd/issues/42)

## Rejected observations and driver corrections

- In Journey 1, an initial probe passed `$3` in double-quoted bash strings, which
  expanded to an empty string. Rewriting the probe using heredocs resolved the
  driver issue and demonstrated that `$` in tube names is valid ASCII per the
  protocol.
- In Journey 2, reading beyond the body bytes on `peek-delayed` without
  accounting for the 2-byte CRLF delimiter desynchronized a subsequent read.
  Adding CRLF draining resolved the driver issue.

## Unresolved and unexplored areas

No unresolved product failures remained in the selected journeys. This pass did
not attempt sustained high-volume concurrency benchmarking, simulated disk
write failures or corrupt WAL headers, or IPv6 transport.

## Cleanup and limitations

All containers and Docker volumes created during this pass were removed. No
active probe resources remain. Testing was performed using Docker 29.4.0
(OrbStack, aarch64) on macOS.
