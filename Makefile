PREFIX ?= /usr/local
CC ?= gcc

.PHONY: all cli gui clean check-link

all: cli gui

cli:
	$(MAKE) -C cli PREFIX=$(PREFIX) CC=$(CC)

gui:
	$(MAKE) -C gui

clean:
	$(MAKE) -C cli clean
	$(MAKE) -C gui clean

check-link:
	$(MAKE) -C cli PREFIX=$(PREFIX) CC=$(CC) check-link
