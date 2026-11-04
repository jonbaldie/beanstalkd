# Worker and persistence exploratory pass, 2026-11-04

## Setup

Tested `origin/master` at `a628b4894c2acbaabd314d3f2983bc440e07054a` in a separate worktree. The Dockerfile built the patched upstream v1.13 daemon and ran its C suite. The [build and successful replay](evidence/2026-11-04/replay.txt) include the output. The project has no dependency lockfile. The source archive is version-pinned and checksum-verified, but the Alpine base and packages are not locked. The replay used a fresh named volume, ephemeral loopback ports, and separate TCP clients. Persistence used `beanstalkd -b /data -f 0`.

The [protocol specification](https://github.com/beanstalkd/beanstalkd/blob/v1.13/doc/protocol.txt) describes priorities, tube selection, time-to-run expiry, and the job commands exercised here. The [README](../../README.md) documents the container and persistent volume setup.

The transcripts record the Docker commands and TCP requests used in each journey, but do not identify the client for each request or record disconnects and waits. An independent review checked the temporary driver against the transcript and found that its cleanup could delete pre-existing Docker resources if its PID-based names collided. The driver was not retained as a reusable script. No collision was observed during these runs.

## Journeys

1. **Queue and process jobs.** A producer inserted jobs with different priorities into `alpha`. A worker watching only the default tube timed out. After watching `alpha` and ignoring `default`, it reserved the higher-priority job first, checked both bodies, deleted both jobs, and confirmed that the queue was empty.
2. **Recover work from a worker.** A worker reserved a job and disconnected. Another connection reserved the same job and body, released it, and reserved it again. After the two-second time-to-run expired, the producer reserved and deleted the job. The former worker's delete returned `NOT_FOUND`.
3. **Keep jobs across restarts.** With a new named volume, a worker buried one job and left another ready. After a container restart, `peek-buried` returned the buried job and the ready job was reserved with its body intact. The worker deleted the ready job, kicked and deleted the buried job, and restarted again. Both an empty reserve and `peek-buried` confirmed that deletion persisted.

No product bugs were confirmed and no new issue was filed. Related previous fixes include [#67](https://github.com/jonbaldie/beanstalkd/issues/67) for buried-job replay and [#76](https://github.com/jonbaldie/beanstalkd/issues/76) for time-to-run expiry. This pass did not check replay counters or the exact expiry boundary.

## Driver observation and limits

The [initial attempt](evidence/2026-11-04/initial-attempt.txt) failed to reconnect after restart while reusing the old ephemeral host port. The cause is not proven because the driver did not inspect the new mapping on that attempt. On replay, Docker assigned a new port after restart. The driver queried the mapping again and all three journeys passed with fresh state. No product defect was confirmed from the initial refusal. No unresolved product candidates remain from these journeys.

The pass did not exercise delayed jobs, malformed commands, multiple concurrent workers, crash or power-loss recovery, WAL corruption, or remote networking. A Docker restart is not a power failure. The package has no authentication journey in the documented interface.

## Cleanup

Both runs removed their registered containers, volumes, images, and dedicated builders. The transcripts include teardown listings. The builder's cache lived in its own Docker volume and was removed with the builder. The [follow-up resource and port check](evidence/2026-11-04/cleanup.txt) found no remaining resources or listeners from either run. The worktree is removed after the report is published.
