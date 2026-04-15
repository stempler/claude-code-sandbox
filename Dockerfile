# syntax=docker/dockerfile:1
###############################################################################
# Dockerfile — Hardened Claude Code sandbox
#
# Portable template: customize the "Project dependencies" section for your
# repo's language/framework, then adjust claude-settings.json for your
# permission rules.
#
# Security: non-root agent (gosu drop), iptables egress firewall, locked settings,
#           no host credentials, host UID/GID remap for workspace ownership
###############################################################################

FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

# ── System packages ─────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl git ca-certificates gnupg gosu \
    iptables iproute2 dnsutils \
    squid \
    python3 python3-pip python3-venv \
    build-essential \
    ncurses-term \
    podman podman-docker fuse-overlayfs slirp4netns uidmap crun \
    && rm -rf /var/lib/apt/lists/*

# ── mise-en-place ────────────────────────────────────────────────────────────
RUN install -dm 755 /etc/apt/keyrings \
    && curl -fSs https://mise.jdx.dev/gpg-key.pub \
       > /etc/apt/keyrings/mise-archive-keyring.asc \
    && echo "deb [signed-by=/etc/apt/keyrings/mise-archive-keyring.asc] https://mise.jdx.dev/deb stable main" \
       > /etc/apt/sources.list.d/mise.list \
    && apt-get update && apt-get install -y mise \
    && rm -rf /var/lib/apt/lists/*

# ── Claude Code CLI ─────────────────────────────────────────────────────────
# RUN curl -fsSL https://claude.ai/install.sh | bash \
#     && cp /root/.local/bin/claude /usr/local/bin/claude

# ── Non-root user ───────────────────────────────────────────────────────────
# No sudo needed: entrypoint runs as root and drops to devuser via gosu.
RUN useradd -m -s /bin/bash devuser \
    && echo 'eval "$(mise activate bash)"' >> /home/devuser/.bashrc \
    && echo "devuser:100000:65536" >> /etc/subuid \
    && echo "devuser:100000:65536" >> /etc/subgid

# ── Project dependencies (CUSTOMIZE THIS) ───────────────────────────────────
# Example: Python venv with your project's packages
RUN python3 -m venv /home/devuser/venv \
    && chown -R devuser:devuser /home/devuser/venv
# RUN --mount=type=cache,target=/root/.cache/pip \
#     /home/devuser/venv/bin/pip install \
#     your-package-here pytest black ruff

# ── Copy scripts and config ─────────────────────────────────────────────────
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
COPY lock-settings.sh /usr/local/bin/lock-settings.sh
COPY entrypoint.sh    /usr/local/bin/entrypoint.sh
COPY proxy-log.sh     /usr/local/bin/proxy-log
RUN chmod 755 /usr/local/bin/init-firewall.sh /usr/local/bin/lock-settings.sh /usr/local/bin/entrypoint.sh /usr/local/bin/proxy-log

# Config: copy the config/ tree (mirrors home dir) to the user home AND to a
# root-owned canonical location that the entrypoint restores on every boot.
COPY config/ /usr/local/share/sandbox-config/
COPY config-dind/ /usr/local/share/sandbox-config-dind/
RUN find /usr/local/share/sandbox-config -type f -exec chmod 0444 {} + \
    && find /usr/local/share/sandbox-config-dind -type f -exec chmod 0444 {} + \
    && chown -R devuser:devuser /home/devuser

# ── Entrypoint runs as root so it can remap devuser UID/GID to match the ────
# host user, then drops privileges via gosu before handing off to CMD.
USER root
WORKDIR /workspace

ENV PATH="/home/devuser/.opencode/bin:/home/devuser/.local/bin:/home/devuser/.local/share/mise/shims:/home/devuser/venv/bin:$PATH"
ENV VIRTUAL_ENV="/home/devuser/venv"

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
