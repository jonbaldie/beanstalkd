# Exploratory testing — beanstalkd AFK pass

Date: 2026-10-03

## Build and starting state

- Repository: `jonbaldie/beanstalkd`, `master` at `0fb5366` (includes the #66 and #67 fixes)
- Image: `jonbaldie/beanstalkd:latest`, built with `make build`; `make test` passed (exit 0)
- Docker Server: 29.4.0 (OrbStack, aarch64), macOS
- Each journey used a fresh labelled container on a random loopback port and,
  where persistence mattered, a fresh named volume with `-b /data -f 0`.
  Restarts were `docker stop -t 5`, then a new container on the same volume.
- Driver: a small Python socket client speaking the text protocol (the replay
  script is embedded in the timeout evidence file).
- Source reading: upstream 1.13 with this repository's `patches/` applied.

## Journeys exercised

### 1. Worker failure recovery (TTR expiry, worker disconnect) — 1 bug

Goal: a job whose worker dies is returned to the queue, and its history
(`reserves`, `timeouts`) stays available to later workers, including after a
daemon restart.

- TTR expiry: `put 50 0 1 4`, reserve, wait 2.5 s → `state: ready`,
  `reserves: 1`, `timeouts: 1`; server `job-timeouts: 1`. As expected.
- Disconnect: a worker that reserves and closes the connection returns the job
  to `ready`. As expected.
- Variation — restart: after restarting on the same volume, the timed-out job
  reported `timeouts: 0`, `reserves: 0`. A control job that was reserved,
  buried and kicked kept `reserves: 1`, `kicks: 1`. Confirmed as **#70**.
- Variation — TTR edges: `put` with TTR 0 is stored as `ttr: 1`. `touch`
  resets `time-left`. A `reserve-with-timeout` in the safety margin returns
  `DEADLINE_SOON` when no job is ready, and reserves a ready job when one
  exists. That second case is upstream design (`conndeadlinesoon(c) && !conn_ready(c)`),
  so it is not a bug.

Evidence: [ttr-timeout-counter-restart](evidence/2026-10-03-ttr-timeout-counter-restart.txt),
[worker-recovery](evidence/2026-10-03-worker-recovery.txt).

### 2. Delayed jobs across restart — no bugs

Goal: delayed work keeps its remaining delay across a restart, and kicked
delayed jobs stay ready.

- `put 5 10 30` showed `time-left: 6` after 3 s. After a ~3 s restart window it
  showed `time-left: 4`, then became ready and was reserved. As expected.
- A job whose 2 s delay matured before the restart stayed `ready`.
- `kick-job` and tube `kick 1` on delayed jobs left them `ready` with
  `kicks: 1`, and that state survived the restart.
- `stats-tube` ready and delayed counts matched after the restart.

Evidence: [delayed-job-restart](evidence/2026-10-03-delayed-job-restart.txt).

### 3. Drain mode and shutdown — no bugs

Goal: an operator can stop new work (`SIGUSR1`) while workers finish, then stop
the container.

- Before the signal: `put` → `INSERTED 1`, `stats` → `draining: false`.
- After `docker kill -s USR1`: `put` → `DRAINING`, `draining: true`, and
  `reserve-with-timeout 0` still returned the existing job.
- `docker stop` returned in 0.16 s with exit code 143. Upstream handles
  SIGTERM by exiting immediately (`main.c`), so the container does not wait
  for Docker's SIGKILL timeout.

Observation: the daemon logs `prot.c:890 in enqueue_incoming_job: server error: DRAINING`
for each rejected `put`. Expected behaviour is logged as an error, which may
alarm operators who read the logs. This is a suggestion, not a bug.

## Confirmed bugs filed

- [#70 — beanstalkd resets a job's timeouts counter to 0 upon restart after its TTR expired](https://github.com/jonbaldie/beanstalkd/issues/70)
  (labels `bug`, `ready-for-agent`). Replayed 2 of 2 times from fresh volumes.
  Likely cause: in `conn_timeout()`, the TTR-expiry path calls
  `enqueue_job(..., 0, 0)` and never writes the new counters to the WAL. This
  is the same class as #66.

## Rejected candidates

- Reserving a ready job during the TTR safety margin instead of returning
  `DEADLINE_SOON`: upstream behaviour by design (see journey 1).

## Unresolved / not explored

- Disconnect-returned jobs also lose `reserves` on restart, because reserve is
  never persisted upstream. Whether `reserves` should survive a restart when no
  other transition is logged is a product decision. It is noted in #70 and
  was not filed separately.
- Not explored this pass: `pause-tube` across restart (tubes are not persisted
  upstream), and WAL `-s` size limits under load (covered 2026-09-26).

## Cleanup and limitations

Every container and volume carried the `bt-pass-20261003` label and was removed
after the pass. Results come from one host (OrbStack on aarch64), and the
restart timings are at one-second resolution.
