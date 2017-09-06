FROM alpine

MAINTAINER Jonathan Baldie "jon@jonbaldie.com"

ADD install.sh install.sh
RUN chmod +x install.sh && sh install.sh && rm install.sh

EXPOSE 11300
CMD beanstalkd -p 11300
