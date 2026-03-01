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

# Docker embedded DNS
iptables -A OUTPUT -d 127.0.0.11 -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -d 127.0.0.11 -p tcp --dport 53 -j ACCEPT

# Drop all other UDP — prevents DNS tunneling to external resolvers
iptables -A OUTPUT -p udp -j DROP

###############################################################################
# Allowlisted destinations (CUSTOMIZE THIS)
###############################################################################

# ── Anthropic API (required for Claude Code) ────────────────────────────────
ANTHROPIC_IPS=$(dig +short api.anthropic.com A 2>/dev/null || echo "")
if [ -n "$ANTHROPIC_IPS" ]; then
    for ip in $ANTHROPIC_IPS; do
        iptables -A OUTPUT -d "$ip" -p tcp --dport 443 -j ACCEPT
        echo "[firewall]   Allowed: api.anthropic.com -> $ip:443"
    done
else
    # Fail closed: do NOT allow all :443 — better to fail than to allow exfiltration
    echo "[firewall]   ERROR: Could not resolve api.anthropic.com"
    echo "[firewall]   Claude Code will not be able to connect. Check DNS and retry."
fi

# ── Claude subscription auth (OAuth endpoints) ─────────────────────────────
CLAUDE_IPS=$(dig +short claude.ai A 2>/dev/null || echo "")
if [ -n "$CLAUDE_IPS" ]; then
    for ip in $CLAUDE_IPS; do
        iptables -A OUTPUT -d "$ip" -p tcp --dport 443 -j ACCEPT
        echo "[firewall]   Allowed: claude.ai -> $ip:443"
    done
fi

# ── PyPI (uncomment if agent needs to pip install) ──────────────────────────
# for domain in pypi.org files.pythonhosted.org; do
#     IPS=$(dig +short "$domain" A 2>/dev/null || echo "")
#     if [ -n "$IPS" ]; then
#         for ip in $IPS; do
#             iptables -A OUTPUT -d "$ip" -p tcp --dport 443 -j ACCEPT
#             echo "[firewall]   Allowed: $domain -> $ip:443"
#         done
#     fi
# done

# ── npm registry (uncomment if agent needs npm install) ─────────────────────
# NPM_IPS=$(dig +short registry.npmjs.org A 2>/dev/null || echo "")
# if [ -n "$NPM_IPS" ]; then
#     for ip in $NPM_IPS; do
#         iptables -A OUTPUT -d "$ip" -p tcp --dport 443 -j ACCEPT
#         echo "[firewall]   Allowed: registry.npmjs.org -> $ip:443"
#     done
# fi

# ── Internal services (Docker network, example) ────────────────────────────
# iptables -A OUTPUT -d 172.16.0.0/12 -p tcp --dport 8080 -j ACCEPT

# ── GitHub (uncomment if agent needs git push) ──────────────────────────────
# for domain in github.com; do
#     IPS=$(dig +short "$domain" A 2>/dev/null || echo "")
#     for ip in $IPS; do
#         iptables -A OUTPUT -d "$ip" -p tcp --dport 443 -j ACCEPT
#         iptables -A OUTPUT -d "$ip" -p tcp --dport 22  -j ACCEPT
#     done
# done

###############################################################################

# ── Log and drop everything else ────────────────────────────────────────────
iptables -A OUTPUT -m limit --limit 5/min -j LOG \
    --log-prefix "[FIREWALL-BLOCKED] " --log-level 4
iptables -A OUTPUT -j DROP

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
    echo "[firewall] Active. DEFAULT DENY. Allowed: loopback, Docker DNS, Anthropic API, claude.ai"
else
    echo "[firewall] WARNING: Rules were applied but verification found issues."
fi
echo ""
