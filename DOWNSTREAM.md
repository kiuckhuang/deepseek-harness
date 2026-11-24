# Downstream fork

This checkout is a downstream fork of DeepSeek Harness. Upstream supplies the harness; this branch adds a small set of layered changes and the tooling that keeps them applying to each upstream release.

## Patch layers

The `dsh_*.patch` files beside this document are derived artifacts, not sources. The branch is the source of truth for every downstream change, and `make sync` regenerates each layer from the merged branch before committing it. Do not edit a layer by hand; edit the branch and re-run the sync.

A layer covers the files it already names, and every layer is verified against the newest `dsh-v*` release tag that `make release` builds. Extending a downstream change to a file the layer does not name yet requires adding that path to the layer once; later syncs keep it current.

| Layer | Downstream change |
|---|---|
| `dsh_copilot.patch` | Real-composition test for the GitHub Copilot GPT-6.1 Sol route |
| `dsh_mcp.patch` | Re-initializes a Streamable HTTP MCP session that the server dropped while the connection stayed open |
| `dsh_sandbox.patch` | Model-visible sandbox-unavailable text that names host capability instead of cueing an escalation |
| `dsh_cache.patch` | Prefix-cache probe for self-hosted DS4-compatible endpoints: measures which request fields the engine caches, and names the first divergence between two captured requests |

The fork's own tooling — the `Makefile` targets, `sync_dsh.sh`, `mk_dsh.sh`, `setup_sandbox.sh`, the layers, this document, and the Agent Notes under `.agents/notes/implemented/process/` — is branch-only and is not part of any layer, because a release build does not need it.

## Commands

`make sync` merges upstream's default branch and commits the regenerated layers. `make check` runs the same merge and layer verification without changing the working tree, and fails when the merge would conflict. `make release` builds the newest release tag plus every layer in a disposable worktree, leaving the caller's branch and index untouched.

`make sandbox` installs bubblewrap on Linux, or confirms that the kernel enforces Landlock, then proves the runner actually confines a write outside the workspace. `make web`, `make desktop`, and `make dev-*` launch the built application; `make help` lists the forwarded arguments. `make stop` stops the `make web` instance listening on `127.0.0.1:$PORT` (default 3080) after verifying the listener is the `dsh web` launcher, and `make restart` stops and relaunches through `make web`; a launch that overrides the port passes the same `PORT=` to both.

## Telemetry

The `Makefile` exports `DSH_TELEMETRY_DISABLED=1` for every recipe and runs `telemetry-guard` before build and launch. The guard composes the profile tree with `dsh --profile web --dump-config`, rejects any enabled row that matches the telemetry or DeepSeek request-metadata patterns, and warns when the collector hosts are not blocked in `/etc/hosts`. The durable opt-out lives in `~/.dsh/cordis.patch.yml`; the environment variable only covers commands started through `make`.

## Prefix-cache reuse on self-hosted DS4

[`packages/llm/llm-pi-ai/diagnostics/prefix-cache-probe.mjs`](packages/llm/llm-pi-ai/diagnostics/prefix-cache-probe.mjs) measures the KV-prefix rule an endpoint applies (`rules`), records request bodies byte-for-byte through a logging proxy (`capture`), and reports where two captured requests first diverge (`diff`). It reads `usage.prompt_tokens_details.cached_tokens`, which Project Maya, vLLM with automatic prefix caching, and llama.cpp servers report per request. The Harness reports nothing equivalent on these routes: pi-ai's `openai-completions` parser leaves `Usage.cacheRead` at zero, so `mapUsage` omits `cacheReadTokens` and a session that re-prefills its whole context looks identical to one that reuses it.

Measured against `deepseek-v4.1-flash`:

| Change from the previous request | Reused | Cost |
|---|---|---|
| Unchanged, or the previous prompt plus one new tail turn | 99.9% | about 0.1 s at 28k tokens |
| One character changed anywhere in the system message, including its last character | 0 | full re-read: 36-45 s at 162k tokens |
| One character changed in any tool description, or two declarations swapped | 0 | full re-read |
| `reasoning_effort` changed | 0 | full re-read |
| `temperature`, `top_p`, `max_tokens`, `enable_thinking`, `user`, `session_id`, `prompt_cache_key` | 99.9% | none |

The engine keeps a restore point at the end of the rendered system-and-tools header (5470 tokens for the `standard` preset, 7361 for PTC) and at the end of the previous prompt. Reuse is content-addressed: it survives a new TCP connection, and separate conversations interleaved request by request keep their own points, so no session or conversation field is needed and this endpoint ignores the ones OpenAI defines. A change after the header costs the tail; a change inside it costs the whole conversation.

Harness requests satisfy that rule in steady state. Eight consecutive PTC requests of a web-profile session, carrying a 78,896-character header, 22 registered tools rendered into it, a background job, and a read, were header-identical and append-only, and reused 99.9%. Sessions that never reuse are sessions whose header text changed between steps. Two paths do that: rebuilding or hot-reloading the running harness under a live Session, because the committed header carries `tools:sdk` rendered from the live registry ([`tool-executor-ptc/src/index.ts:30`](packages/core/tool-executor-ptc/src/index.ts)) and tool description text moves between builds; and switching provider, model, or thinking level inside one Session, which re-commits `deployment:persona-prefix` and re-templates the prompt. Both cost a full re-prefill of the entire context, so the price scales with Session length rather than with the edit.

Two follow-ups are deliberately not taken here; each needs its own change and evidence.

- Report reuse in-product: preserve `prompt_tokens_details.cached_tokens` into `Usage.cacheRead` in the pinned dependency patch [`patches/@earendil-works__pi-ai@1.3.0.patch`](patches/@earendil-works__pi-ai@1.3.0.patch). [`llm-pi-ai/src/stream.ts`](packages/llm/llm-pi-ai/src/stream.ts) already maps `cacheRead` to `cacheReadTokens`, so no other package changes. Applying it needs a full `pnpm install`, which is unsafe beside live Sessions.
- Keep header mutations out of the cached prefix: [`llm-pi-ai/src/models.ts`](packages/llm/llm-pi-ai/src/models.ts) grants in-history system and tool updates only from `compat.supportsMidConvoSystemMessages` and `compat.supportsMidConvoToolAdditions`, and [`llm-pi-ai/src/catalog.ts`](packages/llm/llm-pi-ai/src/catalog.ts) marks both `withhold`, so a self-hosted endpoint cannot declare them and every tool-set change rewrites the `tools` array through [`llm/src/content.ts`](packages/llm/llm/src/content.ts). Maya does accept mid-conversation `system` messages, but the pinned pi-ai build has no consumer for in-history tool additions, so offering that flag today would hide newly registered tools from the model.

## Keeping the branch clean

Recorded-session fixtures change whenever model-visible text changes, so a layer that edits an error message must update every fixture that carries it. Snapshot replay selects the highest committed format generation, so only the selected generation proves the change.

Keep screenshots and other scratch captures out of the repository root; `tmp/` is ignored.
