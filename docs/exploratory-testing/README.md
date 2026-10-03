# Exploratory testing reports

These reports record user-facing journeys exercised against the packaged
beanstalkd image and link to replay evidence.

- [2026-10-03 AFK pass](2026-10-03-beanstalkd-afk.md) — worker failure
  recovery and TTR timeout counter persistence (#70), delayed jobs across
  restart, drain mode.
- [2026-10-02 AFK pass](2026-10-02-beanstalkd-afk.md) — protocol command
  fuzzing, zero-delay release WAL persistence, and buried counter replay.
- [2026-09-30 AFK pass](2026-09-30-beanstalkd-afk.md) — protocol boundary
  fuzzing, reserve-job WAL persistence recovery, and stats counter coverage.
- [2026-09-26 AFK pass](2026-09-26-beanstalkd-afk.md) — multi-tube work,
  worker concurrency, WAL recovery, and IPv6 host access.
- [2026-09-19 AFK pass](2026-09-19-beanstalkd-afk.md) — tube lifecycle, job
  state management, and protocol grammar.
- [2026-09-12 AFK pass](2026-09-12-beanstalkd-afk.md) — protocol boundaries,
  worker ownership, and drain behavior.
- [2026-09-12 protocol exploration](2026-09-12-beanstalkd.md) — parser
  boundaries, instrumented execution, and stateful action sequences.
- [2026-09-10 protocol and runtime exploration](2026-09-10-beanstalkd.md) —
  normal queue work, worker recovery, and documented Docker persistence.
