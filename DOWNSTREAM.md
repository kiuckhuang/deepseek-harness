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

[`packages/llm/llm-pi-ai/diagnostics/prefix-cache-probe.mjs`](packages/llm/llm-pi-ai/diagnostics/prefix-cache-probe.mjs) measures the KV-prefix rule an endpoint applies (`rules`), records request bodies byte-for-byte through a logging proxy (`capture`), and reports where two captured requests first diverge (`diff`). It reads `usage.prompt_tokens_details.cached_tokens`, which Project Maya, vLLM with automatic prefix caching, and llama.cpp servers report per request.

Reuse is already visible in-product where the endpoint reports it: pi-ai's `parseChunkUsage` reads `prompt_tokens_details.cached_tokens`, `prompt_cache_hit_tokens`, and `cached_tokens` into `cacheRead`, and [`llm-pi-ai/src/stream.ts`](packages/llm/llm-pi-ai/src/stream.ts) maps that to `cacheReadTokens`. A recorded `0` is therefore ambiguous: it can be a true miss, or an endpoint that sent no cache detail at all. The dgx-32 vLLM route returns `usage` without `prompt_tokens_details`, so every request there records no cache figure even while the engine's own `vllm:prefix_cache_hits_total` shows hits; `rules` separates the two cases.

Measured against `deepseek-v4.1-flash`, which does report:

| Change from the previous request | Reused | Cost |
|---|---|---|
| Unchanged, or the previous prompt plus one new tail turn | 99.9% | about 0.1 s at 216k tokens |
| One character changed anywhere in the system message, including its last character | 0 | full re-read: 36-45 s at 162k tokens |
| One character changed in any tool description, or two declarations swapped | 0 | full re-read |
| `reasoning_effort` changed | 0 | full re-read |
| `temperature`, `top_p`, `max_tokens`, `enable_thinking`, `user`, `session_id`, `prompt_cache_key` | 99.9% | none |

The engine keeps a restore point at the end of the rendered system-and-tools header (5470 tokens for the `standard` preset, 7361 for PTC) and at the end of the previous prompt. Reuse is content-addressed: it survives a new TCP connection, and separate conversations interleaved request by request keep their own points, so no session or conversation field is needed and this endpoint ignores the ones OpenAI defines. A change after the last restore point costs the tail; a change inside the header costs the whole conversation.

Ordinary operation therefore reuses. Two live Sessions measured 217k-245k and 250k-266k reused tokens per request with only tens to thousands of new tokens, and resuming a Session in a fresh process reused 12481 of 12493 tokens. A full re-read of the conversation happens when the cached prefix is gone or has changed:

- The harness is rebuilt under a live Session and the rendered `tools:sdk` text differs, because that section carries the live registry ([`tool-executor-ptc/src/index.ts:30`](packages/core/tool-executor-ptc/src/index.ts)) and tool descriptions move between builds.
- The provider or model changes to a different engine, which leaves the previous engine's prefix behind.
- A Session sits idle long enough for the engine to evict the prefix; one observed Session resumed after 2.5 hours and read 216k tokens once before reusing again.
- A legacy head carries no `source.sections`, so [`system-prompt/src/projection.ts:49`](packages/core/system-prompt/src/projection.ts) marks a rebuild and rewrites the whole head. Sessions written by older builds contain such heads; each restore pays one full re-read until the rebuild writes a sectioned head.

The remaining follow-up is the last item: a restore should not rewrite a head whose committed text already matches. Fixing it means distinguishing a legacy whole-prompt head (content, no sections, rebuild) from a current empty placeholder (no content, no sections, no-op), which changes admission semantics and needs its own tests.

## Keeping the branch clean

Recorded-session fixtures change whenever model-visible text changes, so a layer that edits an error message must update every fixture that carries it. Snapshot replay selects the highest committed format generation, so only the selected generation proves the change.

Keep screenshots and other scratch captures out of the repository root; `tmp/` is ignored.