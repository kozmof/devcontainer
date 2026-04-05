#!/bin/bash
# Verifies that safe-chain, Takumi Guard, and Island are installed and working.
# Run inside the devcontainer as the dev user after postCreateCommand completes.
set -uo pipefail
IFS=$'\n\t'

PASSES=0
FAILS=0
WARNS=0

pass() { echo "[PASS] $*"; PASSES=$((PASSES + 1)); }
fail() { echo "[FAIL] $*" >&2; FAILS=$((FAILS + 1)); }
warn() { echo "[WARN] $*"; WARNS=$((WARNS + 1)); }

# ---------------------------------------------------------------------------
# Safe-chain
# ---------------------------------------------------------------------------
check_safe_chain() {
    echo ""
    echo "==> safe-chain"

    # safe-chain installs to ~/.safe-chain/bin/ and adds it to PATH via .bashrc.
    # When the script runs under sh (no .bashrc), fall back to the known install path.
    local bin
    if bin=$(command -v safe-chain 2>/dev/null); then
        pass "binary found: $bin"
    elif [[ -x "$HOME/.safe-chain/bin/safe-chain" ]]; then
        bin="$HOME/.safe-chain/bin/safe-chain"
        pass "binary found: $bin (not on PATH — .bashrc not sourced)"
    else
        fail "safe-chain not found (checked PATH and $HOME/.safe-chain/bin/)"
        return
    fi

    if safe-chain --version >/dev/null 2>&1 || safe-chain --help >/dev/null 2>&1; then
        pass "binary responds"
    else
        fail "safe-chain does not respond (exit $?)"
    fi

    # safe-chain-verify checks that the hook is registered in npm's config.
    # Run it in an interactive bash subshell so .bashrc is sourced — safe-chain's
    # npm command registration is only visible in the interactive environment.
    local verify_out
    verify_out=$(bash -i -c "npm safe-chain-verify" 2>&1)
    if echo "$verify_out" | grep -q "OK"; then
        pass "npm safe-chain-verify OK (hook registered)"
    else
        fail "npm safe-chain-verify failed: $verify_out"
    fi
}

# ---------------------------------------------------------------------------
# Takumi Guard
# ---------------------------------------------------------------------------
check_takumi_guard() {
    echo ""
    echo "==> Takumi Guard"

    # The registry is set in ~/.npmrc (copied from .devcontainer/.npmrc at build time).
    local npmrc="$HOME/.npmrc"
    if grep -q "^registry=https://npm.flatt.tech/" "$npmrc" 2>/dev/null; then
        pass "npm registry configured: https://npm.flatt.tech/ (in $npmrc)"
    else
        fail "registry=https://npm.flatt.tech/ not found in $npmrc"
    fi

    # Any HTTP response (including 4xx) means the endpoint is up.
    local http_code
    http_code=$(wget --timeout=5 --server-response -qO- https://npm.flatt.tech/ 2>&1 | awk '/HTTP\//{code=$2} END{print code+0}')

    if [[ "${http_code:-0}" -gt 0 ]]; then
        pass "npm.flatt.tech reachable (HTTP $http_code)"
    else
        fail "npm.flatt.tech not reachable (network or firewall issue)"
    fi
}

# ---------------------------------------------------------------------------
# Island
# ---------------------------------------------------------------------------
check_island() {
    echo ""
    echo "==> Island"

    local bin
    if bin=$(command -v island 2>/dev/null); then
        pass "binary found: $bin"
    else
        fail "island not found on PATH"
        return
    fi

    if island --version >/dev/null 2>&1; then
        pass "binary responds"
    else
        fail "island does not respond (exit $?)"
    fi

    # Profile directories
    local profile_base
    profile_base="$(cd "$(dirname "$0")/../island/profiles" 2>/dev/null && pwd)" || true

    if [[ -z "$profile_base" ]]; then
        # Fall back to a path relative to the workspace
        profile_base="/workspace/.devcontainer/island/profiles"
    fi

    for profile in claude-code npm-workspace pnpm-workspace git-workspace; do
        if [[ -d "$profile_base/$profile" ]]; then
            pass "profile present: $profile"
        else
            fail "profile missing: $profile (looked in $profile_base)"
        fi
    done

    # Shims
    local git_path npm_path pnpm_path
    git_path=$(command -v git 2>/dev/null || true)
    npm_path=$(command -v npm 2>/dev/null || true)
    pnpm_path=$(command -v pnpm 2>/dev/null || true)

    if grep -q "island" "$git_path" 2>/dev/null; then
        pass "git shim uses island ($git_path)"
    else
        fail "git at '$git_path' does not appear to be the island shim"
    fi

    if grep -q "island" "$npm_path" 2>/dev/null; then
        pass "npm shim uses island ($npm_path)"
    else
        fail "npm at '$npm_path' does not appear to be the island shim"
    fi

    if grep -q "island" "$pnpm_path" 2>/dev/null; then
        pass "pnpm shim uses island ($pnpm_path)"
    else
        fail "pnpm at '$pnpm_path' does not appear to be the island shim"
    fi

    # claude alias
    local aliases_file="$HOME/.bash_aliases"
    if grep -q "island run -p claude-code" "$aliases_file" 2>/dev/null || \
       grep -q "island run -p claude-code" "$HOME/.bashrc" 2>/dev/null; then
        pass "claude alias uses island"
    else
        fail "claude alias not found or does not reference island (checked $aliases_file and ~/.bashrc)"
    fi

    # Sandbox enforcement tests.
    # sandbox_blocks: the command must fail inside the profile (path is blocked).
    # sandbox_allows: the command must succeed inside the profile (path is allowed).
    sandbox_blocks() {
        local profile="$1"; shift
        if island run -p "$profile" -- "$@" >/dev/null 2>&1; then
            fail "sandbox ($profile): '$*' succeeded — expected to be blocked"
        else
            pass "sandbox ($profile): '$*' correctly blocked"
        fi
    }
    sandbox_allows() {
        local profile="$1"; shift
        if island run -p "$profile" -- "$@" >/dev/null 2>&1; then
            pass "sandbox ($profile): '$*' correctly allowed"
        else
            fail "sandbox ($profile): '$*' failed — expected to be allowed"
        fi
    }

    # npm-workspace: protects against malicious postinstall hooks
    # Blocked: /opt/scripts, /var/log, /home/dev/.gnupg
    # Allowed: /workspace (project files + npm cache), /tmp
    sandbox_blocks npm-workspace ls /opt/scripts
    sandbox_blocks npm-workspace ls /var/log
    sandbox_allows npm-workspace ls /workspace
    sandbox_allows npm-workspace ls /tmp

    # pnpm-workspace: same threat model as npm-workspace
    # Blocked: /opt/scripts, /var/log, /home/dev/.gnupg
    # Allowed: /workspace (project files + pnpm store), /tmp
    sandbox_blocks pnpm-workspace ls /opt/scripts
    sandbox_blocks pnpm-workspace ls /var/log
    sandbox_allows pnpm-workspace ls /workspace
    sandbox_allows pnpm-workspace ls /tmp

    # git-workspace: protects against compromised git hooks
    # Blocked: /opt/scripts, /var/log, /home/dev/.npmrc (unlike npm-workspace)
    # Allowed: /workspace (git repos), /tmp (SSH_AUTH_SOCK lives here)
    sandbox_blocks git-workspace ls /opt/scripts
    sandbox_blocks git-workspace ls /var/log
    sandbox_allows git-workspace ls /workspace
    sandbox_allows git-workspace ls /tmp

    # claude-code: isolates Claude CLI from sensitive config and firewall scripts
    # Blocked: /opt/scripts, /var/log, /home/dev/.npmrc
    # Allowed: /workspace (user projects), /tmp
    sandbox_blocks claude-code ls /opt/scripts
    sandbox_blocks claude-code ls /var/log
    sandbox_allows claude-code ls /workspace
    sandbox_allows claude-code ls /tmp
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
check_safe_chain
check_takumi_guard
check_island

echo ""
echo "==> Summary: $PASSES passed, $FAILS failed, $WARNS warnings"

[[ "$FAILS" -eq 0 ]]
