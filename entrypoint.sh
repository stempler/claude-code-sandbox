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
# Format constraint: values must be shell-safe (no spaces, quotes, or expansions)
# so both `source` and PAM accept them.
cat > /etc/environment <<'EOF'
http_proxy=http://localhost:3128
https_proxy=http://localhost:3128
HTTP_PROXY=http://localhost:3128
HTTPS_PROXY=http://localhost:3128
no_proxy=localhost,127.0.0.1
NO_PROXY=localhost,127.0.0.1
EOF
set -a
. /etc/environment
set +a

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

    # Make the root mount shared so Podman can set up bind mounts inside containers.
    # Requires SYS_ADMIN capability (added by --enable-docker in bin/code-sandbox).
    mount --make-rshared / 2>/dev/null || true

    DEVUSER_UID=$(id -u devuser)
    RUNTIME_DIR="/run/user/$DEVUSER_UID"

    # XDG_RUNTIME_DIR is required by Podman for the socket and tmp files
    mkdir -p "$RUNTIME_DIR"
    chown devuser:devuser "$RUNTIME_DIR"
    chmod 700 "$RUNTIME_DIR"

    # Write Podman config: containers.conf (proxy injection) + storage.conf (fuse-overlayfs)
    CONTAINERS_CONF_DIR="/home/devuser/.config/containers"
    mkdir -p "$CONTAINERS_CONF_DIR"
    cat > "$CONTAINERS_CONF_DIR/containers.conf" <<CONF
[containers]
# Propagate proxy env vars into inner containers automatically
http_proxy = true
env = ["http_proxy=http://localhost:3128", "https_proxy=http://localhost:3128", "no_proxy=localhost,127.0.0.1"]
# Suppress default sysctl that /proc/sys is read-only inside Docker
default_sysctls = []
# Share the sandbox PID, UTS, and network namespaces so inner containers:
#   - don't need to mount /proc (pidns=host bypasses Docker's nested PID ns restriction)
#   - don't call sethostname (utsns=host)
#   - can reach the Squid proxy at localhost:3128 (netns=host shares the outer loopback)
# With netns=host, inner container traffic is subject to the same iptables rules as
# devuser — it can only exit via Squid (loopback traffic is allowed; direct TCP is not).
pidns = "host"
utsns = "host"
netns = "host"

[engine]
runtime = "crun"
CONF
    cat > "$CONTAINERS_CONF_DIR/storage.conf" <<STOR
[storage]
driver = "overlay"

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
mountopt = "nodev,noatime"
STOR
    chown -R devuser:devuser /home/devuser/.config

    # Append DinD env to /etc/environment and source it, following the same
    # single-source-of-truth pattern as the proxy vars above.
    # podman-docker provides /usr/bin/docker as a shim to podman.
    # TESTCONTAINERS_RYUK_DISABLED: Ryuk is incompatible with Podman socket API
    #   and is unnecessary in an ephemeral sandbox.
    cat >> /etc/environment <<EOF
ENABLE_DOCKER=true
XDG_RUNTIME_DIR=$RUNTIME_DIR
DOCKER_HOST=unix://$RUNTIME_DIR/podman/podman.sock
TESTCONTAINERS_RYUK_DISABLED=true
EOF
    set -a
    . /etc/environment
    set +a

    # Pre-create the socket directory — podman system service won't create it.
    mkdir -p "$RUNTIME_DIR/podman"
    chown devuser:devuser "$RUNTIME_DIR/podman"

    # Start the Podman API socket (Docker-compatible) as devuser so
    # testcontainers and docker CLI can connect to it immediately.
    # --time=0 means no idle timeout — runs for the lifetime of the container.
    gosu devuser bash -c "
        XDG_RUNTIME_DIR=$RUNTIME_DIR \
        podman system service --time=0 unix://$RUNTIME_DIR/podman/podman.sock &
    "

    # Wait for the socket to appear (up to 10 seconds)
    SOCKET_READY=false
    for i in $(seq 1 20); do
        if [ -S "$RUNTIME_DIR/podman/podman.sock" ]; then
            SOCKET_READY=true
            break
        fi
        sleep 0.5
    done

    if [ "$SOCKET_READY" = "true" ]; then
        echo "[entrypoint] Podman API socket ready at $RUNTIME_DIR/podman/podman.sock"
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
