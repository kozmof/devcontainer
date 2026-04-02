#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

WHITELIST="${FIREWALL_WHITELIST:-/opt/scripts/extra-whitelist.conf}"
SET="allowed-net"
TMP_SET="${SET}-next"
STATUS_FILE="/var/log/firewall-status.txt"

SERVICE_DOMAINS=(
    "api.anthropic.com"
    "statsig.anthropic.com"
    "statsig.com"
    "sentry.io"
    "registry.npmjs.org"
    "marketplace.visualstudio.com"
    "vscode.blob.core.windows.net"
    "update.code.visualstudio.com"
)

GITHUB_FALLBACK_DOMAINS=(
    "github.com"
    "api.github.com"
    "codeload.github.com"
    "raw.githubusercontent.com"
    "objects.githubusercontent.com"
)

WARNINGS=0
BUILD_DYNAMIC_SUCCESSES=0
BUILD_TOTAL_ENTRIES=0

log() {
    echo "[firewall] $*"
}

warn() {
    WARNINGS=$((WARNINGS + 1))
    echo "[firewall] WARNING: $*" >&2
}

validate_ip() {
    local ip="$1"
    local octet

    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

    IFS=. read -r -a octets <<< "$ip"
    [[ "${#octets[@]}" -eq 4 ]] || return 1

    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
        ((10#$octet >= 0 && 10#$octet <= 255)) || return 1
    done
}

validate_cidr() {
    local cidr="$1"
    local ip="${cidr%/*}"
    local prefix="${cidr#*/}"

    [[ "$cidr" == */* ]] || return 1
    validate_ip "$ip" || return 1
    [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
    ((prefix >= 0 && prefix <= 32)) || return 1
}

set_entry_count() {
    local set_name="$1"

    ipset list -t "$set_name" 2>/dev/null | awk '/^Number of entries:/ { print $4; exit }'
}

add_entry_to_set() {
    local set_name="$1"
    local entry="$2"
    local label="$3"

    if ipset test "$set_name" "$entry" >/dev/null 2>&1; then
        return 0
    fi

    if ipset add "$set_name" "$entry" >/dev/null 2>&1; then
        return 0
    fi

    warn "failed to add $label ($entry) to $set_name"
    return 1
}

add_ip_to_set() {
    local set_name="$1"
    local entry="$2"

    if validate_ip "$entry" || validate_cidr "$entry"; then
        add_entry_to_set "$set_name" "$entry" "whitelist entry"
    else
        warn "invalid IP/CIDR, skipping: $entry"
        return 1
    fi
}

add_domain_to_set() {
    local set_name="$1"
    local domain="$2"
    local label="$3"
    local dynamic="${4:-false}"
    local added=0
    local ip
    local -a resolved_ips=()
    # Only A records; AAAA records are intentionally ignored because the ipset is
    # IPv4-only (family inet) and IPv6 outbound is fully blocked at the ip6tables level.
    mapfile -t resolved_ips < <(dig +short A "$domain" 2>/dev/null | awk 'NF' | sort -u)

    if [[ "${#resolved_ips[@]}" -eq 0 ]]; then
        warn "failed to resolve $label ($domain)"
        return 1
    fi

    for ip in "${resolved_ips[@]}"; do
        if ! validate_ip "$ip"; then
            warn "unexpected value resolving $label ($domain): $ip"
            continue
        fi

        if add_entry_to_set "$set_name" "$ip" "$label"; then
            added=1
        fi
    done

    if [[ "$added" -eq 0 ]]; then
        warn "resolved $label ($domain) but no usable IPv4 addresses were added"
        return 1
    fi

    if [[ "$dynamic" == "true" ]]; then
        BUILD_DYNAMIC_SUCCESSES=$((BUILD_DYNAMIC_SUCCESSES + 1))
    fi
}

add_github_ranges() {
    local set_name="$1"
    local gh_meta
    local added=0
    local cidr

    log "Fetching GitHub IP ranges..."

    if ! gh_meta=$(wget -qO- https://api.github.com/meta 2>/dev/null); then
        warn "failed to fetch GitHub IP ranges; using DNS fallback entries instead"
        return 1
    fi

    if ! echo "$gh_meta" | jq -e '.web and .api and .git and .packages' >/dev/null 2>&1; then
        warn "GitHub API response missing expected fields; using DNS fallback entries instead"
        return 1
    fi

    while IFS= read -r cidr; do
        [[ -z "$cidr" ]] && continue
        if ! validate_cidr "$cidr"; then
            warn "unexpected value from GitHub meta: $cidr"
            continue
        fi
        if add_entry_to_set "$set_name" "$cidr" "GitHub metadata range"; then
            added=1
        fi
    done < <(echo "$gh_meta" | jq -r '(.web + .api + .git + .packages)[]' 2>/dev/null | sort -u)

    if [[ "$added" -eq 0 ]]; then
        warn "GitHub metadata response did not yield any usable CIDRs"
        return 1
    fi

    BUILD_DYNAMIC_SUCCESSES=$((BUILD_DYNAMIC_SUCCESSES + 1))
}

load_user_whitelist() {
    local set_name="$1"
    local line
    local entry

    [[ -f "$WHITELIST" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        entry=$(printf '%s' "$line" | sed 's/#.*//' | tr -d ' \t\r')
        [[ -z "$entry" ]] && continue

        if validate_ip "$entry" || validate_cidr "$entry"; then
            add_ip_to_set "$set_name" "$entry" || true
        else
            log "Resolving extra whitelist entry: $entry..."
            add_domain_to_set "$set_name" "$entry" "extra whitelist entry" true || true
        fi
    done < "$WHITELIST"
}

build_allowed_set() {
    local set_name="$1"
    local domain

    BUILD_DYNAMIC_SUCCESSES=0

    ipset create "$set_name" hash:net family inet >/dev/null 2>&1 || true
    ipset flush "$set_name"

    add_github_ranges "$set_name" || true

    for domain in "${GITHUB_FALLBACK_DOMAINS[@]}"; do
        log "Resolving GitHub fallback domain: $domain..."
        add_domain_to_set "$set_name" "$domain" "GitHub fallback domain" true || true
    done

    for domain in "${SERVICE_DOMAINS[@]}"; do
        log "Resolving $domain..."
        add_domain_to_set "$set_name" "$domain" "$domain" true || true
    done

    load_user_whitelist "$set_name"

    BUILD_TOTAL_ENTRIES=$(set_entry_count "$set_name")
    BUILD_TOTAL_ENTRIES="${BUILD_TOTAL_ENTRIES:-0}"

    log "Prepared whitelist set $set_name with $BUILD_TOTAL_ENTRIES entries"
}

capture_docker_dns_rules() {
    iptables-save -t nat 2>/dev/null | grep "127\.0\.0\.11" || true
}

restore_docker_dns_rules() {
    local docker_dns_rules="$1"
    local rule
    local -a rule_parts=()

    if [[ -z "$docker_dns_rules" ]]; then
        log "No Docker DNS rules to restore"
        return
    fi

    log "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true

    while IFS= read -r rule; do
        [[ -z "$rule" ]] && continue
        read -r -a rule_parts <<< "$rule"
        iptables -t nat "${rule_parts[@]}" >/dev/null 2>&1 || true
    done <<< "$docker_dns_rules"
}

detect_host_gateway() {
    local host_ip

    host_ip=$(ip route | awk '/default/ { print $3; exit }')

    if ! validate_ip "$host_ip"; then
        echo "[firewall] ERROR: Failed to detect a valid host gateway IP" >&2
        return 1
    fi

    printf '%s\n' "$host_ip"
}

configure_firewall_rules() {
    local host_ip="$1"

    log "Allowing host gateway: $host_ip"

    iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
    iptables -A INPUT  -p udp --sport 53 -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
    iptables -A INPUT  -p tcp --sport 53 -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
    iptables -A INPUT  -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
    iptables -A INPUT  -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A INPUT  -s "$host_ip" -j ACCEPT
    iptables -A OUTPUT -d "$host_ip" -j ACCEPT

    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT DROP

    iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -m set --match-set "$SET" dst -j ACCEPT
    iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

    # IPv6 is not used in this devcontainer; block it entirely to reduce
    # attack surface and prevent IPv6 as a bypass path for the IPv4-only allowlist.
    ip6tables -F 2>/dev/null || true
    ip6tables -P INPUT DROP 2>/dev/null || true
    ip6tables -P FORWARD DROP 2>/dev/null || true
    ip6tables -P OUTPUT DROP 2>/dev/null || true
    ip6tables -A INPUT -i lo -j ACCEPT 2>/dev/null || true
    ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
    ip6tables -A OUTPUT -j REJECT --reject-with icmp6-adm-prohibited 2>/dev/null || true
}

verify_firewall() {
    log "Verifying firewall behavior..."

    if wget --timeout=4 -qO- https://example.com >/dev/null 2>&1; then
        warn "example.com should be blocked but is reachable"
    else
        log "Blocked example.com - OK"
    fi

    if wget --timeout=5 -qO- https://api.github.com/zen >/dev/null 2>&1; then
        log "Reached api.github.com - OK"
    else
        warn "api.github.com should be reachable but is blocked"
    fi
}

write_status_file() {
    local tmp_file="${STATUS_FILE}.$$"
    local entry_count
    local reject_packets
    local reject_bytes

    entry_count=$(set_entry_count "$SET")
    entry_count="${entry_count:-0}"

    read -r reject_packets reject_bytes < <(
        iptables -L OUTPUT -v -n -x 2>/dev/null | awk '
            $3 == "REJECT" { packets = $1; bytes = $2 }
            END { print packets + 0, bytes + 0 }
        '
    )

    {
        printf 'Updated: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf 'Whitelisted IPv4 entries: %s\n' "$entry_count"
        printf 'Denied outbound packets: %s\n' "${reject_packets:-0}"
        printf 'Denied outbound bytes: %s\n' "${reject_bytes:-0}"
        printf '\nCurrent OUTPUT rules:\n'
        iptables -L OUTPUT -v -n --line-numbers 2>/dev/null || true
        printf '\nCurrent whitelist members:\n'
        ipset list "$SET" 2>/dev/null || true
    } > "$tmp_file"

    chmod 644 "$tmp_file"
    mv "$tmp_file" "$STATUS_FILE"
}

initial_setup() {
    local docker_dns_rules
    local host_ip

    docker_dns_rules=$(capture_docker_dns_rules)

    iptables -F
    iptables -X
    iptables -t nat -F
    iptables -t nat -X
    iptables -t mangle -F
    iptables -t mangle -X
    ipset destroy "$TMP_SET" 2>/dev/null || true
    ipset destroy "$SET" 2>/dev/null || true

    restore_docker_dns_rules "$docker_dns_rules"
    build_allowed_set "$SET"

    host_ip=$(detect_host_gateway)
    configure_firewall_rules "$host_ip"
    verify_firewall
    write_status_file

    log "Setup complete. $BUILD_TOTAL_ENTRIES entries in whitelist."
    if [[ "$WARNINGS" -gt 0 ]]; then
        log "Completed with $WARNINGS warning(s). See /var/log/firewall.log for details."
    fi
}

refresh_whitelist() {
    ipset destroy "$TMP_SET" 2>/dev/null || true
    build_allowed_set "$TMP_SET"

    if [[ "$BUILD_DYNAMIC_SUCCESSES" -eq 0 ]]; then
        warn "skipping whitelist refresh because no dynamic entries resolved successfully"
        ipset destroy "$TMP_SET" 2>/dev/null || true
        return 0
    fi

    if [[ "$BUILD_TOTAL_ENTRIES" -eq 0 ]]; then
        warn "skipping whitelist refresh because the rebuilt set is empty"
        ipset destroy "$TMP_SET" 2>/dev/null || true
        return 0
    fi

    ipset swap "$TMP_SET" "$SET"
    ipset destroy "$TMP_SET" 2>/dev/null || true
    write_status_file
    log "Whitelist refresh complete. $BUILD_TOTAL_ENTRIES entries active."
}

case "${1:---setup}" in
    --setup)
        initial_setup
        ;;
    --refresh-only)
        refresh_whitelist
        ;;
    --write-status)
        write_status_file
        ;;
    *)
        echo "Usage: $0 [--setup|--refresh-only|--write-status]" >&2
        exit 1
        ;;
esac
