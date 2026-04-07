CC ?= gcc
PREFIX ?= /usr/local

TARGET := smb2fs
SRC := smb2fs.c

CPPFLAGS += -I$(PREFIX)/include/osxfuse/fuse \
            -I$(PREFIX)/include/osxfuse \
            -I$(PREFIX)/include
CFLAGS += -O2 -D_FILE_OFFSET_BITS=64
LDFLAGS += -Wl,-rpath,$(PREFIX)/lib
LDLIBS += $(PREFIX)/lib/libsmb2.a \
          $(PREFIX)/lib/libosxfuse.2.dylib

.PHONY: all cli gui clean check-link

all: cli gui

cli: $(TARGET)

gui:
	$(MAKE) -C gui

$(TARGET): $(SRC)
	$(CC) -o $@ $(SRC) $(CPPFLAGS) $(CFLAGS) $(LDLIBS) $(LDFLAGS)

clean:
	rm -f $(TARGET)
	$(MAKE) -C gui clean

check-link: cli
	otool -L ./$(TARGET) | egrep -i 'osxfuse|fuse'
