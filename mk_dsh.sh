#!/usr/bin/env bash
set -Eeuo pipefail

# Synchronize the downstream branch with upstream, preserve local edits,
# apply the maintained patches when they are not already present, and build it.
# The script never resets or cleans the user's checkout.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_PATH="$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")"
if [[ -n "${REPO_DIR:-}" ]]; then
    REPO_DIR=$REPO_DIR
elif [[ -e "$SCRIPT_DIR/.git" ]]; then
    REPO_DIR=$SCRIPT_DIR
else
    REPO_DIR="$SCRIPT_DIR/deepseek-harness"
fi
REMOTE=${REMOTE:-upstream}
BRANCH=${BRANCH:-master}
WORK_BRANCH=${WORK_BRANCH:-downstream}
UPDATE_STRATEGY=${UPDATE_STRATEGY:-rebase}
UPSTREAM_URL=${UPSTREAM_URL:-https://github.com/deepseek-ai/deepseek-harness.git}
MCP_PATCH=${MCP_PATCH:-"$SCRIPT_DIR/dsh_mcp.patch"}
BUILD_PATCH=${BUILD_PATCH:-"$SCRIPT_DIR/dsh_build.patch"}
PNPM=${PNPM:-pnpm}
INSTALL_DEPS=1
BUILD_ARGS=()

absolute_path() {
    local path=$1
    if [[ "$path" = /* ]]; then
        printf '%s\n' "$path"
    else
        printf '%s/%s\n' "$PWD" "$path"
    fi
}

usage() {
    cat <<'EOF'
Usage: mk_dsh.sh [--no-install] [--] [build command and arguments]

The default operation fetches upstream/master, updates downstream, preserves
local edits with Git stash, applies each configured patch only when needed,
and runs pnpm build. It does not reset or clean the checkout.

Environment overrides:
  REPO_DIR          Checkout to synchronize (auto-detected from script location)
  REMOTE            Git remote (default: upstream)
  BRANCH            Remote branch (default: master)
  WORK_BRANCH       Local branch updated from upstream (default: downstream)
  UPDATE_STRATEGY   rebase or merge (default: rebase)
  MCP_PATCH         MCP patch path (default: ./dsh_mcp.patch)
  BUILD_PATCH       build patch path (default: ./dsh_build.patch)
  UPSTREAM_URL      URL used when the upstream remote is absent
  PNPM              Package-manager command (default: pnpm)

Examples:
  ./mk_dsh.sh
  ./mk_dsh.sh --no-install -- pnpm run build:lib
  UPDATE_STRATEGY=merge ./mk_dsh.sh
EOF
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

while (($# > 0)); do
    case $1 in
        --no-install)
            INSTALL_DEPS=0
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --)
            shift
            BUILD_ARGS=("$@")
            break
            ;;
        *)
            BUILD_ARGS=("$@")
            break
            ;;
    esac
done

[[ -e "$REPO_DIR/.git" ]] || die "not a git repository: $REPO_DIR"
MCP_PATCH=$(absolute_path "$MCP_PATCH")
BUILD_PATCH=$(absolute_path "$BUILD_PATCH")
SCRIPT_PATH=$(absolute_path "$SCRIPT_PATH")
[[ -f "$MCP_PATCH" ]] || die "MCP patch not found: $MCP_PATCH"
[[ -f "$BUILD_PATCH" ]] || die "build patch not found: $BUILD_PATCH"

case "$UPDATE_STRATEGY" in
    rebase|merge) ;;
    *) die "UPDATE_STRATEGY must be rebase or merge: $UPDATE_STRATEGY" ;;
esac

REPO_DIR=$(cd -- "$REPO_DIR" && pwd)
TOOL_BACKUP=$(mktemp -d)
RESTORE_TARGETS=()
STASH_REF=

backup_tool_file() {
    local path=$1
    case "$path" in
        "$REPO_DIR"/*)
            local relative=${path#"$REPO_DIR"/}
            if [[ -f "$path" && ! -e "$TOOL_BACKUP/$relative" ]]; then
                mkdir -p -- "$TOOL_BACKUP/$(dirname -- "$relative")"
                cp -p -- "$path" "$TOOL_BACKUP/$relative"
                RESTORE_TARGETS+=("$relative")
            fi
            ;;
    esac
}

restore_tool_files() {
    local relative
    for relative in "${RESTORE_TARGETS[@]}"; do
        mkdir -p -- "$REPO_DIR/$(dirname -- "$relative")"
        cp -p -- "$TOOL_BACKUP/$relative" "$REPO_DIR/$relative"
    done
}

cleanup() {
    local status=$?
    restore_tool_files || true
    if ((status != 0)) && [[ -n "$STASH_REF" ]]; then
        printf '[INFO] local edits remain in stash %s; restore it after resolving the sync failure\n' "$STASH_REF" >&2
    fi
    rm -rf -- "$TOOL_BACKUP"
    trap - EXIT
    exit "$status"
}
trap cleanup EXIT

is_tracked() {
    git ls-files --error-unmatch -- "$1" >/dev/null 2>&1
}

prepare_tool_files() {
    local relative
    for relative in "${RESTORE_TARGETS[@]}"; do
        if ! git diff --cached --quiet -- "$relative"; then
            die "tool file has staged changes; commit or unstage it before syncing: $relative"
        fi
        if is_tracked "$relative"; then
            git restore --source=HEAD --staged --worktree -- "$relative"
        else
            rm -f -- "$REPO_DIR/$relative"
        fi
    done
}

apply_patch_file() {
    local patch=$1
    [[ -f "$patch" ]] || die "patch not found: $patch"
    if [[ ! -s "$patch" ]]; then
        printf '[skip]  %s: empty patch\n' "$patch"
        return
    fi

    if git apply --reverse --check "$patch" >/dev/null 2>&1; then
        printf '[skip]  %s: already applied\n' "$patch"
    elif git apply --check "$patch" >/dev/null 2>&1; then
        printf '[apply] %s\n' "$patch"
        git apply "$patch"
    else
        printf '[apply] %s with three-way fallback\n' "$patch"
        git apply --3way "$patch" || die "patch does not apply cleanly: $patch"
    fi
}

cd "$REPO_DIR"
backup_tool_file "$MCP_PATCH"
backup_tool_file "$BUILD_PATCH"
backup_tool_file "$SCRIPT_PATH"
prepare_tool_files

if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
    if [[ "$REMOTE" = upstream ]]; then
        printf '==> adding upstream remote\n'
        git remote add upstream "$UPSTREAM_URL"
    else
        die "git remote not found: $REMOTE"
    fi
fi

printf '==> fetching %s/%s\n' "$REMOTE" "$BRANCH"
git fetch "$REMOTE" "$BRANCH"

if [[ -n "$(git status --porcelain)" ]]; then
    STASH_MESSAGE="dsh-sync-$(date +%Y%m%d-%H%M%S)-$$"
    printf '==> stashing local edits (%s)\n' "$STASH_MESSAGE"
    git stash push --include-untracked --message "$STASH_MESSAGE"
    STASH_REF=$(git rev-parse refs/stash)
fi

if git show-ref --verify --quiet "refs/heads/$WORK_BRANCH"; then
    printf '==> switching to %s\n' "$WORK_BRANCH"
    git switch "$WORK_BRANCH"
    case "$UPDATE_STRATEGY" in
        rebase)
            printf '==> rebasing %s onto %s/%s\n' "$WORK_BRANCH" "$REMOTE" "$BRANCH"
            git rebase "$REMOTE/$BRANCH"
            ;;
        merge)
            printf '==> merging %s/%s into %s\n' "$REMOTE" "$BRANCH" "$WORK_BRANCH"
            git merge --no-edit "$REMOTE/$BRANCH"
            ;;
    esac
else
    printf '==> creating %s from %s/%s\n' "$WORK_BRANCH" "$REMOTE" "$BRANCH"
    git switch -c "$WORK_BRANCH" "$REMOTE/$BRANCH"
fi

restore_tool_files

if [[ -n "$STASH_REF" ]]; then
    printf '==> restoring local edits\n'
    git stash pop stash@{0}
    STASH_REF=
fi

apply_patch_file "$MCP_PATCH"
apply_patch_file "$BUILD_PATCH"

if ((INSTALL_DEPS)); then
    printf '==> installing dependencies\n'
    "$PNPM" install --frozen-lockfile
fi

if ((${#BUILD_ARGS[@]} > 0)); then
    printf '==> running custom build command: %q' "${BUILD_ARGS[0]}"
    if ((${#BUILD_ARGS[@]} > 1)); then
        printf ' %q' "${BUILD_ARGS[@]:1}"
    fi
    printf '\n'
    "${BUILD_ARGS[@]}"
else
    printf '==> running pnpm run build\n'
    "$PNPM" run build
fi

printf '==> synchronized %s with %s/%s\n' "$WORK_BRANCH" "$REMOTE" "$BRANCH"
git status --short | sed -n '1,20p'

exit 0
