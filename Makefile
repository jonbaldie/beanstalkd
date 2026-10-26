IMAGE ?= jonbaldie/beanstalkd:latest

.PHONY: build test test-ct push

build:
	docker build -t "$(IMAGE)" .

test-ct:
	./test_ct_manifest.sh
	@test ! -L .ct-build
	mkdir -p .ct-build
	./ct-tests/run.sh ".ct-build/run-$$$$"

test: build
	./test_ct_manifest.sh
	./test_test.sh
	./test_makefile.sh
	./test_cleanup.sh "$(IMAGE)"
	./test_resource_receipts.sh "$(IMAGE)"
	./test_volume_isolation.sh "$(IMAGE)"
	./test_busy_port.sh "$(IMAGE)"
	./test_name_collision.sh "$(IMAGE)"
	./test.sh "$(IMAGE)"

push:
	docker push "$(IMAGE)"
