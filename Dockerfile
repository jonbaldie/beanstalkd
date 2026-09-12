# The Alpine beanstalkd package (1.13) accepts malformed `kick` bounds: the
# bound is parsed with a bare strtoul(), so `kick 1garbage` is silently
# truncated and `kick -1` wraps to a huge unsigned count. Both reply `KICKED n`
# and kick the whole buried queue instead of returning BAD_FORMAT with the
# queue untouched (issue #36). It likewise accepts malformed
# `reserve-with-timeout` bounds: the bound is parsed with a non-NULL end
# pointer, which disables read_u32()'s full-consumption check, so trailing
# garbage is silently accepted and the command reserves a ready job
# (issue #39). It also hangs indefinitely when command lines split \r\n across
# the 224-byte read buffer boundary, discarding \r and desynchronizing the
# connection (issue #40). It also accepts pause-tube commands lacking a space
# delimiter between the command word and tube argument, pausing the tube
# instead of returning UNKNOWN_COMMAND (issue #41). It also closes the
# connection without a response for any command line beginning with "quit"
# that is not exactly `quit\r\n` (issue #42). No upstream release fixes
# these yet, so the published daemon is built here from the pinned upstream
# source with packaging-level patches (patches/kick-bound.patch,
# patches/reserve-timeout-bound.patch, patches/split-buffer-hang.patch,
# patches/pause-tube-delimiter.patch, patches/quit-prefix.patch) that
# validate bounds, require command delimiters, preserve split line
# terminators, and reject malformed quit prefixes. Everything else about the
# package (user, directories, runtime dependencies) is unchanged; the patched
# binary replaces the package binary.

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