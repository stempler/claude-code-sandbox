#!/bin/bash
###############################################################################
# init-firewall.sh — Default-deny egress firewall
#
# Only allowlisted destinations are reachable. This is the primary defense
# against data exfiltration, even with --dangerously-skip-permissions.
#
# CUSTOMIZE: Edit the "Allowlisted destinations" section below to add any
# endpoints your project needs (internal APIs, package registries, etc.)
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

iptables -F OUTPUT
iptables -F INPUT
iptables -F FORWARD

# Default policies
iptables -P INPUT ACCEPT
iptables -P OUTPUT DROP
iptables -P FORWARD DROP

# Loopback
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT  -i lo -j ACCEPT

# Established connections
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# DNS: allow all nameservers from /etc/resolv.conf (covers both Docker embedded
# DNS at 127.0.0.11 on compose networks and host DNS on the default bridge)
DNS_SERVERS=$(grep -oP '^\s*nameserver\s+\K\S+' /etc/resolv.conf || true)
for dns in $DNS_SERVERS; do
    iptables -A OUTPUT -d "$dns" -p udp --dport 53 -j ACCEPT
    iptables -A OUTPUT -d "$dns" -p tcp --dport 53 -j ACCEPT
    echo "[firewall]   Allowed DNS: $dns"
done

# Drop all other UDP — prevents DNS tunneling to external resolvers
iptables -A OUTPUT -p udp -j DROP

###############################################################################
# Allowlisted destinations (CUSTOMIZE THIS)
###############################################################################

# Helper: resolve a domain and allow all its A record IPs on port 443
resolve_and_allow() {
    local domain="$1"
    local ips
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [ -n "$ips" ]; then
        for ip in $ips; do
            iptables -A OUTPUT -d "$ip" -p tcp --dport 443 -j ACCEPT
            echo "[firewall]   Allowed: $domain -> $ip:443"
        done
    else
        echo "[firewall]   WARNING: Could not resolve $domain"
    fi
}

# ── Anthropic API (static CIDR — docs.anthropic.com/en/api/ip-addresses) ────
# Using official published CIDR ranges avoids DNS/CDN IP rotation issues.
iptables -A OUTPUT -d 160.79.104.0/23 -p tcp --dport 443 -j ACCEPT
echo "[firewall]   Allowed: Anthropic API CIDR 160.79.104.0/23:443"

# ── Claude Code required domains ────────────────────────────────────────────
# claude.ai          — subscription auth
# platform.claude.com — console/API key auth
# downloads.claude.ai — update installer, version manifests
# statsig.anthropic.com — feature flags (blocks Claude startup if unreachable)
ALLOWED_DOMAINS=(claude.ai platform.claude.com downloads.claude.ai statsig.anthropic.com api.github.com release-assets.githubusercontent.com)
for domain in "${ALLOWED_DOMAINS[@]}"; do
    resolve_and_allow "$domain"
done

# ── PyPI (uncomment if agent needs to pip install) ──────────────────────────
# for domain in pypi.org files.pythonhosted.org; do
#     resolve_and_allow "$domain"
# done

# ── npm registry (uncomment if agent needs npm install) ─────────────────────
# resolve_and_allow "registry.npmjs.org"

# ── GitHub
for domain in github.com; do
    IPS=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    for ip in $IPS; do
        iptables -A OUTPUT -d "$ip" -p tcp --dport 443 -j ACCEPT
        iptables -A OUTPUT -d "$ip" -p tcp --dport 22  -j ACCEPT
    done
done

# ── Sentry error reporting (uncomment if desired) ───────────────────────────
# resolve_and_allow "sentry.io"

# ── Legacy Claude update downloads (uncomment if needed) ────────────────────
# resolve_and_allow "storage.googleapis.com"

# ── Internal services (Docker network, example) ────────────────────────────
# iptables -A OUTPUT -d 172.16.0.0/12 -p tcp --dport 8080 -j ACCEPT

###############################################################################

# ── Reject everything else immediately (avoids hanging timeouts) ─────────────
# REJECT gives an immediate ICMP error rather than silently timing out, which
# makes it obvious when a connection is blocked and prevents Claude from hanging.
iptables -A OUTPUT -m limit --limit 5/min -j LOG \
    --log-prefix "[FIREWALL-BLOCKED] " --log-level 4
iptables -A OUTPUT -j REJECT --reject-with icmp-port-unreachable

# ── Self-verify and write results for test consumption ────────────────────
# The test runs as devuser and cannot sudo iptables directly (sudoers only
# allows the two init scripts), so we verify here while still running as
# root and write the results to a file the test can read.
VERIFY_FILE="/run/firewall-verify"
VERIFY_OK=true

OUTPUT_POLICY=$(iptables -L OUTPUT -n | head -1 | grep -o "DROP" || echo "NOT_DROP")
if [ "$OUTPUT_POLICY" != "DROP" ]; then
    echo "[firewall] VERIFY FAILED: OUTPUT policy is $OUTPUT_POLICY, expected DROP"
    VERIFY_OK=false
fi

# Note: iptables -L -n uses numeric protocol IDs (17=UDP), not names
if ! iptables -L OUTPUT -n | grep -qE "DROP\s+17\b|DROP.*udp"; then
    echo "[firewall] VERIFY FAILED: no UDP DROP rule found"
    VERIFY_OK=false
fi

{
    echo "OUTPUT_POLICY=$OUTPUT_POLICY"
    if iptables -L OUTPUT -n | grep -qE "DROP\s+17\b|DROP.*udp"; then
        echo "UDP_DROP=yes"
    else
        echo "UDP_DROP=no"
    fi
} > "$VERIFY_FILE"
chmod 0444 "$VERIFY_FILE"

if [ "$VERIFY_OK" = true ]; then
    DOMAIN_LIST=$(IFS=", "; echo "${ALLOWED_DOMAINS[*]}")
    echo "[firewall] Active. DEFAULT DENY. Allowed: loopback, Docker DNS, GitHub, Anthropic API (CIDR), ${DOMAIN_LIST}"
else
    echo "[firewall] WARNING: Rules were applied but verification found issues."
fi
echo ""
