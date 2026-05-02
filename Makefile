build:
	docker build -t jonbaldie/beanstalkd:latest .

test: build
	./test.sh 

