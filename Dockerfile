FROM alpine

ADD install.sh install.sh
RUN chmod +x install.sh && sh install.sh && rm install.sh

USER beanstalk

EXPOSE 11300
CMD ["beanstalkd", "-p", "11300"]
