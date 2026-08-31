# Repository agent notes

## Verification scripts

- Run multi-command shell verification scripts with fail-fast behavior (`set -e` at minimum; add `-u` and `pipefail` when compatible). Without it, an early failure can be followed by misleading later output and a false success summary.
- Temporary Git repositories used in tests must disable commit signing locally (`git config commit.gpgsign false`) so the scenario does not depend on a developer's signing agent.
- Commands run under zsh: do not use reserved/read-only parameters such as `status` for scratch variables; choose task-specific names (for example, `checks_exit`).
