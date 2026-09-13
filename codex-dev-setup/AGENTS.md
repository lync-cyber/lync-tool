# Development environment

- This repository bootstraps Windows hosts that may not have WSL installed. Develop and test its Windows launcher, PowerShell modules, and host integration directly in Windows PowerShell 7 from a Windows local path. WSL is not a prerequisite for this work.
- Develop Linux helpers in WSL2 Ubuntu under `/home`, using Bash and Linux-native tools. Do not run Linux development commands through Windows executables or work under `/mnt`.
- Windows host actions may invoke `wsl.exe` to detect, install, and configure the target distribution. This bootstrap boundary is distinct from running repository development commands in Linux.
- Keep Windows and Linux dependencies, caches, and tool installations separate. Do not use Windows development tools against a `\\wsl$` checkout.
- Before retrying a failed command, inspect the working directory, OS, active shell, and relevant command paths; on Linux also inspect `uname -s` and `WSL_DISTRO_NAME`.
- Preserve unrelated changes and use repository scripts instead of inventing replacement command lines.
- Do not install global development dependencies when a project-local or temporary tool is sufficient.

# Verification

- Run `pwsh -NoProfile -File tests/Run-All.Tests.ps1` on Windows for host source and behavior checks; Linux-native `pwsh` may run the same tests when available.
- Run `./tests/run-wsl-tests.sh` in WSL for WSL-native checks.
- Run installation, elevation, restart, and rollback integration checks on a designated Windows test machine. Do not install or reset the developer's environment merely to test a code change.
- Report every skipped platform check. Mocked checks do not constitute real installation or Desktop integration evidence.
