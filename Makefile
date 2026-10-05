IMAGE ?= jonbaldie/beanstalkd:latest

.PHONY: build test push

build:
	docker build -t $(IMAGE) .

test: build
	./test_test.sh
	./test_makefile.sh
	./test_cleanup.sh "$(IMAGE)"
	./test_volume_isolation.sh "$(IMAGE)"
	./test_busy_port.sh "$(IMAGE)"
	./test_name_collision.sh "$(IMAGE)"
	./test.sh "$(IMAGE)"

push:
	docker push $(IMAGE)
