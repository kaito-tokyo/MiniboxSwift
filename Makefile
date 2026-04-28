CONFIGURATION ?= release
PREFIX ?= /usr/local

SWIFT_SOURCES := $(wildcard Sources/*/*.swift)
SWIFT_SOURCES += entitlements.plist
SWIFT_SOURCES += Package.swift
SWIFT_SOURCES += Package.resolved

SWIFT_TEST_SOURCES := $(wildcard Tests/*/*.swift)

SCRIPT_SOURCES := $(wildcard Scripts/minibox*)

BUILT_PRODUCTS_DIR := .build/$(CONFIGURATION)
BUILD_STAMP := $(BUILT_PRODUCTS_DIR)/.make_build
CODESIGN_STAMP := $(BUILT_PRODUCTS_DIR)/.make_codesign

.PHONY: all build codesign
all: codesign
build: $(BUILD_STAMP)
codesign: $(CODESIGN_STAMP)

$(BUILD_STAMP): $(SWIFT_SOURCES)
	swift build --configuration "$(CONFIGURATION)" --disable-sandbox
	touch "$(BUILD_STAMP)"

$(CODESIGN_STAMP): $(BUILD_STAMP)
	codesign --entitlements entitlements.plist --options runtime --sign - --force "$(BUILT_PRODUCTS_DIR)/minibox-create-base-macos"
	codesign --entitlements entitlements.plist --options runtime --sign - --force "$(BUILT_PRODUCTS_DIR)/minibox-run"
	codesign --entitlements entitlements.plist --options runtime --sign - --force "$(BUILT_PRODUCTS_DIR)/minibox-view"
	touch "$(CODESIGN_STAMP)"

.PHONY: install
install: $(CODESIGN_STAMP) $(SCRIPT_SOURCES)
	install -Dm755 "$(BUILT_PRODUCTS_DIR)/minibox-create-base-macos" "$(PREFIX)/bin/minibox-create-base-macos"
	install -Dm755 "$(BUILT_PRODUCTS_DIR)/minibox-run" "$(PREFIX)/bin/minibox-run"
	install -Dm755 "$(BUILT_PRODUCTS_DIR)/minibox-view" "$(PREFIX)/bin/minibox-view"
	install -Dm755 Scripts/minibox-create-base "$(PREFIX)/bin/minibox-create-base"
	install -Dm755 Scripts/minibox-ls "$(PREFIX)/bin/minibox-ls"
	install -Dm755 Scripts/minibox-prepare "$(PREFIX)/bin/minibox-prepare"
	install -Dm755 Scripts/minibox-prepare-macos "$(PREFIX)/bin/minibox-prepare-macos"
	install -Dm755 Scripts/minibox "$(PREFIX)/bin/minibox"

.PHONY: test
test: $(SWIFT_SOURCES) $(SWIFT_TEST_SOURCES)
	swift test --configuration "$(CONFIGURATION)" --disable-sandbox

.PHONY: clean
clean:
	rm -rf "$(BUILT_PRODUCTS_DIR)"
