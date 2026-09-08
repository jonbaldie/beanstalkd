# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- Removed `VOLUME ["/data"]` from the image: a default (non-persistent) run
  attached an unused anonymous volume to `/data`, and `docker rm -f` never
  deletes anonymous volumes, so they accumulated on the host (#24). Named-volume
  persistence (`docker run -v vol:/data ... beanstalkd -b /data`) is unchanged;
  the beanstalk-owned `/data` directory in the image is what makes it work.

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

[1.0.0]: https://github.com/jonbaldie/beanstalkd/releases/tag/v1.0.0
