# Credential Injection for Sandbox

## Context

The sandbox currently has no mechanism for injecting credentials from the host. Tasks that need authenticated access to external services (Gradle builds with private registries, npm with auth tokens, API keys for test suites) cannot be supported without manual workarounds.

The goal is a configuration-driven system where users declare sandbox-specific credentials (not personal keys) and how they should be placed inside the container. This restricts the blast radius of a potential leak and makes credential rotation straightforward.

## Design Overview

A per-project `.sandbox-secrets.yaml` file declares secrets (sourced from pluggable shell commands on the host) and targets (gomplate templates that render secrets into config files inside the container). Secret resolution happens entirely on the host. Resolved values are transported via a tmpfs-mounted JSON payload. Inside the container, the entrypoint renders templates, locks output files, and wipes the payload before the agent starts. Rendered files are hidden from the agent via auto-generated deny rules.

## Config File: `.sandbox-secrets.yaml`

Located in the workspace root on the host, alongside `.sandbox-domains`.

```yaml
secrets:
  NEXUS_USER:
    source: gopass show ci/nexus/user
  NEXUS_PASS:
    source: gopass show ci/nexus/password
  NPM_TOKEN:
    source: sops -d --extract '["npm_token"]' secrets.enc.yaml

targets:
  - template: gradle-properties          # built-in template name
    dest: /home/devuser/.gradle/gradle.properties
    secrets:                              # scoped + aliased
      - name: NEXUS_USER
        as: nexusUser
      - name: NEXUS_PASS
        as: nexusPassword

  - template: dotenv
    dest: /workspace/.env.sandbox
    secrets:                              # scoped, no aliasing
      - NEXUS_USER
      - NEXUS_PASS

  - template: .sandbox-templates/npmrc.tpl   # custom template
    dest: /home/devuser/.npmrc
    secrets:
      - name: NPM_TOKEN
        as: authToken
```

### Schema

**`secrets`** (required): A map of logical secret names to their sources.

| Field | Type | Description |
|-------|------|-------------|
| `<NAME>` | map key | Logical name used to reference the secret in targets |
| `source` | string | Shell command executed on the host. Stdout is captured as the value. |

**`targets`** (required): A list of template-to-file mappings.

| Field | Type | Description |
|-------|------|-------------|
| `template` | string | Built-in template name (no `/` or `.tpl` suffix) or path to a custom `.tpl` file relative to the workspace root. |
| `dest` | string | Absolute path inside the container where the rendered file is placed. |
| `secrets` | list (optional) | Which secrets to expose to this template. If omitted, all secrets are available. Each entry is either a string (secret name, no aliasing) or an object with `name` and `as` fields. |

**`secrets` entry formats:**
- **String**: `- NEXUS_USER` -- passes the secret with its original name
- **Object**: `- name: NEXUS_USER` / `  as: nexusUser` -- passes the secret under an alternate name

## Host-Side Resolution (`bin/code-sandbox`)

A new function `resolve_secrets()` is added after the domain-allowlist handling (after line 145) and before assembling final `DOCKER_ARGS`.

### Steps

1. Check for `$WORKSPACE_DIR/.sandbox-secrets.yaml`. If absent, skip (no-op).
2. Parse the file with `yq` (Go-based, Mike Farah's `yq`). This is a new host dependency documented in the README.
3. For each entry in `secrets`, execute the `source` command via `bash -c "$source_cmd"`, capturing stdout. Trim trailing newlines.
4. Build a JSON payload:
   ```json
   {
     "secrets": {
       "NEXUS_USER": "resolved_value",
       "NEXUS_PASS": "resolved_value",
       "NPM_TOKEN": "resolved_value"
     },
     "targets": [
       {
         "template": "gradle-properties",
         "dest": "/home/devuser/.gradle/gradle.properties",
         "secrets": [
           {"name": "NEXUS_USER", "as": "nexusUser"},
           {"name": "NEXUS_PASS", "as": "nexusPassword"}
         ]
       }
     ]
   }
   ```
5. Build a deny-rules JSON array from the target `dest` paths:
   ```json
   [
     "Read(/home/devuser/.gradle/gradle.properties)",
     "Bash(cat /home/devuser/.gradle/gradle.properties*)",
     "Read(/workspace/.env.sandbox)",
     "Bash(cat /workspace/.env.sandbox*)",
     "Read(/home/devuser/.npmrc)",
     "Bash(cat /home/devuser/.npmrc*)"
   ]
   ```
6. Write both files to a host-side temp directory (`mktemp -d`).
7. Add to `DOCKER_ARGS`:
   ```bash
   --mount type=tmpfs,destination=/run/sandbox-secrets,tmpfs-mode=0700,tmpfs-size=1048576
   -v "$SECRETS_DIR/payload.json:/run/sandbox-secrets/payload.json:ro"
   -v "$SECRETS_DIR/deny-rules.json:/run/sandbox-secrets/deny-rules.json:ro"
   -e SANDBOX_SECRETS=true
   ```
8. Register a trap to clean up the host temp directory: `trap "rm -rf '$SECRETS_DIR'" EXIT`.

### Error Handling

- If any `source` command exits non-zero, print `[code-sandbox] ERROR: secret '<NAME>' source command failed (exit <code>)` and abort before starting the container.
- If `yq` is not installed, print a clear message with install instructions and exit.
- All-or-nothing: either all secrets resolve successfully or the container does not start.

## Container-Side Rendering

### `lock-settings.sh` Changes

At the end of `lock-settings.sh`, after locking all config files and claiming `settings.local.json`, add a deny-rules overlay step:

```bash
# ── Merge secret deny rules (if present) ──────────────────────────────
SECRETS_DENY="/run/sandbox-secrets/deny-rules.json"
if [ -f "$SECRETS_DENY" ]; then
    SETTINGS="$CLAUDE_DIR/settings.json"
    chmod 0644 "$SETTINGS"
    jq --slurpfile extra "$SECRETS_DENY" \
       '.permissions.deny += $extra[0]' "$SETTINGS" > "${SETTINGS}.tmp"
    mv "${SETTINGS}.tmp" "$SETTINGS"
    chown root:devuser "$SETTINGS"
    chmod 0444 "$SETTINGS"
    echo "[lock-settings] Added $(jq length "$SECRETS_DENY") secret-deny rules"
fi
```

This runs as root before the agent starts. The deny rules are merged into the locked `settings.json`, so the agent cannot read the credential files via Claude Code's `Read` tool or `Bash(cat ...)`.

### `entrypoint.sh` Changes

A new block after `lock-settings.sh` (line 101) and before `init-firewall.sh` (line 105):

```bash
# ── Render sandbox secrets ────────────────────────────────────────────
if [ "${SANDBOX_SECRETS:-}" = "true" ] && [ -f /run/sandbox-secrets/payload.json ]; then
    echo "[entrypoint] Rendering sandbox secrets..."
    /usr/local/bin/render-secrets.sh
fi
```

### `render-secrets.sh` (new script)

Runs as root during entrypoint, before privilege drop.

**Steps:**

1. Read `/run/sandbox-secrets/payload.json`.
2. For each target in the `targets` array:
   a. **Build per-target context**: If the target has a `secrets` list, construct a filtered/aliased secrets map. Otherwise, use the full `secrets` map. Write the per-target context to `/run/sandbox-secrets/ctx-<i>.json`:
      ```json
      { "secrets": { "nexusUser": "val", "nexusPassword": "val" } }
      ```
   b. **Resolve template path** (two-tier lookup):
      - If the template value contains `/` or ends with `.tpl`: treat as a custom template at `/workspace/<template>`.
      - Otherwise: look for `/workspace/.sandbox-templates/<name>.tpl` first (project-local override), then fall back to `/usr/local/share/sandbox-templates/<name>.tpl` (built-in).
   c. **Create destination directory**: `mkdir -p "$(dirname "$dest")"`.
   d. **Run gomplate**:
      ```bash
      gomplate -d "ctx=file:///run/sandbox-secrets/ctx-${i}.json?type=application/json" \
          -f "$template_path" \
          -o "$dest"
      ```
   e. **Lock output file**:
      ```bash
      chown root:devuser "$dest"
      chmod 0444 "$dest"
      ```
3. **Wipe all secret material**: `rm -rf /run/sandbox-secrets/*`

**Error handling:**
- Template not found (neither custom, project-local override, nor built-in): print error with the lookup paths tried, exit non-zero.
- gomplate fails (e.g. template syntax error, `required` check fails): print error, exit non-zero. This halts the entrypoint before the agent starts.

## Template System

### Built-In Templates

Stored at `/usr/local/share/sandbox-templates/` in the Docker image.

**`gradle-properties.tpl`** -- Java properties format:
```
{{- range $name, $value := (ds "ctx").secrets }}
{{ $name }}={{ $value }}
{{- end }}
```

**`dotenv.tpl`** -- Shell-compatible env file:
```
{{- range $name, $value := (ds "ctx").secrets }}
{{ $name }}={{ $value | quote }}
{{- end }}
```

**`npmrc.tpl`** -- npm auth config:
```
{{- with (ds "ctx").secrets }}
{{- if .registry }}registry={{ .registry }}{{ end }}
{{- if .authToken }}//registry.npmjs.org/:_authToken={{ .authToken }}{{ end }}
{{- end }}
```

**`netrc.tpl`** -- machine/login/password format:
```
{{- with (ds "ctx").secrets }}
machine {{ .machine | required "machine is required" }}
login {{ .login | required "login is required" }}
password {{ .password | required "password is required" }}
{{- end }}
```

### Built-In Template Conventions

Built-in templates that iterate over all secrets (like `gradle-properties` and `dotenv`) work with any secret names. Templates that reference specific keys (like `npmrc` expecting `authToken`, or `netrc` expecting `machine`/`login`/`password`) document their expected names. Users configure `as` aliases in their YAML to provide secrets under the expected names.

### Custom Templates

Users can create custom templates in `.sandbox-templates/` in their workspace or reference them by relative path in the `template` field.

### Template Context

Every template receives a gomplate datasource named `ctx` containing:

```json
{
  "secrets": {
    "<effective_name>": "<value>",
    ...
  }
}
```

Where `<effective_name>` is the `as` alias if provided, or the original secret name.

**Accessing secrets:**
- By name: `{{ (ds "ctx").secrets.nexusUser }}`
- With required validation: `{{ (ds "ctx").secrets.nexusUser | required "nexusUser is required" }}`
- Iterate all: `{{ range $k, $v := (ds "ctx").secrets }}{{ $k }}={{ $v }}\n{{ end }}`

## Agent Protection

Rendered credential files are hidden from the agent through two layers:

### 1. File Permissions

Each rendered file is set to `root:devuser 0444`. Since the agent runs as `devuser` with no sudo, it cannot modify these files. The files are readable by processes running as devuser (Gradle, npm, etc.) so tools that automatically read credentials from these paths work normally.

### 2. Claude Code Deny Rules

Auto-generated deny rules are merged into `settings.json` for each target destination:
- `Read(<dest>)` -- blocks Claude Code's Read tool
- `Bash(cat <dest>*)` -- blocks reading via cat

The deny rules are generated on the host and applied during `lock-settings.sh`, before the agent starts. The agent cannot remove them because `settings.json` is root-owned and read-only.

Note: The existing deny rules for `Bash(env)`, `Bash(printenv *)`, and `Bash(export *)` already prevent the agent from inspecting environment variables.

### 3. Payload Cleanup

The tmpfs-mounted `/run/sandbox-secrets/` directory is wiped after rendering. By the time the agent starts, the source JSON payload no longer exists. The existing deny rule `Read(/run/secrets/*)` provides defense-in-depth.

## Docker Image Changes

### Dockerfile Additions

1. **Install gomplate** (single static binary, ~15 MB):
   ```dockerfile
   RUN curl -fsSL https://github.com/hairyhenderson/gomplate/releases/download/v4.3.0/gomplate_linux-amd64 \
       -o /usr/local/bin/gomplate \
       && chmod 755 /usr/local/bin/gomplate
   ```

2. **Install jq** (for deny-rule merging in `lock-settings.sh`). Add `jq` to the existing `apt-get install` line in the system packages section.

3. **Copy built-in templates and render script**:
   ```dockerfile
   COPY sandbox-templates/ /usr/local/share/sandbox-templates/
   COPY render-secrets.sh  /usr/local/bin/render-secrets.sh
   RUN chmod 755 /usr/local/bin/render-secrets.sh
   ```

## Files Changed

| File | Change |
|------|--------|
| `bin/code-sandbox` | Add `resolve_secrets()` function (~50 lines) after domain-allowlist handling |
| `entrypoint.sh` | Add render-secrets block (~4 lines) after `lock-settings.sh`, before `init-firewall.sh` |
| `lock-settings.sh` | Add deny-rules overlay (~12 lines) at the end |
| `Dockerfile` | Install gomplate + jq, copy templates and render script |
| `render-secrets.sh` (new) | Template rendering, per-target context building, file locking, payload cleanup |
| `sandbox-templates/` (new dir) | Built-in `.tpl` files: gradle-properties, dotenv, npmrc, netrc |
| `test-sandbox.sh` | New test cases for credential injection |
| `CLAUDE.md` | Document the feature, config format, and `yq` host dependency |

## Host Dependencies

- **`yq`** (Go-based, Mike Farah's): Required on the host for parsing `.sandbox-secrets.yaml`. Install via `brew install yq`, `apt install yq`, or download from GitHub releases.
- Secret source tools (gopass, sops, etc.) must be installed on the host as needed.

## Verification Plan

### Manual Testing

1. Create a test `.sandbox-secrets.yaml` with gopass or echo-based sources
2. Run `bin/code-sandbox` and verify:
   - Secrets resolve on the host (check stdout messages)
   - Template files are rendered at correct destinations inside the container
   - Files are root-owned and read-only (`ls -la`)
   - `/run/sandbox-secrets/` is empty after startup
   - Claude Code cannot read the files (test with `claude -p "read /home/devuser/.gradle/gradle.properties"`)

### Automated Tests (`test-sandbox.sh`)

Add test cases:
1. **Secrets rendered correctly**: Use `echo`-based source commands, verify file contents match expected output
2. **Files are locked**: Verify `root:devuser 0444` permissions on rendered files
3. **Payload wiped**: Verify `/run/sandbox-secrets/` is empty after startup
4. **Deny rules present**: Verify `settings.json` contains deny entries for each target dest
5. **Agent cannot read secrets**: Run `cat` on rendered files as devuser through Claude Code settings evaluation (or verify deny rules block it)
6. **Missing template fails gracefully**: Use a nonexistent template name, verify container startup aborts with a clear error
7. **Failed source command aborts**: Use a source that exits non-zero, verify container does not start
