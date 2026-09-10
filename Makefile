.PHONY: all build check help sync web

all: sync

sync:
	./sync_dsh.sh

check:
	./sync_dsh.sh --check

build:
	./mk_dsh.sh

web:
	pnpm dsh web

help:
	@printf '%s\n' \
		'Targets:' \
		'  make         sync the branch to the newest upstream release and regenerate patch layers' \
		'  make check   verify that sync without changing anything' \
		'  make build   build the newest release plus patch layers in a disposable worktree' \
		'  make web     run pnpm dsh web' \
		'  make help    show this message and the sync options' \
		''
	@./sync_dsh.sh --help
