all: build run

CMD = docker run --rm -it --name memstorage -p 8081:8081 -v $(shell pwd):/memstore --network memstorage registry.gitlab.com/picodata/dockers/memstorage-builder
dev_deps:
	docker-compose -f dev/docker-compose-dev.yml up -d

build:
	$(CMD) /bin/bash -c "cartridge build; cp /kafka/kafka/tntkafka.so /memstore/.rocks/lib/tarantool/kafka/tntkafka.so;"

run:
	$(CMD) /bin/bash -c "cartridge start --debug"

stop:
	docker exec memstorage cartridge stop
	
release:
	$(CMD) cartridge pack rpm . --version=$(shell git describe --tags)

clean:
	rm -rf .rocks && rm -rf tmp && rm -rf kafka

test_memtx:
	$(CMD) /bin/bash -c ".rocks/bin/luatest --coverage test/integration/app/roles/storage_test.lua"

test_vinyl:
	$(CMD) /bin/bash -c ".rocks/bin/luatest --coverage test/integration/app/roles/storage_test_vinyl.lua"

test_all:
	$(CMD) /bin/bash -c ".rocks/bin/luatest --coverage test/"
