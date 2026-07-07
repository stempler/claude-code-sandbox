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

# shellcheck source=/usr/local/lib/sandbox-init.sh
. /usr/local/lib/sandbox-init.sh

# ── Remap devuser to host UID/GID ──────────────────────────────────────────
# HOST_UID / HOST_GID are passed by bin/code-sandbox so files written to
# the bind-mounted /workspace are owned by the calling host user, not by the
# container's default devuser ID.
sandbox::remap_devuser_uid_gid

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

# ── Render injected credentials ────────────────────────────────────────
if [ "${SANDBOX_CREDENTIALS:-}" = "true" ] && [ -f /run/sandbox-secrets/payload.json ]; then
    echo "[entrypoint] Rendering sandbox credentials..."
    /usr/local/bin/render-credentials.sh
fi

# ── Initialize egress firewall ─────────────────────────────────────────────
echo "[entrypoint] Setting up egress firewall..."
/usr/local/bin/init-firewall.sh

# /etc/environment is the single source of truth for sandbox-managed env vars.
# - Original (docker run) session: sourced here so `exec gosu devuser` propagates
#   them via execve into the devuser shell.
# - Attached (docker exec) session: sourced by /usr/local/bin/sandbox-exec, which
#   is used as the exec target by bin/code-sandbox for container-reuse attaches.
# Both lower- and upper-case proxy vars are written; different tools check different
# cases. no_proxy excludes localhost to prevent a proxy loop (devuser → :3128 → :3128).
# JAVA_TOOL_OPTIONS is also written so JVM tools (Gradle, Maven, java) pick up the
# proxy — the JVM ignores http_proxy/https_proxy and only reads system properties.
# Format: /etc/environment is only ever shell-sourced in this sandbox, not read by
# PAM, so double-quoted values containing spaces (e.g. JAVA_TOOL_OPTIONS) are safe.
sandbox::write_proxy_environment

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

# ── Docker-in-Docker: initialize rootless Podman ──────────────────────────────
if [ "${ENABLE_DOCKER:-}" = "true" ]; then
    echo "[entrypoint] Initializing Docker-in-Docker (rootless Podman)..."
    sandbox::reharden_proc_paths
    sandbox::setup_rootless_podman
    sandbox::append_dind_environment
    sandbox::start_podman_socket
    sandbox::wait_for_podman_socket
    if [ "$SOCKET_READY" = "true" ]; then
        echo "[entrypoint] Podman API socket ready at $SOCKET"
        echo "[entrypoint]   DOCKER_HOST=$DOCKER_HOST"
        echo "[entrypoint]   TESTCONTAINERS_RYUK_DISABLED=true"
    else
        echo "[entrypoint] WARNING: Podman socket did not appear within 10 seconds."
        echo "[entrypoint]   Docker commands may fail until the socket is ready."
    fi
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
