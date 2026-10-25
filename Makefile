.PHONY: build release test app bundle run install install-hooks install-hooks-approval status uninstall-hooks clean
.DEFAULT_GOAL := build
UNAME_S := $(shell uname -s)

## PREFIX is the same on both platforms, and on macOS that is a fix rather than
## a tidy-up: it used to be /usr/local, which is root-owned on a stock macOS, so
## the install command the README leads with died on its first line —
## `install: chmod 755 /usr/local/bin: Operation not permitted`, make Error 71 —
## for anyone who had not already made that directory writable. A home prefix
## needs no sudo, matches Linux, and `make install PREFIX=/usr/local` (with
## sudo) still works for anyone who wants it there.
PREFIX ?= $(HOME)/.local

ifeq ($(UNAME_S),Darwin)
CLI = ./build/GentleMerge.app/Contents/MacOS/gentlemerge
CLI_PREREQUISITE = app
else
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
##
## The two notices after the copy are about the failure that looks like
## success: the file lands, and the shell keeps running something else. The
## second one matters most right after the PREFIX change above — anyone who
## installed to /usr/local/bin before will still find that copy first, because
## it comes earlier in almost every PATH.
install: release
	install -d "$(DESTDIR)$(PREFIX)/bin"
	install -m 755 .build/release/gentlemerge "$(DESTDIR)$(PREFIX)/bin/gentlemerge"
	@target="$(DESTDIR)$(PREFIX)/bin"; \
	case ":$$PATH:" in \
	  *":$$target:"*) ;; \
	  *) printf 'gentlemerge: installed to %s, which is not on your PATH.\n  Add it to PATH, or install elsewhere with: make install PREFIX=<dir>\n' "$$target" >&2 ;; \
	esac; \
	found=$$(command -v gentlemerge 2>/dev/null || true); \
	if [ -n "$$found" ] && [ "$$found" != "$$target/gentlemerge" ]; then \
	  printf 'gentlemerge: your PATH finds %s first, so that is still the one that runs.\n  Delete it, or put %s earlier in PATH.\n' "$$found" "$$target" >&2; \
	fi; \
	printf 'gentlemerge: installed %s\n' "$$target/gentlemerge"

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
