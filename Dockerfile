# syntax=docker/dockerfile:1
###############################################################################
# Dockerfile — Hardened Claude Code sandbox
#
# Portable template: customize the "Project dependencies" section for your
# repo's language/framework, then adjust claude-settings.json for your
# permission rules.
#
# Security: non-root user, iptables egress firewall, locked settings,
#           no host credentials, scoped sudo
###############################################################################

FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

# ── System packages ─────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl git ca-certificates gnupg sudo \
    iptables iproute2 dnsutils \
    python3 python3-pip python3-venv \
    build-essential \
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

# ── Non-root user with limited sudo ─────────────────────────────────────────
RUN useradd -m -s /bin/bash devuser \
    && echo "devuser ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" \
       >> /etc/sudoers.d/devuser \
    && echo "devuser ALL=(root) NOPASSWD: /usr/local/bin/lock-settings.sh" \
       >> /etc/sudoers.d/devuser \
    && chmod 0440 /etc/sudoers.d/devuser \
    && echo 'eval "$(mise activate bash)"' >> /home/devuser/.bashrc

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
RUN chmod 755 /usr/local/bin/init-firewall.sh /usr/local/bin/lock-settings.sh /usr/local/bin/entrypoint.sh

# Config: copy the config/ tree (mirrors home dir) to the user home AND to a
# root-owned canonical location that the entrypoint restores on every boot.
COPY config/ /usr/local/share/sandbox-config/
RUN find /usr/local/share/sandbox-config -type f -exec chmod 0444 {} + \
    && chown -R devuser:devuser /home/devuser

# ── Switch to non-root ──────────────────────────────────────────────────────
USER devuser
WORKDIR /workspace

ENV PATH="/home/devuser/.local/bin:/home/devuser/.local/share/mise/shims:/home/devuser/venv/bin:$PATH"
ENV VIRTUAL_ENV="/home/devuser/venv"

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
