# Queue and recovery exploratory pass, 2026-10-27

## Setup

Tested `origin/master` at `65dd7dfbd7c886c818ec4512734a45435244aa80` in a separate worktree. Built the Dockerfile image locally. The Docker build ran the patched upstream v1.13 C suite and reported `PASS`. The project has no dependency lockfile; the upstream tarball is version-pinned and checksum-verified, while Alpine packages are resolved at build time. The pass used a fresh named volume, an ephemeral loopback port, and two TCP clients. The persistent server used `beanstalkd -b /data -f 0`.

[Replay script](evidence/2026-10-27/journeys.py) and [successful transcript](evidence/2026-10-27/replay.log). Run the script from the repository root with Docker and Python 3. It builds and removes its own named image, container, and volume. Do not run it if resources named `explore-beanstalkd-20261027` already exist.

## Journeys and results

1. **Priority and ownership.** A producer submitted two jobs to a non-default tube. A worker watched that tube, reserved the higher-priority job first, and deleted both. A second client could not delete the reserved job. An empty reserve timed out. The job bodies were checked as well as responses.
2. **Delay and retry.** A delayed job was initially unavailable, became reservable, was buried, and was unavailable again. Kicking it returned it to the ready queue, where the worker reserved and deleted the same body.
3. **Recovery.** A zero-delay release and a buried job were written to the volume. After a container restart, the released job was reservable with its body intact. The buried job stayed unavailable until kicked, then was reserved and deleted. This checks state after restart, not merely the initial responses.

No product bugs were confirmed. Existing related fixes include [#66](https://github.com/jonbaldie/beanstalkd/issues/66) for release persistence and [#67](https://github.com/jonbaldie/beanstalkd/issues/67) for buried-job replay. This pass did not inspect their counters. Existing issues and closed issues were listed before reporting; no new issue was filed.

## Driver observation and limits

The [first attempt](evidence/2026-10-27/initial-driver-timeout.log) timed out in the client during a four-second reserve because its socket timeout was only two seconds. The socket timeout was raised to eight seconds and all journeys were replayed on a fresh volume; the delayed job was then reserved successfully. This was a test-driver fault, not a confirmed daemon failure.

This pass did not cover concurrent worker races, crash or power-loss recovery, WAL corruption, authentication, or remote networks. Docker restart is a graceful container restart, not a power failure. No unresolved product candidates remain from these journeys.

## Cleanup

The driver registered its image, container and volume before creation and removed them in `finally`. The final check found no container, volume or tagged image with the pass-specific name. The worktree and scratch build outputs are removed after publication; shared Docker build cache is not pruned because it may contain other runs' data.
