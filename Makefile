# tmux-pi-session-manager — developer makefile

BASH := bash
TESTS := tests/run.sh
SHELL_SCRIPTS := $(wildcard scripts/*.sh) bin/pi-tmux tmux/*.tmux

.PHONY: all test lint typecheck install uninstall help

all: test

## test — run the full automated suite
test:
	$(BASH) $(TESTS)

## lint — bash syntax check every shell file
lint:
	@for f in $(SHELL_SCRIPTS) tests/*.sh tests/lib.sh; do \
		$(BASH) -n "$$f" || exit 1; \
	done
	@echo "syntax OK"

## typecheck — type-check pi/extension.ts against the installed pi SDK
typecheck:
	@./scripts/typecheck.sh

## install — symlink the CLI into ~/.local/bin
install:
	@mkdir -p "$$HOME/.local/bin"
	@ln -sfn "$$(pwd)/bin/pi-tmux" "$$HOME/.local/bin/pi-tmux"
	@echo "installed $$HOME/.local/bin/pi-tmux"

## uninstall — remove the CLI symlink (extension untouched)
uninstall:
	@rm -f "$$HOME/.local/bin/pi-tmux"
	@echo "removed $$HOME/.local/bin/pi-tmux"

help:
	@grep -E '^## ' Makefile | sed 's/## //'
