.PHONY: build release test app bundle run install install-hooks install-hooks-approval status uninstall-hooks clean
.DEFAULT_GOAL := build
UNAME_S := $(shell uname -s)

ifeq ($(UNAME_S),Darwin)
PREFIX ?= /usr/local
CLI = ./build/GentleMerge.app/Contents/MacOS/gentlemerge
CLI_PREREQUISITE = app
else
PREFIX ?= $(HOME)/.local
CLI = ./.build/release/gentlemerge
CLI_PREREQUISITE = release
endif

build:
	swift build

release:
	swift build -c release

test:
	swift test
	python3 Scripts/test-build-contract.py

## Install only the CLI; hooks remain an explicit, reversible opt-in.
install: release
	install -d "$(DESTDIR)$(PREFIX)/bin"
	install -m 755 .build/release/gentlemerge "$(DESTDIR)$(PREFIX)/bin/gentlemerge"

ifeq ($(UNAME_S),Darwin)
## Assemble build/GentleMerge.app for notifications and Automation.
app bundle:
	@sh Scripts/bundle.sh

run: app
	@pkill -f 'GentleMerge.app/Contents/MacOS/gentlemerge' 2>/dev/null || true
	@open build/GentleMerge.app
	@echo "GentleMerge is in the menu bar."
else
app bundle run:
	@printf 'The menu-bar app is macOS only; use make install for the CLI.\n' >&2
	@exit 1
endif

install-hooks: $(CLI_PREREQUISITE)
	@$(CLI) install

install-hooks-approval: $(CLI_PREREQUISITE)
	@$(CLI) install --remote-approval

status: $(CLI_PREREQUISITE)
	@$(CLI) status

uninstall-hooks: $(CLI_PREREQUISITE)
	@$(CLI) uninstall

clean:
	rm -rf .build build
