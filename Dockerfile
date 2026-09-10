# The Alpine beanstalkd package (1.13) accepts malformed `kick` bounds: the
# bound is parsed with a bare strtoul(), so `kick 1garbage` is silently
# truncated and `kick -1` wraps to a huge unsigned count. Both reply `KICKED n`
# and kick the whole buried queue instead of returning BAD_FORMAT with the
# queue untouched (issue #36). No upstream release fixes this yet, so the
# published daemon is built here from the pinned upstream source with a
# packaging-level patch (patches/kick-bound.patch) that validates the bound
# with the daemon's own read_u32(), exactly as the other integer arguments are
# validated. Everything else about the package (user, directories, runtime
# dependencies) is unchanged; the patched binary replaces the package binary.

FROM alpine AS build

RUN apk add --no-cache gcc musl-dev make patch wget

COPY patches/ /patches/

RUN set -eu; \
    wget -q -O /tmp/beanstalkd.tar.gz \
        "https://github.com/kr/beanstalkd/archive/v1.13.tar.gz"; \
    echo "26292dcdc0a7011d2f8ad968612f2cd8b2ef07687224876015399ae85e9e5263  /tmp/beanstalkd.tar.gz" \
        | sha256sum -c -; \
    tar xzf /tmp/beanstalkd.tar.gz -C /tmp; \
    cd /tmp/beanstalkd-1.13; \
    for p in /patches/*.patch; do patch -p1 < "$p"; done; \
    make; \
    cp beanstalkd /beanstalkd

FROM alpine

RUN apk add --no-cache beanstalkd \
    && apk upgrade --no-cache \
    && mkdir -p /data \
    && chown beanstalk:daemon /data

COPY --from=build /beanstalkd /usr/bin/beanstalkd

# No VOLUME here: a VOLUME would attach an unused anonymous volume to every
# default run, and `docker rm -f` never deletes anonymous volumes (issue #24).
# The beanstalk-owned /data directory is enough for
# `docker run -v vol:/data ... beanstalkd -b /data` to persist its WAL.

USER beanstalk

EXPOSE 11300
CMD ["beanstalkd", "-p", "11300"]