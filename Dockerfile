FROM alpine

RUN apk add --no-cache beanstalkd \
    && apk upgrade --no-cache \
    && mkdir -p /data \
    && chown beanstalk:daemon /data

# No VOLUME here: a VOLUME would attach an unused anonymous volume to every
# default run, and `docker rm -f` never deletes anonymous volumes (issue #24).
# The beanstalk-owned /data directory is enough for
# `docker run -v vol:/data ... beanstalkd -b /data` to persist its WAL.

USER beanstalk

EXPOSE 11300
CMD ["beanstalkd", "-p", "11300"]
