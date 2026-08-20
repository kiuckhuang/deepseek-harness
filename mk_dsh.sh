#!/usr/bin/env bash
set -Eeuo pipefail

# Synchronize a DeepSeek Harness checkout, apply local patches, and build it.
# The sync is intentionally destructive: tracked and untracked checkout changes
# are removed before the selected upstream ref is installed.

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

Environment overrides:
  REPO_DIR       Checkout to synchronize (auto-detected from script location)
  REMOTE         Git remote (default: upstream)
  BRANCH         Remote branch (default: master)
  WORK_BRANCH    Local branch rebuilt from upstream (default: downstream)
  MCP_PATCH      MCP patch path (default: /dev/shm/dsh_mcp.patch)
  BUILD_PATCH    pnpm build fix patch path (default: /dev/shm/dsh_build.patch)
  UPSTREAM_URL   URL used when the upstream remote is absent
  PNPM           Package-manager command (default: pnpm)

Examples:
  mk_dsh.sh
  mk_dsh.sh --no-install -- pnpm run build:lib
EOF
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

apply_patch_file() {
    local patch=$1
    [[ -f "$patch" ]] || die "patch not found: $patch"

    if git apply --reverse --check "$patch" >/dev/null 2>&1; then
        printf '[skip]  %s: already applied\n' "$patch"
    elif git apply --check "$patch" >/dev/null 2>&1; then
        printf '[apply] %s\n' "$patch"
        git apply "$patch"
    else
        die "patch does not apply cleanly: $patch"
    fi
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

REPO_DIR=$(cd -- "$REPO_DIR" && pwd)
TOOL_BACKUP=$(mktemp -d)
declare -a RESTORE_TARGETS=()
cleanup() {
    rm -rf "$TOOL_BACKUP"
}
trap cleanup EXIT

backup_tool_file() {
    local path=$1
    case "$path" in
        "$REPO_DIR"/*)
            local relative=${path#"$REPO_DIR"/}
            mkdir -p "$TOOL_BACKUP/$(dirname -- "$relative")"
            cp -p "$path" "$TOOL_BACKUP/$relative"
            RESTORE_TARGETS+=("$relative")
            ;;
    esac
}

restore_tool_files() {
    local relative
    for relative in "${RESTORE_TARGETS[@]}"; do
        mkdir -p "$REPO_DIR/$(dirname -- "$relative")"
        cp -p "$TOOL_BACKUP/$relative" "$REPO_DIR/$relative"
    done
}

backup_tool_file "$MCP_PATCH"
backup_tool_file "$BUILD_PATCH"
backup_tool_file "$SCRIPT_PATH"

cd "$REPO_DIR"
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

printf '==> rebuilding local branch %s from %s/%s\n' "$WORK_BRANCH" "$REMOTE" "$BRANCH"
git switch --discard-changes -C "$WORK_BRANCH" "$REMOTE/$BRANCH"
git clean -fd
restore_tool_files

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
