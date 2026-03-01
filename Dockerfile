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

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# ── System packages ─────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl git ca-certificates gnupg sudo \
    iptables iproute2 dnsutils \
    python3 python3-pip python3-venv \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# ── Node.js 20 (required by Claude Code) ────────────────────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# ── Claude Code CLI ─────────────────────────────────────────────────────────
RUN --mount=type=cache,target=/root/.npm \
    npm install -g @anthropic-ai/claude-code --loglevel info --foreground-scripts

# ── Non-root user with limited sudo ─────────────────────────────────────────
RUN useradd -m -s /bin/bash devuser \
    && echo "devuser ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" \
       >> /etc/sudoers.d/devuser \
    && echo "devuser ALL=(root) NOPASSWD: /usr/local/bin/lock-settings.sh" \
       >> /etc/sudoers.d/devuser \
    && chmod 0440 /etc/sudoers.d/devuser

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

# Settings: copy to user dir AND to a root-owned canonical location
# that the entrypoint restores on every boot (tamper recovery).
COPY claude-settings.json /home/devuser/.claude/settings.json
COPY claude-settings.json /usr/local/share/claude-settings.json
RUN chmod 0444 /usr/local/share/claude-settings.json \
    && chown -R devuser:devuser /home/devuser/.claude

# ── Switch to non-root ──────────────────────────────────────────────────────
USER devuser
WORKDIR /workspace

ENV PATH="/home/devuser/venv/bin:$PATH"
ENV VIRTUAL_ENV="/home/devuser/venv"

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
