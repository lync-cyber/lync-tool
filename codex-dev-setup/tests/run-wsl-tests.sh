#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

[[ "$(uname -s)" == "Linux" ]] || fail "tests must run directly on Linux"
[[ -n "${WSL_DISTRO_NAME:-}" ]] || fail "WSL_DISTRO_NAME is empty"
[[ "$ROOT_DIR" == /home/* ]] || fail "repository must be under /home"
pass "WSL execution boundary"

command -v jq >/dev/null || fail "jq is required"
RG_BIN=/usr/bin/rg
[[ -x "$RG_BIN" ]] || fail "Linux-native ripgrep is required at /usr/bin/rg"

while IFS= read -r script; do
  bash -n "$script"
done < <(find wsl tests -type f -name '*.sh' -print | sort)
pass "Bash syntax"

jq -e '
  .schemaVersion == 2 and
  (has("scriptVersion") | not) and
  (has("profileName") | not) and
  .environmentMode == "WslFirst" and
  (.preferences | has("language") | not) and
  (.preferences | has("failurePolicy") | not) and
  .paths.wslProjects == "~/code" and
  .wsl.distribution == "Ubuntu-24.04" and
  (.wsl.packages | type == "array" and length > 0) and
  (.wsl | has("packageGroups") | not) and
  (.wsl | has("additionalCommandProbes") | not) and
  .wsl.installCodexCli == true and
  .wsl.installPnpm == true and
  .wsl.configureGit == true and
  .toolchains.node.enabled == true and
  (.toolchains.node | keys == ["enabled"]) and
  .toolchains.python.enabled == true and
  (.toolchains.python | keys == ["enabled"]) and
  .codex.approvalPolicy == "on-request" and
  .codex.sandboxMode == "workspace-write" and
  .codex.windowsSandbox == "elevated"
' config/defaults.json >/dev/null
[[ "$(<VERSION)" == "0.1.0" ]] || fail "the repository version must remain 0.1.0"
pass "schema v2 defaults"

LEGACY_PATTERN='agentStrategy|terminalStrategy|shareWindowsHomeToWsl|manageMcpPluginsSkills|wslEnvironment|wslNetworking|interviewAnswers|configureWindowsGit|overwriteExistingWithoutConfirmation|Merge-MissingSetupConfig|CheckAndPrompt|packageGroups|profileName|failurePolicy|\$scriptVersion = '\''[0-9]'
if "$RG_BIN" -n "$LEGACY_PATTERN" \
  config modules Start-CodexSetup.ps1 Bootstrap-CodexSetup.ps1 wsl templates >/dev/null; then
  "$RG_BIN" -n "$LEGACY_PATTERN" \
    config modules Start-CodexSetup.ps1 Bootstrap-CodexSetup.ps1 wsl templates >&2
  fail "legacy v1 fields remain in implementation"
fi
pass "legacy implementation removed"

STALE_ROUTE_PATTERN='recommendation\.(agent|terminal)|Codex WSL \(Ubuntu\)|Get-PlanningProperty \$network '\''configure'\'''
if "$RG_BIN" -n "$STALE_ROUTE_PATTERN" \
  Start-CodexSetup.ps1 modules >/dev/null; then
  "$RG_BIN" -n "$STALE_ROUTE_PATTERN" Start-CodexSetup.ps1 modules >&2
  fail "stale environment routing remains"
fi
pass "v2 environment routing"

[[ ! -e templates/project/config.toml.template ]] || fail "project-level personal Codex config template still exists"
[[ -f templates/global/AGENTS.wsl.md.template ]] || fail "WSL global AGENTS template is missing"
[[ -f templates/global/AGENTS.windows.md.template ]] || fail "Windows global AGENTS template is missing"
[[ -f templates/project/AGENTS.md.template ]] || fail "project AGENTS template is missing"

"$RG_BIN" -q 'WSL2 Ubuntu' templates/global/AGENTS.wsl.md.template || fail "WSL global template lacks environment rule"
"$RG_BIN" -q 'Bash' templates/global/AGENTS.wsl.md.template || fail "WSL global template lacks Bash rule"
"$RG_BIN" -q '/mnt' templates/global/AGENTS.wsl.md.template || fail "WSL global template lacks mounted-filesystem prohibition"
"$RG_BIN" -q 'Windows native' templates/global/AGENTS.windows.md.template || fail "Windows global template lacks native-mode rule"
"$RG_BIN" -q '\{\{ENVIRONMENT_RULES\}\}' templates/project/AGENTS.md.template || fail "project template lacks environment placeholder"
"$RG_BIN" -q '\{\{PROJECT_COMMANDS\}\}' templates/project/AGENTS.md.template || fail "project template lacks command placeholder"
for marker in 'packageManager' 'pnpm-lock.yaml' 'package-lock.json' 'uv.lock' 'pyproject.toml' 'uv sync' 'uv run pytest' 'uv run ruff'; do
  "$RG_BIN" -Fq "$marker" modules/CodexSetup.Actions.psm1 || fail "project command discovery lacks $marker"
done
pass "instruction template layering"

"$RG_BIN" -q 'https://chatgpt.com/codex/install.sh' wsl/setup.sh || fail "official Codex CLI installer is not wired"
"$RG_BIN" -q 'https://get.pnpm.io/install.sh' wsl/setup.sh || fail "official pnpm installer is not wired"
"$RG_BIN" -Fq -- '--command %q --command %q --command %q' wsl/setup.sh || fail "WSL verifier does not require rg"
"$RG_BIN" -Fq -- '--uv-managed-python %q' wsl/setup.sh || fail "WSL verifier does not require uv-managed Python"
"$RG_BIN" -Fq '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH' wsl/setup.sh || \
  fail "Linux system paths do not take precedence over inherited Windows paths"
"$RG_BIN" -Fq "requiredCommandNames.Add('rg')" modules/CodexSetup.Detection.psm1 || \
  fail "deep WSL detection does not require Linux-native rg"
"$RG_BIN" -Fq 'state:uvManagedPython=ready' modules/CodexSetup.Detection.psm1 || \
  fail "deep WSL detection does not verify uv-managed Python"
"$RG_BIN" -q 'core.autocrlf' wsl/setup.sh || fail "WSL Git baseline is not wired"
"$RG_BIN" -q 'AGENTS' wsl/setup.sh || fail "WSL global instructions are not wired"
"$RG_BIN" -q 'packages.microsoft.com/config/ubuntu' wsl/setup.sh || fail "Microsoft PowerShell repository is not wired"
"$RG_BIN" -q "apt-get install -y powershell" wsl/setup.sh || fail "Linux PowerShell installation is not wired"
if "$RG_BIN" -n 'on-failure' config wsl modules Start-CodexSetup.ps1 >/dev/null; then
  "$RG_BIN" -n 'on-failure' config wsl modules Start-CodexSetup.ps1 >&2
  fail "deprecated approval policy remains in implementation"
fi
if "$RG_BIN" -n 'CODEX_HOME|node_modules.*(/mnt|Windows)|\.venv.*(/mnt|Windows)' wsl/setup.sh >/dev/null; then
  "$RG_BIN" -n 'CODEX_HOME|node_modules.*(/mnt|Windows)|\.venv.*(/mnt|Windows)' wsl/setup.sh >&2
  fail "cross-environment sharing remains in WSL setup"
fi
pass "single WSL toolchain wiring"

"$RG_BIN" -Fq 'uv python install 3.12 --default' wsl/setup.sh || fail "Python runtime is not managed exclusively by uv"
if "$RG_BIN" -n 'pip install|conda|poetry' wsl/setup.sh modules/CodexSetup.Actions.psm1 >/dev/null; then
  fail "a second Python package manager remains"
fi
pass "uv-only Python management"

wsl/setup.sh \
  --what-if \
  --code-root "$HOME/code" \
  --expected-distro "Ubuntu-24.04" \
  --global-agents-template templates/global/AGENTS.wsl.md.template \
  --verify-script wsl/verify.sh \
  --configure-git \
  --approval-policy on-request \
  --sandbox-mode workspace-write \
  --network-access true \
  --web-search live \
  --check-for-update true >/dev/null
if wsl/setup.sh \
  --what-if \
  --code-root /mnt/c/invalid \
  --expected-distro "Ubuntu-24.04" \
  --global-agents-template templates/global/AGENTS.wsl.md.template \
  --verify-script wsl/verify.sh >/dev/null 2>&1; then
  fail "WSL setup accepted a Windows-mounted code root"
fi
pass "WSL helper WhatIf and path rejection"

TEST_HOME=$(mktemp -d "$ROOT_DIR/.test-home.XXXXXX")
trap 'rm -rf -- "$TEST_HOME"' EXIT
BROKEN_HOME="$TEST_HOME/broken-markers"
mkdir -p "$BROKEN_HOME/.codex" "$BROKEN_HOME/.local/bin" "$BROKEN_HOME/code"
printf '%s\n' '# >>> CodexDevSetup:WSL >>>' 'private data' >"$BROKEN_HOME/.bashrc"
printf '%s\n' 'sandbox_mode = "read-only"' >"$BROKEN_HOME/.codex/config.toml"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$BROKEN_HOME/.local/bin/pwsh"
chmod 0755 "$BROKEN_HOME/.local/bin/pwsh"
broken_shell_hash=$(sha256sum "$BROKEN_HOME/.bashrc" | cut -d' ' -f1)
broken_config_hash=$(sha256sum "$BROKEN_HOME/.codex/config.toml" | cut -d' ' -f1)
if HOME="$BROKEN_HOME" wsl/setup.sh \
  --apply \
  --code-root "$BROKEN_HOME/code" \
  --expected-distro "Ubuntu-24.04" \
  --global-agents-template templates/global/AGENTS.wsl.md.template \
  --verify-script wsl/verify.sh >/dev/null 2>&1; then
  fail "WSL setup accepted an incomplete managed block"
fi
[[ "$(sha256sum "$BROKEN_HOME/.bashrc" | cut -d' ' -f1)" == "$broken_shell_hash" ]] || fail "broken managed block was modified"
[[ "$(sha256sum "$BROKEN_HOME/.codex/config.toml" | cut -d' ' -f1)" == "$broken_config_hash" ]] || fail "config changed before broken managed block rejection"
[[ ! -e "$BROKEN_HOME/.codex/AGENTS.md" ]] || fail "persistent files changed before broken managed block rejection"

mkdir -p "$TEST_HOME/.codex" "$TEST_HOME/code"
printf '%s\n' 'sandbox_mode = "workspace-write"' '"""unsafe' >"$TEST_HOME/.codex/config.toml"
chmod 0600 "$TEST_HOME/.codex/config.toml"
if HOME="$TEST_HOME" wsl/setup.sh \
  --apply \
  --code-root "$TEST_HOME/code" \
  --expected-distro "Ubuntu-24.04" \
  --global-agents-template templates/global/AGENTS.wsl.md.template \
  --verify-script wsl/verify.sh >/dev/null 2>&1; then
  fail "WSL setup accepted unsafe TOML"
fi
[[ ! -e "$TEST_HOME/.bashrc" ]] || fail "unsafe TOML was rejected after a persistent shell change"
printf '%s\n' 'sandbox_mode = "read-only"' >"$TEST_HOME/.codex/config.toml"
printf '%s\n' '# private shell file' >"$TEST_HOME/.bashrc"
mkdir -p "$TEST_HOME/.local/bin"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$TEST_HOME/.local/bin/pwsh"
chmod 0755 "$TEST_HOME/.local/bin/pwsh"
chmod 0600 "$TEST_HOME/.codex/config.toml" "$TEST_HOME/.bashrc"
HOME="$TEST_HOME" SHELL=/bin/bash wsl/setup.sh \
  --apply \
  --code-root "$TEST_HOME/code" \
  --expected-distro "Ubuntu-24.04" \
  --global-agents-template templates/global/AGENTS.wsl.md.template \
  --verify-script wsl/verify.sh >/dev/null
[[ "$(stat -c '%a' "$TEST_HOME/.codex/config.toml")" == 600 ]] || fail "config.toml permissions were widened"
[[ "$(stat -c '%a' "$TEST_HOME/.bashrc")" == 600 ]] || fail ".bashrc permissions were widened"
wrapper_json=$(cd "$TEST_HOME/code" && HOME="$TEST_HOME" SHELL=/bin/bash "$TEST_HOME/.local/bin/codex-env-check" --json)
jq -e '
  .schemaVersion == 2 and .verdict == "PASS" and .failureCount == 0 and
  .expectedDistro == "Ubuntu-24.04" and .currentDistro == "Ubuntu-24.04" and
  (.codeRoot | startswith("/home/")) and (.codeRoot as $root | .workingDirectory | startswith($root)) and
  (.checks | type == "array" and length >= 7) and
  any(.checks[]; .id == "command:pwsh" and .status == "PASS") and
  any(.checks[]; .id == "command:rg" and .status == "PASS" and .detail == "/usr/bin/rg")
' <<<"$wrapper_json" >/dev/null || fail "codex-env-check did not forward --json"
pass "WSL fail-fast configuration and file permissions"

[[ -x wsl/verify.sh ]] || fail "wsl/verify.sh is not executable"
verifier_text=$(wsl/verify.sh \
  --code-root "$ROOT_DIR" \
  --expected-distro "Ubuntu-24.04" \
  --command bash \
  --command git \
  --command jq)
[[ "$verifier_text" == *'PASS  Linux kernel'* ]] || fail "verifier text mode lost its kernel result"
[[ "$verifier_text" == *'WSL development environment is ready.'* ]] || fail "verifier text mode lost its success summary"
verifier_json=$(wsl/verify.sh \
  --json \
  --code-root "$ROOT_DIR" \
  --expected-distro "Ubuntu-24.04" \
  --command bash \
  --command git \
  --command jq)
jq -e '.schemaVersion == 2 and .verdict == "PASS" and .failureCount == 0' <<<"$verifier_json" >/dev/null || \
  fail "verifier JSON mode is not machine-readable"

VERIFIER_HOME="$TEST_HOME/verifier-native"
VERIFIER_BIN="$VERIFIER_HOME/.local/bin"
VERIFIER_MANAGED_ROOT="$VERIFIER_HOME/.local/share/uv/python"
VERIFIER_PYTHON="$VERIFIER_MANAGED_ROOT/cpython-3.12-test/bin/python3.12"
mkdir -p "$VERIFIER_BIN" "$(dirname -- "$VERIFIER_PYTHON")"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$VERIFIER_BIN/rg"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [[ $1 == python && $2 == dir ]]; then' \
  '  if [[ ${FAKE_UV_MOUNTED:-0} == 1 ]]; then printf "%s\\n" /mnt/c; else printf "%s\\n" "$HOME/.local/share/uv/python"; fi' \
  'elif [[ $1 == python && $2 == find ]]; then' \
  '  if [[ ${FAKE_UV_MOUNTED:-0} == 1 ]]; then printf "%s\\n" /mnt/c/Windows/System32/cmd.exe; elif [[ ${FAKE_UV_OUTSIDE:-0} == 1 ]]; then printf "%s\\n" /usr/bin/python3; else printf "%s\\n" "$HOME/.local/share/uv/python/cpython-3.12-test/bin/python3.12"; fi' \
  'else' \
  '  exit 2' \
  'fi' >"$VERIFIER_BIN/uv"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [[ ${1:-} == -c ]]; then printf "%s\\n" 3.12; else exit 2; fi' >"$VERIFIER_PYTHON"
chmod 0755 "$VERIFIER_BIN/rg" "$VERIFIER_BIN/uv" "$VERIFIER_PYTHON"

managed_python_json=$(cd "$ROOT_DIR" && HOME="$VERIFIER_HOME" SHELL=/bin/bash PATH="$VERIFIER_BIN:/usr/bin:/bin" \
  wsl/verify.sh --json --code-root "$ROOT_DIR" --expected-distro Ubuntu-24.04 \
  --command rg --command uv --uv-managed-python 3.12)
jq -e '
  .verdict == "PASS" and
  any(.checks[]; .id == "command:rg" and .status == "PASS") and
  any(.checks[]; .id == "python:uv-managed-3.12" and .status == "PASS" and (.detail | startswith("/home/")))
' <<<"$managed_python_json" >/dev/null || fail "verifier rejected a Linux rg and uv-managed Python 3.12"

if outside_python_json=$(cd "$ROOT_DIR" && HOME="$VERIFIER_HOME" SHELL=/bin/bash \
  PATH="$VERIFIER_BIN:/usr/bin:/bin" FAKE_UV_OUTSIDE=1 wsl/verify.sh --json \
  --code-root "$ROOT_DIR" --expected-distro Ubuntu-24.04 --command rg --command uv --uv-managed-python 3.12); then
  fail "verifier accepted a system interpreter as uv-managed Python"
fi
jq -e '
  .verdict == "FAIL" and
  any(.checks[]; .id == "python:uv-managed-3.12" and .status == "FAIL" and (.detail | contains("outside")))
' <<<"$outside_python_json" >/dev/null || fail "verifier did not report the non-managed Python failure"

if mounted_python_json=$(cd "$ROOT_DIR" && HOME="$VERIFIER_HOME" SHELL=/bin/bash \
  PATH="$VERIFIER_BIN:/usr/bin:/bin" FAKE_UV_MOUNTED=1 wsl/verify.sh --json \
  --code-root "$ROOT_DIR" --expected-distro Ubuntu-24.04 --command rg --command uv --uv-managed-python 3.12); then
  fail "verifier accepted uv-managed Python from a Windows mount"
fi
jq -e '
  .verdict == "FAIL" and
  any(.checks[]; .id == "python:uv-managed-3.12" and .status == "FAIL" and (.detail | startswith("/mnt/")))
' <<<"$mounted_python_json" >/dev/null || fail "verifier did not report the mounted uv Python path"

INJECTED_BIN="$TEST_HOME/injected-path"
mkdir -p "$INJECTED_BIN"
[[ -x /mnt/c/Windows/System32/cmd.exe ]] || fail "Windows mount target for the rg injection test is unavailable"
ln -s /mnt/c/Windows/System32/cmd.exe "$INJECTED_BIN/rg"
if injected_rg_json=$(cd "$ROOT_DIR" && HOME="$VERIFIER_HOME" SHELL=/bin/bash PATH="$INJECTED_BIN:/usr/bin:/bin" \
  wsl/verify.sh --json --code-root "$ROOT_DIR" --expected-distro Ubuntu-24.04 --command rg); then
  fail "verifier accepted rg from an injected Windows path"
fi
jq -e '
  .verdict == "FAIL" and
  any(.checks[]; .id == "command:rg" and .status == "FAIL" and (.detail | startswith("/mnt/")))
' <<<"$injected_rg_json" >/dev/null || fail "verifier did not report the injected rg path"
pass "WSL environment verifier"

acceptance_script=tests/windows-integration/Invoke-Windows11Acceptance.ps1
[[ -f "$acceptance_script" ]] || fail "Windows 11 acceptance entry point is missing"
for marker in \
  "'Preflight', 'Apply', 'PostRestart', 'DesktopEvidence', 'Rollback', 'Report'" \
  'LOCALAPPDATA' \
  "@('GitHub.cli', 'Microsoft.WindowsTerminal', 'Git.Git')" \
  'PASS_CURRENT_HOST_WSL2' \
  'DesktopScreenshotPath' \
  'AgentEvidenceJsonPath' \
  'TerminalEvidenceJsonPath' \
  'AgentWslOnly' \
  'TerminalWslOnly' \
  'BaselineRestored' \
  'desktopEvidenceNonce' \
  'CodexDesktopChannelEvidence' \
  'command:rg' \
  'python:uv-managed-3.12' \
  'final-reapply.json' \
  'System.Drawing.Image' \
  'Get-WindowsPackageCatalog' \
  'wsl --shutdown' \
  'currentHostOnly=$true' \
  'uninstallPreinstalledPackages=$false'; do
  "$RG_BIN" -Fq "$marker" "$acceptance_script" || fail "Windows acceptance contract lacks $marker"
done
desktop_channel_script=tests/windows-integration/Invoke-DesktopChannelCheck.ps1
for marker in "[ValidateSet('Agent', 'Terminal')]" '[string]$RunId' '[string]$Nonce' "captureType='CodexDesktopChannelEvidence'"; do
  "$RG_BIN" -Fq "$marker" "$desktop_channel_script" || fail "Desktop channel evidence contract lacks $marker"
done
if "$RG_BIN" -n -- '--unregister|SendKeys|AutomationElement|UIAutomation' "$acceptance_script" >/dev/null; then
  "$RG_BIN" -n -- '--unregister|SendKeys|AutomationElement|UIAutomation' "$acceptance_script" >&2
  fail "Windows acceptance violates its no-unregister/no-UI-automation boundary"
fi
"$RG_BIN" -Fq "'--disable-interactivity', '--silent'" modules/CodexSetup.Actions.psm1 || fail "WinGet mutation is not non-interactive"
"$RG_BIN" -Fq 'state:sudo=passwordless' modules/CodexSetup.Detection.psm1 || fail "sudo capability does not distinguish passwordless mode"
if "$RG_BIN" -n -- 'source[[:space:]]+.*\.env|SUDO(_|)[A-Z_]*PASS' wsl modules Start-CodexSetup.ps1 >/dev/null; then
  fail "implementation reads sudo credentials from environment files or variables"
fi
if "$RG_BIN" -n -- 'winget(\.exe)?[[:space:]]+list|ChatGPT\|OpenAI' "$acceptance_script" modules >/dev/null; then
  fail "Windows package detection parses a table or uses a broad identity"
fi
"$RG_BIN" -Fq '[string]$ResultJsonPath' Start-CodexSetup.ps1 || fail "Start entry point lacks -ResultJsonPath"
for marker in 'detection = $WorkflowResult.detection' 'plan = $WorkflowResult.plan' 'results = @($WorkflowResult.results)' 'remainingPlan = $WorkflowResult.remainingPlan'; do
  "$RG_BIN" -Fq "$marker" Start-CodexSetup.ps1 || fail "machine result lacks $marker"
done
for marker in \
  'blockingReasons = @($blockingReasons)' \
  'Test-SetupProcessExitRequired' \
  'if ($isDotSourced) { return }' \
  'WasModeExplicit:$modeWasExplicit'; do
  "$RG_BIN" -Fq "$marker" Start-CodexSetup.ps1 || fail "machine result and exit contract lacks $marker"
done
if "$RG_BIN" -n '\$plan\.blockingReasons[[:space:]]*=' Start-CodexSetup.ps1 >/dev/null; then
  fail "ProjectInit or another workflow overwrites planning blockers"
fi
for exit_code in 0 10 20 1; do
  "$RG_BIN" -Fq "$exit_code" Start-CodexSetup.ps1 || fail "Start entry point lacks exit code $exit_code"
done
pass "Windows 11 acceptance static contract"

printf 'All WSL-native tests passed.\n'
