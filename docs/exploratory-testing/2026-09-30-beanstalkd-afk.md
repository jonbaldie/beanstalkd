# Exploratory testing — beanstalkd AFK pass

Date: 2026-09-30

## Build and starting state

- Repository: `jonbaldie/beanstalkd`, commit `f303c7d` (`v1.0.5`)
- Image: `jonbaldie/beanstalkd:latest`, rebuilt with `make test`
- Docker Server: 29.4.0 (OrbStack, aarch64)
- Service version from `stats`: beanstalkd 1.13
- The repository integration suite (`make test`) passed completely.
- Live tests used fresh uniquely named containers and random loopback-only host
  ports with dedicated Docker named volumes.
- Runtime instrumentation: compiled and tested with Clang AddressSanitizer (ASan)
  and UndefinedBehaviorSanitizer (UBSan).
- Static analysis: evaluated across daemon translation units with `clang --analyze`.

## Journeys exercised

### 1. Systematic protocol boundary and malformed argument fuzzing

Goal: systematically evaluate argument validation and stream synchronization across
all 25 protocol commands, verifying proper rejection with `BAD_FORMAT\r\n` or
`UNKNOWN_COMMAND\r\n`, prevention of bitbucket hangs, and stream integrity on
pipelined follow-up commands (`list-tube-used`).

Tested:
- Missing arguments, empty arguments, trailing characters, and extra arguments
  across single-argument, two-argument, and three-argument commands.
- Integer boundaries: negative integers (`-1`), zero (`0`), maximum unsigned 32-bit
  (`4294967295`), 32-bit overflow (`4294967296`), 64-bit bounds
  (`18446744073709551615`), and arbitrary multi-digit strings.
- Non-decimal character inputs (hex `0x10`, signed integers `+1`, punctuation).
- Space delimiters: extra leading/embedded spaces across integer and tube commands.
  Observed that `use`, `watch`, `ignore`, and `stats-tube` correctly reject leading
  spaces with `BAD_FORMAT\r\n`, while `pause-tube` strips leading spaces in
  `read_tube_name`.

Observed:
- Malformed commands returned `BAD_FORMAT\r\n` or `UNKNOWN_COMMAND\r\n`.
- Pipelined follow-up commands executed successfully, confirming stream synchronization
  remains intact.
- Under Clang ASan and UBSan, no memory corruption, out-of-bounds access, or undefined
  operations occurred during fuzzed deliveries.

### 2. Buried and delayed job reservation via `reserve-job` and WAL persistence recovery

Goal: track jobs transitioned out of `Buried` and `Delayed` states via `reserve-job <id>`,
followed by subsequent return to `Ready` (via `release <id> <pri> 0`, worker socket
disconnection, or TTR expiration), and verify whether the in-memory ready state is
preserved across daemon restarts on a Docker-managed named volume with fsync enabled (`-f 0`).

Observed:
- In memory, reserving a buried job via `reserve-job 1` and releasing it with delay 0
  (`release 1 0 0`) returned `RELEASED\r\n` and successfully placed Job 1 in the ready
  queue (`peek-ready` returned `FOUND 1 5\r\n`, `peek-buried` returned `NOT_FOUND\r\n`).
- However, after stopping and restarting the beanstalkd container with the same persistence
  volume, Job 1 was absent from the ready queue (`peek-ready` returned `NOT_FOUND\r\n`)
  and reappeared in the buried queue (`peek-buried` returned `FOUND 1 5\r\n`).
- The same reversion occurred when the worker holding the reserved buried job abruptly
  disconnected: in memory the daemon returned the job to ready, but upon restart it
  reverted to buried.
- Reserving a delayed job with `reserve-job` and releasing with delay 0 similarly reverted
  to delayed with remaining delay after restart.
- Root cause: `OP_RESERVE_JOB` does not update the WAL or reserve WAL space when
  reserving buried/delayed jobs. Subsequent returns to ready via `release` (delay 0),
  disconnect, or TTR timeout pass `update_store = 0`, bypassing `walwrite()`. The on-disk
  binlog retains the obsolete `Buried` or `Delayed` record. Upon restart, `prot_replay`
  replays the obsolete record and buries/delays the job.

Evidence: [2026-09-30-reserve-job-wal-persistence.txt](evidence/2026-09-30-reserve-job-wal-persistence.txt).

### 3. Command counter reporting audit in `stats`

Goal: verify that internal operational counters (`op_ct`) map accurately to reported
`stats` YAML metrics.

Observed:
- Command dispatches for `OP_RESERVE_JOB` and `OP_KICKJOB` increment `op_ct[type]`.
- However, neither `cmd-reserve-job` nor `cmd-kick-job` is exposed in `STATS_FMT` or
  emitted by `fmt_stats`, and neither metric is specified in `doc/protocol.txt`.

## Confirmed bugs filed

- [#61 — beanstalkd reverts buried and delayed jobs reserved via reserve-job back to buried/delayed upon restart](https://github.com/jonbaldie/beanstalkd/issues/61)
  Filed in issue tracker following `docs/agents/issue-tracker.md`.
  Labels: `bug`, `ready-for-agent`.
  Evidence: `docs/exploratory-testing/evidence/2026-09-30-reserve-job-wal-persistence.txt`.

## Existing confirmed findings not duplicated

The repository already resolved earlier findings:

- [#36 — beanstalkd accepts malformed kick bounds](https://github.com/jonbaldie/beanstalkd/issues/36)
- [#39 — beanstalkd accepts malformed reserve-with-timeout bounds](https://github.com/jonbaldie/beanstalkd/issues/39)
- [#40 — beanstalkd hangs when command lines split \r\n across buffer boundary](https://github.com/jonbaldie/beanstalkd/issues/40)
- [#41 — beanstalkd accepts pause-tube commands lacking space delimiter](https://github.com/jonbaldie/beanstalkd/issues/41)
- [#42 — beanstalkd closes the connection for malformed quit prefixes](https://github.com/jonbaldie/beanstalkd/issues/42)
- [#48 — beanstalkd hangs in bitbucket mode for malformed put commands with oversize body](https://github.com/jonbaldie/beanstalkd/issues/48)

## Cleanup and limitations

All containers and Docker named volumes created during this pass were destroyed.
Testing was conducted using Docker 29.4.0 (OrbStack, aarch64) on macOS with the
upstream beanstalkd 1.13 code base and current repository packaging patches.
