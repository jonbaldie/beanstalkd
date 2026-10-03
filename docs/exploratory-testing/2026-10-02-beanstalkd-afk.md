# Exploratory testing — beanstalkd AFK pass

Date: 2026-10-02

## Build and starting state

- Repository: `jonbaldie/beanstalkd`, commit `74bec79` (`release/v1.0.6`)
- Image: `jonbaldie/beanstalkd:latest`, rebuilt with `make test`
- Docker Server: 29.4.0 (OrbStack, aarch64)
- Service version from `stats`: beanstalkd 1.13
- The repository integration suite (`make test`) passed completely.
- Live tests used fresh uniquely named containers and random loopback-only host ports with dedicated Docker named volumes.
- Runtime instrumentation: compiled and tested with Clang AddressSanitizer (ASan) and UndefinedBehaviorSanitizer (UBSan).
- Static analysis: evaluated across daemon translation units with `clang --analyze`.

## Journeys exercised

### 1. Systematic protocol command fuzzing and stream synchronization

Goal: systematically evaluate argument validation and stream synchronization across all 25 protocol commands, verifying proper rejection with `BAD_FORMAT\r\n` or `UNKNOWN_COMMAND\r\n`, prevention of bitbucket hangs, and stream integrity on pipelined follow-up commands (`list-tube-used`).

Tested 122 command variants:
- Missing arguments, empty arguments, trailing characters, extra arguments, and missing space delimiters across single-argument, two-argument, and three-argument commands.
- Integer boundaries: negative integers (`-1`), zero (`0`), maximum unsigned 32-bit (`4294967295`), 32-bit overflow (`4294967296`), 64-bit bounds (`18446744073709551615`), and arbitrary multi-digit strings.
- Non-decimal character inputs (hex `0x10`, signed integers `+1`, punctuation).
- Space delimiters: extra leading/embedded spaces across integer and tube commands.
- Trailing garbage on single-word commands (`stats`, `peek-ready`, `peek-delayed`, `peek-buried`, `list-tubes`, `list-tube-used`, `list-tubes-watched`, `quit`).

Observed:
- All 122 malformed command variants returned `BAD_FORMAT\r\n` or `UNKNOWN_COMMAND\r\n`.
- Pipelined follow-up commands executed successfully, confirming stream synchronization remained intact.
- Under Clang ASan and UBSan, no memory corruption, out-of-bounds access, or undefined operations occurred during fuzzed deliveries.

### 2. Job reprioritization and release counter persistence across restart on `release <id> <pri> 0`

Goal: track jobs released back to the ready queue with a new priority and zero delay (`release <id> <new_pri> 0`), and verify whether the newly assigned priority and release counters are preserved across daemon restarts on a Docker-managed named volume with fsync enabled (`-f 0`).

Observed:
- A job was created with initial priority 100 (`put 100 0 0 5`), reserved (`reserve`), and released with new priority 10 and delay 0 (`release 1 10 0`).
- In memory before restart, `stats-job 1` confirmed `state: ready`, `pri: 10`, `reserves: 1`, and `releases: 1`.
- After stopping and restarting the beanstalkd container with the same volume, `stats-job 1` reported `state: ready`, `pri: 100`, `reserves: 0`, and `releases: 0`.
- The job silently reverted from priority 10 back to its original priority 100 upon restart, and all reservation/release history was lost.
- Root cause: In `prot.c`, `OP_RELEASE` only calls `walresvupdate` when `delay != 0` and passes `update_store = !!delay` to `enqueue_job()`. When `delay == 0`, `update_store` evaluates to 0, completely bypassing `walwrite()`. The updated priority and release counters are never written to the WAL. Upon restart, `prot_replay()` loads the stale pre-release record from disk.

Evidence: [2026-10-02-release-delay-zero-wal-persistence.txt](evidence/2026-10-02-release-delay-zero-wal-persistence.txt).

### 3. Buried job replay and `buries` counter audit

Goal: verify whether operational counters in `stats-job` are accurately restored from disk during WAL binlog replay without corruption or extraneous increments.

Observed:
- A job was created, reserved, and buried via `bury 1 0`. Before restart, `stats-job 1` reported `buries: 1`.
- After restarting the persistent container, `stats-job 1` reported `buries: 2`.
- Root cause: In `prot.c`, `prot_replay()` recovers buried jobs from the log by calling `bury_job(s, j, 0)`. However, `bury_job()` unconditionally executes `j->r.bury_ct++` on line 560. Because `readrec()` in `file.c` had already loaded the true `bury_ct` from disk, calling `bury_job()` adds an extraneous increment on startup replay.

Evidence: [2026-10-02-buried-job-buries-counter-inflation.txt](evidence/2026-10-02-buried-job-buries-counter-inflation.txt).

## Confirmed bugs filed

- [#66 — beanstalkd reverts job priority and release counters upon restart when released with delay 0](https://github.com/jonbaldie/beanstalkd/issues/66)
  Filed in issue tracker following `docs/agents/issue-tracker.md`.
  Labels: `bug`, `ready-for-agent`.
  Evidence: `docs/exploratory-testing/evidence/2026-10-02-release-delay-zero-wal-persistence.txt`.

- [#67 — beanstalkd increments buried job buries counter on every daemon restart](https://github.com/jonbaldie/beanstalkd/issues/67)
  Filed in issue tracker following `docs/agents/issue-tracker.md`.
  Labels: `bug`, `ready-for-agent`.
  Evidence: `docs/exploratory-testing/evidence/2026-10-02-buried-job-buries-counter-inflation.txt`.

## Existing confirmed findings not duplicated

The repository already resolved earlier findings:

- [#36 — beanstalkd accepts malformed kick bounds](https://github.com/jonbaldie/beanstalkd/issues/36)
- [#39 — beanstalkd accepts malformed reserve-with-timeout bounds](https://github.com/jonbaldie/beanstalkd/issues/39)
- [#40 — beanstalkd hangs when command lines split \r\n across buffer boundary](https://github.com/jonbaldie/beanstalkd/issues/40)
- [#41 — beanstalkd accepts pause-tube commands lacking space delimiter](https://github.com/jonbaldie/beanstalkd/issues/41)
- [#42 — beanstalkd closes the connection for malformed quit prefixes](https://github.com/jonbaldie/beanstalkd/issues/42)
- [#48 — beanstalkd hangs in bitbucket mode for malformed put commands with oversize body](https://github.com/jonbaldie/beanstalkd/issues/48)
- [#61 — beanstalkd reverts buried and delayed jobs reserved via reserve-job back to buried/delayed upon restart](https://github.com/jonbaldie/beanstalkd/issues/61)

## Cleanup and limitations

All containers and Docker named volumes created during this pass were destroyed. Testing was conducted using Docker 29.4.0 (OrbStack, aarch64) on macOS with the upstream beanstalkd 1.13 code base and current repository packaging patches.
