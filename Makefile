PRODUCT := macbook-dock-brightness
SOURCE := Sources/macbook-dock-brightness.m
BUILD_DIR := build
BINARY := $(BUILD_DIR)/$(PRODUCT)

SDK := $(shell xcrun --sdk macosx --show-sdk-path)
ARCH := $(shell uname -m)
DEPLOYMENT_TARGET ?= 13.0

OBJC_FLAGS := \
	-fobjc-arc \
	-fblocks \
	-fmodules \
	-O2 \
	-Wall \
	-Wextra \
	-Werror \
	-Wno-unused-parameter \
	-isysroot $(SDK) \
	-mmacosx-version-min=$(DEPLOYMENT_TARGET) \
	-arch $(ARCH)

FRAMEWORKS := \
	-framework AppKit \
	-framework CoreGraphics \
	-framework Foundation

.PHONY: all release debug analyze check clean

all: release

release: $(BINARY)

$(BINARY): $(SOURCE)
	mkdir -p $(BUILD_DIR)
	xcrun clang $(OBJC_FLAGS) $(SOURCE) -o $(BINARY) $(FRAMEWORKS)

debug:
	mkdir -p $(BUILD_DIR)
	xcrun clang $(filter-out -O2,$(OBJC_FLAGS)) -O0 -g $(SOURCE) -o $(BINARY) $(FRAMEWORKS)

analyze:
	xcrun clang --analyze $(filter-out -O2,$(OBJC_FLAGS)) $(SOURCE) -o /dev/null

check: release analyze
	./tests/smoke.sh $(BINARY)
	/bin/sh -n scripts/install.sh
	/bin/sh -n scripts/uninstall.sh
	plutil -lint LaunchAgent.plist.template

clean:
	rm -rf $(BUILD_DIR)
