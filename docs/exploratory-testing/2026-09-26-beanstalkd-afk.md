# Exploratory testing — beanstalkd AFK pass

Date: 2026-09-26

## Build and starting state

- Repository: `jonbaldie/beanstalkd`, commit `57453ce` (`v1.0.5`)
- Image: `jonbaldie/beanstalkd:latest`, rebuilt with `make test`
- Docker Server: 29.4.0 (OrbStack, aarch64)
- Service version from `stats`: beanstalkd 1.13
- The repository integration suite (`make test`) passed completely.
- Live tests used fresh uniquely named containers and random loopback-only host
  ports. Probe containers and temporary Docker volumes were removed after each
  journey.
- Existing exploratory reports and evidence were preserved.

## Journeys exercised

### 1. Multi-tube routing, cross-tube worker competition, tube pause isolation, and empty tube garbage collection

Goal: exercise creation of tubes with various allowed characters (`+-+/;.$_()`),
the 200-byte tube name boundary, rejection of invalid tube names, routing of jobs
across multiple workers with distinct watch-lists, strict priority scheduling across
different tubes, tube pause isolation between workers, immediate resumption via
`pause-tube <tube> 0`, and automatic garbage collection of unreferenced empty tubes.

Observed:

- Tube names containing allowed punctuation (`alpha+1`, `beta-2`, `gamma/3`,
  `delta;4`, `epsilon.5`, `zeta$6`, `eta_7`, `theta(8)`) and 200-character tube
  names were accepted by `use` and returned in `list-tubes`.
- Names exceeding 200 characters (201 characters), names starting with a hyphen
  (`-invalid`), or containing spaces (`bad tube`) or colons (`bad:tube`) were
  rejected with `BAD_FORMAT\r\n`.
- Multi-tube routing: Worker 1 (watching only `urgent_queue`) and Worker 2
  (watching only `bulk_queue`) received only the jobs destined for their
  respective tubes.
- Strict priority ordering across tubes: Worker 3 (watching both `urgent_queue`
  and `bulk_queue`) was offered a pri 5 job in `bulk_queue` ahead of a pri 50 job
  in `urgent_queue`.
- Tube pause isolation: pausing `urgent_queue` for 10 seconds caused Worker 1 to
  time out on reservation, while Worker 3 (watching both) bypassed the paused
  tube and immediately received ready work from `bulk_queue`.
- Immediate unpause: `pause-tube urgent_queue 0` immediately unpaused the tube and
  allowed Worker 1 to reserve the withheld job.
- Tube garbage collection: a transient empty tube created by a client was
  automatically deleted when all client connections disconnected, and did not
  appear in subsequent `list-tubes` queries from new connections.

Evidence: [2026-09-26-multi-tube-lifecycle.txt](evidence/2026-09-26-multi-tube-lifecycle.txt).

### 2. Complex job lifecycle transitions, concurrent worker race conditions, TTR deadline enforcement, and connection drop recovery

Goal: track a single job through all state transitions (ready, reserved, delayed,
buried), verify cross-client action rejection on reserved work, manage multiple
reservations per worker, verify `DEADLINE_SOON` safety margin triggers, refresh
deadlines with `touch`, verify automatic requeuing on TTR expiry, and verify
recovery of in-flight work upon abrupt worker socket disconnects.

Observed:

- Full state transition path:
  `put` (ready) -> `reserve` (reserved) -> `release` with delay 2s (delayed) ->
  delay expiry (auto-transitioned to ready) -> `reserve-job` (reserved) -> `bury`
  (buried) -> `kick-job` (ready) -> `reserve` (reserved) -> `delete` (destroyed).
- Cross-client isolation: while Worker A held a reserved job, Worker B attempted
  `delete`, `release`, `bury`, `touch`, and `reserve-job`. All five operations
  returned `NOT_FOUND\r\n`. Read-only inspection via `peek <id>` remained
  permitted for other clients.
- Multiple reservations and deadline enforcement: Worker A reserved two jobs
  concurrently (TTR 5 and TTR 2). When the earliest job reached <= 1s remaining on
  its TTR, subsequent `reserve` commands on an empty queue immediately returned
  `DEADLINE_SOON\r\n`.
- Touch extension: Worker A called `touch` on the expiring job, refreshing its
  remaining time-to-run back towards 2 seconds and allowing further reservations.
- TTR expiry and stale owner rejection: when Worker A let the job's TTR lapse
  without touching, the daemon automatically returned the job to the ready queue
  and incremented `timeouts: 1`. Worker B reserved the job. Worker A's subsequent
  `delete` returned `NOT_FOUND\r\n`.
- Abrupt disconnect: Worker A disconnected while holding a reserved job. The
  daemon immediately returned the job to the ready queue, where Worker B reserved
  and completed it.

Evidence: [2026-09-26-ttr-deadline-transitions.txt](evidence/2026-09-26-ttr-deadline-transitions.txt).

### 3. Write-Ahead Log (WAL) persistence, file rollover, compaction, and directory locking

Goal: verify multi-file binlog rollover under low file size limits (`-s 4096`),
automatic log compaction (`walcompact`) and dead file pruning (`walgc`),
exclusion of concurrent daemons via directory locking (`waldirlock`), and complete
recovery of ready, delayed, and buried jobs across container stop and recreate
cycles on a Docker-managed named volume.

Observed:

- Directory locking (`waldirlock`): when Container 1 ran with `-b /data`, launching
  Container 2 against the same directory failed immediately with exit code 10 and
  logged `beanstalkd: serv.c:24 in srv_acquire_wal: failed to lock wal dir /data`.
- Binlog rollover: writing 50 jobs with 150-byte bodies under `-s 4096` generated 5
  consecutive binlog files (`binlog.1` through `binlog.5`).
- Binlog compaction: deleting 45 of the 50 jobs and performing a trigger write
  invoked `walmaint` / `walcompact`. Obsolete log files (`binlog.1`, `binlog.2`,
  `binlog.3`) were unlinked by `walgc`, leaving only active files.
- Persistence recovery across restart: Container 1 was stopped and destroyed.
  Container 3 was launched with the same volume mounted to `/data`. All tubes and
  jobs in Ready, Delayed (remaining delay preserved), and Buried states were
  recovered intact with their payloads and priorities matching pre-restart state.

Evidence: [2026-09-26-wal-compaction-recovery.txt](evidence/2026-09-26-wal-compaction-recovery.txt).

## Follow-up pass on the same date

The additional journeys below were run from commit `813fd32` on 2026-09-26.
The image was rebuilt with `make test`; the suite passed, including container
cleanup, volume isolation, occupied-port and name-collision handling, the
protocol regressions, and persistence checks. The built image ID was
`sha256:effc1e220cae058ca696ecc46d0e96689febb3feebdab7fb23073a2d89be48cb`.

### 4. Competing workers and reservation retry

Goal: start multiple waiting workers before a burst of jobs arrives, then make
sure each job is delivered once with its original payload and that a worker can
continue using its connection after a reservation timeout.

Observed:

- Eight workers waited on the same tube while a producer inserted 100 jobs.
  Every job was delivered and deleted exactly once, all 100 bodies matched, and
  `stats-tube default` reported zero ready and reserved jobs afterward.
- An empty `reserve-with-timeout 1` returned `TIMED_OUT`. The same client then
  received a newly inserted job on a subsequent reservation and deleted it.

Evidence: [2026-09-26-concurrent-worker-recovery.txt](evidence/2026-09-26-concurrent-worker-recovery.txt).

### 5. WAL recovery after abrupt daemon termination

Goal: verify recovery from a daemon process killed without a graceful shutdown,
including a job that was reserved by a worker when the daemon stopped.

Observed:

- With a named volume at `/data` and `beanstalkd -b /data -s 4096 -f 0`, the
  initial job states were buried, delayed, reserved, and ready. `-f 0` made the
  daemon fsync each WAL update.
- Docker reported exit code 137 after `SIGKILL`. A new container using the same
  volume restored the buried, delayed, and ready jobs to their prior states and
  recovered the in-flight reserved job as ready.
- All four payloads matched their pre-kill values. The recovered ready jobs
  could be reserved and deleted; the delayed and buried jobs could be deleted.

Evidence: [2026-09-26-wal-sigkill-recovery.txt](evidence/2026-09-26-wal-sigkill-recovery.txt).

### 6. IPv6 client connection

Goal: use an IPv6 client connection to reach a daemon configured with an IPv6
listener, then complete normal queue work over that connection.

Observed:

- A fresh container was started with `beanstalkd -l :: -p 11300` and published
  on `[::1]` using a random host port.
- An IPv6 client connected to `::1`, read `stats`, inserted a job, reserved it,
  verified its body, and deleted it successfully.
- The Docker bridge reported `enableIPv6=false`. The host-side IPv6 published
  connection worked in this environment, but the container bridge itself did
  not provide an end-to-end IPv6 network path.

Evidence: [2026-09-26-ipv6-transport.txt](evidence/2026-09-26-ipv6-transport.txt).

## Confirmed bugs filed

No new product bugs were uncovered during this exploratory pass. All observed
behaviors across multi-tube routing, worker scheduling and timeouts, and WAL
persistence conformed to the protocol specification and documented design. The
follow-up concurrency, abrupt-process-recovery, and host-side IPv6 journeys also
completed without a confirmed product bug.

## Usability observations

- A client connection remained usable after `reserve-with-timeout` returned
  `TIMED_OUT`; a later reservation on that connection received newly inserted
  work.
- IPv6 host access worked when the daemon was explicitly configured with
  `-l ::` and the port was published on `[::1]`. The IPv6-disabled Docker bridge
  limits this result to the host-published path exercised here.

## Existing confirmed findings not duplicated

The repository already resolved earlier findings:

- [#36 — beanstalkd accepts malformed kick bounds](https://github.com/jonbaldie/beanstalkd/issues/36)
- [#39 — beanstalkd accepts malformed reserve-with-timeout bounds](https://github.com/jonbaldie/beanstalkd/issues/39)
- [#40 — beanstalkd hangs when command lines split \r\n across buffer boundary](https://github.com/jonbaldie/beanstalkd/issues/40)
- [#41 — beanstalkd accepts pause-tube commands lacking space delimiter](https://github.com/jonbaldie/beanstalkd/issues/41)
- [#42 — beanstalkd closes the connection for malformed quit prefixes](https://github.com/jonbaldie/beanstalkd/issues/42)
- [#48 — beanstalkd hangs in bitbucket mode for malformed put commands with oversize body](https://github.com/jonbaldie/beanstalkd/issues/48)

## Rejected observations and driver corrections

- In Journey 1, an initial probe sent `put 100 0 10 7\r\nbulk_job\r\n` where the
  declared body size (7 bytes) was 1 byte shorter than the actual body (8 bytes),
  causing beanstalkd to return `EXPECTED_CRLF\r\n`. Correcting the declared byte
  count to 8 in the test driver resolved the error.
- In Journey 3, `docker logs` did not capture daemon lock failure output on stdout
  because `twarn` writes to stderr. Redirecting stderr in the test runner
  successfully confirmed exit code 10 and the lock failure message.
- The first concurrency driver waited for the `INSERTED` response before sending
  the job body. Beanstalkd correctly waited for the declared body; sending the
  command and body before reading the response corrected the driver, and the
  full 100-job replay passed.
- The first WAL recovery attempt left `crash_tube` outside the worker's watch
  list, so `reserve-with-timeout` returned `TIMED_OUT`. Watching the producer's
  tube corrected the setup. A later verification attempt also needed to consume
  the `reserve-job` payload and its CRLF before issuing `delete`; after draining
  the response body, the crash recovery replay passed.

## Unresolved and unexplored areas

No unresolved product failures remained in the selected journeys. The follow-up
tested recovery after a daemon process `SIGKILL` with fsync enabled; it did not
simulate power loss during a WAL write or host storage failure. IPv6 was tested
from the host through an IPv6 published port, but an IPv6-enabled container
bridge was unavailable because Docker reported `enableIPv6=false`. Deliberate
read-only filesystem mounting also remains unexplored.

## Cleanup and limitations

All containers and Docker named volumes created during this pass were destroyed.
The follow-up containers and its named volume were also removed. Testing was
conducted using Docker 29.4.0 (OrbStack, aarch64) on macOS.
