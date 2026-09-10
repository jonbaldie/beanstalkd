# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- `test.sh` now scopes the default-run volume regression check to mounts on its
  own test container, so it no longer treats unrelated host volumes as leaks
  or deletes them (#31).
- `test.sh` now names its Docker resources with a random per-run suffix and tags
  them with an ownership label, and teardown removes only labelled resources.
  Previously every name was derived from `$$` alone and cleanup force-removed
  those names unconditionally, so a recycled PID let the suite adopt and then
  destroy a container or volume a user already owned (#30).
- `test.sh` refuses to reuse a pre-existing persistence volume instead of
  silently adopting it, and now also cleans up on `HUP`/`INT`/`TERM` (#30).

## [1.0.1] - 2026-09-08

### Fixed
- `test.sh` maps a random localhost port instead of host :11300, so `make test`
  no longer fails with docker exit 125 when that port is already allocated (#25, #28).
- Removed `VOLUME ["/data"]` from the image: a default (non-persistent) run
  attached an unused anonymous volume to `/data`, and `docker rm -f` never
  deletes anonymous volumes, so they accumulated on the host (#24, #27). Named-volume
  persistence (`docker run -v vol:/data ... beanstalkd -b /data`) is unchanged;
  the beanstalk-owned `/data` directory in the image is what makes it work.
- `test.sh` cleans up anonymous `/data` volumes on teardown using `docker rm -fv` (#26).
- `test.sh` assigns container names before execution to guarantee cleanup of
  created containers even when `docker run` fails early (#22).
- Pre-created `/data` with `beanstalk:daemon` ownership in `Dockerfile`, allowing
  the unprivileged `beanstalk` daemon user to acquire WAL locks when using
  Docker-managed named persistence volumes (#21).
- Added pre-flight check in `test.sh` to fail fast with a clear error message
  when host dependency `python3` is missing (#19, #20).
- Fixed `test.sh` process inspection to query the daemon's effective user in the
  container process table (`ps -o user,comm`) rather than evaluating a transient
  `whoami` exec process (#9, #14).
- Inlined package installation in `Dockerfile` via `apk add --no-cache beanstalkd`,
  resolving Hadolint DL3020 and eliminating temporary `install.sh` artifacts from
  intermediate layers (#10, #13).
- Fixed `test.sh` EXIT trap quoting (ShellCheck SC2064) and double-quoted variable
  expansions (ShellCheck SC2086) (#11, #12).

### Security
- Upgraded Alpine base image packages during build (`apk upgrade --no-cache`) to
  resolve CVE-2026-14456 in `libcrypto3` and `libssl3` (#8, #15).

### Changed
- Replaced Beads issue tracking with GitHub Issues and added agent skills
  configuration documentation in `docs/agents/` (#16).

## [1.0.0] - 2026-09-06

### Added
- Integration test suite in `test.sh` verifying:
  - Beanstalkd daemon responds with `OK` to `stats` command on port 11300 over TCP.
  - Process executes as unprivileged `beanstalk` user rather than `root`.
  - Temporary installation script `/install.sh` is removed from final image.
  - Container image metadata explicitly declares `EXPOSE 11300/tcp`.
  - Image size guard enforcing Alpine lightweight footprint under 20 MB (current: ~8 MB).
- GitHub Actions CI workflow (`.github/workflows/ci.yml`) replacing deprecated Travis CI.
- Automated Docker Hub publishing pipeline pushing `jonbaldie/beanstalkd:latest` on push to `master`.
- Issue and task tracking integration with Beads (`bd`).

### Changed
- Migrated base image package installation to use `apk add --no-cache`.
- Switched default `CMD` to exec array format `["beanstalkd", "-p", "11300"]`.

### Security
- Added non-root user `USER beanstalk` to run the daemon with unprivileged permissions.
- Removed deprecated `MAINTAINER` instruction from `Dockerfile`.

[1.0.1]: https://github.com/jonbaldie/beanstalkd/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/jonbaldie/beanstalkd/releases/tag/v1.0.0
