# Worker and persistence exploratory pass, 2026-11-04

## Setup

Tested `origin/master` at `a628b4894c2acbaabd314d3f2983bc440e07054a` in a separate worktree. The Dockerfile built the patched upstream v1.13 daemon and ran its C suite. The [build and successful replay](evidence/2026-11-04/replay.txt) include the output. The project has no dependency lockfile. The source archive is version-pinned and checksum-verified, but the Alpine base and packages are not locked. The replay used a fresh named volume, ephemeral loopback ports, and separate TCP clients. Persistence used `beanstalkd -b /data -f 0`.

The [protocol specification](https://github.com/beanstalkd/beanstalkd/blob/v1.13/doc/protocol.txt) describes priorities, tube selection, worker disconnects, time-to-run expiry, and the job commands exercised here. The [README](../../README.md) documents the container and persistent volume setup.

Run `sh docs/exploratory-testing/evidence/2026-11-04/run.sh` from the repository root to build and repeat the [journeys](evidence/2026-11-04/journeys.py). The script registers unique names for the image, container, volume, and dedicated BuildKit builder before creating them and removes them on exit.

## Journeys

1. **Queue and process jobs.** A producer inserted jobs with different priorities into `alpha`. A worker watching only the default tube timed out. After watching `alpha` and ignoring `default`, it reserved the higher-priority job first, checked both bodies, deleted both jobs, and confirmed that the queue was empty.
2. **Recover work from a worker.** A worker reserved a job and disconnected. Another connection reserved the same job and body, released it, and reserved it again. After the two-second time-to-run expired, the producer reserved and deleted the job. The former worker's delete returned `NOT_FOUND`.
3. **Keep jobs across restarts.** With a new named volume, a worker buried one job and left another ready. After a container restart, `peek-buried` returned the buried job and the ready job was reserved with its body intact. The worker deleted the ready job, kicked and deleted the buried job, and restarted again. Both an empty reserve and `peek-buried` confirmed that deletion persisted.

No product bugs were confirmed and no new issue was filed. Related previous fixes include [#67](https://github.com/jonbaldie/beanstalkd/issues/67) for buried-job replay and [#76](https://github.com/jonbaldie/beanstalkd/issues/76) for time-to-run expiry. This pass did not check replay counters or the exact expiry boundary.

## Driver observation and limits

The [initial attempt](evidence/2026-11-04/initial-attempt.txt) failed to reconnect after restart because the driver reused the old ephemeral host port. Docker had assigned a new port. The driver was changed to query the port again and all three journeys were replayed with fresh state. The corrected replay passed. This was a driver failure, not a product defect. No unresolved product candidates remain from these journeys.

The pass did not exercise delayed jobs, malformed commands, multiple concurrent workers, crash or power-loss recovery, WAL corruption, or remote networking. A Docker restart is not a power failure. The package has no authentication journey in the documented interface.

## Cleanup

Both runs removed their registered containers, volumes, images, and dedicated builders. The transcripts include the teardown checks. The builder's cache lived in its own Docker volume and was removed with the builder. Port and resource checks were repeated after the replay. The worktree is removed after the report is published.
