### Beanstalkd Docker Repository

[![CI](https://github.com/jonbaldie/beanstalkd/actions/workflows/ci.yml/badge.svg)](https://github.com/jonbaldie/beanstalkd/actions/workflows/ci.yml) [![Docker Pulls](https://img.shields.io/docker/pulls/jonbaldie/beanstalkd.svg)](https://hub.docker.com/jonbaldie/beanstalkd)

To use:

`docker pull jonbaldie/beanstalkd`

Alternatively you can `git clone` the repo and run `make` from the project root.

To persist jobs across container restarts, mount a named volume at the
beanstalk-owned `/data` directory and enable the write-ahead log:

```sh
docker volume create beanstalkd-data
docker run -d --name beanstalkd -p 11300:11300 \
  -v beanstalkd-data:/data \
  jonbaldie/beanstalkd:latest beanstalkd -b /data
```

(c) 2017 Jonathan Baldie
