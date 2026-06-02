build:
	docker build -t jonbaldie/beanstalkd:latest .

test: build
	./test.sh

mutation-test: build
	./mutation_test.sh

