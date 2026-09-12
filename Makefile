.PHONY: all build check help sandbox sync web

all: sync

sync:
	./sync_dsh.sh

check:
	./sync_dsh.sh --check

build:
	./mk_dsh.sh

sandbox:
	./setup_sandbox.sh

web:
	pnpm dsh web

help:
	@printf '%s\n' \
		'Targets:' \
		'  make         sync the branch to upstream master and regenerate patch layers' \
		'  make check   verify that sync without changing anything' \
		'  make build   build the newest release plus patch layers in a disposable worktree' \
		'  make sandbox install and verify the sandbox runner (fixes SANDBOX_UNAVAILABLE)' \
		'  make web     run pnpm dsh web' \
		'  make help    show this message and the sync options' \
		''
	@./sync_dsh.sh --help
