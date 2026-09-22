# Short names for the Web and Desktop application commands. The package.json
# scripts they call stay the source of truth; docs/development.md documents both.
.DEFAULT_GOAL := help
.PHONY: help build web desktop dev-web dev-desktop sync check sandbox release

PNPM ?= pnpm
ARGS ?=

help:
	@echo "make build        pnpm run build           complete repository build"
	@echo "make web          pnpm run start:web       serve the built Web artifacts from source"
	@echo "make desktop      pnpm run start:desktop   launch the built Desktop artifacts"
	@echo "make dev-web      pnpm run dev:web         build, serve, and rebuild Web on source edits"
	@echo "make dev-desktop  pnpm run dev:desktop     build, then launch Desktop"
	@echo "ARGS='--no-open --port 3081' forwards options to the launched application;"
	@echo "the Web commands accept dsh web flags, the Desktop launcher accepts none."
	@echo "make sync         ./sync_dsh.sh            merge upstream and regenerate patch layers"
	@echo "make check        ./sync_dsh.sh --check    verify that sync without changing anything"
	@echo "make sandbox      ./setup_sandbox.sh       install and verify the sandbox runner"
	@echo "make release      ./mk_dsh.sh              build the newest release plus patch layers in a disposable worktree"

build:
	$(PNPM) run build

web:
	$(PNPM) run start:web $(ARGS)

desktop:
	$(PNPM) run start:desktop $(ARGS)

dev-web:
	$(PNPM) run dev:web $(ARGS)

dev-desktop:
	$(PNPM) run dev:desktop $(ARGS)

sync:
	./sync_dsh.sh

check:
	./sync_dsh.sh --check

sandbox:
	./setup_sandbox.sh

release:
	./mk_dsh.sh
