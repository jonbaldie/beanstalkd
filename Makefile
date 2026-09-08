build:
	docker build -t jonbaldie/beanstalkd:latest .

test: build
	./test_test.sh
	./test_cleanup.sh
	./test_busy_port.sh
	./test.sh
