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

.PHONY: all clean check-link

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) -o $@ $(SRC) $(CPPFLAGS) $(CFLAGS) $(LDLIBS) $(LDFLAGS)

clean:
	rm -f $(TARGET)

check-link: $(TARGET)
	otool -L ./$(TARGET) | egrep -i 'osxfuse|fuse'
