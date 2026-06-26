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

CONFIG_SRC="/usr/local/share/sandbox-config"
CONFIG_SRC_DIND="/usr/local/share/sandbox-config-dind"
CONFIG_DST="/home/devuser"
CLAUDE_DIR="$CONFIG_DST/.claude"
SETTINGS_LOCAL="$CLAUDE_DIR/settings.local.json"

# Copy every regular file from a config tree to CONFIG_DST, skipping *.overrides.json
# (those are patch files consumed by the settings merge step, not direct config files).
apply_tree() {
    local src="$1"
    find "$src" -type f ! -name '*.overrides.json' | while read -r src_file; do
        local rel="${src_file#"$src"/}"
        local dst="$CONFIG_DST/$rel"
        mkdir -p "$(dirname "$dst")"
        cp "$src_file" "$dst"
        chown root:devuser "$dst"
        chmod 0444 "$dst"
        echo "[lock-settings]   Locked: $rel"
    done
}

if [ ! -d "$CONFIG_SRC" ]; then
    echo "[lock-settings] ERROR: Canonical config not found at $CONFIG_SRC"
    echo "[lock-settings] The image may have been built incorrectly."
    exit 1
fi

# ── Preserve user plugin enablement across the lock ───────────────────
# Claude Code records which plugins are enabled in settings.json under the
# "enabledPlugins" key. The apply_tree below overwrites settings.json with
# the canonical (plugin-less) copy from the image, which would silently
# disable every plugin the user installed in a previous session — even
# though the plugin files themselves persist in the claude-state-home
# volume. Capture the current enablement now and re-merge it after the
# canonical copy is in place so installed plugins stay enabled across
# container restarts. Permissions/hooks still come solely from the locked
# image canonical; only enabledPlugins carries over.
SETTINGS="$CLAUDE_DIR/settings.json"
PREV_ENABLED_PLUGINS='{}'
if [ -f "$SETTINGS" ]; then
    PREV_ENABLED_PLUGINS="$(jq -c '.enabledPlugins // {}' "$SETTINGS" 2>/dev/null || echo '{}')"
fi

# Always start from the base tree
apply_tree "$CONFIG_SRC"

# Re-merge the preserved plugin enablement (see capture above).
if [ "$PREV_ENABLED_PLUGINS" != "{}" ] && [ "$PREV_ENABLED_PLUGINS" != "null" ]; then
    chmod 0644 "$SETTINGS"
    jq --argjson ep "$PREV_ENABLED_PLUGINS" \
       '.enabledPlugins = ($ep + (.enabledPlugins // {}))' \
       "$SETTINGS" > "${SETTINGS}.tmp"
    mv "${SETTINGS}.tmp" "$SETTINGS"
    chown root:devuser "$SETTINGS"
    chmod 0444 "$SETTINGS"
    echo "[lock-settings] Preserved enabledPlugins across restart: $(echo "$PREV_ENABLED_PLUGINS" | jq -c 'keys')"
fi

if [ "${ENABLE_DOCKER:-}" = "true" ] && [ -d "$CONFIG_SRC_DIND" ]; then
    echo "[lock-settings] Applying DinD overlay (ENABLE_DOCKER=true)"
    # Overlay DinD-specific files on top (only files that differ need to live here)
    apply_tree "$CONFIG_SRC_DIND"

    # Merge settings.overrides.json patch into the already-copied settings.json
    OVR="$CONFIG_SRC_DIND/.claude/settings.overrides.json"
    SETTINGS="$CLAUDE_DIR/settings.json"
    if [ -f "$OVR" ]; then
        chmod 0644 "$SETTINGS"
        jq -s '
          .[0] as $b | .[1] as $o |
          $b
          + {_profile: ($o._profile // $b._profile),
             _description: ($o._description // $b._description)}
          | .permissions.allow = (.permissions.allow + ($o.permissions_allow_add // []))
          | .permissions.deny  = (.permissions.deny  - ($o.permissions_deny_remove // []))
        ' "$SETTINGS" "$OVR" > "${SETTINGS}.tmp"
        mv "${SETTINGS}.tmp" "$SETTINGS"
        chown root:devuser "$SETTINGS"
        chmod 0444 "$SETTINGS"
        echo "[lock-settings] Applied DinD settings overrides from $(basename "$OVR")"
    fi
fi

# ── Reclaim agent-writable mise global config ─────────────────────────
# Earlier image versions seeded ~/.config/mise/config.toml through the locked
# config tree, leaving it root-owned read-only. That file is exactly where
# `mise use -g <tool>` writes, so the lock broke global tool installs. The
# experimental setting now lives in the immutable MISE_EXPERIMENTAL image env
# var instead, and this config is no longer managed here. Because /home/devuser
# is a persisted volume, a stale root-owned copy can survive from older images —
# hand it (and its parent dir) back to devuser so global installs work again.
MISE_GLOBAL_CONFIG="$CONFIG_DST/.config/mise/config.toml"
if [ -e "$MISE_GLOBAL_CONFIG" ] && [ "$(stat -c '%U' "$MISE_GLOBAL_CONFIG")" != "devuser" ]; then
    chown devuser:devuser "$CONFIG_DST/.config/mise" "$MISE_GLOBAL_CONFIG"
    chmod u+rw "$MISE_GLOBAL_CONFIG"
    echo "[lock-settings] Reclaimed mise global config for devuser (was root-owned read-only)"
fi

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
