# Agent Note: Release worktree synchronization

Status: implemented

English | [中文](2026-08-22-release-worktree-sync.zh.md)

## Problem

`mk_dsh.sh` updated the caller's `downstream` branch by stashing edits, rebasing or merging `upstream/master`, restoring selected files, and applying patch files. It did not select an immutable release tag, could leave a changed branch or unresolved Git operation after a failure, and could not distinguish an already-upstreamed build patch from an incompatible patch. The build patch's pnpm invocation change is included in `dsh-v0.1.1-rc.2`, while the MCP session recovery patch remains a downstream change.

## Decision

`mk_dsh.sh` fetches the newest version-sorted `dsh-v*` release tag by default, or the explicitly configured `RELEASE_REF` tag, resolves it to a commit, optionally verifies `EXPECTED_COMMIT`, and builds a detached Git worktree created from that commit. The script applies `dsh_mcp.patch` and the empty build patch in order; a patch is skipped only when it is empty or its reverse applies cleanly, and an incompatible non-empty patch fails before installation. The temporary worktree is removed on success or failure, while the caller's branch, index, worktree, and stash remain untouched.

The worktree installs with `--frozen-lockfile` by default and runs `pnpm run build`, or an explicitly supplied command after `--`. `make` invokes the same default operation, `make web` runs `pnpm dsh web`, and `make help` delegates to the script help. `REPO_DIR`, `REMOTE`, `UPSTREAM_URL`, `RELEASE_REF`, `EXPECTED_COMMIT`, patch paths, `PNPM`, and `--no-install` provide explicit operational choices without introducing branch update or stash restoration modes.

## Alternatives considered

**Rebase or merge the active downstream branch.** Rejected because synchronization and build preparation do not need to rewrite a user's branch, and failures in stash restoration or conflict resolution create recovery state unrelated to the build.

**Use a Git submodule for upstream.** Rejected because the requested operation is a reproducible release build with two root-level patches, not a source dependency consumed by the repository. A fetched tag plus a disposable worktree provides the required upstream pin without adding submodule checkout and nested-worktree state.

**Keep the build patch and rely on three-way application.** Rejected because upstream release `dsh-v0.1.1-rc.2` already contains the build change. The patch is retained as an empty, explicit layer entry so the two-patch invocation remains stable and its retirement is visible.

## Consequences

A successful build produces artifacts only in the temporary worktree, so callers that need them must provide a custom command that copies or publishes them before the script exits. The script requires a tag reachable from the configured remote and does not merge arbitrary local commits into the release. Patch refreshes are deliberate: a non-empty patch that no longer applies fails with the target release named in the diagnostic.

The selected release tag is fetched into the local tag namespace with force and prune semantics. `EXPECTED_COMMIT` can prevent a mutable remote tag from selecting an unexpected object. Installation and build failures no longer damage the active checkout. The default path follows the newest version-sorted `dsh-v*` tag; callers requiring reproducibility can set both `RELEASE_REF` and `EXPECTED_COMMIT`.

## Verification

At the time of this decision, the newest upstream tag is `dsh-v0.1.1-rc.2`, resolving to commit `b150a551b8d465e31e418e1b2eaf5e79bbb7d28e`. The MCP patch applies forward to that release. The build patch fails as a forward patch and is represented by an empty patch file because its change is upstream. `bash -n mk_dsh.sh` and `git diff --check` pass.
