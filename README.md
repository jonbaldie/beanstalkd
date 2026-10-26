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
