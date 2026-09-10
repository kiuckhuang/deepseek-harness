#!/usr/bin/env bash
set -Eeuo pipefail

# Give this machine a usable sandbox runner so the harness can enforce the
# confined modes instead of failing closed with SANDBOX_UNAVAILABLE. Linux needs
# bubblewrap; macOS and Windows already ship a runner, so the probes still run
# but nothing is installed. The harness needs a restart afterwards because the
# runner verdict is cached for the life of the server process.

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

info() {
    printf '==> %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

SUDO=
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    SUDO=sudo
fi

# One runner argv per platform, matching packages/sandbox/sandbox-local so the
# probe here answers the same question the harness asks.
probe_runner() {
    case $(uname -s) in
        Linux) printf 'bwrap\n' ;;
        Darwin) printf 'sandbox-exec\n' ;;
        *) printf '\n' ;;
    esac
}

install_bwrap() {
    if command -v bwrap >/dev/null 2>&1; then
        info "bubblewrap already present: $(bwrap --version)"
        return 0
    fi

    info 'bubblewrap is missing; installing it'
    if command -v dnf >/dev/null 2>&1; then
        $SUDO dnf install -y bubblewrap
    elif command -v apt-get >/dev/null 2>&1; then
        $SUDO apt-get update
        $SUDO apt-get install -y bubblewrap
    elif command -v pacman >/dev/null 2>&1; then
        $SUDO pacman -S --noconfirm bubblewrap
    elif command -v zypper >/dev/null 2>&1; then
        $SUDO zypper --non-interactive install bubblewrap
    elif command -v apk >/dev/null 2>&1; then
        $SUDO apk add bubblewrap
    else
        die 'no supported package manager found (dnf, apt-get, pacman, zypper, apk)'
    fi

    command -v bwrap >/dev/null 2>&1 \
        || die 'bubblewrap is still not on PATH after the install'
}

# Prove the profile both launches and actually confines: a write outside the
# workspace must be refused. A launcher that merely starts is not evidence.
verify_runner() {
    local runner
    runner=$(probe_runner)

    if [ -z "$runner" ]; then
        warn "no install step for $(uname -s); the harness uses its platform runner"
        return 0
    fi

    command -v "$runner" >/dev/null 2>&1 \
        || die "$runner is not on PATH; the harness will keep reporting SANDBOX_UNAVAILABLE"

    if [ "$runner" = bwrap ]; then
        local -a base=(--ro-bind / / --dev /dev --unshare-pid --proc /proc --die-with-parent)
        local workspace=$REPO_DIR
        local escape=$HOME/.dsh-sandbox-escape-check

        bwrap "${base[@]}" -- true >/dev/null 2>&1 \
            || die 'bwrap cannot create a read-only profile on this host (check user namespaces)'
        info 'read-only profile: OK'

        bwrap "${base[@]}" --tmpfs /tmp --bind "$workspace" "$workspace" -- true >/dev/null 2>&1 \
            || die 'bwrap cannot create a workspace-write profile on this host'
        info 'workspace-write profile: OK'

        rm -f "$escape"
        if bwrap "${base[@]}" --tmpfs /tmp --bind "$workspace" "$workspace" \
            -- bash -c "echo escape > '$escape'" >/dev/null 2>&1; then
            rm -f "$escape"
            die 'bwrap launched but did not confine: a write outside the workspace succeeded'
        fi
        info 'enforcement: a write outside the workspace is refused'
    else
        info "$runner present; the harness will probe it at the first confined call"
    fi
}

case $(uname -s) in
    Linux)
        install_bwrap
        ;;
    *)
        info "$(uname -s) ships its own sandbox runner; nothing to install"
        ;;
esac

cd "$REPO_DIR"
verify_runner

info 'sandbox runner is usable; restart dsh so the cached verdict is re-probed'
