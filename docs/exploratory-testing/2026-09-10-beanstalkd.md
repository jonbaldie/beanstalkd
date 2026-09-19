# Exploratory testing — beanstalkd

Date: 2026-09-10

Build and starting state

- Repository: `jonbaldie/beanstalkd`, commit `67a2c19` (`v1.0.1`)
- Image: `jonbaldie/beanstalkd:latest`, built with `make build`
- Docker Server: 29.4.0 (OrbStack, aarch64)
- Service version from `stats`: beanstalkd 1.13
- The repository integration suite passed with `make test`.
- Live tests used fresh uniquely named containers and loopback-only random host ports. Temporary containers and named volumes were cleaned up after each run.

## Journeys exercised

### 1. Normal queue work

Goal: publish, route, process, retry, inspect, and finish jobs through the TCP protocol.

Observed: passed. The journey covered `stats`, tube creation and selection, watch/ignore, priority ordering, reserve/delete, delayed release, bury/kick, tube stats, malformed `put` recovery, and empty-queue `peek-ready`.

### 2. Worker failure and timing behavior

Goal: ensure work remains recoverable when workers compete, disconnect, exceed TTR, or need more time.

Observed: passed. Two workers received the expected priority-ordered jobs; an abrupt client disconnect requeued its reservation; TTR expiry handed the job to another worker and rejected the stale owner; `touch` extended the reservation; and an empty `reserve-with-timeout 1` returned `TIMED_OUT` after about one second.

### 3. Documented Docker persistence

Goal: persist jobs on a named `/data` volume across a container stop/remove/recreate cycle.

Observed: passed. Ready, delayed, buried, and in-flight jobs all survived. The in-flight job was requeued after the graceful stop; the delayed job remained delayed until its deadline; and the buried job remained inspectable and kickable after restart. The exact README-style `-v <volume>:/data ... beanstalkd -b /data` flow is also covered by `make test`.

## Confirmed bug

Beanstalkd 1.13 accepts malformed `kick` bounds instead of returning `BAD_FORMAT`. `kick 1garbage` kicked a buried job, and `kick -1` kicked all two buried jobs in the test. Both cases reproduced twice from clean instances. The user impact is unintended queue mutation from malformed or incorrectly validated client requests.

Detailed transcript and replay conditions: [2026-09-10-kick-parser.txt](evidence/2026-09-10-kick-parser.txt).

Issue tracker: [#36 — beanstalkd accepts malformed kick bounds and mutates the queue](https://github.com/jonbaldie/beanstalkd/issues/36).

## Rejected candidates

- The first persistence observation that appeared to lose a buried job was a driver error: the post-restart client was watching the right tube but still using `default`, while `peek-buried` is scoped to the current `use` tube. A corrected clean replay found the buried job intact.
- Earlier `BAD_FORMAT` observations were caused by the temporary Python driver rendering byte IDs as `b'2'`, and by clients that had not watched the producer tube. Corrected replays passed.

## Unresolved and unexplored areas

No unresolved product failures remained in the selected journeys. This pass did not attempt high-volume load, power-loss or filesystem-corruption recovery, deliberate disk-full behavior, IPv6-only networking, or payloads at the maximum job-size boundary.

## Environment limitations

The persistence stress used `-f0` to make the restart probe deterministic; the ordinary README configuration without that instrumentation passed through `make test`. Docker resources belonging to unrelated local workloads were left untouched.
