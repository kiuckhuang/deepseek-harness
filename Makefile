# Short names for the Web and Desktop application commands. The package.json
# scripts they call stay the source of truth; docs/development.md documents both.
.DEFAULT_GOAL := help
.PHONY: help build web desktop dev-web dev-desktop sync check sandbox release telemetry-guard

PNPM ?= pnpm
ARGS ?=

# Telemetry opt-out. The launcher treats any non-empty DSH_TELEMETRY_DISABLED
# as opt-out and patches the session-telemetry row disabled before boot. The
# durable disable lives in ~/.dsh/cordis.patch.yml; this re-asserts the env
# opt-out for every recipe.
export DSH_TELEMETRY_DISABLED ?= 1

# Row fragments that mark telemetry or DeepSeek request-metadata egress in the
# composed tree. The guard fails `make` when a matching row is not disabled,
# so a harness update that adds or renames an egress row fails loudly instead
# of shipping silently. `plugin-inventory` (local RPC) and `session-log-*`
# (local export) deliberately do not match.
TELEMETRY_ROW_PATTERN := telemetry|analytics|dsh-otel|package-inventory-deepseek|session-log-deepseek|^otel$$

telemetry-guard:
	@dump=$$(mktemp); \
	if ! $(PNPM) dsh --profile web --dump-config > $$dump 2>/dev/null; then \
	  echo "ERROR: telemetry guard could not compose the profile tree; run 'pnpm dsh --profile web --dump-config' to see why"; \
	  rm -f $$dump; exit 1; \
	fi; \
	bad=$$(awk -v pat='$(TELEMETRY_ROW_PATTERN)' ' \
	  /^[[:space:]]*- id: / { if (id != "" && !dis && (id ~ pat || nm ~ pat)) print id; id = $$3; nm = ""; dis = 0; next } \
	  /^[[:space:]]+name: / { nm = $$2; next } \
	  /^[[:space:]]+disabled: true[[:space:]]*$$/ { dis = 1; next } \
	  /^[[:space:]]+disabled:/ { dis = 0; next } \
	  END { if (id != "" && !dis && (id ~ pat || nm ~ pat)) print id }' $$dump); \
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
	@echo "make telemetry-guard  verify telemetry stays disabled (runs before build/launch/sync targets)"

build: telemetry-guard
	$(PNPM) run build

web: telemetry-guard
	$(PNPM) run start:web $(ARGS)

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
