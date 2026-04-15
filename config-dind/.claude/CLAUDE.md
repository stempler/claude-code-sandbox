# Common project conventions

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
