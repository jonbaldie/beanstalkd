# Exploratory testing — beanstalkd AFK pass

Date: 2026-10-24 (UTC)

## Build and starting state

- Repository: `jonbaldie/beanstalkd`, commit
  `66629e3f9f2fe8a4db6034f296147d017cb9e117` on `master`.
- Built the repository Dockerfile as `beanstalkd-et-20261024:run`;
  image ID `sha256:a2321b5c728235bab4da1eceac6ceeaa2cde4c82d12473f0ebfcff8386a3cedd`.
  The patched upstream v1.13 build and upstream ct suite passed.
- Environment: macOS host, Docker 29.8.2, Linux/arm64 daemon (OrbStack).
- Each journey started with fresh uniquely named containers, random loopback-only
  TCP ports, and (for persistence) a fresh named volume at `/data`.
- Driver: Python standard-library sockets against the public TCP protocol. No
  internal daemon calls or instrumentation. The runtime user is `beanstalk`.
- No project dependency lockfile exists. No host dependencies were installed.
  The Dockerfile downloads checksum-verified v1.13 source and installs Alpine
  packages without a lockfile; the Alpine base and package versions are mutable.
  Builds used the workspace Docker context and existing shared Docker cache.
  No dependencies or build outputs were mutated through symlinks into another
  checkout. The supplied `TMPDIR` held the reference protocol document.

Evidence directory: [evidence/2026-10-24/](evidence/2026-10-24/).
[Build log](evidence/2026-10-24/build.txt),
[integration log](evidence/2026-10-24/integration.txt),
[environment and cleanup](evidence/2026-10-24/environment-cleanup.txt).

## Expectations

The README promises named-volume WAL persistence. The upstream
[v1.13 protocol](https://github.com/beanstalkd/beanstalkd/blob/v1.13/doc/protocol.txt)
defines opaque job bodies, size rejection, watch lists, pause/unpause, touch,
worker-disconnect recovery, and error responses. These public contracts ground
this pass; it does not assume contiguous job IDs or persistence of process-wide
cumulative counters.

## Journeys exercised

### 1. Process work from multiple queues while one queue is paused

Goal: pause email processing without blocking audit work, then resume email and
recover its job after a worker disconnects.

- Produced an email job containing NUL and CRLF and an audit job in separate
  tubes. One worker watched both and ignored `default`.
- Paused email for 30 seconds. The worker received and deleted the audit job;
  a subsequent immediate reservation timed out while the email job remained.
- Variation: attempted pause durations `-1`, `4294967296`, and `1garbage`.
  Each returned `BAD_FORMAT`; the queue stayed paused.
- Corrected the pause to zero and reserved the original email bytes.
- Touched its two-second TTR after 1.1 seconds. After another 1.1 seconds,
  `stats-job` still reported `reserved`, demonstrating the extended deadline.
- Closed the owning worker connection. A new worker reserved the same ID and
  exact payload, deleted it, and `peek` confirmed `NOT_FOUND`.

Outcome: passed in both fresh runs.

### 2. Persist opaque jobs at a custom size boundary

Goal: every accepted body survives restart, and persisted state/counters and
subsequent deletion remain correct.

- Started with `-b /data -f 0 -z 1000 -s 4096` and a fresh named volume.
- Put bodies of 0, 256 (all byte values), 998, 999, and 1000 bytes, followed by
  a small sentinel job. The binary body's header CRLF and body were fragmented
  across socket writes.
- Reserved and buried the binary job at priority 7.
- Restarted twice. Every job's ID and bytes matched using `peek`; the buried
  job's state, priority, reserves, buries, and kicks matched the pre-restart
  values. Evidence logs include body SHA-256 hashes; assertions compare bytes.
- Variation: deleted the sentinel, restarted a third time, and confirmed it
  stayed absent. Kicked, reserved, checked and deleted the restored binary job.

Outcome: passed in both fresh runs. The custom-limit boundary and later-job
survival check did not reproduce the previously fixed data loss in
[#82](https://github.com/jonbaldie/beanstalkd/issues/82).

### 3. Recover a producer connection after rejected payloads

Goal: correct bad input without losing the next valid job or desynchronizing
commands on the same connection.

- Started a fresh daemon with `-z 1000`.
- Pipelined a 1001-byte put and a valid two-byte put in one write. Observed
  `JOB_TOO_BIG` then `INSERTED`; reserved the exact valid body and deleted it.
- Variation: sent an oversized put header with an extra argument but no body.
  It immediately returned `BAD_FORMAT`. A corrected put with fragmented header
  and body then reserved/deleted successfully on that connection.
- Sent a two-byte job with an invalid two-byte terminator. Observed
  `EXPECTED_CRLF`; a same-connection retry delivered the exact new body and
  deleted successfully. `peek-ready` then returned `NOT_FOUND`.

Outcome: passed in both fresh runs. The malformed oversized header did not
reproduce the previously fixed hang in
[#48](https://github.com/jonbaldie/beanstalkd/issues/48).

## Findings and candidate classification

- **Confirmed bugs: none.** No issues filed; existing fixes were not duplicated.
- **Rejected candidates:** malformed pause bounds did not mutate the queue;
  near-limit bodies and later jobs did not disappear on restart; rejected puts
  did not consume the next valid command. Each was exercised twice.
- **Unresolved candidates: none.** No driver failures or product exceptions
  occurred during these runs.
- Usability observation: after `EXPECTED_CRLF`, the next successful job ID
  skipped a number. The protocol does not promise contiguous IDs; clients
  should use the returned ID rather than infer the next one. Not a bug.

## Replay and verification

[Replay script](evidence/2026-10-24/journeys.py),
[first run](evidence/2026-10-24/run-1.txt),
[second run](evidence/2026-10-24/run-2.txt).

```sh
docker build -t beanstalkd-et-20261024:run .
python3 docs/exploratory-testing/evidence/2026-10-24/journeys.py
IMAGE=beanstalkd-et-20261024:run make test
docker image rm beanstalkd-et-20261024:run
```

The replay script removes its containers and volume in `finally`; the caller
owns image removal. The actual run performed the replay twice and the complete
`make test` once. All exited successfully; logs retain terminal diagnostics.

## Cleanup and limitations

All containers, named volumes, and the tagged image created by this pass were
removed. The integration suite reported successful teardown; the replay logs
record explicit removal of each resource. The final resource checks found no
remaining replay containers, volumes, or run image. Pre-existing unrelated
Docker resources and shared build/download caches were preserved.

Only Linux/arm64 under OrbStack was exercised. This was a functional pass, not
a performance or sustained-load test. It did not cover other architectures,
disk exhaustion, corrupt WAL, bind-mounted host permissions, or SIGKILL/power
loss. Restart tests used `docker restart`, not a simulated crash. The short
TTR test used wall-clock sleeps and checks a single deadline extension rather
than all scheduler races. No production fixes were made.
