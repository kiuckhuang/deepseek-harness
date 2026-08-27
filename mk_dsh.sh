#!/usr/bin/env bash
set -Eeuo pipefail

# Build an upstream release plus the local patch layers in a disposable worktree.
# Layers are discovered by name, so adding one is dropping a file beside this
# script: no edit here is needed. The caller's branch, index, worktree, and
# stash are never changed.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=${REPO_DIR:-$SCRIPT_DIR}
REMOTE=${REMOTE:-upstream}
UPSTREAM_URL=${UPSTREAM_URL:-https://github.com/deepseek-ai/deepseek-harness.git}
RELEASE_REF=${RELEASE_REF:-latest}
EXPECTED_COMMIT=${EXPECTED_COMMIT:-}
PATCH_DIR=${PATCH_DIR:-$SCRIPT_DIR}
PATCH_GLOB=${PATCH_GLOB:-dsh_*.patch}
PNPM=${PNPM:-pnpm}
INSTALL_DEPS=1
BUILD_ARGS=()
WORKTREE=
WORKTREE_CREATED=0

# Layers named explicitly by $PATCHES or --patch, in the given order. Empty
# selects discovery under $PATCH_DIR, which is sorted bytewise for reproducibility.
EXPLICIT_PATCHES=()
if [[ -n "${PATCHES:-}" ]]; then
    read -r -a EXPLICIT_PATCHES <<<"$PATCHES"
fi
PATCH_LAYERS=()

usage() {
    cat <<'EOF'
Usage: mk_dsh.sh [--no-install] [--patch FILE]... [--] [build command and arguments]

Fetch the newest upstream dsh-v* release tag, build a detached disposable
worktree, and apply the patch layers in order. Layers are discovered as
dsh_*.patch beside this script, so a new layer is just a new file; a layer is
skipped when it is empty or already upstream, and an incompatible layer fails
before installation. The current branch and its local edits are not changed.
The temporary worktree is removed after the build.

Environment overrides:
  REPO_DIR          Repository to fetch from (default: script directory)
  REMOTE            Git remote (default: upstream)
  UPSTREAM_URL      URL used when REMOTE is absent
  RELEASE_REF       Upstream tag to build (default: latest dsh-v* tag)
  EXPECTED_COMMIT   Optional commit object required for RELEASE_REF
  PATCH_DIR         Directory holding the layers (default: script directory)
  PATCH_GLOB        Layer filename pattern, no slash (default: dsh_*.patch)
  PATCHES           Whitespace-separated layer list; replaces discovery
  PNPM              Package-manager command (default: pnpm)

Options:
  --patch FILE      Add one layer, repeatable; replaces discovery. Order is
                    preserved, so a layer that must follow another goes later.
  --no-install      Skip the dependency install in the worktree
  -h, --help        Show this help

Examples:
  ./mk_dsh.sh
  ./mk_dsh.sh --no-install -- pnpm run build:lib
  ./mk_dsh.sh --patch ./dsh_mcp.patch --patch ./dsh_sandbox.patch
  RELEASE_REF=dsh-v0.1.1-rc.2 ./mk_dsh.sh
  EXPECTED_COMMIT=<commit-sha> ./mk_dsh.sh
  PATCHES="dsh_mcp.patch dsh_sandbox.patch dsh_build.patch" ./mk_dsh.sh
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

# Name the layers to apply: explicit list as given, else sorted discovery.
resolve_patch_layers() {
    if ((${#EXPLICIT_PATCHES[@]} > 0)); then
        PATCH_LAYERS=("${EXPLICIT_PATCHES[@]}")
    else
        [[ "$PATCH_GLOB" != */* ]] \
            || die "PATCH_GLOB must be a filename pattern without a slash: $PATCH_GLOB"
        mapfile -d '' -t PATCH_LAYERS < <(
            find "$PATCH_DIR" -maxdepth 1 -type f -name "$PATCH_GLOB" -print0 | LC_ALL=C sort -z
        )
        ((${#PATCH_LAYERS[@]} > 0)) \
            || die "no patch layer matched ${PATCH_GLOB} under ${PATCH_DIR} (write one, or name layers with PATCHES/--patch)"
    fi

    local index
    for index in "${!PATCH_LAYERS[@]}"; do
        PATCH_LAYERS[index]=$(absolute_path "${PATCH_LAYERS[index]}")
        [[ -f "${PATCH_LAYERS[index]}" ]] || die "patch layer not found: ${PATCH_LAYERS[index]}"
    done
}

while (($# > 0)); do
    case $1 in
        --no-install)
            INSTALL_DEPS=0
            shift
            ;;
        --patch)
            (($# >= 2)) || die "--patch requires a file argument"
            EXPLICIT_PATCHES+=("$2")
            shift 2
            ;;
        --patch=*)
            EXPLICIT_PATCHES+=("${1#--patch=}")
            shift
            ;;
        --help | -h)
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

resolve_patch_layers
printf '==> %d patch layer(s):\n' "${#PATCH_LAYERS[@]}"
for layer in "${PATCH_LAYERS[@]}"; do
    printf '      %s\n' "$layer"
done

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

APPLIED=0
SKIPPED=0

apply_patch_file() {
    local patch=$1
    [[ -s "$patch" ]] || {
        printf '[skip]  %s: empty patch (already provided upstream or intentionally retired)\n' "$patch"
        SKIPPED=$((SKIPPED + 1))
        return
    }

    if git -C "$WORKTREE" apply --reverse --check "$patch" >/dev/null 2>&1; then
        printf '[skip]  %s: already included in %s (retire the layer or keep it as a marker)\n' "$patch" "$RELEASE_REF"
        SKIPPED=$((SKIPPED + 1))
    elif git -C "$WORKTREE" apply --check "$patch" >/dev/null 2>&1; then
        printf '[apply] %s\n' "$patch"
        git -C "$WORKTREE" apply "$patch"
        APPLIED=$((APPLIED + 1))
    else
        die "patch is incompatible with release $RELEASE_REF: $patch (refresh or retire the patch)"
    fi
}

for layer in "${PATCH_LAYERS[@]}"; do
    apply_patch_file "$layer"
done
printf '==> patch layers: %d applied, %d skipped of %d\n' \
    "$APPLIED" "$SKIPPED" "${#PATCH_LAYERS[@]}"
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
