# Agent Note: 发布 worktree 同步

Status: implemented

[English](2026-08-22-release-worktree-sync.md) | 中文

## 问题

`mk_dsh.sh` 通过暂存编辑、切换 `downstream` 分支、rebase 或 merge `upstream/master`、恢复选定文件并应用补丁来更新调用方分支。它没有选择不可变的发布 tag；失败时可能留下已改变的分支或未解决的 Git 操作；也无法区分已进入上游的构建补丁与不兼容补丁。构建补丁中的 pnpm 调用变更已包含在 `dsh-v0.1.1-rc.2`，而 MCP 会话恢复补丁仍是下游变更。

## 决策

`mk_dsh.sh` 默认获取按版本排序的最新 `dsh-v*` release tag，也可以获取显式配置的 `RELEASE_REF` tag；随后将其解析为 commit，可选地校验 `EXPECTED_COMMIT`，并从该 commit 创建 detached Git worktree。脚本按顺序应用 `dsh_mcp.patch`、`dsh_sandbox.patch` 和空的构建补丁；仅当补丁为空或其逆向检查成功时才跳过补丁；非空且不兼容的补丁会在安装前失败。临时 worktree 在成功或失败时都会被删除，调用方的分支、索引、worktree 和 stash 保持不变。

worktree 默认以 `--frozen-lockfile` 安装依赖并运行 `pnpm run build`；也可以在 `--` 后提供明确命令。`make` 执行相同的默认操作，`make web` 运行 `pnpm dsh web`，`make help` 委托脚本显示帮助。`REPO_DIR`、`REMOTE`、`UPSTREAM_URL`、`RELEASE_REF`、`EXPECTED_COMMIT`、补丁路径、`PNPM` 以及 `--no-install` 提供显式操作选择，但不再提供更新分支或恢复 stash 的模式。

## 曾考虑的替代方案

**rebase 或 merge 活跃的 downstream 分支。** 不采用，因为同步和构建准备不需要改写用户分支，而 stash 恢复或冲突解决失败会留下与构建无关的恢复状态。

**为上游使用 Git submodule。** 不采用，因为这里需要的是带两个根目录补丁的可复现发布构建，而不是仓库消费的源码依赖。获取 tag 加 disposable worktree 能提供所需的上游固定点，同时不增加 submodule checkout 和嵌套 worktree 状态。

**保留构建补丁并依靠三方应用。** 不采用，因为上游发布版本 `dsh-v0.1.1-rc.2` 已包含构建变更。保留一个空的、明确的补丁层条目，使双补丁调用保持稳定，并让这次退役清晰可见。

## 后果

成功构建只在临时 worktree 中生成产物，因此需要产物的调用方必须提供自定义命令，在脚本退出前复制或发布它们。脚本要求 tag 可从配置的 remote 获取，不会把任意本地 commit 合并到发布版本。补丁刷新是有意为之：不再适用于目标发布版本的非空补丁会在诊断中明确指出发布版本。

选定的 release tag 使用 force 和 prune 语义获取到本地 tag 命名空间。`EXPECTED_COMMIT` 可防止可变远程 tag 选择非预期对象。安装或构建失败不再损坏活跃 checkout。默认路径跟随按版本排序的最新 `dsh-v*` tag；需要可复现构建时，可同时设置 `RELEASE_REF` 和 `EXPECTED_COMMIT`。

## 验证

在本决策作出时，最新 upstream tag 为 `dsh-v0.1.1-rc.2`，解析到 commit `b150a551b8d465e31e418e1b2eaf5e79bbb7d28e`。MCP 补丁可以正向应用到该发布版本。构建补丁作为正向补丁失败，并已表示为空补丁文件，因为其变更已进入上游。`bash -n mk_dsh.sh` 和 `git diff --check` 通过。
