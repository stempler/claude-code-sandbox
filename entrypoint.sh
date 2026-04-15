#!/bin/bash
###############################################################################
# entrypoint.sh — Container startup for Claude Code sandbox
#
# Runs as root so it can:
#   1. Remap devuser UID/GID to match the host user (fixes bind-mount ownership)
#   2. Refresh Claude Code and OpenCode CLIs (before firewall)
#   3. Lock agent permissions (settings.json + settings.local.json)
#   4. Initialize egress firewall
#   5. Warn if /workspace has no git repository
#   6. Drop privileges and hand off to CMD via gosu
###############################################################################

set -euo pipefail

# ── Remap devuser to host UID/GID ──────────────────────────────────────────
# HOST_UID / HOST_GID are passed by bin/code-sandbox so files written to
# the bind-mounted /workspace are owned by the calling host user, not by the
# container's default devuser ID.
if [[ "${HOST_UID:-}" =~ ^[0-9]+$ ]] && [[ "${HOST_GID:-}" =~ ^[0-9]+$ ]]; then
    CURRENT_UID=$(id -u devuser)
    CURRENT_GID=$(id -g devuser)

    if [ "$HOST_GID" != "$CURRENT_GID" ]; then
        # If a group with HOST_GID already exists, reuse it; otherwise rename devuser's group.
        EXISTING_GROUP=$(getent group "$HOST_GID" | cut -d: -f1 || true)
        if [ -n "$EXISTING_GROUP" ]; then
            usermod -g "$HOST_GID" devuser
        else
            groupmod -g "$HOST_GID" devuser
        fi
    fi

    if [ "$HOST_UID" != "$CURRENT_UID" ]; then
        # Another account may already own HOST_UID (e.g. distro default user at 1000).
        uid_owner=$(getent passwd "$HOST_UID" | cut -d: -f1 || true)
        if [ -n "$uid_owner" ] && [ "$uid_owner" != "devuser" ]; then
            echo "[entrypoint] UID $HOST_UID is in use by $uid_owner; relocating to a spare UID"
            temp_uid=99990
            while getent passwd "$temp_uid" >/dev/null; do
                temp_uid=$((temp_uid + 1))
            done
            other_home=$(getent passwd "$uid_owner" | cut -d: -f6)
            usermod -u "$temp_uid" "$uid_owner"
            if [ -n "$other_home" ] && [ -d "$other_home" ]; then
                chown -R "$uid_owner:" "$other_home" 2>/dev/null || true
            fi
        fi
        usermod -u "$HOST_UID" devuser
    fi

    # Reconcile ownership of the user home (critical for Claude config/state).
    chown -R devuser /home/devuser 2>/dev/null || true
    # Best-effort: /workspace may be large; only fix the top-level dir itself.
    chown devuser /workspace 2>/dev/null || true

    echo "[entrypoint] devuser remapped to UID=$HOST_UID GID=$HOST_GID"
else
    echo "[entrypoint] WARNING: HOST_UID/HOST_GID not set or non-numeric -- skipping UID remap."
    echo "[entrypoint] Files written in /workspace may be owned by the wrong user on the host."
fi

# ── Check for subscription auth ─────────────────────────────────────────────
if [ -f /home/devuser/.claude/.credentials.json ]; then
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

# ── Update Claude Code to latest version ───────────────────────────────────
echo "[entrypoint] Updating Claude Code..."
gosu devuser bash -c 'curl -fsSL https://claude.ai/install.sh | bash' 2>&1 \
    || echo "[entrypoint] Update failed, using image version"

# ── Update OpenCode CLI ─────────────────────────────────────────────────────
echo "[entrypoint] Updating OpenCode..."
gosu devuser bash -c 'curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path' 2>&1 \
    || echo "[entrypoint] OpenCode install failed, using existing install if any"

if [ ! -f /home/devuser/.local/share/opencode/auth.json ]; then
    echo ""
    echo "  No OpenCode provider credentials found."
    echo "  Run 'opencode auth login' to configure providers (stored under /home/devuser)."
    echo ""
fi

# ── Lock down agent permissions ────────────────────────────────────────────
echo "[entrypoint] Locking agent permissions..."
/usr/local/bin/lock-settings.sh

# ── Initialize egress firewall ─────────────────────────────────────────────
echo "[entrypoint] Setting up egress firewall..."
/usr/local/bin/init-firewall.sh

# Export proxy env vars so gosu-launched devuser inherits them.
# Both lower and upper case are needed — different tools check different cases.
# no_proxy excludes localhost to prevent a proxy loop (devuser → :3128 → :3128).
export http_proxy=http://localhost:3128
export https_proxy=http://localhost:3128
export HTTP_PROXY=http://localhost:3128
export HTTPS_PROXY=http://localhost:3128
export no_proxy=localhost,127.0.0.1
export NO_PROXY=localhost,127.0.0.1

# Write proxy vars to /etc/environment so that docker exec sessions and tools
# that read system-wide env (rather than inheriting from the entrypoint process)
# also pick them up automatically.
cat > /etc/environment <<'EOF'
http_proxy=http://localhost:3128
https_proxy=http://localhost:3128
HTTP_PROXY=http://localhost:3128
HTTPS_PROXY=http://localhost:3128
no_proxy=localhost,127.0.0.1
NO_PROXY=localhost,127.0.0.1
EOF

# ── Verify API connectivity ────────────────────────────────────────────────
# Any HTTP response (even 4xx) means TCP+TLS succeeded and the host is reachable.
# HTTP code 000 means the connection itself failed (firewall, DNS, etc.).
echo "[entrypoint] Verifying API connectivity..."
HTTP_CODE=$(curl -s --connect-timeout 5 -o /dev/null -w "%{http_code}" https://api.anthropic.com || true)
if [ "$HTTP_CODE" != "000" ] && [ -n "$HTTP_CODE" ]; then
    echo "[entrypoint] API reachable (HTTP $HTTP_CODE)."
else
    echo "[entrypoint] WARNING: Cannot reach api.anthropic.com -- Claude may not respond."
fi

# ── Check for git repo in workspace ──────────────────────────────────────────
cd /workspace
if [ ! -d .git ]; then
    echo ""
    echo "  WARNING: /workspace is not a git repository."
    echo "  Claude Code works best with version control. Consider running 'git init'."
    echo ""
else
    echo "[entrypoint] Git repo found in /workspace"
fi

# ── Drop privileges and hand off ───────────────────────────────────────────
echo "[entrypoint] Sandbox ready."
echo ""
exec gosu devuser "$@"
