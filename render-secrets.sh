#!/bin/bash
###############################################################################
# render-secrets.sh — Container-side secret rendering
#
# Runs as root at container startup, BEFORE gosu drops to devuser.
# Reads /run/sandbox-secrets/payload.json, renders gomplate templates for each
# target, locks the output files root-owned/read-only, then wipes all secret
# material from /run/sandbox-secrets/.
#
# Payload schema:
#   {
#     "secrets": { "<NAME>": "<value>", ... },
#     "targets": [
#       {
#         "template": "<bare-name or path>",
#         "dest": "/absolute/path/to/output",
#         "secrets": [               # optional; null/absent = all secrets
#           "NAME",                  # string: use as-is (name == as)
#           {"name": "N", "as": "A"} # object: alias N → A in template
#         ]
#       },
#       ...
#     ]
#   }
#
# Template lookup (two-tier):
#   - If template contains "/" OR ends with ".tpl": custom path -> /workspace/<template>
#   - Otherwise (bare name):
#       1. /workspace/.sandbox-templates/<name>.tpl
#       2. /usr/local/share/sandbox-templates/<name>.tpl
#     First found wins; if neither exists: error + exit 1.
#
# Tools required in image: bash, jq, gomplate
###############################################################################

set -euo pipefail

PAYLOAD=/run/sandbox-secrets/payload.json
BUILTIN_TEMPLATES=/usr/local/share/sandbox-templates
WORKSPACE_TEMPLATES=/workspace/.sandbox-templates

# -- Guard: skip silently if no payload -------------------------------------
if [ ! -f "$PAYLOAD" ]; then
    exit 0
fi

echo "[render-secrets] Processing secret payload..."

# Read full payload once into a variable for repeated jq use
payload_json=$(cat "$PAYLOAD")

# Count targets
count=$(printf '%s' "$payload_json" | jq '.targets | length')

if [ "$count" -eq 0 ]; then
    echo "[render-secrets] No targets defined; nothing to render."
    rm -f "$PAYLOAD"
    exit 0
fi

# -- Process each target ----------------------------------------------------
for i in $(seq 0 $((count - 1))); do
    template_name=$(printf '%s' "$payload_json" | jq -r ".targets[$i].template")
    dest=$(printf '%s' "$payload_json" | jq -r ".targets[$i].dest")

    # 1. Build per-target context JSON
    ctx_file="/run/sandbox-secrets/ctx-${i}.json"
    jq -n --argjson payload "$payload_json" --argjson idx "$i" '
      $payload.targets[$idx] as $target |
      ($payload.secrets) as $all_secrets |
      if $target.secrets == null then
        {"secrets": $all_secrets}
      else
        {"secrets": ($target.secrets | reduce .[] as $entry (
          {};
          . + (
            if ($entry | type) == "string" then
              {($entry): $all_secrets[$entry]}
            else
              {($entry.as): $all_secrets[$entry.name]}
            end
          )
        ))}
      end
    ' > "$ctx_file"

    # 2. Resolve template path (two-tier lookup)
    if [[ "$template_name" == */* ]] || [[ "$template_name" == *.tpl ]]; then
        # Custom path: treat as relative to /workspace
        template_path="/workspace/$template_name"
        if [ ! -f "$template_path" ]; then
            echo "[render-secrets] ERROR: Custom template not found: $template_path"
            exit 1
        fi
    else
        # Bare name: workspace override first, then built-in
        workspace_tpl="$WORKSPACE_TEMPLATES/${template_name}.tpl"
        builtin_tpl="$BUILTIN_TEMPLATES/${template_name}.tpl"
        if [ -f "$workspace_tpl" ]; then
            template_path="$workspace_tpl"
        elif [ -f "$builtin_tpl" ]; then
            template_path="$builtin_tpl"
        else
            echo "[render-secrets] ERROR: Template '$template_name' not found."
            echo "[render-secrets]   Tried: $workspace_tpl"
            echo "[render-secrets]   Tried: $builtin_tpl"
            exit 1
        fi
    fi

    # 3. Create destination directory
    mkdir -p "$(dirname "$dest")"

    # 4. Render template via gomplate
    if ! gomplate \
            -d "ctx=file://${ctx_file}?type=application/json" \
            -f "$template_path" \
            -o "$dest"; then
        echo "[render-secrets] ERROR: gomplate failed for target $i (template=$template_name dest=$dest)"
        exit 1
    fi

    # 5. Lock the output file: root-owned, group-readable by devuser, immutable to agent
    chown root:devuser "$dest"
    chmod 0444 "$dest"

    echo "[render-secrets] Rendered: $template_name -> $dest"
done

# -- Wipe all secret material -----------------------------------------------
# Remove per-target context files and the payload; leave the directory intact
# (lock-settings.sh may place deny-rules.json there later).
rm -f /run/sandbox-secrets/ctx-*.json
rm -f "$PAYLOAD"

echo "[render-secrets] Secret material wiped."
