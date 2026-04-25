CONFIGURATION ?= release
PREFIX ?= /usr/local

SWIFT_SOURCES := $(wildcard Sources/*/*.swift)
SWIFT_SOURCES += entitlements.plist
SWIFT_SOURCES += Package.swift
SWIFT_SOURCES += Package.resolved

SCRIPT_SOURCES := Scripts/minibox

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
	codesign --entitlements entitlements.plist --options runtime --sign - --force "$(BUILT_PRODUCTS_DIR)/minibox-create-base"
	codesign --entitlements entitlements.plist --options runtime --sign - --force "$(BUILT_PRODUCTS_DIR)/minibox-run"
	touch "$(CODESIGN_STAMP)"

.PHONY: install
install: $(CODESIGN_STAMP) $(SCRIPT_SOURCES)
	install -Dm755 "$(BUILT_PRODUCTS_DIR)/minibox-create-base" "$(PREFIX)/bin/minibox-create-base"
	install -Dm755 "$(BUILT_PRODUCTS_DIR)/minibox-run" "$(PREFIX)/bin/minibox-run"
	install -Dm755 Scripts/minibox "$(PREFIX)/bin/minibox"

.PHONY: clean
clean:
	rm -rf "$(BUILT_PRODUCTS_DIR)"
