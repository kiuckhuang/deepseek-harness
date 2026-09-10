#!/usr/bin/env bash
set -Eeuo pipefail

# Sync the current branch to the newest upstream dsh-v* release and regenerate
# the dsh_*.patch layers from the merged branch. The branch is the source of
# truth for a downstream change; a layer is a derived artifact, so a release
# sync derives it instead of asking anyone to retarget it by hand. A change
# upstream has adopted empties its own layer, which retires it visibly.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=${REPO_DIR:-$SCRIPT_DIR}
REMOTE=${REMOTE:-upstream}
UPSTREAM_URL=${UPSTREAM_URL:-https://github.com/deepseek-ai/deepseek-harness.git}
RELEASE_REF=${RELEASE_REF:-latest}
PATCH_DIR=${PATCH_DIR:-$SCRIPT_DIR}
PATCH_GLOB=${PATCH_GLOB:-dsh_*.patch}
MODE=sync
WORKTREE=
WORKTREE_CREATED=0
TMP_FILES=()

usage() {
    cat <<'EOF'
Usage: sync_dsh.sh [--check] [--patch FILE]... [--help]

Merge the newest upstream dsh-v* release tag into the current branch, then
regenerate every patch layer beside this script from the merged branch.

The branch is merged forward; it is never reset or rewritten. A conflicting
merge is aborted and reported, so the caller resolves it once by hand and
re-runs. A regenerated layer that no longer differs from the release is left
empty, which mk_dsh.sh skips.

Options:
  --check           Verify the merge and the regenerated layers, change nothing
  --patch FILE      Regenerate only this layer, repeatable; replaces discovery
  -h, --help        Show this help

Environment overrides:
  REPO_DIR          Repository to sync (default: script directory)
  REMOTE            Git remote (default: upstream)
  UPSTREAM_URL      URL used when REMOTE is absent
  RELEASE_REF       Release tag to sync to (default: latest dsh-v* tag)
  PATCH_DIR         Directory holding the layers (default: script directory)
  PATCH_GLOB        Layer filename pattern, no slash (default: dsh_*.patch)
  PATCHES           Whitespace-separated layer list; replaces discovery
EOF
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

info() {
    printf '==> %s\n' "$*"
}

cleanup() {
    local status=$?
    if ((WORKTREE_CREATED)); then
        git worktree remove --force "$WORKTREE" >/dev/null 2>&1 \
            || printf '[WARN] could not remove temporary worktree: %s\n' "$WORKTREE" >&2
    fi
    if ((${#TMP_FILES[@]} > 0)); then
        rm -f -- "${TMP_FILES[@]}"
    fi
    trap - EXIT
    exit "$status"
}
trap cleanup EXIT

absolute_path() {
    local path=$1
    if [[ "$path" = /* ]]; then
        printf '%s\n' "$path"
    else
        printf '%s/%s\n' "$PWD" "$path"
    fi
}

EXPLICIT_PATCHES=()
if [[ -n "${PATCHES:-}" ]]; then
    read -r -a EXPLICIT_PATCHES <<<"$PATCHES"
fi
PATCH_LAYERS=()

# Name the layers to regenerate: explicit list as given, else sorted discovery.
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
        --check)
            MODE=check
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
        *)
            die "unknown argument: $1"
            ;;
    esac
done

resolve_patch_layers
info "$MODE: ${#PATCH_LAYERS[@]} patch layer(s)"
for layer in "${PATCH_LAYERS[@]}"; do
    printf '      %s\n' "$layer"
done

REPO_DIR=$(git -C "$REPO_DIR" rev-parse --show-toplevel 2>/dev/null) \
    || die "not a git repository: $REPO_DIR"
cd "$REPO_DIR"

BRANCH=$(git symbolic-ref --quiet --short HEAD) \
    || die "refusing to sync a detached HEAD; check out a branch first"

if git remote get-url "$REMOTE" >/dev/null 2>&1; then
    FETCH_SOURCE=$REMOTE
elif [[ "$REMOTE" = upstream ]]; then
    FETCH_SOURCE=$UPSTREAM_URL
    info "fetching upstream directly ($UPSTREAM_URL)"
else
    die "git remote not found: $REMOTE"
fi

[[ "$RELEASE_REF" != /* && "$RELEASE_REF" != *..* ]] \
    || die "RELEASE_REF must be a tag name, not a path or revision range: $RELEASE_REF"

if [[ "$RELEASE_REF" = latest ]]; then
    info 'finding latest dsh-v* release tag'
    RELEASE_REF=$(git ls-remote --refs --tags --sort='version:refname' "$FETCH_SOURCE" 'refs/tags/dsh-v*' \
        | awk -F/ 'NF >= 3 { tag = $NF; if (tag !~ /\^\{\}$/) latest = tag } END { if (latest != "") print latest }')
    [[ -n "$RELEASE_REF" ]] || die "no dsh-v* release tags found on $FETCH_SOURCE"
fi

[[ "$RELEASE_REF" == dsh-v* ]] || die "RELEASE_REF must start with dsh-v: $RELEASE_REF"

info "fetching $FETCH_SOURCE tag $RELEASE_REF"
git fetch --prune --force "$FETCH_SOURCE" \
    "refs/tags/$RELEASE_REF:refs/tags/$RELEASE_REF"
RELEASE_COMMIT=$(git rev-parse --verify "refs/tags/$RELEASE_REF^{commit}") \
    || die "fetched tag does not resolve to a commit: $RELEASE_REF"

if git merge-base --is-ancestor "$RELEASE_COMMIT" HEAD; then
    info "$RELEASE_REF ($RELEASE_COMMIT) is already contained in $BRANCH"
fi

# DERIVE_REF is the tree the layers are the difference from. In sync mode it is
# HEAD after the merge; in check mode it is the tree a real merge would produce,
# so nothing is mutated while still deriving from the merged result.
DERIVE_REF=HEAD
if [[ "$MODE" = check ]]; then
    info "merge check: $BRANCH <- $RELEASE_REF ($RELEASE_COMMIT)"
    merge_probe=$(mktemp)
    TMP_FILES+=("$merge_probe")
    if git merge-tree --write-tree --name-only "$BRANCH" "$RELEASE_COMMIT" >"$merge_probe" 2>&1; then
        DERIVE_REF=$(head -n 1 "$merge_probe")
        info "merge would succeed without conflicts"
    else
        info "WARNING: merge would conflict; layers are derived from $BRANCH instead"
    fi
else
    if ! git diff --quiet || ! git diff --cached --quiet; then
        die "working tree is dirty; commit or stash before syncing"
    fi
    info "merging $RELEASE_REF into $BRANCH"
    if ! git merge --no-edit "$RELEASE_COMMIT"; then
        git merge --abort >/dev/null 2>&1 || true
        die "merge of $RELEASE_REF conflicted and was aborted; run 'git merge $RELEASE_REF' to resolve it, then re-run this script"
    fi
    DERIVE_REF=HEAD
fi

# The paths a layer covers come from the layer itself, so extending a downstream
# change to another file means extending the layer once; later syncs derive it.
layer_paths() {
    git apply --numstat -- "$1" 2>/dev/null | awk -F'\t' 'NF >= 3 { print $3 }'
}

# Regenerate one layer as the branch's difference from the release for the paths
# that layer already covers. An empty result retires the layer.
regenerate_layer() {
    local layer=$1 out=$2
    local -a paths=()
    mapfile -t paths < <(layer_paths "$layer")
    if ((${#paths[@]} == 0)); then
        : >"$out"
        return 0
    fi
    git diff --no-color --no-ext-diff "$RELEASE_COMMIT" "$DERIVE_REF" -- "${paths[@]}" >"$out"
}

# Prove every regenerated layer still applies to a pristine release checkout.
verify_layers() {
    local -a regenerated=("$@")
    local layer
    info "verifying regenerated layers against $RELEASE_REF"
    WORKTREE=$(mktemp -d "${TMPDIR:-/tmp}/dsh-sync-verify.XXXXXX")
    rmdir "$WORKTREE"
    git worktree add --detach "$WORKTREE" "$RELEASE_COMMIT" >/dev/null
    WORKTREE_CREATED=1
    for layer in "${regenerated[@]}"; do
        if [[ ! -s "$layer" ]]; then
            printf '[skip]  %s: empty layer (no downstream difference remains)\n' "$layer"
            continue
        fi
        git -C "$WORKTREE" apply --check "$layer" \
            || die "regenerated layer does not apply to $RELEASE_REF: $layer"
        git -C "$WORKTREE" apply "$layer"
        printf '[apply] %s\n' "$layer"
    done
    git worktree remove --force "$WORKTREE"
    WORKTREE_CREATED=0
}

STAGED_LAYERS=()
index=0
for layer in "${PATCH_LAYERS[@]}"; do
    staged="${layer}.sync-staged.$$.$index"
    TMP_FILES+=("$staged")
    regenerate_layer "$layer" "$staged"
    STAGED_LAYERS+=("$staged")
    index=$((index + 1))
done

verify_layers "${STAGED_LAYERS[@]}"

if [[ "$MODE" = check ]]; then
    info "check complete; nothing changed"
    exit 0
fi

CHANGED=()
for staged in "${STAGED_LAYERS[@]}"; do
    original=${staged%%.sync-staged.*}
    if cmp -s "$staged" "$original"; then
        printf '[layer] unchanged %s\n' "$original"
    else
        cp -- "$staged" "$original"
        CHANGED+=("$original")
        printf '[layer] regenerated %s\n' "$original"
    fi
done

if ((${#CHANGED[@]} > 0)); then
    git add -- "${CHANGED[@]}"
    git commit -m "chore: sync downstream to $RELEASE_REF"
    info "committed regenerated layers for $RELEASE_REF"
else
    info "no layer changed; $BRANCH is already in sync with $RELEASE_REF"
fi

info "sync complete for $RELEASE_REF ($RELEASE_COMMIT); push when ready"
