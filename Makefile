CONFIGURATION ?= release

BUILD_PATH = ./.build/$(CONFIGURATION)

.PHONY: all build sign

all: build sign

build:
	swift build --configuration "$(CONFIGURATION)" --disable-sandbox

sign:
	codesign --entitlements entitlements.plist --force --sign - "$(BUILD_PATH)/minibox-install"
	codesign --entitlements entitlements.plist --force --sign - "$(BUILD_PATH)/minibox-run"

