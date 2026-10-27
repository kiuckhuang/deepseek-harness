# Downstream fork

This checkout is a downstream fork of DeepSeek Harness. Upstream supplies the harness; this branch adds a small set of layered changes and the tooling that keeps them applying to each upstream release.

## Patch layers

The `dsh_*.patch` files beside this document are derived artifacts, not sources. The branch is the source of truth for every downstream change, and `make sync` regenerates each layer from the merged branch before committing it. Do not edit a layer by hand; edit the branch and re-run the sync.

A layer covers the files it already names, and every layer is verified against the newest `dsh-v*` release tag that `make release` builds. Extending a downstream change to a file the layer does not name yet requires adding that path to the layer once; later syncs keep it current.

| Layer | Downstream change |
|---|---|
| `dsh_build.patch` | Raises the `git ls-files` buffer in `scripts/rescope-vendor.ts` for this repository's tracked-file count |
| `dsh_copilot.patch` | Real-composition test for the GitHub Copilot GPT-6.1 Sol route |
| `dsh_mcp.patch` | Re-initializes a Streamable HTTP MCP session that the server dropped while the connection stayed open |
| `dsh_sandbox.patch` | Model-visible sandbox-unavailable text that names host capability instead of cueing an escalation |

The fork's own tooling — the `Makefile` targets, `sync_dsh.sh`, `mk_dsh.sh`, `setup_sandbox.sh`, the layers, this document, and the Agent Notes under `.agents/notes/implemented/process/` — is branch-only and is not part of any layer, because a release build does not need it.

## Commands

`make sync` merges upstream's default branch and commits the regenerated layers. `make check` runs the same merge and layer verification without changing the working tree, and fails when the merge would conflict. `make release` builds the newest release tag plus every layer in a disposable worktree, leaving the caller's branch and index untouched.

`make sandbox` installs bubblewrap on Linux, or confirms that the kernel enforces Landlock, then proves the runner actually confines a write outside the workspace. `make web`, `make desktop`, and `make dev-*` launch the built application; `make help` lists the forwarded arguments.

## Telemetry

The `Makefile` exports `DSH_TELEMETRY_DISABLED=1` for every recipe and runs `telemetry-guard` before build and launch. The guard composes the profile tree with `dsh --profile web --dump-config`, rejects any enabled row that matches the telemetry or DeepSeek request-metadata patterns, and warns when the collector hosts are not blocked in `/etc/hosts`. The durable opt-out lives in `~/.dsh/cordis.patch.yml`; the environment variable only covers commands started through `make`.

## Keeping the branch clean

Recorded-session fixtures change whenever model-visible text changes, so a layer that edits an error message must update every fixture that carries it. Snapshot replay selects the highest committed format generation, so only the selected generation proves the change.

Keep screenshots and other scratch captures out of the repository root; `tmp/` is ignored.
