# Interactive Mode Selection for `code-sandbox` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When `code-sandbox` starts a fresh container without a mode flag, prompt the user to pick no-Docker vs. Docker mode; keep all non-interactive/scripted behaviour unchanged.

**Architecture:** A single Bash launcher (`bin/code-sandbox`). Add two flags (`--no-docker`, `--non-interactive`) and two state booleans (`MODE_EXPLICIT`, `NON_INTERACTIVE`) to the existing flag-parsing loop, plus a mode-selection block inserted after the container-reuse `exec` block and before `DOCKER_ARGS` assembly. Non-TTY and any explicit flag skip the prompt.

**Tech Stack:** Bash (`set -euo pipefail`), Docker CLI. No new dependencies.

## Global Constraints

- Target file: `bin/code-sandbox` only. No changes to entrypoint, firewall, or DinD security model.
- Script runs under `set -euo pipefail` — code must be safe under `-u` (unset var) and `-e` (errexit); note `read` returns non-zero on EOF.
- Default mode when unspecified is no-Docker (`ENABLE_DOCKER=false`), matching current behaviour.
- The prompt fires only when ALL hold: fresh container (guaranteed by placement after the reuse `exec`), `MODE_EXPLICIT=false`, `NON_INTERACTIVE=false`, and both stdin+stdout are a TTY (`[ -t 0 ] && [ -t 1 ]`).
- Passing both `--enable-docker` and `--no-docker` is a usage error (exit 1).
- Prompt menu text (verbatim):
  ```
  Select sandbox mode:
    1) No Docker (default)
    2) Docker (Podman) enabled
  Choice [1]:
  ```
  Empty or `1` → no-Docker; `2` → Docker; anything else → re-ask.

---

### Task 1: Add flags and state tracking to the parse loop

**Files:**
- Modify: `bin/code-sandbox:37-39` (state var declarations)
- Modify: `bin/code-sandbox:47-74` (flag-parsing `while` loop)
- Test: manual — `bash -n` syntax check + flag-conflict behaviour

**Interfaces:**
- Consumes: existing `ENABLE_DOCKER` variable (currently declared at line 38).
- Produces: booleans read by later steps/tasks — `MODE_EXPLICIT` (`true`/`false`, set by `--enable-docker` or `--no-docker`), `NON_INTERACTIVE` (`true`/`false`, set by `--non-interactive`), and the internal `_ENABLE_DOCKER_SEEN` / `_NO_DOCKER_SEEN` flags used only for the conflict check in Step 4.

- [ ] **Step 1: Add the state variables**

In the block that currently reads (lines 37-39):

```bash
WORKSPACE_DIR="$(pwd)"
SKIP_BUILD=false
ENABLE_DOCKER=false
ENTRYPOINT_OVERRIDE=""
```

change to:

```bash
WORKSPACE_DIR="$(pwd)"
SKIP_BUILD=false
ENABLE_DOCKER=false
MODE_EXPLICIT=false
NON_INTERACTIVE=false
_ENABLE_DOCKER_SEEN=false
_NO_DOCKER_SEEN=false
ENTRYPOINT_OVERRIDE=""
```

- [ ] **Step 2: Add the mode and non-interactive flag cases**

Replace the existing `--enable-docker` case (lines 53-56):

```bash
        --enable-docker)
            ENABLE_DOCKER=true
            shift
            ;;
```

with:

```bash
        --enable-docker)
            ENABLE_DOCKER=true
            MODE_EXPLICIT=true
            _ENABLE_DOCKER_SEEN=true
            shift
            ;;
        --no-docker)
            ENABLE_DOCKER=false
            MODE_EXPLICIT=true
            _NO_DOCKER_SEEN=true
            shift
            ;;
        --non-interactive)
            NON_INTERACTIVE=true
            shift
            ;;
```

- [ ] **Step 3: Update the usage line in the unknown-option case**

Replace the `-*)` case body (lines 65-69):

```bash
        -*)
            echo "Unknown option: $1" >&2
            echo "Usage: code-sandbox [--no-build] [--enable-docker] [--entrypoint <cmd>] [-- <command> [args...]]" >&2
            exit 1
            ;;
```

with:

```bash
        -*)
            echo "Unknown option: $1" >&2
            echo "Usage: code-sandbox [--no-build] [--enable-docker | --no-docker] [--non-interactive] [--entrypoint <cmd>] [-- <command> [args...]]" >&2
            exit 1
            ;;
```

- [ ] **Step 4: Add the conflict check after the parse loop**

Immediately after the `done` that closes the `while` loop (currently line 74) and before the `# Remaining arguments...` comment (line 76), insert:

```bash

# Reject contradictory mode flags
if [[ "$_ENABLE_DOCKER_SEEN" == "true" ]] && [[ "$_NO_DOCKER_SEEN" == "true" ]]; then
    echo "[code-sandbox] ERROR: --enable-docker and --no-docker are mutually exclusive." >&2
    exit 1
fi
```

- [ ] **Step 5: Syntax check**

Run: `bash -n bin/code-sandbox`
Expected: no output, exit 0.

- [ ] **Step 6: Verify conflict detection and non-conflicting flags parse**

Run: `bash bin/code-sandbox --enable-docker --no-docker --no-build --entrypoint true -- true; echo "exit=$?"`
Expected: prints the mutual-exclusive ERROR line and `exit=1`.

Run: `bash bin/code-sandbox --no-docker --non-interactive --no-build --entrypoint true -- true; echo "exit=$?"`
Expected: proceeds past parsing (may fail later if Docker daemon/image absent, but does NOT print the mutual-exclusive error and does NOT hang on a prompt). `exit` reflects the run, not a parse error.

- [ ] **Step 7: Commit**

```bash
git add bin/code-sandbox
git commit -m "feat: add --no-docker and --non-interactive flags to code-sandbox"
```

---

### Task 2: Add the interactive mode-selection prompt

**Files:**
- Modify: `bin/code-sandbox` — insert a new block between the container-reuse `exec` block (ends ~line 194) and the `# ── Assemble docker run args ──` comment (~line 196)
- Test: manual — TTY prompt behaviour + non-TTY auto-skip

**Interfaces:**
- Consumes: `MODE_EXPLICIT`, `NON_INTERACTIVE` (from Task 1) and `ENABLE_DOCKER`.
- Produces: possibly-updated `ENABLE_DOCKER` consumed by the existing `if $ENABLE_DOCKER; then` block at line 214.

- [ ] **Step 1: Insert the prompt block**

Between line 194 (`fi` closing the reuse block) and line 196 (`# ── Assemble docker run args ──...`), insert:

```bash

# ── Interactive mode selection (fresh container only) ────────────────────────
# Reached only when NOT attaching to a running container (the block above
# exec's away when it attaches). Prompt only when mode was not chosen via flag,
# --non-interactive was not passed, and we have an interactive terminal.
if [[ "$MODE_EXPLICIT" == "false" ]] && [[ "$NON_INTERACTIVE" == "false" ]] \
   && [ -t 0 ] && [ -t 1 ]; then
    while true; do
        echo "Select sandbox mode:"
        echo "  1) No Docker (default)"
        echo "  2) Docker (Podman) enabled"
        # `read` returns non-zero on EOF; guard so `set -e` doesn't abort.
        read -r -p "Choice [1]: " _mode_choice || _mode_choice=""
        case "$_mode_choice" in
            ""|1)
                ENABLE_DOCKER=false
                break
                ;;
            2)
                ENABLE_DOCKER=true
                break
                ;;
            *)
                echo "[code-sandbox] Please enter 1 or 2." >&2
                ;;
        esac
    done
fi
```

- [ ] **Step 2: Syntax check**

Run: `bash -n bin/code-sandbox`
Expected: no output, exit 0.

- [ ] **Step 3: Verify non-TTY auto-skips (no hang)**

Run: `printf '' | bash bin/code-sandbox --no-build --entrypoint true -- true; echo "exit=$?"`
Expected: does NOT print the "Select sandbox mode" menu and does NOT hang (stdin is not a TTY here). Command returns promptly. (It may fail later if the image is absent — that's fine; the point is no prompt, no hang.)

- [ ] **Step 4: Verify the interactive path manually (real terminal)**

In an interactive terminal run: `bin/code-sandbox --no-build`
Expected: the menu appears. Pressing Enter or `1` proceeds in no-Docker mode; `2` proceeds in Docker mode; invalid input reprints "Please enter 1 or 2." and re-asks. (Confirm the chosen mode via the later `[code-sandbox] Starting sandbox...` behaviour / whether DinD args are used.)

- [ ] **Step 5: Commit**

```bash
git add bin/code-sandbox
git commit -m "feat: prompt for sandbox mode when starting a fresh container"
```

---

### Task 3: Update header-comment documentation

**Files:**
- Modify: `bin/code-sandbox:5-20` (Usage / Options / Examples comment block)
- Test: manual — `bash -n` + visual read

**Interfaces:**
- Consumes: nothing (comment-only change).
- Produces: nothing.

- [ ] **Step 1: Update the Usage and Options lines**

Replace lines 5-14:

```bash
# Usage:
#   code-sandbox [--no-build] [--enable-docker] [-- <command> [args...]]
#
# Options:
#   --no-build        Skip rebuilding the Docker image before running
#   --enable-docker   Enable rootless Podman inside the sandbox for tasks that
#                     need Docker (testcontainers, image builds, compose stacks).
#                     Inner containers are isolated and go through the same
#                     egress firewall as the agent. Increases PIDs (512) and
#                     memory (8g) limits.
```

with:

```bash
# Usage:
#   code-sandbox [--no-build] [--enable-docker | --no-docker] [--non-interactive] [-- <command> [args...]]
#
# Options:
#   --no-build        Skip rebuilding the Docker image before running
#   --enable-docker   Enable rootless Podman inside the sandbox for tasks that
#                     need Docker (testcontainers, image builds, compose stacks).
#                     Inner containers are isolated and go through the same
#                     egress firewall as the agent. Increases PIDs (512) and
#                     memory (8g) limits.
#   --no-docker       Explicitly run without Docker. Skips the interactive mode
#                     prompt.
#   --non-interactive Skip the interactive mode prompt and use the default
#                     (no Docker) unless a mode flag is also given. Used by the
#                     test suite and scripted invocations.
#
# When starting a fresh container without a mode flag, an interactive prompt
# asks whether to enable Docker. The prompt is skipped when a mode flag or
# --non-interactive is given, or when stdin/stdout is not a terminal.
```

- [ ] **Step 2: Add an example**

Replace lines 16-20:

```bash
# Examples:
#   code-sandbox                              # interactive bash shell
#   code-sandbox -- claude -p "fix the bug" --max-turns 30
#   code-sandbox --no-build -- bash           # skip rebuild, run immediately
#   code-sandbox --enable-docker -- bash      # shell with Docker (Podman) access
```

with:

```bash
# Examples:
#   code-sandbox                              # prompts for mode, then bash shell
#   code-sandbox -- claude -p "fix the bug" --max-turns 30
#   code-sandbox --no-build -- bash           # skip rebuild, run immediately
#   code-sandbox --enable-docker -- bash      # shell with Docker (Podman) access
#   code-sandbox --non-interactive -- bash    # no prompt, default (no Docker)
```

- [ ] **Step 3: Syntax check**

Run: `bash -n bin/code-sandbox`
Expected: no output, exit 0.

- [ ] **Step 4: Commit**

```bash
git add bin/code-sandbox
git commit -m "docs: document --no-docker and --non-interactive in code-sandbox header"
```

---

### Task 4: Verify the existing test suite still passes

**Files:**
- Test: `test-sandbox.sh` (no modification expected)

**Interfaces:**
- Consumes: the modified `bin/code-sandbox`.
- Produces: confidence that non-TTY and `--enable-docker` paths are unaffected.

- [ ] **Step 1: Confirm no test invocation would hit the prompt**

Run: `grep -n '"\$SANDBOX"' test-sandbox.sh`
Expected: every invocation either passes `--enable-docker`, uses `--entrypoint`, or has captured/non-TTY stdout — so all auto-skip the prompt. Confirm by inspection; if any interactive invocation exists, add `--non-interactive` to it in this step and note it in the commit.

- [ ] **Step 2: Run the suite**

Run: `bash test-sandbox.sh`
Expected: suite completes with its normal PASS summary (same result as before this change). If it can't run locally (no Docker), note that CI (`.github/workflows/test-sandbox.yml`) covers it and rely on that.

- [ ] **Step 3: Commit (only if Step 1 required a test edit)**

```bash
git add test-sandbox.sh
git commit -m "test: pass --non-interactive in code-sandbox invocations"
```

If no test edit was needed, skip this commit.

---

## Self-Review

**Spec coverage:**
- `--no-docker` flag → Task 1. ✓
- `--non-interactive` flag → Task 1. ✓
- `MODE_EXPLICIT` / `NON_INTERACTIVE` state → Task 1. ✓
- Conflict error on both mode flags → Task 1, Step 4. ✓
- Prompt fires only fresh + no explicit flag + not non-interactive + TTY → Task 2, Step 1. ✓
- Menu text and 1/2/empty/invalid handling → Task 2, Step 1. ✓
- Placement after reuse `exec`, before `DOCKER_ARGS` → Task 2, Step 1. ✓
- Header/usage/example docs → Task 3. ✓
- Existing tests unaffected (non-TTY auto-skip) → Task 2 Step 3 + Task 4. ✓

**Placeholder scan:** No placeholders. The `_ENABLE_DOCKER_SEEN`/`_NO_DOCKER_SEEN` flags are declared in Task 1 Step 1, set in Step 2, and consumed by the conflict check in Step 4 — all shown as exact code.

**Type consistency:** Variable names consistent across tasks — `MODE_EXPLICIT`, `NON_INTERACTIVE`, `ENABLE_DOCKER`, `_ENABLE_DOCKER_SEEN`, `_NO_DOCKER_SEEN`. The prompt sets `ENABLE_DOCKER`, which the pre-existing `if $ENABLE_DOCKER; then` block (line 214) already consumes. ✓
