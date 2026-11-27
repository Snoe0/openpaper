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

.PHONY: gen build test run app-path e2e install

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

# e2e: drive the real canvas-mcp over stdio against an isolated copy of the built app (see Tests/E2E/E2E.swift).
# The path is passed as is (abspath splits on spaces); E2E.swift resolves a relative one against this directory.
e2e: build
	xcrun swift -swift-version 5 Tests/E2E/E2E.swift "$(APP_PATH)"

# install: build Release, copy Canvas.app to $(PREFIX_APPS), link canvas-mcp into $(PREFIX_BIN), and print
# the `claude mcp add` command (it isn't run). The link points into the installed app, so the CLI always
# matches the app and launches that exact copy. Both prefixes must be absolute; they may contain spaces.
PREFIX_APPS ?= /Applications
PREFIX_BIN  ?= $(HOME)/.local/bin
RELEASE_APP     = $(DERIVED_DATA)/Build/Products/Release/Canvas.app
INSTALLED_APP   = $(PREFIX_APPS)/Canvas.app
INSTALLED_CLI   = $(PREFIX_BIN)/canvas-mcp
APP_BUNDLE_ID   = local.canvas.app

install:
	@if [ -z "$(strip $(PREFIX_APPS))" ] || [ -z "$(strip $(PREFIX_BIN))" ]; then echo "PREFIX_APPS and PREFIX_BIN must not be empty." >&2; exit 1; fi
	@if [[ "$(PREFIX_APPS)" != /* || "$(PREFIX_BIN)" != /* ]]; then echo "PREFIX_APPS and PREFIX_BIN must be absolute paths (start with /)." >&2; exit 1; fi
	@if [ -e "$(INSTALLED_APP)" ] && [ "$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$(INSTALLED_APP)/Contents/Info.plist" 2>/dev/null)" != "$(APP_BUNDLE_ID)" ]; then echo "$(INSTALLED_APP) isn't this app ($(APP_BUNDLE_ID)); remove it first." >&2; exit 1; fi
	@if pgrep -qf "$(INSTALLED_APP)/Contents/MacOS/Canvas"; then echo "Canvas is running from $(INSTALLED_APP); quit it first." >&2; exit 1; fi
	@if [ -e "$(INSTALLED_CLI)" ] && [ ! -L "$(INSTALLED_CLI)" ]; then echo "$(INSTALLED_CLI) exists and isn't a link; remove it first." >&2; exit 1; fi
	$(MAKE) build CONFIGURATION=Release
	mkdir -p "$(PREFIX_APPS)" "$(PREFIX_BIN)"
	rm -rf "$(INSTALLED_APP)"
	ditto "$(RELEASE_APP)" "$(INSTALLED_APP)"
	ln -sfn "$(INSTALLED_APP)/Contents/Helpers/canvas-mcp" "$(INSTALLED_CLI)"
	@echo
	@echo "Installed $(INSTALLED_APP) and $(INSTALLED_CLI)."
	@echo "Connect Claude Code (or use Connect agent… in the app):"
	@echo
	@echo "  claude mcp add --scope user canvas -- '$(INSTALLED_CLI)'"
