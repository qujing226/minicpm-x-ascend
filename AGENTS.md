# Repository instructions

## Git workflow

- Never commit directly to `main`.
- Create branches using `codex/<task-name>`.
- Never force-push.
- Never merge pull requests.
- Before committing, run all relevant tests and inspect `git diff`.
- Do not commit model files, generated audio, benchmark results, credentials,
  environment files, build directories, or logs unless explicitly requested.
- Keep commits atomic.
- Use Conventional Commits.

## Required checks

- Shell scripts: `shellcheck`
- Python: `ruff check .`
- Python formatting: `ruff format --check .`
- Tests: run the smallest relevant test set first
- Include exact benchmark commands in the PR description

## Ascend environment

- Do not change CANN, driver, torch_npu, or system package versions without approval.
- Do not install packages globally unless explicitly approved.
- Do not assume successful execution uses the NPU; verify with runtime logs and `npu-smi`.
