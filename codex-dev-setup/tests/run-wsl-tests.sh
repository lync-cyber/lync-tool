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
command -v jq >/dev/null || fail "jq is required"
pass "WSL execution boundary"

while IFS= read -r script; do
  bash -n "$script"
done < <(find wsl tests -type f -name '*.sh' -print | sort)

state_probe=$(sed -n "/^[[:space:]]*\$stateScriptText = @'$/,/^'@$/p" modules/CodexSetup.Detection.psm1 | sed '1d;$d')
tool_probe=$(sed -n "/^[[:space:]]*\$toolScriptText = @'$/,/^'@$/p" modules/CodexSetup.Detection.psm1 | sed '1d;$d')
[[ -n "$state_probe" && -n "$tool_probe" ]] || fail "embedded WSL probe is missing"
printf '%s\n%s\n' "$state_probe" "$tool_probe" | bash -n
pass "Bash syntax"

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

printf 'All WSL-native tests passed.\n'
