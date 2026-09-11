# Agent Note: Downstream release sync

Status: implemented

English | [中文](2026-09-10-downstream-release-sync.zh.md)

## Problem

The fork keeps a downstream change in two places: committed on the branch, and duplicated in a `dsh_*.patch` layer that [release worktree sync](2026-08-22-release-worktree-sync.md) applies to a release tag. Every upstream release required retargeting each layer by hand, so a layer drifted from the branch and stopped applying at the next tag; six `chore: retarget patch layers to dsh-vX` commits and repeated snapshot rewrites come from that duplication.

## Decision

`sync_dsh.sh` (`make sync`) merges the newest upstream `dsh-v*` release tag into the current branch and regenerates every `dsh_*.patch` layer beside it from the merged result. The branch is the source of truth for a downstream change, and a layer is a derived artifact.

The script resolves `latest` through `git ls-remote --refs --tags --sort=version:refname`, fetches that tag with force and prune semantics, and refuses a detached HEAD or a dirty working tree. It merges the release commit forward with `git merge --no-edit`; a conflicting merge is aborted and reported, so the caller resolves it once and re-runs. It never resets, rebases, or otherwise rewrites the branch.

A layer's covered paths come from the layer itself (`git apply --numstat`), so extending a downstream change to another file means extending that layer once. Regeneration writes the branch's difference from the release for those paths. A layer whose change upstream has adopted regenerates empty, which retires it visibly because `mk_dsh.sh` skips empty layers. Every regenerated layer is applied to a disposable worktree at the release commit before installation, so an incompatible layer fails with the release named. Changed layers are committed as `chore: sync downstream to <tag>`.

`--check` (`make check`) performs the same fetch, merge check, derivation, and verification without mutating anything. It derives from the tree `git merge-tree --write-tree` would produce instead of from a merged HEAD.

## Alternatives considered

**Keep retargeting layers by hand.** Rejected because the two copies drift: a stored layer stopped applying nine commits past the tag it named, and every refresh was a manual edit that the next release invalidated again.

**Derive the release build directly from the branch.** Rejected because `mk_dsh.sh` exists to build a pristine published tag plus named layers, which a branch checkout cannot prove; the layer remains the record of what the fork changes relative to a release.

**Reset the branch to the release tag instead of merging.** Rejected because the fork's own tooling (`mk_dsh.sh`, `Makefile`, layers) lives on the branch and a reset would discard it, and because a rewrite would require a forced push to the fork.

## Consequences

A release sync is one command, and a layer can no longer be stale with respect to the branch. Upstream adopting a downstream change retires its layer without an edit. One cost remains real: a release that changes the files a layer covers conflicts the merge, and the caller resolves that by hand before re-running.

The branch mirrors upstream outside layer-covered paths and downstream-only files. A standing diff on upstream-owned documentation (the bilingual README corpus included) conflicts every release that touches the same files, so documentation changes ride with upstream, and fork-owned prose stays in layer-covered paths and downstream-only files.

Layer coverage is derived from the existing layer, so a downstream change that adds a file to an already-covered area needs that file added to the layer once; later discovery is not automatic. Because `sync_dsh.sh` merges a tag while `mk_dsh.sh` builds one, a branch ahead of the newest release — for example after merging `upstream/master` — makes a derived layer carry that untagged drift until a release contains it.

## Verification

At the time of this decision the newest upstream release is `dsh-v0.1.5-rc.1`, resolving to `183f08e9c6dde7e36cd2318eaee70b0da08fb35e`. `bash -n sync_dsh.sh` passes. `make check` reports a conflict-free merge, applies the two non-empty layers to a detached `dsh-v0.1.5-rc.1` worktree, and leaves the tree unchanged. `./mk_dsh.sh --no-install -- true` still reports two applied and one skipped layer for that release.
