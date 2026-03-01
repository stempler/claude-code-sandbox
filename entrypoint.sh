#!/bin/bash
###############################################################################
# entrypoint.sh — Container startup for Claude Code sandbox
#
# 1. Lock agent permissions (settings.json + settings.local.json)
# 2. Initialize egress firewall
# 3. Initialize isolated git repo in /workspace
# 4. Hand off to CMD
###############################################################################

set -euo pipefail

# ── Check for subscription auth ─────────────────────────────────────────────
if [ -f "$HOME/.claude/.credentials.json" ]; then
    echo "[entrypoint] Found existing Claude subscription credentials"
else
    echo ""
    echo "  No subscription credentials found."
    echo "  Run 'claude login' to authenticate with your Pro/Max plan."
    echo "  Credentials are persisted in the claude-state Docker volume."
    echo ""
fi

# Safety check: warn if API key is set (would override subscription)
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    echo ""
    echo "  WARNING: ANTHROPIC_API_KEY is set in the environment."
    echo "  Claude Code will use API billing instead of your subscription."
    echo ""
fi

# ── Lock down agent permissions ────────────────────────────────────────────
echo "[entrypoint] Locking agent permissions..."
sudo /usr/local/bin/lock-settings.sh

# ── Initialize egress firewall ─────────────────────────────────────────────
echo "[entrypoint] Setting up egress firewall..."
sudo /usr/local/bin/init-firewall.sh

# ── Initialize isolated git repo in workspace ──────────────────────────────
cd /workspace
if [ ! -d .git ]; then
    git init --quiet
    git add -A
    git commit -m "Initial state" --quiet
    echo "[entrypoint] Initialized isolated git repo in /workspace"
else
    echo "[entrypoint] Git repo already exists in /workspace"
fi

# ── Hand off ────────────────────────────────────────────────────────────────
echo "[entrypoint] Sandbox ready."
echo ""
exec "$@"
