#!/bin/bash

if [ -z "${BASH_VERSION:-}" ]; then
    exec /bin/bash "$0" "$@"
fi
# Verifies that safe-chain, Takumi Guard, and Island are installed and working.
# Run inside the devcontainer as the dev user after postCreateCommand completes.
set -uo pipefail
IFS=$'\n\t'

PASSES=0
FAILS=0
WARNS=0
NESTED_SANDBOX=0

pass() { echo "[PASS] $*"; PASSES=$((PASSES + 1)); }
fail() { echo "[FAIL] $*" >&2; FAILS=$((FAILS + 1)); }
warn() { echo "[WARN] $*"; WARNS=$((WARNS + 1)); }

# Landlock restrictions are inherited and cannot be relaxed. If this script is
# launched by an already-sandboxed agent, broader profile allow-tests and
# Safe-chain checks can produce false failures because the parent policy wins.
if ! ls /var/log >/dev/null 2>&1; then
    NESTED_SANDBOX=1
    warn "existing filesystem sandbox detected; parent-denied positive-access checks will be skipped"
fi

format_command() {
    local formatted
    printf -v formatted '%q ' "$@"
    printf '%s' "${formatted% }"
}


# ---------------------------------------------------------------------------
# Safe-chain
# ---------------------------------------------------------------------------
check_safe_chain() {
    echo ""
    echo "==> safe-chain"

    if [[ "$NESTED_SANDBOX" -eq 1 ]]; then
        warn "safe-chain execution skipped inside an existing agent sandbox"
        return
    fi

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

    if "$bin" --version >/dev/null 2>&1 || "$bin" --help >/dev/null 2>&1; then
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

    # Public registry policy is installed as a root-owned system npmrc.
    local npmrc="/etc/npmrc"
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
# Takumi Guard (Go)
# ---------------------------------------------------------------------------
check_takumi_guard_golang() {
    echo ""
    echo "==> Takumi Guard (Go)"

    # Skip gracefully on non-Go containers (shared script).
    local go_bin=/usr/local/go/bin/go
    if [[ ! -x "$go_bin" ]]; then
        echo "    go not installed — skipped"
        return
    fi

    # Read GOPROXY directly from the real binary to avoid the island shim.
    local proxy
    proxy=$("$go_bin" env GOPROXY 2>/dev/null || true)
    if [[ "$proxy" == "https://golang.flatt.tech" ]]; then
        pass "GOPROXY configured: $proxy"
    else
        fail "GOPROXY is '$proxy' — expected https://golang.flatt.tech (no ,direct fallback)"
    fi

    # Any HTTP response (including 4xx) means the endpoint is up.
    local http_code
    http_code=$(wget --timeout=5 --server-response -qO- https://golang.flatt.tech/ 2>&1 | awk '/HTTP\//{code=$2} END{print code+0}')
    if [[ "${http_code:-0}" -gt 0 ]]; then
        pass "golang.flatt.tech reachable (HTTP $http_code)"
    else
        fail "golang.flatt.tech not reachable (network or firewall issue)"
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

    # Profiles and enforcement assets
    local profile_base="/etc/island/profiles"
    local profile protected_path

    for profile in claude-code codex herdr npm-workspace pnpm-workspace git-workspace go-workspace cargo-workspace zig-workspace; do
        if [[ -d "$profile_base/$profile" ]]; then
            pass "profile present: $profile"
        else
            fail "profile missing: $profile (looked in $profile_base)"
        fi
    done

    for protected_path in /etc/island /usr/local/share/npm-global /usr/local/bin/island; do
        if [[ -e "$protected_path" ]] && [[ "$(stat -c %U "$protected_path" 2>/dev/null)" == "root" ]] && [[ ! -w "$protected_path" ]]; then
            pass "enforcement asset is root-owned and not writable: $protected_path"
        else
            fail "enforcement asset is missing or writable by dev: $protected_path"
        fi
    done

    # Shims
    local git_path npm_path pnpm_path
    git_path=$(command -v git 2>/dev/null || true)
    # Use type -P to resolve files, bypassing safe-chain shell functions.
    npm_path=$(type -P npm 2>/dev/null || true)
    pnpm_path=$(type -P pnpm 2>/dev/null || true)

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

    # claude shim — protects terminal and script invocations of claude.
    # Note: the VS Code extension uses its own bundled native binary and does not
    # go through this shim; island sandboxing does not apply to the extension.
    #
    # claude may be installed as either a shim file or a shell alias
    # (e.g. alias claude='island run -p claude-code -- ...').  Handle both:
    # check the alias/function definition first, then fall back to the file.
    local claude_ref
    claude_ref=$(command -v claude 2>/dev/null || true)
    if echo "$claude_ref" | grep -q "island run -p claude-code"; then
        pass "claude shim uses island (alias)"
    elif grep -q "island run -p claude-code" "$claude_ref" 2>/dev/null; then
        pass "claude shim uses island ($claude_ref)"
    else
        fail "claude at '$claude_ref' does not appear to be the island shim"
    fi

    # codex shim — protects terminal and script invocations of codex.
    # Same caveat as above: may be a file shim or a shell alias.
    local codex_ref
    codex_ref=$(command -v codex 2>/dev/null || true)
    if echo "$codex_ref" | grep -q "island run -p codex"; then
        pass "codex shim uses island (alias)"
    elif grep -q "island run -p codex" "$codex_ref" 2>/dev/null; then
        pass "codex shim uses island ($codex_ref)"
    else
        fail "codex at '$codex_ref' does not appear to be the island shim"
    fi

    # herdr shim — always installed; the underlying binary only exists when the
    # image was built with INSTALL_HERDR=true.  Same alias/file handling as above.
    local herdr_ref
    herdr_ref=$(command -v herdr 2>/dev/null || true)
    if echo "$herdr_ref" | grep -q "island run -p herdr"; then
        pass "herdr shim uses island (alias)"
    elif grep -q "island run -p herdr" "$herdr_ref" 2>/dev/null; then
        pass "herdr shim uses island ($herdr_ref)"
    else
        fail "herdr at '$herdr_ref' does not appear to be the island shim"
    fi

    if [[ -x /opt/herdr/bin/herdr ]]; then
        if [[ "$(stat -c %U /opt/herdr/bin/herdr 2>/dev/null)" == "root" ]] && [[ ! -w /opt/herdr/bin/herdr ]]; then
            pass "herdr binary is root-owned and not writable: /opt/herdr/bin/herdr"
        else
            fail "herdr binary is writable or missing: /opt/herdr/bin/herdr"
        fi
    fi

    if [[ -x /opt/rust/bin/cargo ]]; then
        local cargo_path rustc_path
        for protected_path in /opt/rust/bin/cargo /opt/rust/bin/rustc; do
            if [[ "$(stat -c %U "$protected_path" 2>/dev/null)" == "root" ]] && [[ ! -w "$protected_path" ]]; then
                pass "Rust toolchain is root-owned and not writable: $protected_path"
            else
                fail "Rust toolchain asset is writable or missing: $protected_path"
            fi
        done

        cargo_path=$(type -P cargo 2>/dev/null || true)
        rustc_path=$(type -P rustc 2>/dev/null || true)
        if grep -q "island run -p cargo-workspace" "$cargo_path" 2>/dev/null; then
            pass "cargo shim uses island ($cargo_path)"
        else
            fail "cargo at '$cargo_path' does not use the cargo-workspace profile"
        fi
        if grep -q "island run -p cargo-workspace" "$rustc_path" 2>/dev/null; then
            pass "rustc shim uses island ($rustc_path)"
        else
            fail "rustc at '$rustc_path' does not use the cargo-workspace profile"
        fi
    fi


    # Sandbox enforcement tests.
    # sandbox_blocks: the command must fail inside the profile (path is blocked).
    # sandbox_allows: the command must succeed inside the profile (path is allowed).
    sandbox_blocks() {
        local profile="$1"; shift
        local command_text
        command_text=$(format_command "$@")
        if XDG_CONFIG_HOME=/etc island run -p "$profile" -- "$@" >/dev/null 2>&1; then
            fail "sandbox ($profile): '$command_text' succeeded — expected to be blocked"
        else
            pass "sandbox ($profile): '$command_text' correctly blocked"
        fi
    }
    sandbox_allows() {
        local profile="$1"; shift
        local command_text
        command_text=$(format_command "$@")
        if XDG_CONFIG_HOME=/etc island run -p "$profile" -- "$@" >/dev/null 2>&1; then
            pass "sandbox ($profile): '$command_text' correctly allowed"
        else
            fail "sandbox ($profile): '$command_text' failed — expected to be allowed"
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

    # cargo-workspace: protects Cargo build scripts, proc macros, rustfmt,
    # clippy, and tests.  Also checks that the agents can actually reach the
    # toolchain, which is a separate failure mode (see the overlay note below).
    if [[ -x /opt/rust/bin/cargo ]]; then
        sandbox_blocks cargo-workspace ls /opt/scripts
        sandbox_blocks cargo-workspace ls /var/log
        sandbox_allows cargo-workspace ls /workspace
        if cargo --version >/dev/null 2>&1 && rustc --version >/dev/null 2>&1 &&
           cargo fmt --version >/dev/null 2>&1 && cargo clippy --version >/dev/null 2>&1; then
            pass "sandboxed Rust toolchain, rustfmt, and clippy respond"
        else
            fail "sandboxed Rust toolchain, rustfmt, or clippy does not respond"
        fi

        # Landlock domains nest by intersection, so an agent that cannot execute
        # /opt/rust cannot spawn cargo no matter what cargo-workspace allows.
        # This is the failure the profiles-rust/ overlay exists to prevent.
        for profile in claude-code codex; do
            sandbox_allows "$profile" /opt/rust/bin/rustc --version
        done
        if [[ -x /opt/herdr/bin/herdr ]]; then
            sandbox_allows herdr /opt/rust/bin/rustc --version
        fi

        # rust-toolchain.toml is honoured by rustup, which this image does not
        # ship — cargo silently uses the baked-in toolchain instead.  A mismatch
        # is a real footgun, so surface it rather than letting it pass unseen.
        local toolchain_file=/workspace/rust-toolchain.toml
        [[ -f /workspace/rust-toolchain ]] && toolchain_file=/workspace/rust-toolchain
        if [[ -f "$toolchain_file" ]]; then
            local wanted installed
            wanted=$(grep -oE 'channel[[:space:]]*=[[:space:]]*"[^"]+"' "$toolchain_file" 2>/dev/null |
                     head -1 | sed -E 's/.*"([^"]+)".*/\1/')
            installed=$(/opt/rust/bin/rustc --version 2>/dev/null | awk '{print $2}')
            if [[ -z "$wanted" ]]; then
                pass "$toolchain_file pins no explicit channel"
            elif [[ "$wanted" == "$installed" ]]; then
                pass "rust-toolchain channel matches the image: $installed"
            else
                warn "$toolchain_file asks for '$wanted' but the image ships $installed — no rustup here, so the request is ignored (rebuild with --build-arg RUST_VERSION=$wanted and its RUST_SHA512)"
            fi
        fi
    fi

    # zig-workspace: protects against code executed by `zig build` — build.zig
    # itself, build steps, generators, and test binaries.  Skipped unless the
    # image actually ships Zig (Dockerfile.withZig).
    if [[ -x /usr/local/zig/zig ]]; then
        if [[ "$(stat -c %U /usr/local/zig/zig 2>/dev/null)" == "root" ]] && [[ ! -w /usr/local/zig/zig ]]; then
            pass "Zig toolchain is root-owned and not writable: /usr/local/zig/zig"
        else
            fail "Zig toolchain asset is writable or missing: /usr/local/zig/zig"
        fi

        local zig_path
        zig_path=$(type -P zig 2>/dev/null || true)
        if grep -q "island run -p zig-workspace" "$zig_path" 2>/dev/null; then
            pass "zig shim uses island ($zig_path)"
        else
            fail "zig at '$zig_path' does not use the zig-workspace profile"
        fi

        sandbox_blocks zig-workspace ls /opt/scripts
        sandbox_blocks zig-workspace ls /var/log
        sandbox_allows zig-workspace ls /workspace
        sandbox_allows zig-workspace ls /tmp

        if zig version >/dev/null 2>&1; then
            pass "sandboxed Zig toolchain responds"
        else
            fail "sandboxed Zig toolchain does not respond"
        fi

        # Landlock domains nest by intersection, so an agent that cannot execute
        # the toolchain cannot spawn zig no matter what zig-workspace allows.
        # /usr/local/zig is covered by the agents' existing /usr grant, which is
        # why this image needs no profiles-zig/ overlay — assert that it holds.
        for profile in claude-code codex; do
            sandbox_allows "$profile" /usr/local/zig/zig version
        done
        if [[ -x /opt/herdr/bin/herdr ]]; then
            sandbox_allows herdr /usr/local/zig/zig version
        fi
    fi

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

    # codex: isolates Codex CLI from sensitive config and firewall scripts
    # Blocked: /opt/scripts, /var/log, /home/dev/.npmrc
    # Allowed: /workspace (user projects), /tmp
    sandbox_blocks codex ls /opt/scripts
    sandbox_blocks codex ls /var/log
    sandbox_allows codex ls /workspace
    sandbox_allows codex ls /tmp
    # The profile points CODEX_HOME here and codex refuses to start when the
    # directory is missing (it does not create it).
    sandbox_allows codex ls /home/dev/.island/codex/config/codex

    # herdr: isolates the agent-multiplexer from sensitive config and firewall
    # scripts.  The profile is always present, so these run even when the
    # herdr binary itself was not installed (INSTALL_HERDR=false).
    # Blocked: /opt/scripts, /var/log, /home/dev/.ssh
    # Allowed: /workspace, /tmp, /home/dev/.island (nested agent state)
    sandbox_blocks herdr ls /opt/scripts
    sandbox_blocks herdr ls /var/log
    sandbox_allows herdr ls /workspace
    sandbox_allows herdr ls /tmp
    if [[ "$NESTED_SANDBOX" -eq 1 ]]; then
        warn "herdr positive-access checks skipped because the parent sandbox is narrower"
        return
    fi
    sandbox_allows herdr ls /home/dev/.island
    # Forked descendants must be able to read their own /proc/<pid> — a
    # /proc/self grant binds to the island process's pid only, and Claude
    # Code aborts if /proc/self/cgroup is unreadable.  'true;' forces the
    # shell to fork rather than exec, so cat runs under a different pid.
    sandbox_allows herdr sh -c "true; cat /proc/self/cgroup"
    sandbox_allows herdr sh -c "true; cat /home/dev/.bashrc"
    sandbox_allows herdr sh -c "true; cat /home/dev/.safe-chain/scripts/init-posix.sh"
    # Safe-chain (Aikido) writes scan state to ~/.aikido when wrapping
    # npm/pnpm inside pane shells
    sandbox_allows herdr sh -c "true; touch /home/dev/.aikido/.preflight && rm /home/dev/.aikido/.preflight"
    if [[ -x /opt/herdr/bin/herdr ]]; then
        if XDG_CONFIG_HOME=/etc island run -p herdr -- /opt/herdr/bin/herdr --version >/dev/null 2>&1; then
            pass "sandboxed herdr responds"
        else
            fail "sandboxed herdr does not respond"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
check_safe_chain
check_takumi_guard
check_takumi_guard_golang
check_island

echo ""
echo "==> Summary: $PASSES passed, $FAILS failed, $WARNS warnings"

[[ "$FAILS" -eq 0 ]]
