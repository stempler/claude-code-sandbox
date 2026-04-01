#!/bin/bash
###############################################################################
# init-firewall.sh — Squid proxy + iptables backstop egress firewall
#
# Architecture:
#   devuser → http_proxy=localhost:3128 → Squid (domain ACL) → internet
#   iptables: default-deny; only proxy UID and root exit directly
#
# Environment variables:
#   ALLOWED_DOMAINS       — space-separated list; replaces the default allowlist
#   EXTRA_ALLOWED_DOMAINS — space-separated list; appended to the default allowlist
#   ALLOW_ALL_HTTPS       — set to "true" to disable domain filtering entirely
###############################################################################

set -euo pipefail

echo "[firewall] Initializing egress firewall..."

# Verify iptables is functional before proceeding
if ! iptables -L OUTPUT -n > /dev/null 2>&1; then
    echo "[firewall] ERROR: iptables is not functional."
    echo "[firewall] This usually means the iptable_filter kernel module is not loaded,"
    echo "[firewall] or the container lacks NET_ADMIN capability."
    echo "[firewall] The container will NOT have network restrictions!"
    exit 1
fi

###############################################################################
# Default domain allowlist
###############################################################################

DEFAULT_DOMAINS=(
    # Anthropic / Claude
    .anthropic.com
    .claude.ai
    # GitHub
    .github.com
    .githubusercontent.com
    .githubassets.com
    # PyPI
    .pypi.org
    .pythonhosted.org
    # npm
    .npmjs.org
    .npmjs.com
    # Rust / Cargo
    .crates.io
    .rust-lang.org
    # Go modules
    proxy.golang.org
    sum.golang.org
    pkg.go.dev
    # Search & web browsing
    .google.com
    .bing.com
    .duckduckgo.com
    .wikipedia.org
    # Dev docs
    .stackoverflow.com
    .readthedocs.io
    .docs.rs
    .developer.mozilla.org
    # Common CDNs
    .cloudflare.com
    .fastly.net
)

###############################################################################
# Generate squid.conf
###############################################################################

SQUID_CONF=/etc/squid/squid.conf

# Build the domain list from env vars or defaults
if [ -n "${ALLOWED_DOMAINS:-}" ]; then
    # shellcheck disable=SC2206
    DOMAIN_LIST=($ALLOWED_DOMAINS)
else
    DOMAIN_LIST=("${DEFAULT_DOMAINS[@]}")
    if [ -n "${EXTRA_ALLOWED_DOMAINS:-}" ]; then
        # shellcheck disable=SC2206
        DOMAIN_LIST+=($EXTRA_ALLOWED_DOMAINS)
    fi
fi

{
    echo "http_port 3128"
    echo ""
    echo "# Disable disk cache — this is a security proxy, not a caching proxy"
    echo "cache_dir null /tmp"
    echo "cache deny all"
    echo ""
    echo "# Log all requests for auditability"
    echo "access_log /var/log/squid/access.log squid"
    echo ""

    if [ "${ALLOW_ALL_HTTPS:-}" = "true" ]; then
        echo "# ALLOW_ALL_HTTPS=true: domain filtering disabled, proxy acts as audit logger"
        echo "http_access allow all"
    else
        echo "# Domain allowlist — .domain matches the domain itself and all subdomains"
        for domain in "${DOMAIN_LIST[@]}"; do
            echo "acl allowed_domains dstdomain $domain"
        done
        echo ""
        echo "acl CONNECT method CONNECT"
        echo "http_access allow CONNECT allowed_domains"
        echo "http_access allow allowed_domains"
        echo "http_access deny all"
    fi
} > "$SQUID_CONF"

echo "[firewall] Generated $SQUID_CONF"
if [ "${ALLOW_ALL_HTTPS:-}" = "true" ]; then
    echo "[firewall]   Mode: ALLOW ALL HTTPS (audit logging only)"
else
    echo "[firewall]   Mode: domain allowlist (${#DOMAIN_LIST[@]} entries)"
fi

###############################################################################
# Start Squid
###############################################################################

echo "[firewall] Starting Squid..."
squid -f "$SQUID_CONF"

# Wait for Squid to accept connections (poll /dev/tcp, up to 10 seconds)
READY=false
for i in $(seq 1 20); do
    if (echo > /dev/tcp/localhost/3128) 2>/dev/null; then
        READY=true
        break
    fi
    sleep 0.5
done

if [ "$READY" != "true" ]; then
    echo "[firewall] ERROR: Squid did not start within 10 seconds."
    exit 1
fi
echo "[firewall] Squid ready on :3128"

###############################################################################
# iptables rules
###############################################################################

iptables -F OUTPUT
iptables -F INPUT
iptables -F FORWARD

# Default policies
iptables -P INPUT ACCEPT
iptables -P OUTPUT DROP
iptables -P FORWARD DROP

# Loopback (also carries devuser → Squid connections via localhost:3128)
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT  -i lo -j ACCEPT

# Established connections (return traffic for Squid's outbound connections)
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# DNS: allow resolv.conf nameservers only (covers Docker embedded DNS and host DNS)
DNS_SERVERS=$(grep -oP '^\s*nameserver\s+\K\S+' /etc/resolv.conf || true)
for dns in $DNS_SERVERS; do
    iptables -A OUTPUT -d "$dns" -p udp --dport 53 -j ACCEPT
    iptables -A OUTPUT -d "$dns" -p tcp --dport 53 -j ACCEPT
    echo "[firewall]   Allowed DNS: $dns"
done

# Drop all other UDP — prevents DNS tunneling to external resolvers
iptables -A OUTPUT -p udp -j DROP

# Anthropic API CIDR — direct access (stable published range, no proxy overhead)
# This also serves as a reliability fallback if Squid is unavailable.
iptables -A OUTPUT -d 160.79.104.0/23 -p tcp --dport 443 -j ACCEPT
echo "[firewall]   Allowed direct: Anthropic API CIDR 160.79.104.0/23:443"

# Root — allow direct outbound (needed for entrypoint health checks and init)
iptables -A OUTPUT -m owner --uid-owner 0 -j ACCEPT

# Squid (proxy user, UID 13 on Ubuntu) — allow outbound to forward requests
iptables -A OUTPUT -m owner --uid-owner proxy -j ACCEPT
echo "[firewall]   Allowed direct: root and proxy UIDs (Squid workers)"

# Reject everything else with an immediate ICMP error (no hanging timeouts)
iptables -A OUTPUT -m limit --limit 5/min -j LOG \
    --log-prefix "[FIREWALL-BLOCKED] " --log-level 4
iptables -A OUTPUT -j REJECT --reject-with icmp-port-unreachable

###############################################################################
# Self-verify and write results for test-sandbox.sh consumption
###############################################################################

VERIFY_FILE="/run/firewall-verify"
VERIFY_OK=true

OUTPUT_POLICY=$(iptables -L OUTPUT -n | head -1 | grep -o "DROP" || echo "NOT_DROP")
if [ "$OUTPUT_POLICY" != "DROP" ]; then
    echo "[firewall] VERIFY FAILED: OUTPUT policy is $OUTPUT_POLICY, expected DROP"
    VERIFY_OK=false
fi

if ! iptables -L OUTPUT -n | grep -qE "DROP[[:space:]]+17|DROP.*udp"; then
    echo "[firewall] VERIFY FAILED: no UDP DROP rule found"
    VERIFY_OK=false
fi

PROXY_UID=$(id -u proxy 2>/dev/null || echo "13")
if ! iptables -L OUTPUT -n -v | grep -q "owner UID match $PROXY_UID"; then
    echo "[firewall] VERIFY FAILED: no proxy UID allow rule found"
    VERIFY_OK=false
fi

{
    echo "OUTPUT_POLICY=$OUTPUT_POLICY"
    if iptables -L OUTPUT -n | grep -qE "DROP[[:space:]]+17|DROP.*udp"; then
        echo "UDP_DROP=yes"
    else
        echo "UDP_DROP=no"
    fi
    if iptables -L OUTPUT -n -v | grep -q "owner UID match $PROXY_UID"; then
        echo "PROXY_UID_RULE=yes"
    else
        echo "PROXY_UID_RULE=no"
    fi
    if (echo > /dev/tcp/localhost/3128) 2>/dev/null; then
        echo "SQUID_RUNNING=yes"
    else
        echo "SQUID_RUNNING=no"
    fi
} > "$VERIFY_FILE"
chmod 0444 "$VERIFY_FILE"

if [ "$VERIFY_OK" = true ]; then
    echo "[firewall] Active. DEFAULT DENY + Squid proxy on :3128"
    if [ "${ALLOW_ALL_HTTPS:-}" = "true" ]; then
        echo "[firewall]   Domain filtering: DISABLED (ALLOW_ALL_HTTPS=true)"
    else
        echo "[firewall]   Domain filtering: ${#DOMAIN_LIST[@]} entries"
    fi
else
    echo "[firewall] WARNING: Rules were applied but verification found issues."
fi
echo ""
