.PHONY: all help sync web

all: sync

sync:
	./mk_dsh.sh

web:
	pnpm dsh web

help:
	@printf '%s\n' 'Targets:' '  make       fetch the latest upstream release, apply patches, and build' '  make web   run pnpm dsh web' '  make help  show targets and sync options' ''
	@./mk_dsh.sh --help
