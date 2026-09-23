# Contributing

## Reporting Bugs

Please use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.md) and include:
- Your platform (Linux / macOS / WSL / Windows)
- Claude Code version (`claude --version`)
- The full statusline output or error message

## Submitting Pull Requests

1. Fork the repository
2. Create a branch: `git checkout -b fix/your-fix`
3. Make your changes
4. Test on your platform
5. Open a pull request with a clear description of what changed and why

## Guidelines

- Keep changes focused — one fix or feature per PR
- Test both `statusline.sh` and `statusline.ps1` if your change affects both
- Do not commit cache files (`*.cache`)
