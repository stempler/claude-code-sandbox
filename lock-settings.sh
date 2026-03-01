#!/bin/bash
###############################################################################
# lock-settings.sh — Restore and lock Claude Code permissions
#
# Runs as root (via sudo) at container startup, BEFORE Claude Code launches.
# Copies the canonical settings.json from the image into the writable
# claude-state volume and makes it root-owned + read-only so the agent
# cannot tamper with its own permission rules.
###############################################################################

set -euo pipefail

SETTINGS_SRC="/usr/local/share/claude-settings.json"
SETTINGS_DST="/home/devuser/.claude/settings.json"
SETTINGS_DIR="$(dirname "$SETTINGS_DST")"
SETTINGS_LOCAL="$SETTINGS_DIR/settings.local.json"

if [ ! -f "$SETTINGS_SRC" ]; then
    echo "[lock-settings] ERROR: Canonical settings not found at $SETTINGS_SRC"
    echo "[lock-settings] The image may have been built incorrectly."
    exit 1
fi

mkdir -p "$SETTINGS_DIR"

# Restore canonical settings.json
cp "$SETTINGS_SRC" "$SETTINGS_DST"
chown root:devuser "$SETTINGS_DST"
chmod 0444 "$SETTINGS_DST"

# Stake claim on settings.local.json — Claude Code supports this as an
# override file. Create it root-owned and read-only so the agent cannot
# create its own version to override permissions.
echo '{}' > "$SETTINGS_LOCAL"
chown root:devuser "$SETTINGS_LOCAL"
chmod 0444 "$SETTINGS_LOCAL"

echo "[lock-settings] settings.json restored from image and locked (root-owned, read-only)"
echo "[lock-settings] settings.local.json claimed and locked (prevents override attack)"
