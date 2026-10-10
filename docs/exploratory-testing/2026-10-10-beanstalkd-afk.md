# Exploratory testing — beanstalkd AFK pass

Date: 2026-10-10

## Build and starting state

- Repository: `jonbaldie/beanstalkd`, `origin/master` at `d7e0dc3` (after the
  v1.0.8 release and the upstream ct suite build step, #81).
- Image: built as `beanstalkd-xt-20261010:local` with
  `make test IMAGE=beanstalkd-xt-20261010:local`. The full suite passed.
- Docker Server: 29.4.0 (OrbStack, arm64) on macOS.
- Each journey used fresh, uniquely named containers on random loopback host
  ports and fresh Docker named volumes mounted at `/data`, as the README shows.
- Client: a small Python socket client that sends raw protocol commands.

## Journeys exercised

### 1. Job state transitions across restart — no bugs

Goal: every state change a producer or worker makes is still there after a
restart with `-b /data -f 0`.

Tested: `kick-job` and `kick` on delayed jobs, `reserve-job` then
`bury <id> <new-pri>`, `reserve-job` then `release <id> <new-pri> 3600`,
`reserve-job` then `delete`. Variation: a job in a custom tube that was
reserved, buried, kicked, reserved again, touched and released with a new
priority. Each was checked with `stats-job` after one, two and three restarts.

Observed: state, priority, delay and all counters matched before and after
every restart. Deleted jobs stayed deleted.

Evidence: [2026-10-10-state-transition-persistence.txt](evidence/2026-10-10-state-transition-persistence.txt).

### 2. Operator lifecycle on a shared volume — no bugs

Goal: an operator cannot corrupt the WAL by starting a second daemon on the
same volume, and `docker stop` is prompt.

Observed:
- A second container on a volume already in use exits with code 10 and logs
  `waldirlock: fcntl: Resource temporarily unavailable` /
  `failed to lock wal dir /data`. Once the first container stopped,
  `docker start` on the second one worked and it served the persisted jobs.
- `docker stop` took about 0.2 s (SIGTERM as PID 1 works). The exit code is
  143.

### 3. Size and name limits, including persistence — 1 bug

Goal: anything the server accepts within its stated limits works and survives
a restart.

Tested: tube names of 200 characters (accepted) and 201 (`BAD_FORMAT` for
`use` and `watch`), a leading `-` (`BAD_FORMAT`), `$` and `()` in names
(accepted), a 0-byte job, a body that contains `\r\n`, bodies of 65535
(`INSERTED`) and 65536 bytes (`JOB_TOO_BIG`). Variation: the same jobs with
`-b /data -s 1000`, then a restart.

Observed: protocol responses matched `doc/protocol.txt`. On restart, the
65535-byte job was missing and the log said
`job 4 is too big (65537 > 65535)`.

Reduced: bodies of `max-job-size - 1` and `max-job-size` bytes are accepted
by `put` but rejected by WAL replay. Replay then stops reading that binlog
file, so every job written after the large one in the same file is lost too.
This is the same with the default limit, with `-z 1000`, and with `-f 0`. A
control run at 998 bytes with `-z 1000` kept all jobs.

Root cause: `put` stores the body with its CRLF (`body_size + 2`,
`prot.c:1344`). Replay compares that stored size with the user-facing limit
(`file.c:226`, `file.c:351`) and jumps to `Error`, which ends the file read.

Evidence: [2026-10-10-max-job-size-wal-replay.txt](evidence/2026-10-10-max-job-size-wal-replay.txt).

## Confirmed bugs filed

- [#82 — beanstalkd drops jobs of max-job-size-1 or max-job-size bytes on restart, plus every later job in the same binlog](https://github.com/jonbaldie/beanstalkd/issues/82)
  (labels `bug`, `ready-for-agent`). Replayed 2 of 2 times with the default
  limit from fresh volumes, plus once each with `-z 1000` and
  `-z 1000 -f 0`.

## Rejected candidates

- `total-jobs: 0` after restart while replayed jobs are present. `stats` counters
  are cumulative since the process started, so this is expected.
- Binlog files larger than `-s 1000`. Upstream grows a binlog file to fit
  a job that is bigger than the set size. Replay of the 5000-byte job worked.

## Usability observations

- The only sign of the #82 data loss is a warning in `docker logs`. The
  container starts normally and `stats` gives no hint that records were skipped.
- Exit code 143 on `docker stop` may look like a failure in some process
  supervisors. This is an observation, not a suggested change.

## Unresolved / not explored

- Whether the unread records from #82 can be recovered once the server writes
  new records and compacts old binlog files. Not tested.
- Bind-mounted host directories for `/data` (the README only documents named
  volumes).

## Cleanup and limitations

Every container, named volume, and the `beanstalkd-xt-20261010:local` image
created by this pass were removed. The run used macOS with OrbStack only.
