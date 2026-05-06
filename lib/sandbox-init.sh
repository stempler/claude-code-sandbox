#!/bin/bash
# sandbox-init.sh — Shared initialization functions for entrypoint.sh and test-sandbox.sh.
#
# Source this file; do not execute it directly.
# Callers own shell options (set -euo pipefail). This file sets none.
# All functions are namespaced sandbox:: to avoid collisions.

# ── sandbox::remap_devuser_uid_gid ────────────────────────────────────────────
# Remaps the devuser account inside the container to HOST_UID / HOST_GID so
# files written to the bind-mounted /workspace are owned by the calling host
# user. Sets DEVUSER_UID and DEVUSER_GID as globals for subsequent calls.
sandbox::remap_devuser_uid_gid() {
    if [[ "${HOST_UID:-}" =~ ^[0-9]+$ ]] && [[ "${HOST_GID:-}" =~ ^[0-9]+$ ]]; then
        local CURRENT_UID
        local CURRENT_GID
        CURRENT_UID=$(id -u devuser)
        CURRENT_GID=$(id -g devuser)

        if [ "$HOST_GID" != "$CURRENT_GID" ]; then
            local EXISTING_GROUP
            EXISTING_GROUP=$(getent group "$HOST_GID" | cut -d: -f1 || true)
            if [ -n "$EXISTING_GROUP" ]; then
                usermod -g "$HOST_GID" devuser
            else
                groupmod -g "$HOST_GID" devuser
            fi
        fi

        if [ "$HOST_UID" != "$CURRENT_UID" ]; then
            local uid_owner
            uid_owner=$(getent passwd "$HOST_UID" | cut -d: -f1 || true)
            if [ -n "$uid_owner" ] && [ "$uid_owner" != "devuser" ]; then
                echo "[entrypoint] UID $HOST_UID is in use by $uid_owner; relocating to a spare UID"
                local temp_uid=99990
                while getent passwd "$temp_uid" >/dev/null; do
                    temp_uid=$((temp_uid + 1))
                done
                local other_home
                other_home=$(getent passwd "$uid_owner" | cut -d: -f6)
                usermod -u "$temp_uid" "$uid_owner"
                if [ -n "$other_home" ] && [ -d "$other_home" ]; then
                    chown -R "$uid_owner:" "$other_home" 2>/dev/null || true
                fi
            fi
            usermod -u "$HOST_UID" devuser
        fi

        chown -R devuser /home/devuser 2>/dev/null || true
        chown devuser /workspace 2>/dev/null || true

        echo "[entrypoint] devuser remapped to UID=$HOST_UID GID=$HOST_GID"
    else
        echo "[entrypoint] WARNING: HOST_UID/HOST_GID not set or non-numeric -- skipping UID remap."
        echo "[entrypoint] Files written in /workspace may be owned by the wrong user on the host."
    fi

    DEVUSER_UID=$(id -u devuser)
    DEVUSER_GID=$(id -g devuser)
}

# ── sandbox::write_proxy_environment ─────────────────────────────────────────
# Writes proxy variables to /etc/environment and sources it into the current
# shell. Both lower- and upper-case variants are written; different tools check
# different cases. no_proxy/NO_PROXY exclude localhost to avoid proxy loops.
sandbox::write_proxy_environment() {
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
}

# ── sandbox::setup_rootless_podman ────────────────────────────────────────────
# Prepares the rootless Podman runtime inside the container:
#   - makes the root mount shared (required for bind mounts in inner containers)
#   - creates XDG_RUNTIME_DIR for devuser
#   - writes containers.conf (proxy injection, namespace sharing) and
#     storage.conf (fuse-overlayfs driver)
# Exports DEVUSER_UID and RUNTIME_DIR as globals for subsequent DinD functions.
# Requires SYS_ADMIN capability (added by --enable-docker in bin/code-sandbox).
sandbox::setup_rootless_podman() {
    mount --make-rshared / 2>/dev/null || true

    DEVUSER_UID=$(id -u devuser)
    RUNTIME_DIR="/run/user/$DEVUSER_UID"

    mkdir -p "$RUNTIME_DIR"
    chown devuser:devuser "$RUNTIME_DIR"
    chmod 700 "$RUNTIME_DIR"

    local CONTAINERS_CONF_DIR="/home/devuser/.config/containers"
    mkdir -p "$CONTAINERS_CONF_DIR"
    cat > "$CONTAINERS_CONF_DIR/containers.conf" <<'CONF'
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
    cat > "$CONTAINERS_CONF_DIR/storage.conf" <<'STOR'
[storage]
driver = "overlay"

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
mountopt = "nodev,noatime"
STOR
    chown -R devuser:devuser /home/devuser/.config
}

# ── sandbox::append_dind_environment ─────────────────────────────────────────
# Appends DinD-specific variables to /etc/environment and re-sources it.
# Must be called after sandbox::setup_rootless_podman (needs DEVUSER_UID /
# RUNTIME_DIR). TESTCONTAINERS_RYUK_DISABLED: Ryuk is incompatible with Podman
# and unnecessary in an ephemeral sandbox.
sandbox::append_dind_environment() {
    cat >> /etc/environment <<EOF
ENABLE_DOCKER=true
XDG_RUNTIME_DIR=$RUNTIME_DIR
DOCKER_HOST=unix://$RUNTIME_DIR/podman/podman.sock
TESTCONTAINERS_RYUK_DISABLED=true
EOF
    set -a
    . /etc/environment
    set +a
}

# ── sandbox::start_podman_socket ─────────────────────────────────────────────
# Pre-creates the Podman socket directory and starts the API service as devuser
# in the background. Must be called after sandbox::setup_rootless_podman.
# Sets SOCKET as a global (path to the Podman socket file).
# Output is suppressed to avoid interfering with TEST_*= token parsing in tests.
sandbox::start_podman_socket() {
    SOCKET="$RUNTIME_DIR/podman/podman.sock"
    mkdir -p "$RUNTIME_DIR/podman"
    chown devuser:devuser "$RUNTIME_DIR/podman"

    gosu devuser bash -c "
        XDG_RUNTIME_DIR=$RUNTIME_DIR \
        podman system service --time=0 unix://$SOCKET
    " >/dev/null 2>&1 &
}

# ── sandbox::wait_for_podman_socket ──────────────────────────────────────────
# Polls for the Podman API socket to appear (up to 10 seconds).
# Sets SOCKET_READY=true if the socket appeared, false otherwise.
# Does not print; callers decide how to report the outcome so this function
# works identically in entrypoint (log lines) and test (TEST_*= tokens).
# Must be called after sandbox::start_podman_socket.
sandbox::wait_for_podman_socket() {
    SOCKET_READY=false
    local i
    for i in $(seq 1 20); do
        if [ -S "$SOCKET" ]; then
            SOCKET_READY=true
            break
        fi
        sleep 0.5
    done
}
