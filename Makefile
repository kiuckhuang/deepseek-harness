# Short names for the Web and Desktop application commands. The package.json
# scripts they call stay the source of truth; docs/development.md documents both.
.DEFAULT_GOAL := help
.PHONY: help build clean web desktop dev-web dev-desktop stop restart sync check sandbox release telemetry-guard

PNPM ?= pnpm
ARGS ?=

# The Web instance serves 127.0.0.1:$(PORT); `dsh web` defaults to 3080. A
# launch that overrides the port (`ARGS='--port 3081'`) needs the same value
# here: make stop PORT=3081.
PORT ?= 3080

# Telemetry opt-out. The launcher treats any non-empty DSH_TELEMETRY_DISABLED
# as opt-out and patches the session-telemetry row disabled before boot. The
# durable disable lives in ~/.dsh/cordis.patch.yml; this re-asserts the env
# opt-out for every recipe.
export DSH_TELEMETRY_DISABLED ?= 1

# Row fragments that mark telemetry or DeepSeek request-metadata egress in the
# composed tree. The guard fails `make` when a matching row is not disabled,
# so a harness update that adds or renames an egress row fails loudly instead
# of shipping silently. `plugin-inventory` (local RPC) and `session-log-*`
# (local export) deliberately do not match. Row keys are anchored to the dump's
# column-0 `- id:`/`- name:` entries, so a nested `id` inside a plugin's config
# cannot reset the tracker and hide the row that owns it.
TELEMETRY_ROW_PATTERN := telemetry|analytics|dsh-otel|package-inventory-deepseek|session-log-deepseek|^otel$$

telemetry-guard:
	@dump=$$(mktemp); \
	if ! $(PNPM) dsh --profile web --dump-config > $$dump 2>/dev/null; then \
	  echo "ERROR: telemetry guard could not compose the profile tree; run 'pnpm dsh --profile web --dump-config' to see why"; \
	  rm -f $$dump; exit 1; \
	fi; \
	bad=$$(awk -v pat='$(TELEMETRY_ROW_PATTERN)' ' \
	  function flush() { if ((id != "" || nm != "") && !dis && (id ~ pat || nm ~ pat)) print (id != "" ? id : nm) } \
	  /^- id: / { flush(); id = $$3; nm = ""; dis = 0; next } \
	  /^- name: / { flush(); id = ""; nm = $$3; dis = 0; next } \
	  /^  name: / { nm = $$2; next } \
	  /^  disabled: true[[:space:]]*$$/ { dis = 1; next } \
	  /^  disabled:/ { dis = 0; next } \
	  END { flush() }' $$dump); \
	rm -f $$dump; \
	if [ -n "$$bad" ]; then \
	  echo "ERROR: the composed profile mounts enabled telemetry/egress rows:"; \
	  echo "$$bad" | sed 's/^/  - id: /'; \
	  echo "  fix: add '- id: <row>' with 'disabled: true' to ~/.dsh/cordis.patch.yml, then rerun"; \
	  exit 1; \
	fi; \
	if grep -q 'dsh-otel-collector' /etc/hosts 2>/dev/null && grep -q 'harness-telemetry' /etc/hosts 2>/dev/null; then \
	  echo "telemetry guard: env opt-out set; composed tree has no enabled egress rows; collector hosts blocked"; \
	else \
	  echo "WARN: /etc/hosts lacks the collector blocks (dsh-otel-collector / harness-telemetry .deepseeksvc.com)"; \
	fi

help:
	@echo "make build        pnpm run build           complete repository build"
	@echo "make clean        pnpm run clean           remove build outputs and safe deleted-package residue"
	@echo "make web          pnpm run start:web       serve the built Web artifacts from source"
	@echo "make stop         stop the Web instance listening on 127.0.0.1:$(PORT) (idempotent)"
	@echo "make restart      make stop, then make web — same telemetry guard and ARGS forwarding"
	@echo "PORT=3081         select the instance port for stop/restart after ARGS='--port 3081'"
	@echo "make desktop      pnpm run start:desktop   launch the built Desktop artifacts"
	@echo "make dev-web      pnpm run dev:web         build, serve, and rebuild Web on source edits"
	@echo "make dev-desktop  pnpm run dev:desktop     build, then launch Desktop"
	@echo "ARGS='--no-open --port 3081' forwards options to the launched application;"
	@echo "the Web commands accept dsh web flags, the Desktop launcher accepts none."
	@echo "make sync         ./sync_dsh.sh            merge upstream and regenerate patch layers"
	@echo "make check        ./sync_dsh.sh --check    verify that sync without changing anything"
	@echo "make sandbox      ./setup_sandbox.sh       install and verify the sandbox runner"
	@echo "make release      ./mk_dsh.sh              build the newest release plus patch layers in a disposable worktree"
	@echo "make telemetry-guard  verify telemetry stays disabled (runs before build/launch/sync targets)"

build: telemetry-guard
	$(PNPM) run build

clean:
	$(PNPM) run clean

web: telemetry-guard
	$(PNPM) run start:web $(ARGS)

# Stop the Web instance `make web` started. The port's listener identifies the
# instance, and the command line must name the `dsh web` launcher before any
# signal is sent, so a foreign service on the port fails the recipe instead of
# being killed. Idempotent: a free port reports already-stopped and succeeds,
# which is what lets restart run stop unconditionally.
stop:
	@command -v ss >/dev/null 2>&1 || { echo "ERROR: make stop needs ss (iproute2) to find the Web instance"; exit 1; }; \
	pids=$$(ss -tlnp "sport = :$(PORT)" 2>/dev/null | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | sort -u); \
	if [ -z "$$pids" ]; then \
	  echo "make stop: nothing listens on 127.0.0.1:$(PORT); already stopped"; \
	  exit 0; \
	fi; \
	for pid in $$pids; do \
	  if ! tr '\0' ' ' < "/proc/$$pid/cmdline" 2>/dev/null | grep -q 'apps/cli/src/bin.ts web'; then \
	    echo "ERROR: port $(PORT) belongs to a foreign process (pid $$pid); refusing to stop it"; \
	    echo "  fix: pass the port the Web instance launched with, e.g. make stop PORT=3081"; \
	    exit 1; \
	  fi; \
	done; \
	echo "make stop: stopping the Web instance on 127.0.0.1:$(PORT) (pid$$(echo $$pids | sed 's/ /, pid/g'))"; \
	kill -TERM $$pids 2>/dev/null || true; \
	i=0; \
	while [ $$i -lt 50 ] && ss -tln "sport = :$(PORT)" 2>/dev/null | grep -q ":$(PORT) "; do \
	  sleep 0.2; i=$$((i + 1)); \
	done; \
	if ss -tln "sport = :$(PORT)" 2>/dev/null | grep -q ":$(PORT) "; then \
	  echo "make stop: SIGTERM did not free the port in 10s; sending SIGKILL"; \
	  kill -KILL $$pids 2>/dev/null || true; \
	  sleep 1; \
	fi; \
	if ss -tln "sport = :$(PORT)" 2>/dev/null | grep -q ":$(PORT) "; then \
	  echo "ERROR: something still listens on 127.0.0.1:$(PORT) after stop"; \
	  exit 1; \
	fi; \
	echo "make stop: Web instance stopped"

# Restart the Web instance: stop frees the port, then the `web` target relaunches
# it in the foreground with its telemetry guard and the forwarded ARGS.
restart:
	@$(MAKE) --no-print-directory stop
	@$(MAKE) --no-print-directory web ARGS='$(ARGS)'

desktop: telemetry-guard
	$(PNPM) run start:desktop $(ARGS)

dev-web: telemetry-guard
	$(PNPM) run dev:web $(ARGS)

dev-desktop: telemetry-guard
	$(PNPM) run dev:desktop $(ARGS)

sync: telemetry-guard
	./sync_dsh.sh
	@$(MAKE) --no-print-directory telemetry-guard

check: telemetry-guard
	./sync_dsh.sh --check

sandbox: telemetry-guard
	./setup_sandbox.sh

release: telemetry-guard
	./mk_dsh.sh
