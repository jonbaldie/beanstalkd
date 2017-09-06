build:
	- docker build -t jonbaldie/beanstalkd:latest .

test:
	- docker run --rm jonbaldie/beanstalkd which beanstalkd | grep '/usr/bin/beanstalkd' 

