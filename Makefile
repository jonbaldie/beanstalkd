build:
	- docker build -t jonbaldie/beanstalkd .

test:
	- docker run --rm jonbaldie/beanstalkd which beanstalkd | grep '/usr/bin/beanstalkd' 

