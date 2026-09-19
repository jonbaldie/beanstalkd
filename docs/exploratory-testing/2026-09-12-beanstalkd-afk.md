# Exploratory testing — beanstalkd AFK pass

Date: 2026-09-12

## Build and starting state

- Repository: `jonbaldie/beanstalkd`, commit `bebc2c3` (`v1.0.2`)
- Image: `jonbaldie/beanstalkd:latest`, rebuilt with `make test`
- Docker Server: 29.4.0 (OrbStack, aarch64)
- Service version from `stats`: beanstalkd 1.13
- The repository integration suite passed completely.
- Live tests used fresh uniquely named containers and random loopback-only host
  ports. Probe containers were removed after each journey.
- Existing untracked exploratory reports and evidence were preserved.

## Journeys exercised

### 1. Protocol command grammar and boundaries

Goal: send ordinary commands, malformed command prefixes, and job-size boundary
requests, then verify both the response and any lasting queue effect.

Observed:

- The rebuilt image passed `make test`, including the repository's malformed
  `kick` regression and persistence checks.
- `65535`-byte jobs were inserted; `65536`- and `65537`-byte jobs returned
  `JOB_TOO_BIG`; the ready queue remained at one job. Details are in
  [2026-09-12-job-size-boundary.txt](evidence/2026-09-12-job-size-boundary.txt).
- The exact command `quit\r\n` closed the connection as documented, while
  `statsgarbage\r\n` returned `BAD_FORMAT\r\n`.
- The malformed `quitgarbage\r\n` prefix closed the connection without any
  error response in three clean replays. `quit foo\r\n` did the same.

### 2. Worker ownership and job state transitions

Goal: process a job through reservation, cross-client action attempts, TTR
expiry, re-reservation, and deletion; then exercise `reserve-job` across
delayed, buried, and ready states.

Observed: passed. A second worker could not delete, release, bury, or touch a
job reserved by the first worker. After TTR expiry, the job was requeued,
reserved by the second worker, and reported one timeout. Explicit reservation,
bury, peek, kick, and deletion across the other states also behaved correctly.

Evidence: [2026-09-12-afk-stateful.txt](evidence/2026-09-12-afk-stateful.txt).

### 3. Tube pause and server drain behavior

Goal: pause a tube, verify that a ready job is not delivered during the pause,
then verify delivery after expiry. Enter drain mode and confirm that existing
work remains consumable while new puts are rejected.

Observed: passed. `pause-tube` withheld the ready job until the pause expired;
SIGUSR1 set `draining: true`, returned `DRAINING` for a new put, and left the
ready count at zero.

## Confirmed bug filed

### Beanstalkd closes the connection for malformed `quit` prefixes

- User impact: a client that sends a typo or extra argument beginning with
  `quit` loses the connection without an error response, unlike other malformed
  commands. This can hide input errors and disrupt a persistent protocol
  session.
- Reproducer: send `quitgarbage\r\n` to a fresh instance and read until EOF.
- Expected: an error response such as `BAD_FORMAT\r\n` or
  `UNKNOWN_COMMAND\r\n`; only exact `quit\r\n` should close the connection.
- Actual: EOF with no response. Reproduced three times from clean instances;
  `quit foo\r\n` behaved the same.
- Evidence: [2026-09-12-quit-prefix.txt](evidence/2026-09-12-quit-prefix.txt).
- Issue: [#42 — beanstalkd closes the connection for malformed quit prefixes](https://github.com/jonbaldie/beanstalkd/issues/42).

The expected error handling and exact `quit` form are defined in the upstream
protocol document: [protocol.txt](https://github.com/beanstalkd/beanstalkd/blob/master/doc/protocol.txt#L28-L50).

## Existing confirmed findings not duplicated

The same-day working tree already contained evidence for, and GitHub issues for:

- [#39 — malformed `reserve-with-timeout` bounds mutate the queue](https://github.com/jonbaldie/beanstalkd/issues/39)
- [#40 — a command line boundary split can hang the daemon](https://github.com/jonbaldie/beanstalkd/issues/40)
- [#41 — `pause-tube` accepts a missing command/argument delimiter](https://github.com/jonbaldie/beanstalkd/issues/41)

The earlier malformed `kick` finding is fixed and covered by the passing
regression test in [#36](https://github.com/jonbaldie/beanstalkd/issues/36).

## Rejected observations and driver corrections

- An initial readiness probe used a driver path that did not tolerate startup
  timing; a direct TCP/stats readiness check passed.
- One state probe initially called `peek-buried` while the worker was watching,
  but not using, the producer tube. After adding `use`, the clean replay passed.
- One queue-order assertion used a ready job with higher urgency than the kicked
  job. Replaying with the documented priority ordering passed.

These were test-driver/setup issues, not product failures.

## Unresolved and unexplored areas

No unresolved product failures remained in the selected journeys. This pass did
not attempt sustained high-volume load, power-loss or filesystem-corruption
recovery, deliberate disk-full behavior, IPv6-only networking, or concurrent
stress beyond the ownership checks.

## Cleanup and limitations

All containers created by this pass were removed; no AFK probe resources remain.
The evidence and report are intentionally retained under `docs/exploratory-testing/`.
The test environment used Docker/OrbStack on arm64, so platform-specific
behavior on other container runtimes or architectures remains untested.
