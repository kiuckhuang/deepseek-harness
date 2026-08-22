#!/usr/bin/env bash
set -Eeuo pipefail

# Build an upstream release plus the local patch layer in a disposable worktree.
# The caller's branch, index, worktree, and stash are never changed.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=${REPO_DIR:-$SCRIPT_DIR}
REMOTE=${REMOTE:-upstream}
UPSTREAM_URL=${UPSTREAM_URL:-https://github.com/deepseek-ai/deepseek-harness.git}
RELEASE_REF=${RELEASE_REF:-latest}
EXPECTED_COMMIT=${EXPECTED_COMMIT:-}
MCP_PATCH=${MCP_PATCH:-$SCRIPT_DIR/dsh_mcp.patch}
SANDBOX_PATCH=${SANDBOX_PATCH:-$SCRIPT_DIR/dsh_sandbox.patch}
BUILD_PATCH=${BUILD_PATCH:-$SCRIPT_DIR/dsh_build.patch}
PNPM=${PNPM:-pnpm}
INSTALL_DEPS=1
BUILD_ARGS=()
WORKTREE=
WORKTREE_CREATED=0

usage() {
    cat <<'EOF'
Usage: mk_dsh.sh [--no-install] [--] [build command and arguments]

Fetch the newest upstream dsh-v* release tag, build a detached disposable
worktree, and apply the configured patches in order. Set RELEASE_REF to pin a
specific tag. The current branch and its local edits are not changed. The
temporary worktree is removed after the build.

Environment overrides:
  REPO_DIR          Repository to fetch from (default: script directory)
  REMOTE            Git remote (default: upstream)
  UPSTREAM_URL      URL used when REMOTE is absent
  RELEASE_REF       Upstream tag to build (default: latest dsh-v* tag)
  EXPECTED_COMMIT   Optional commit object required for RELEASE_REF
  MCP_PATCH         MCP patch path (default: ./dsh_mcp.patch)
  SANDBOX_PATCH     sandbox patch path (default: ./dsh_sandbox.patch)
  BUILD_PATCH       build patch path (default: ./dsh_build.patch)
  PNPM              Package-manager command (default: pnpm)

Examples:
  ./mk_dsh.sh
  ./mk_dsh.sh --no-install -- pnpm run build:lib
  RELEASE_REF=dsh-v0.1.1-rc.2 ./mk_dsh.sh
  EXPECTED_COMMIT=<commit-sha> ./mk_dsh.sh
EOF
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

absolute_path() {
    local path=$1
    if [[ "$path" = /* ]]; then
        printf '%s\n' "$path"
    else
        printf '%s/%s\n' "$PWD" "$path"
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

MCP_PATCH=$(absolute_path "$MCP_PATCH")
SANDBOX_PATCH=$(absolute_path "$SANDBOX_PATCH")
BUILD_PATCH=$(absolute_path "$BUILD_PATCH")
[[ -f "$MCP_PATCH" ]] || die "MCP patch not found: $MCP_PATCH"
[[ -f "$SANDBOX_PATCH" ]] || die "sandbox patch not found: $SANDBOX_PATCH"
[[ -f "$BUILD_PATCH" ]] || die "build patch not found: $BUILD_PATCH"

REPO_DIR=$(git -C "$REPO_DIR" rev-parse --show-toplevel 2>/dev/null) \
    || die "not a git repository: $REPO_DIR"
cd "$REPO_DIR"

command -v "$PNPM" >/dev/null 2>&1 || die "package-manager command not found: $PNPM"

cleanup() {
    local status=$?
    if ((WORKTREE_CREATED)); then
        git worktree remove --force "$WORKTREE" >/dev/null 2>&1 || {
            printf '[WARN] could not remove temporary worktree: %s\n' "$WORKTREE" >&2
        }
    elif [[ -n "$WORKTREE" && -d "$WORKTREE" ]]; then
        rmdir "$WORKTREE" >/dev/null 2>&1 || true
    fi
    trap - EXIT
    exit "$status"
}
trap cleanup EXIT

if git remote get-url "$REMOTE" >/dev/null 2>&1; then
    FETCH_SOURCE=$REMOTE
elif [[ "$REMOTE" = upstream ]]; then
    FETCH_SOURCE=$UPSTREAM_URL
    printf '==> fetching upstream directly (%s)\n' "$UPSTREAM_URL"
else
    die "git remote not found: $REMOTE"
fi

[[ "$RELEASE_REF" != /* && "$RELEASE_REF" != *..* ]] \
    || die "RELEASE_REF must be a tag name, not a path or revision range: $RELEASE_REF"

if [[ "$RELEASE_REF" = latest ]]; then
    printf '==> finding latest dsh-v* release tag\n'
    RELEASE_REF=$(git ls-remote --refs --tags --sort='version:refname' "$FETCH_SOURCE" 'refs/tags/dsh-v*' \
        | awk -F/ 'NF >= 3 { tag = $NF; if (tag !~ /\^\{\}$/) latest = tag } END { if (latest != "") print latest }')
    [[ -n "$RELEASE_REF" ]] || die "no dsh-v* release tags found on $FETCH_SOURCE"
fi

[[ "$RELEASE_REF" == dsh-v* ]] || die "RELEASE_REF must start with dsh-v: $RELEASE_REF"

printf '==> fetching %s tag %s\n' "$FETCH_SOURCE" "$RELEASE_REF"
git fetch --prune --force "$FETCH_SOURCE" \
    "refs/tags/$RELEASE_REF:refs/tags/$RELEASE_REF"
RELEASE_COMMIT=$(git rev-parse --verify "refs/tags/$RELEASE_REF^{commit}") \
    || die "fetched tag does not resolve to a commit: $RELEASE_REF"
if [[ -n "$EXPECTED_COMMIT" && "$RELEASE_COMMIT" != "$EXPECTED_COMMIT" ]]; then
    die "tag $RELEASE_REF resolved to $RELEASE_COMMIT, expected $EXPECTED_COMMIT"
fi

printf '==> preparing release %s (%s)\n' "$RELEASE_REF" "$RELEASE_COMMIT"
WORKTREE=$(mktemp -d "${TMPDIR:-/tmp}/dsh-sync.XXXXXX")
rmdir "$WORKTREE"
git worktree add --detach "$WORKTREE" "$RELEASE_COMMIT" >/dev/null
WORKTREE_CREATED=1

apply_patch_file() {
    local patch=$1
    [[ -s "$patch" ]] || {
        printf '[skip]  %s: empty patch (already provided upstream or intentionally retired)\n' "$patch"
        return
    }

    if git -C "$WORKTREE" apply --reverse --check "$patch" >/dev/null 2>&1; then
        printf '[skip]  %s: already included in %s\n' "$patch" "$RELEASE_REF"
    elif git -C "$WORKTREE" apply --check "$patch" >/dev/null 2>&1; then
        printf '[apply] %s\n' "$patch"
        git -C "$WORKTREE" apply "$patch"
    else
        die "patch is incompatible with release $RELEASE_REF: $patch (refresh or retire the patch)"
    fi
}

apply_patch_file "$MCP_PATCH"
apply_patch_file "$SANDBOX_PATCH"
apply_patch_file "$BUILD_PATCH"
git -C "$WORKTREE" diff --check

cd "$WORKTREE"
if ((INSTALL_DEPS)); then
    printf '==> installing dependencies in disposable worktree\n'
    "$PNPM" install --frozen-lockfile
fi

if ((${#BUILD_ARGS[@]} > 0)); then
    printf '==> running custom build command:'
    printf ' %q' "${BUILD_ARGS[@]}"
    printf '\n'
    "${BUILD_ARGS[@]}"
else
    printf '==> running pnpm run build\n'
    "$PNPM" run build
fi

printf '==> build succeeded for %s (%s)\n' "$RELEASE_REF" "$RELEASE_COMMIT"
