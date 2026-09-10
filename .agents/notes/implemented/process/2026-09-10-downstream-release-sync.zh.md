# Agent Note: 下游发布同步

Status: implemented

[English](2026-09-10-downstream-release-sync.md) | 中文

## 问题

该 fork 把同一个下游改动保存在两处：既提交在分支上，又重复为 `dsh_*.patch` 层，由[发布 worktree 同步](2026-08-22-release-worktree-sync.zh.md)应用到发布 tag 上。每次上游发布都需要手工重定向每一层，于是层与分支逐渐分叉，并在下一个 tag 处不再适用；六次 `chore: retarget patch layers to dsh-vX` 提交与反复重写的快照都来自这份重复。

## 决策

`sync_dsh.sh`（`make sync`）把最新的上游 `dsh-v*` 发布 tag 合并进当前分支，并从合并结果重新生成脚本同旁的每个 `dsh_*.patch` 层。分支是下游改动的唯一事实来源，层是派生产物。

脚本通过 `git ls-remote --refs --tags --sort=version:refname` 解析 `latest`，以 force 和 prune 语义获取该 tag，并拒绝 detached HEAD 或脏工作树。它用 `git merge --no-edit` 向前合并发布 commit；发生冲突的合并会被中止并报告，由调用方解决一次后重新运行。它绝不 reset、rebase 或以其他方式改写分支。

每一层覆盖的路径来自该层自身（`git apply --numstat`），因此把下游改动扩展到另一个文件只需扩展一次该层。重新生成写入分支相对发布版本的差异。上游已采纳其改动的层会重新生成为空，从而可见地退役，因为 `mk_dsh.sh` 会跳过空层。每个重新生成的层在安装前都会先应用到发布 commit 的临时 worktree 上，因此不兼容的层会在诊断中指明发布版本并失败。发生变化的层以 `chore: sync downstream to <tag>` 提交。

`--check`（`make check`）执行相同的获取、合并检查、派生与验证，但不改动任何内容。它从 `git merge-tree --write-tree` 会生成的树派生，而不是从已合并的 HEAD 派生。

## 曾考虑的替代方案

**继续手工重定向补丁层。** 不采用，因为两份副本会分叉：已存储的层在其所指 tag 之后的第九个 commit 处不再适用，而每次刷新都是手工编辑，下一次发布又会使其失效。

**直接从分支派生发布构建。** 不采用，因为 `mk_dsh.sh` 的用途是构建纯净的已发布 tag 加具名层，这是分支 checkout 无法证明的；层仍然是该 fork 相对发布版本所做改动的记录。

**将分支 reset 到发布 tag 而不是合并。** 不采用，因为该 fork 自己的工具（`mk_dsh.sh`、`Makefile`、补丁层）就在分支上，reset 会丢弃它们，而且改写需要强制推送到 fork。

## 后果

一次发布同步就是一条命令，层不再可能相对分支过期。上游采纳某个下游改动时，其层无需编辑即退役。仍有一项成本是真实的：改变层所覆盖文件的发布版本会让合并冲突，调用方必须手工解决后重新运行。

层的覆盖范围派生自既有层，因此某个下游改动若在已覆盖区域新增文件，需要先把该文件加入层一次；事后不会自动发现。由于 `sync_dsh.sh` 合并 tag 而 `mk_dsh.sh` 构建 tag，当分支领先于最新发布版本时（例如合并 `upstream/master` 之后），派生出的层会带着这份未发版的漂移，直到某次发布包含它。

## 验证

在本决策作出时，最新上游发布为 `dsh-v0.1.5-rc.1`，解析到 `183f08e9c6dde7e36cd2318eaee70b0da08fb35e`。`bash -n sync_dsh.sh` 通过。`make check` 报告无冲突合并，把两个非空层应用到 detached 的 `dsh-v0.1.5-rc.1` worktree，并使工作树保持不变。`./mk_dsh.sh --no-install -- true` 对该发布版本仍报告两个应用、一个跳过。
