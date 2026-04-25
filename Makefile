CONFIGURATION ?= release

.PHONY: build
build:
	swift build --configuration release --disable-sandbox

.PHONY: codesign
codesign:
	codesign --entitlements minibox-entitlements.plist --options runtime --sign - --force .build/$(CONFIGURATION)/minibox-install
	codesign --entitlements minibox-entitlements.plist --options runtime --sign - --force .build/$(CONFIGURATION)/minibox-run

.PHONY: all
all: build codesign
