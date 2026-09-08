FROM alpine

RUN apk add --no-cache beanstalkd && apk upgrade --no-cache

USER beanstalk

EXPOSE 11300
CMD ["beanstalkd", "-p", "11300"]
