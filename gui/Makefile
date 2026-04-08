APP_NAME := SMB2FUSE
BUILD_DIR := build
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS_DIR := $(APP_BUNDLE)/Contents
MACOS_DIR := $(CONTENTS_DIR)/MacOS
RESOURCES_DIR := $(CONTENTS_DIR)/Resources
ASSETS_DIR := Assets
APP_EXECUTABLE := $(MACOS_DIR)/$(APP_NAME)
CLI_BINARY := ../cli/smb2fs
ICON_SOURCE := $(ASSETS_DIR)/Icon.png
ICON_NAME := SMB2FUSE
ICONSET_DIR := $(BUILD_DIR)/$(ICON_NAME).iconset
ICON_FILE := $(RESOURCES_DIR)/$(ICON_NAME).icns

CC ?= clang
OBJCFLAGS += -fobjc-arc -fblocks -O2 -Wall -Wextra
FRAMEWORKS += -framework Cocoa -framework Security

SOURCES := main.m \
	SMBAppDelegate.m \
	SMBConnection.m \
	SMBTaskRunner.m \
	SMBKeychainStore.m
OBJECTS := $(patsubst %.m,$(BUILD_DIR)/%.o,$(SOURCES))

.PHONY: all clean

all: $(APP_BUNDLE)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/%.o: %.m *.h | $(BUILD_DIR)
	$(CC) $(OBJCFLAGS) -c $< -o $@

$(APP_EXECUTABLE): $(OBJECTS) | $(BUILD_DIR)
	mkdir -p $(MACOS_DIR) $(RESOURCES_DIR)
	$(CC) -o $@ $(OBJECTS) $(FRAMEWORKS)

$(ICON_FILE): $(ICON_SOURCE) | $(BUILD_DIR)
	mkdir -p $(RESOURCES_DIR) $(ICONSET_DIR)
	sips -z 16 16 $(ICON_SOURCE) --out $(ICONSET_DIR)/icon_16x16.png >/dev/null
	sips -z 32 32 $(ICON_SOURCE) --out $(ICONSET_DIR)/icon_16x16@2x.png >/dev/null
	sips -z 32 32 $(ICON_SOURCE) --out $(ICONSET_DIR)/icon_32x32.png >/dev/null
	sips -z 64 64 $(ICON_SOURCE) --out $(ICONSET_DIR)/icon_32x32@2x.png >/dev/null
	sips -z 128 128 $(ICON_SOURCE) --out $(ICONSET_DIR)/icon_128x128.png >/dev/null
	sips -z 256 256 $(ICON_SOURCE) --out $(ICONSET_DIR)/icon_128x128@2x.png >/dev/null
	sips -z 256 256 $(ICON_SOURCE) --out $(ICONSET_DIR)/icon_256x256.png >/dev/null
	sips -z 512 512 $(ICON_SOURCE) --out $(ICONSET_DIR)/icon_256x256@2x.png >/dev/null
	sips -z 512 512 $(ICON_SOURCE) --out $(ICONSET_DIR)/icon_512x512.png >/dev/null
	cp $(ICON_SOURCE) $(ICONSET_DIR)/icon_512x512@2x.png
	iconutil -c icns $(ICONSET_DIR) -o $(ICON_FILE)

$(APP_BUNDLE): $(APP_EXECUTABLE) $(ICON_FILE) Info.plist
	cp Info.plist $(CONTENTS_DIR)/Info.plist
	printf 'APPL????' > $(CONTENTS_DIR)/PkgInfo
	if [ -f $(CLI_BINARY) ]; then cp $(CLI_BINARY) $(RESOURCES_DIR)/smb2fs; else echo "warning: $(CLI_BINARY) not found; build the CLI first"; fi

clean:
	rm -rf $(BUILD_DIR)
