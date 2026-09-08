FROM alpine

RUN apk add --no-cache beanstalkd

USER beanstalk

EXPOSE 11300
CMD ["beanstalkd", "-p", "11300"]
