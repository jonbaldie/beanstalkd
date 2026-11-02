### Beanstalkd Docker Repository

[![CI](https://github.com/jonbaldie/beanstalkd/actions/workflows/ci.yml/badge.svg)](https://github.com/jonbaldie/beanstalkd/actions/workflows/ci.yml) [![Docker Pulls](https://img.shields.io/docker/pulls/jonbaldie/beanstalkd.svg)](https://hub.docker.com/jonbaldie/beanstalkd)

To use:

`docker pull jonbaldie/beanstalkd`

Alternatively you can `git clone` the repo and run `make` from the project root.

To persist jobs across container restarts, mount a named volume at the
beanstalk-owned `/data` directory and enable the write-ahead log:

```sh
docker volume create beanstalkd-data
docker run -d --name beanstalkd -p 11300:11300 \
  -v beanstalkd-data:/data \
  jonbaldie/beanstalkd:latest beanstalkd -b /data
```

### Integration test CLI

Run `./test.sh [--test NAME] [--docker-cmd EXECUTABLE] [IMAGE]` from the
repository root. With no selector, the runner executes all cases in the order
shown by `./test.sh --help`. `IMAGE` defaults to `jonbaldie/beanstalkd:latest`.
Options can precede or follow the image. `--` ends option parsing.

`--test NAME` executes one case and its required fixtures. Protocol cases share
one daemon during a full run. A selected metadata case starts no daemon.
Persistence cases create their own labelled containers and volumes.

| Name | Check |
| --- | --- |
| `stats` | Daemon readiness and loopback port binding |
| `non_root` | Daemon runs as an unprivileged user |
| `install_artifact` | Install script absent from filesystem and layers |
| `expose` | Image declares port 11300 |
| `image_size` | Image stays within 20 MB |
| `kick_bounds` | Malformed kick bounds preserve queue state |
| `persistence` | Job survives restart on a named volume |
| `volume_leak` | Default run attaches no anonymous volume |
| `reserve_timeout_bounds` | Malformed reserve timeouts preserve queue state |
| `split_buffer` | Split command terminators preserve stream synchronization |
| `pause_tube_delimiter` | Pause command requires its delimiter |
| `quit_prefix` | Malformed quit prefixes are rejected |
| `put_oversize_trailing_garbage` | Malformed oversized puts do not hang |
| `reserve_job_persistence` | Reserved jobs recover across restart |
| `release_persistence` | Release preserves priority and counters |
| `bury_replay` | Restart preserves the bury counter |
| `ttr_timeout_persistence` | Restart preserves the timeout counter |
| `max_job_size_replay` | Maximum-size jobs survive WAL replay |

`--docker-cmd` overrides `DOCKER_CMD`, which defaults to `docker` when unset or
empty. The value is one executable name or path, including paths with spaces.
Arguments and shell expressions are not evaluated. Use an executable wrapper
script when you need extra Docker arguments. The configured executable handles
all runner Docker operations, including diagnostics and cleanup.

```sh
./test.sh --test persistence local/beanstalkd:dev
DOCKER_CMD='/tmp/docker wrapper' ./test.sh --test volume_leak
./test.sh --docker-cmd '/tmp/docker wrapper' --test stats local/beanstalkd:dev
```

Unknown names, unknown options, missing or empty values, repeated `--test` or
`--docker-cmd` options, and extra image arguments fail before Docker operations
or scratch-directory creation.
Invalid CLI input exits with status 2. `--help` requires neither Docker nor Python.

`python3 tests/test_runner_cli.py` checks selection, order, command precedence,
and teardown using deterministic process doubles without Docker. The real
integration cases retain their protocol assertions. `make test` builds `IMAGE`,
runs these CLI checks and the targeted resource meta-tests, then runs the full
integration suite once.

### Upstream patches

`patches/series` lists every patch once in application order. Run `make check-patches`
to download and checksum the pinned source and apply the series without Docker
or compilation. `./test_patch_series.sh` checks inventory and application failures.
The image build and `make test-ct` use the same source preparation script.

### Upstream C tests

Run `make test-ct` without Docker. It requires a C compiler, make, patch, curl,
tar, and either sha256sum or shasum. The runner downloads and SHA-256 verifies
upstream v1.13, applies the packaging patches, assembles the downstream tests,
and runs upstream `make check`. Sources, binaries, and ct failure diagnostics
remain under `.ct-build/run-*` (ignored by Git); remove these directories when
no longer needed. On macOS only, the runner permits Apple Clang's known upstream
constant-VLA warning; other warnings remain errors.

`ct-tests/series` is the authoritative ordered inventory of C fragments. Add new
`.c` files there exactly once. `ct-tests/assemble.sh [SUITE_DIR]` validates the
entire inventory before emitting the shared helpers followed by the fragments;
missing, duplicate, or unlisted fragments fail. Put reusable static helpers in
`ct-tests/testserv-helpers.h`, not individual fragments, since all fragments share
upstream `testserv.c` scope. `./test_ct_manifest.sh` checks this assembly contract.
The Docker build uses the same source runner and assembly seam; `make test`
also runs the manifest contract tests and the container integration suite.

For queue, persistence, worker, and container behavior observed in practice,
see the [exploratory testing reports](docs/exploratory-testing/README.md).

(c) 2017 Jonathan Baldie
