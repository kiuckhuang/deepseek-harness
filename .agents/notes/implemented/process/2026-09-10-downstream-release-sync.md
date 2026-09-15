# Agent Note: Downstream release sync

Status: implemented

English | [中文](2026-09-10-downstream-release-sync.zh.md)

## Problem

The fork keeps a downstream change in two places: committed on the branch, and duplicated in a `dsh_*.patch` layer that [release worktree sync](2026-08-22-release-worktree-sync.md) applies to a release tag. Every upstream release required retargeting each layer by hand, so a layer drifted from the branch and stopped applying at the next tag; six `chore: retarget patch layers to dsh-vX` commits and repeated snapshot rewrites come from that duplication.

## Decision

`sync_dsh.sh` (`make sync`) merges upstream's default branch into the current branch and regenerates every `dsh_*.patch` layer beside it from the merged result. Each layer is derived against the newest `dsh-v*` release tag, so the tag build `mk_dsh.sh` runs still applies it. The branch is the source of truth for a downstream change, and a layer is a derived artifact.

The script resolves `latest` through `git ls-remote --refs --tags --sort=version:refname` for the derivation base, fetches that tag and the configured `SYNC_REF` branch (default `master`) with force and prune semantics, and refuses a detached HEAD or a dirty working tree. It merges whichever of the two lines already contains the other — normally the default branch, which absorbs each release — using `git merge --no-edit`; a conflicting merge is aborted and reported, so the caller resolves it once and re-runs. It never resets, rebases, or otherwise rewrites the branch.

A layer's covered paths come from the layer itself (`git apply --numstat`), so extending a downstream change to another file means extending that layer once. Regeneration writes the branch's difference from the release tag for those paths. A layer whose change upstream has adopted regenerates empty, which retires it visibly because `mk_dsh.sh` skips empty layers. Every regenerated layer is applied to a disposable worktree at the release commit before installation, so an incompatible layer fails with the release named. Changed layers are committed as `chore: sync downstream to <ref>`.

`--check` (`make check`) performs the same fetch, merge check, derivation, and verification without mutating anything. It derives from the tree `git merge-tree --write-tree` would produce instead of from a merged HEAD.

## Alternatives considered

**Keep retargeting layers by hand.** Rejected because the two copies drift: a stored layer stopped applying nine commits past the tag it named, and every refresh was a manual edit that the next release invalidated again.

**Merge the newest release tag instead of the default branch.** Rejected because a release tag is cut from a release branch and reaches the default branch later, so the two lines diverge and every documentation path both lines touched conflicts. One such merge reverted 711 upstream-owned documents the default branch already carried, including a section of the root README, while reporting only 32 conflicts. The tag still supplies the derivation base, because `mk_dsh.sh` builds from a tag.

**Derive the release build directly from the branch.** Rejected because `mk_dsh.sh` exists to build a pristine published tag plus named layers, which a branch checkout cannot prove; the layer remains the record of what the fork changes relative to a release.

**Reset the branch to the release tag instead of merging.** Rejected because the fork's own tooling (`mk_dsh.sh`, `Makefile`, layers) lives on the branch and a reset would discard it, and because a rewrite would require a forced push to the fork.

## Consequences

A release sync is one command, and a layer can no longer be stale with respect to the branch. Upstream adopting a downstream change retires its layer without an edit. One cost remains real: upstream changing the files a layer covers conflicts the merge, and the caller resolves that by hand before re-running.

The branch mirrors upstream outside layer-covered paths and downstream-only files. A standing diff on upstream-owned documentation (the bilingual README corpus included) conflicts every release that touches the same files, so documentation changes ride with upstream, and fork-owned prose stays in layer-covered paths and downstream-only files.

Layer coverage is derived from the existing layer, so a downstream change that adds a file to an already-covered area needs that file added to the layer once; later discovery is not automatic. A layer is the difference between the branch and the release tag, so a branch that has absorbed commits the newest tag does not contain carries that unreleased drift in the layer until a later tag contains it; that drift is what makes the tag build reproduce the branch.

While a release is newer than the default branch, the script merges the release instead, so the branch briefly follows the release line rather than the default branch.

## Verification

At the time of this decision the newest upstream release was `dsh-v0.1.5-rc.2`, and `master` already contained it. `bash -n sync_dsh.sh` passes. `make check` reports a conflict-free merge against `master` and leaves the tree unchanged, and `./mk_dsh.sh --no-install -- true` reports two applied and one skipped layer for `dsh-v0.1.5-rc.2`. Pointing `SYNC_REF` at a branch that predates the release was exercised against a synthetic remote: the script reports that the release is not contained, merges the release tag instead, and still verifies both layers against it.
