# Sandbox environment

Running in a sandbox environment with limited permissions and an HTTP proxy that limits access to domains.
If access to specific domains is denied consider asking the user to allow access.

# General considerations

- when introducing new tools or dependencies (packages, terraform providers, helm charts, etc.) please make sure to use the respective latest releases

# Common project conventions

## Tools

When using/requiring command line tools it is preferred to use [mise-en-place](https://mise.jdx.dev) to provide and manage tools, so they are available in the proper versions for every developer and CI (e.g. using the respective GitHub Action or similar).

## Commits

Commits must follow **Conventional Commits**:

- `feat:` — new feature
- `fix:` — bug fix
- `refactor:` — code restructuring
- `test:` — test-only changes
- `ci:` — CI/CD changes
- `chore:` / `build:` / `docs:` / `perf:` / `style:` — other categories

Commits should include a reference to the related JIRA issue in the footer, e.g. `ING-123`.
The JIRA issue may be deduced from the branch name if it follows one of the patterns `ING-123` or `ING-123-description`.

Use fixup commits (`git commit --fixup`) for corrections to previous commits.
