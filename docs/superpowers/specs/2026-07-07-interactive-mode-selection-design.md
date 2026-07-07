# Interactive mode selection for `code-sandbox`

**Date:** 2026-07-07
**Status:** Approved
**File touched:** `bin/code-sandbox`

## Problem

`bin/code-sandbox` currently defaults to no-Docker mode and only enables
Docker-in-Docker (Podman) when `--enable-docker` is passed. New users don't
discover the Docker mode and can't tell which mode a fresh container will run
in. When the launcher is about to start a *fresh* container, it should ask which
mode to use rather than silently defaulting.

The interactive prompt must be fully suppressible so the test suite
(`test-sandbox.sh`) and any scripted/CI invocation keep working unchanged.

## Goal

When `code-sandbox` starts a **fresh** container and the mode was not specified
on the command line, present an interactive menu to choose no-Docker vs. Docker
mode. Preserve today's non-interactive behaviour everywhere else.

## Design

### New flags

Added to the existing flag-parsing loop:

- `--no-docker` — explicitly select no-Docker mode. Skips the prompt.
  Complements the existing `--enable-docker`.
- `--non-interactive` — skip the prompt and keep the current default
  (no-Docker) unless a mode flag was also given.

Passing both `--enable-docker` and `--no-docker` is a usage error (exit 1 with a
clear message).

### State tracking

Two new booleans alongside the existing `ENABLE_DOCKER`:

- `MODE_EXPLICIT` — set `true` by either `--enable-docker` or `--no-docker`.
- `NON_INTERACTIVE` — set `true` by `--non-interactive`.

### When the prompt fires

The prompt is shown only when **all** of the following hold:

1. We are starting a fresh container. This is guaranteed by placement: the block
   sits after the "attach to running container" block, which `exec`s away when
   it attaches — so when attaching, mode is irrelevant and never asked.
2. `MODE_EXPLICIT` is `false` (no `--enable-docker` / `--no-docker`).
3. `NON_INTERACTIVE` is `false` (no `--non-interactive`).
4. Both stdin and stdout are a TTY: `[ -t 0 ] && [ -t 1 ]` — the same guard
   already used to decide the `-it` flags. Non-TTY invocations (captured output
   via `$(...)`, background jobs, CI) auto-skip to the default, so every
   existing test keeps working with no change.

### The prompt

```
Select sandbox mode:
  1) No Docker (default)
  2) Docker (Podman) enabled
Choice [1]: _
```

- Empty input (just Enter) → `1` → no-Docker (`ENABLE_DOCKER=false`).
- `1` → no-Docker.
- `2` → Docker (`ENABLE_DOCKER=true`).
- Any other input → print a short error and re-ask (validation loop).

Input is read from stdin.

### Placement

A new block is inserted **after** the container-reuse `exec` block
(currently ~line 194) and **before** the `DOCKER_ARGS` assembly (~line 196),
since `$ENABLE_DOCKER` is first consumed by that assembly.

### Documentation

- Update the script header-comment usage block and examples to list
  `--no-docker` and `--non-interactive`.
- Update the `Unknown option` usage line to include the new flags.

## Non-goals

- No change to the DinD security model, entrypoint, or firewall.
- No prompt-specific automated test — a TTY cannot easily be driven in CI. The
  existing suite already covers the non-TTY auto-skip and `--enable-docker`
  paths; the interactive path is verified manually.

## Verification

- `test-sandbox.sh` continues to pass (exercises fresh non-TTY runs and DinD
  runs → confirms auto-skip and `--enable-docker` unaffected).
- Manual: run `code-sandbox` in a terminal → menu appears; `1`/empty → no-Docker,
  `2` → Docker; `--non-interactive`, `--no-docker`, `--enable-docker` each skip
  the menu; conflicting mode flags error out.
