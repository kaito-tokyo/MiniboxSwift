CONFIGURATION ?= release
PREFIX ?= /usr/local
SHAREDIR ?= $(PREFIX)/share/minibox

SWIFT_SOURCES := $(wildcard Sources/*/*.swift)
SWIFT_SOURCES += entitlements.plist
SWIFT_SOURCES += Package.swift

SWIFT_TEST_SOURCES := $(wildcard Tests/*/*.swift)

SCRIPT_SOURCES := $(wildcard Scripts/minibox*)
COMPANION_SOURCES := Setup-macOS-Runner.html

BUILT_PRODUCTS_DIR := .build/$(CONFIGURATION)
BUILD_STAMP := $(BUILT_PRODUCTS_DIR)/.make_build
SWIFT_PRODUCTS := \
	minibox-create-base-macos \
	minibox-run \
	minibox-tools-linux-exec \
	minibox-view

.PHONY: all build codesign
all: codesign
build: $(BUILD_STAMP)
codesign: $(BUILD_STAMP)
	codesign --entitlements entitlements.plist --options runtime --sign - --force $(addprefix $(BUILT_PRODUCTS_DIR)/,$(SWIFT_PRODUCTS))

$(BUILD_STAMP): $(SWIFT_SOURCES)
	swift build --configuration "$(CONFIGURATION)"
	touch "$(BUILD_STAMP)"

.PHONY: install
install: codesign $(SCRIPT_SOURCES) $(COMPANION_SOURCES)
	install -d "$(PREFIX)/bin" "$(SHAREDIR)"
	install -m 755 "$(BUILT_PRODUCTS_DIR)/minibox-create-base-macos" "$(PREFIX)/bin/minibox-create-base-macos"
	install -m 755 "$(BUILT_PRODUCTS_DIR)/minibox-run" "$(PREFIX)/bin/minibox-run"
	install -m 755 "$(BUILT_PRODUCTS_DIR)/minibox-tools-linux-exec" "$(PREFIX)/bin/minibox-tools-linux-exec"
	install -m 755 "$(BUILT_PRODUCTS_DIR)/minibox-view" "$(PREFIX)/bin/minibox-view"

	install -m 755 Scripts/minibox "$(PREFIX)/bin/minibox"
	install -m 755 Scripts/minibox-create-base "$(PREFIX)/bin/minibox-create-base"
	install -m 755 Scripts/minibox-init "$(PREFIX)/bin/minibox-init"
	install -m 755 Scripts/minibox-init-minimal-alpine "$(PREFIX)/bin/minibox-init-minimal-alpine"
	install -m 755 Scripts/minibox-ls "$(PREFIX)/bin/minibox-ls"
	install -m 755 Scripts/minibox-prepare "$(PREFIX)/bin/minibox-prepare"
	install -m 755 Scripts/minibox-prepare-macos "$(PREFIX)/bin/minibox-prepare-macos"
	install -m 755 Scripts/minibox-tools "$(PREFIX)/bin/minibox-tools"
	install -m 644 Setup-macOS-Runner.html "$(SHAREDIR)/Setup-macOS-Runner.html"
	install -m 755 Scripts/minibox-finalize-macos "$(SHAREDIR)/minibox-finalize-macos"

.PHONY: test
test: $(SWIFT_SOURCES) $(SWIFT_TEST_SOURCES)
	swift test --configuration "$(CONFIGURATION)"

.PHONY: clean
clean:
	rm -rf "$(BUILT_PRODUCTS_DIR)"
