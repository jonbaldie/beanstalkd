FROM alpine

RUN apk add --no-cache beanstalkd \
    && apk upgrade --no-cache \
    && mkdir -p /data \
    && chown beanstalk:daemon /data

VOLUME ["/data"]
USER beanstalk

EXPOSE 11300
CMD ["beanstalkd", "-p", "11300"]
