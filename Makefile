build:
	docker build -t jonbaldie/beanstalkd:latest .

test: build
	./test_test.sh
	./test.sh
