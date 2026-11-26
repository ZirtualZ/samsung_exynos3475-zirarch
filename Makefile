.PHONY: all bootstrap build clean

all: build

bootstrap:
	./bootstrap.sh

build:
	./build.sh

clean:
	$(MAKE) -C kernel ARCH=arm clean 2>/dev/null || true
	$(MAKE) -C FieldM clean 2>/dev/null || true
