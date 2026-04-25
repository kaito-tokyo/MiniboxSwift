CONFIGURATION ?= release

.PHONY: build
build:
	swift build --configuration release --disable-sandbox

.PHONY: codesign
codesign:
	codesign --entitlements entitlements.plist --options runtime --sign - --force .build/$(CONFIGURATION)/minibox-create-base
	codesign --entitlements entitlements.plist --options runtime --sign - --force .build/$(CONFIGURATION)/minibox-run

.PHONY: all
all: build codesign
