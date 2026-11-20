PROJECT       := Canvas.xcodeproj
SCHEME        := Canvas
CONFIGURATION := Debug
DERIVED_DATA  := .build
APP_PATH      := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/Canvas.app

XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	-configuration $(CONFIGURATION) -derivedDataPath $(DERIVED_DATA) \
	-destination "platform=macOS,arch=$(shell uname -m)"

# Pretty output via xcbeautify when installed; otherwise raw but quiet (errors stay visible).
ifneq ($(shell command -v xcbeautify 2>/dev/null),)
  RUN_XCODEBUILD = set -o pipefail && $(XCODEBUILD) $(1) 2>&1 | xcbeautify
else
  RUN_XCODEBUILD = $(XCODEBUILD) -quiet $(1)
endif

SHELL := /bin/bash

.PHONY: gen build test run app-path

gen:
	xcodegen generate

build: gen
	$(call RUN_XCODEBUILD,build)

test: gen
	$(call RUN_XCODEBUILD,test)

run: build
	open "$(APP_PATH)"

app-path:
	@echo "$(abspath $(APP_PATH))"

# install: (T8) copy Canvas.app to /Applications, canvas-mcp to ~/.local/bin,
#          and print the `claude mcp add` command.
# install: build
#	...

# e2e: (T8) drive the real canvas-mcp against the running app.
# e2e: build
#	...
