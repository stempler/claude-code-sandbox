#!/bin/bash
###############################################################################
# lock-settings.sh — Restore and lock all files from the config/ tree
#
# Runs as root at container startup, BEFORE Claude Code launches.
# Recursively copies the canonical config tree from the image into the
# writable home directory and makes every file root-owned + read-only so the
# agent cannot tamper with its own permission rules or other config files.
#
# The config/ directory in the repository mirrors /home/devuser/:
#   config/.claude/settings.json -> /home/devuser/.claude/settings.json
###############################################################################

set -euo pipefail

# Select settings profile: DinD profile when ENABLE_DOCKER=true, otherwise default
CONFIG_SRC="/usr/local/share/sandbox-config"
CONFIG_SRC_DIND="/usr/local/share/sandbox-config-dind"

if [ "${ENABLE_DOCKER:-}" = "true" ] && [ -d "$CONFIG_SRC_DIND" ]; then
    CONFIG_SRC="$CONFIG_SRC_DIND"
    echo "[lock-settings] Using DinD settings profile (ENABLE_DOCKER=true)"
fi

CONFIG_DST="/home/devuser"
CLAUDE_DIR="$CONFIG_DST/.claude"
SETTINGS_LOCAL="$CLAUDE_DIR/settings.local.json"

if [ ! -d "$CONFIG_SRC" ]; then
    echo "[lock-settings] ERROR: Canonical config not found at $CONFIG_SRC"
    echo "[lock-settings] The image may have been built incorrectly."
    exit 1
fi

# Restore and lock every file in the canonical config tree
find "$CONFIG_SRC" -type f | while read -r src_file; do
    rel_path="${src_file#"$CONFIG_SRC"/}"
    dst_file="$CONFIG_DST/$rel_path"
    mkdir -p "$(dirname "$dst_file")"
    cp "$src_file" "$dst_file"
    chown root:devuser "$dst_file"
    chmod 0444 "$dst_file"
    echo "[lock-settings]   Locked: $rel_path"
done

# Stake claim on settings.local.json — Claude Code supports this as an
# override file. Create it root-owned and read-only so the agent cannot
# create its own version to override permissions.
mkdir -p "$CLAUDE_DIR"
echo '{}' > "$SETTINGS_LOCAL"
chown root:devuser "$SETTINGS_LOCAL"
chmod 0444 "$SETTINGS_LOCAL"

echo "[lock-settings] All config files restored from image and locked (root-owned, read-only)"
echo "[lock-settings] settings.local.json claimed and locked (prevents override attack)"

# ── Merge credential deny rules (if present) ──────────────────────────
# When .sandbox-secrets.yaml is configured, bin/code-sandbox generates a
# deny-rules.json array of Read/Bash deny patterns for each credential
# destination path. Merge these into settings.json before locking so the
# agent cannot read the injected credential files.
CRED_DENY="/run/sandbox-secrets/deny-rules.json"
if [ -f "$CRED_DENY" ]; then
    SETTINGS="$CLAUDE_DIR/settings.json"
    chmod 0644 "$SETTINGS"
    jq --slurpfile extra "$CRED_DENY" \
       '.permissions.deny += $extra[0]' "$SETTINGS" > "${SETTINGS}.tmp"
    mv "${SETTINGS}.tmp" "$SETTINGS"
    chown root:devuser "$SETTINGS"
    chmod 0444 "$SETTINGS"
    echo "[lock-settings] Merged $(jq 'length' "$CRED_DENY") credential deny rules into settings.json"
fi
