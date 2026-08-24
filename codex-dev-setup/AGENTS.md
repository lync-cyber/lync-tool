# Development environment

- Develop this repository in WSL2 Ubuntu from a path under `/home`.
- Run repository shell commands directly in Bash. Never invoke Windows executables or route commands through `wsl.exe`.
- PowerShell source tests may use Linux-native `pwsh` when it is already available. Windows integration tests run only on a Windows test machine.
- Before retrying a failed command, inspect `pwd`, `uname -s`, `WSL_DISTRO_NAME`, the active shell, and the relevant command path.
- Preserve unrelated changes and use repository scripts instead of inventing replacement command lines.
- Do not install global development dependencies when a project-local or temporary tool is sufficient.

# Verification

- Run `./tests/run-wsl-tests.sh` for WSL-native checks.
- Run `pwsh -NoProfile -File tests/Run-All.Tests.ps1` only when Linux-native PowerShell is available.
- Report every skipped platform check and never claim Windows integration was exercised from WSL.
