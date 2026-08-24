#!/usr/bin/env bash
set -euo pipefail

mode=what-if
non_interactive=0
code_root=""
expected_distro=""
install_node=0
install_python=0
install_pnpm=0
install_codex=0
configure_git=0
verify_docker=0
global_agents_template=""
verify_script=""
approval_policy=on-request
sandbox_mode=workspace-write
network_access=true
web_search=live
check_for_update=true
apt_packages=()
command_aliases=()
temp_files=()

cleanup() {
  local path
  for path in "${temp_files[@]}"; do
    [[ -n $path ]] && rm -f -- "$path"
  done
}
trap cleanup EXIT

usage() {
  printf '%s\n' \
    'Usage: setup.sh [--what-if|--apply] [--non-interactive] --code-root PATH --expected-distro NAME' \
    '  [--apt-package NAME] [--command-alias NAME=TARGET]' \
    '  [--install-node] [--install-python] [--install-pnpm] [--install-codex]' \
    '  [--configure-git] [--verify-docker] --global-agents-template PATH --verify-script PATH' \
    '  [--approval-policy VALUE] [--sandbox-mode VALUE]' \
    '  [--network-access true|false] [--web-search VALUE]' \
    '  [--check-for-update true|false]'
}

require_value() {
  (($# >= 2)) || {
    printf 'Missing value for %s\n' "$1" >&2
    exit 2
  }
}

while (($# > 0)); do
  case "$1" in
    --what-if) mode=what-if; shift ;;
    --apply) mode=apply; shift ;;
    --non-interactive) non_interactive=1; shift ;;
    --code-root) require_value "$@"; code_root=$2; shift 2 ;;
    --expected-distro) require_value "$@"; expected_distro=$2; shift 2 ;;
    --apt-package) require_value "$@"; apt_packages+=("$2"); shift 2 ;;
    --command-alias) require_value "$@"; command_aliases+=("$2"); shift 2 ;;
    --install-node) install_node=1; shift ;;
    --install-python) install_python=1; shift ;;
    --install-pnpm) install_pnpm=1; shift ;;
    --install-codex) install_codex=1; shift ;;
    --configure-git) configure_git=1; shift ;;
    --verify-docker) verify_docker=1; shift ;;
    --global-agents-template) require_value "$@"; global_agents_template=$2; shift 2 ;;
    --verify-script) require_value "$@"; verify_script=$2; shift 2 ;;
    --approval-policy) require_value "$@"; approval_policy=$2; shift 2 ;;
    --sandbox-mode) require_value "$@"; sandbox_mode=$2; shift 2 ;;
    --network-access) require_value "$@"; network_access=$2; shift 2 ;;
    --web-search) require_value "$@"; web_search=$2; shift 2 ;;
    --check-for-update) require_value "$@"; check_for_update=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage; exit 2 ;;
  esac
done

[[ -n $code_root ]] || { printf '%s\n' 'Missing --code-root.' >&2; exit 2; }
[[ -n $expected_distro ]] || { printf '%s\n' 'Missing --expected-distro.' >&2; exit 2; }
[[ -f $global_agents_template ]] || { printf 'Global AGENTS template not found: %s\n' "$global_agents_template" >&2; exit 2; }
[[ -f $verify_script ]] || { printf 'Verification script not found: %s\n' "$verify_script" >&2; exit 2; }
[[ $(uname -s) == Linux ]] || { printf '%s\n' 'This helper requires Linux.' >&2; exit 1; }
[[ -n ${WSL_DISTRO_NAME:-} && $WSL_DISTRO_NAME == "$expected_distro" ]] || {
  printf 'Expected WSL distribution %s, got %s.\n' "$expected_distro" "${WSL_DISTRO_NAME:-none}" >&2
  exit 1
}

case $code_root in
  '~') code_root=$HOME ;;
  '~/'*) code_root="$HOME/${code_root#~/}" ;;
esac
[[ $code_root == "$HOME/code" ]] || { printf 'Code root must be exactly %s/code: %s\n' "$HOME" "$code_root" >&2; exit 2; }

[[ $approval_policy =~ ^(untrusted|on-request|never)$ ]] || { printf 'Invalid approval policy: %s\n' "$approval_policy" >&2; exit 2; }
[[ $sandbox_mode =~ ^(read-only|workspace-write|danger-full-access)$ ]] || { printf 'Invalid sandbox mode: %s\n' "$sandbox_mode" >&2; exit 2; }
[[ $network_access =~ ^(true|false)$ ]] || { printf 'Invalid network access value: %s\n' "$network_access" >&2; exit 2; }
[[ $web_search =~ ^(disabled|cached|indexed|live)$ ]] || { printf 'Invalid web search value: %s\n' "$web_search" >&2; exit 2; }
[[ $check_for_update =~ ^(true|false)$ ]] || { printf 'Invalid update check value: %s\n' "$check_for_update" >&2; exit 2; }

for package in "${apt_packages[@]}"; do
  [[ $package =~ ^[a-z0-9][a-z0-9+.-]*$ ]] || { printf 'Invalid APT package: %s\n' "$package" >&2; exit 2; }
done
for alias_spec in "${command_aliases[@]}"; do
  [[ $alias_spec =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*=[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || {
    printf 'Invalid command alias: %s\n' "$alias_spec" >&2
    exit 2
  }
done

export PATH="$HOME/.local/bin:$HOME/.local/share/fnm:$HOME/.local/share/pnpm:$PATH"

source /etc/os-release
[[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 24.04 ]] || {
  printf 'PowerShell setup requires Ubuntu 24.04, got %s %s.\n' "${ID:-unknown}" "${VERSION_ID:-unknown}" >&2
  exit 1
}

stage() { printf '\n[WSL] %s\n' "$1"; }
die() { printf '%s\n' "$1" >&2; exit 1; }

has_linux_command() {
  local resolved
  resolved=$(command -v -- "$1") || return 1
  [[ $resolved != /mnt/* ]]
}

run() {
  if [[ $mode == what-if ]]; then
    printf '[WhatIf]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

download() {
  local url=$1 destination=$2
  if [[ $mode == what-if ]]; then
    printf '[WhatIf] download %s\n' "$url"
    return 0
  fi
  curl --proto '=https' --tlsv1.2 -fsSL "$url" -o "$destination"
}

backup_and_install() {
  local source=$1 destination=$2 create_mode=$3
  if [[ -f $destination ]] && cmp -s -- "$source" "$destination"; then
    printf 'Unchanged: %s\n' "$destination"
    return 0
  fi
  if [[ $mode == what-if ]]; then
    printf '[WhatIf] install %s -> %s\n' "$source" "$destination"
    return 0
  fi
  mkdir -p -- "$(dirname -- "$destination")"
  if [[ -e $destination ]]; then
    cp -a -- "$destination" "$destination.backup.$(date +%Y%m%d%H%M%S)"
    command cat -- "$source" >"$destination"
  else
    install -m "$create_mode" -- "$source" "$destination"
  fi
}

assert_managed_block_integrity() {
  local destination=$1
  local start='# >>> CodexDevSetup:WSL >>>'
  local end='# <<< CodexDevSetup:WSL <<<'
  if [[ -f $destination ]]; then
    local start_count end_count start_line end_line
    start_count=$(grep -Fxc -- "$start" "$destination" || true)
    end_count=$(grep -Fxc -- "$end" "$destination" || true)
    if (( start_count != end_count || start_count > 1 )); then
      die "Refusing to modify $destination: managed block markers are incomplete or duplicated"
    fi
    if (( start_count == 1 )); then
      start_line=$(grep -Fnx -- "$start" "$destination" | cut -d: -f1)
      end_line=$(grep -Fnx -- "$end" "$destination" | cut -d: -f1)
      (( start_line < end_line )) || die "Refusing to modify $destination: managed block markers are out of order"
    fi
  fi
}

replace_managed_block() {
  local destination=$1 content=$2
  local start='# >>> CodexDevSetup:WSL >>>'
  local end='# <<< CodexDevSetup:WSL <<<'
  local filtered candidate
  assert_managed_block_integrity "$destination"
  filtered=$(mktemp)
  candidate=$(mktemp)
  temp_files+=("$filtered")
  temp_files+=("$candidate")
  if [[ -f $destination ]]; then
    awk -v start="$start" -v end="$end" '
      $0 == start { skip=1; next }
      $0 == end { skip=0; next }
      !skip { print }
    ' "$destination" >"$filtered"
  fi
  {
    cat "$filtered"
    [[ ! -s $filtered ]] || printf '\n'
    printf '%s\n%s\n%s\n' "$start" "$content" "$end"
  } >"$candidate"
  if [[ -f $destination ]] && cmp -s -- "$candidate" "$destination"; then
    printf 'Unchanged: %s\n' "$destination"
    return 0
  fi
  if [[ $mode == what-if ]]; then
    printf '[WhatIf] update managed environment block in %s\n' "$destination"
    return 0
  fi
  mkdir -p -- "$(dirname -- "$destination")"
  if [[ -e $destination ]]; then
    cp -a -- "$destination" "$destination.backup.$(date +%Y%m%d%H%M%S)"
    command cat -- "$candidate" >"$destination"
  else
    install -m 0644 -- "$candidate" "$destination"
  fi
}

set_toml_key() {
  local source=$1 destination=$2 section=$3 key=$4 value=$5
  awk -v target_section="$section" -v target_key="$key" -v target_value="$value" '
    function write_key() {
      print target_key " = " target_value
      key_written = 1
    }
    BEGIN {
      in_target = target_section == ""
      section_seen = in_target
      key_written = 0
    }
    /^[[:space:]]*\[[^]]+\][[:space:]]*(#.*)?$/ {
      if (in_target && !key_written) write_key()
      section_name = $0
      sub(/[[:space:]]*#.*$/, "", section_name)
      sub(/^[[:space:]]*\[/, "", section_name)
      sub(/\][[:space:]]*$/, "", section_name)
      in_target = section_name == target_section
      if (in_target) section_seen = 1
      print
      next
    }
    {
      if (in_target && $0 ~ "^[[:space:]]*" target_key "[[:space:]]*=") {
        if (!key_written) write_key()
        next
      }
      print
    }
    END {
      if (in_target && !key_written) {
        write_key()
      } else if (target_section != "" && !section_seen) {
        print ""
        print "[" target_section "]"
        write_key()
      }
    }
  ' "$source" >"$destination"
}

assert_supported_codex_toml() {
  local source=$1 section_count
  if grep -Eq "'''|\"\"\"" "$source"; then
    printf '%s\n' 'config.toml uses multiline strings; refusing an unsafe update.' >&2
    exit 1
  fi
  if grep -Eq '^[[:space:]]*\[\[' "$source"; then
    printf '%s\n' 'config.toml uses array tables; refusing an unsafe update.' >&2
    exit 1
  fi
  if grep -Eq "^[[:space:]]*\[[[:space:]]*['\"]" "$source"; then
    printf '%s\n' 'config.toml uses quoted table names; refusing an unsafe update.' >&2
    exit 1
  fi
  if grep -Eq "^[[:space:]]*['\"](approval_policy|sandbox_mode|web_search|check_for_update_on_startup|network_access)['\"][[:space:]]*=" "$source"; then
    printf '%s\n' 'config.toml uses a quoted managed key; refusing an unsafe update.' >&2
    exit 1
  fi
  if grep -Eq '^[[:space:]]*sandbox_workspace_write([[:space:]]*=|\.)' "$source"; then
    printf '%s\n' 'config.toml uses a sandbox_workspace_write inline table or dotted key; refusing an ambiguous update.' >&2
    exit 1
  fi
  section_count=$(grep -Ec '^[[:space:]]*\[[[:space:]]*sandbox_workspace_write[[:space:]]*\][[:space:]]*(#.*)?$' "$source" || true)
  if ((section_count > 1)); then
    printf '%s\n' 'config.toml defines [sandbox_workspace_write] more than once.' >&2
    exit 1
  fi
  if ! awk '
    BEGIN { section="" }
    /^[[:space:]]*\[[^]]+\][[:space:]]*(#.*)?$/ {
      section=$0
      sub(/[[:space:]]*#.*$/, "", section)
      sub(/^[[:space:]]*\[/, "", section)
      sub(/\][[:space:]]*$/, "", section)
      next
    }
    {
      if (section == "" && $0 ~ /^[[:space:]]*(approval_policy|sandbox_mode|web_search|check_for_update_on_startup)[[:space:]]*=/) {
        line=$0; sub(/^[[:space:]]*/, "", line); sub(/[[:space:]]*=.*$/, "", line); count["root." line]++
      }
      if (section == "sandbox_workspace_write" && $0 ~ /^[[:space:]]*network_access[[:space:]]*=/) count["sandbox_workspace_write.network_access"]++
    }
    END { for (key in count) if (count[key] > 1) exit 1 }
  ' "$source"; then
    printf '%s\n' 'config.toml repeats a managed key; refusing an unsafe update.' >&2
    exit 1
  fi
}

codex_config=$(mktemp)
codex_config_next=$(mktemp)
temp_files+=("$codex_config" "$codex_config_next")
if [[ -f $HOME/.codex/config.toml ]]; then
  cp -- "$HOME/.codex/config.toml" "$codex_config"
else
  : >"$codex_config"
fi
assert_supported_codex_toml "$codex_config"
assert_managed_block_integrity "$HOME/.bashrc"

missing_packages=()
queue_missing_package() {
  local package=$1 queued
  dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -qx installed && return 0
  for queued in "${missing_packages[@]}"; do
    [[ $queued == "$package" ]] && return 0
  done
  missing_packages+=("$package")
}
for package in "${apt_packages[@]}"; do
  queue_missing_package "$package"
done
if ! has_linux_command pwsh; then
  for package in wget apt-transport-https software-properties-common; do
    queue_missing_package "$package"
  done
fi
if ((${#missing_packages[@]} > 0)); then
  stage 'Install Linux packages'
  if [[ $mode == what-if ]]; then
    run sudo apt-get update
    run sudo apt-get install -y "${missing_packages[@]}"
  else
    if ((non_interactive)); then
      sudo -n true || {
        printf '%s\n' 'System packages are missing and sudo requires interaction. Run the setup interactively in WSL; sudo passwords are never read from .env files.' >&2
        exit 20
      }
      sudo -n apt-get update
      sudo -n apt-get install -y "${missing_packages[@]}"
    else
      sudo -v
      sudo apt-get update
      sudo apt-get install -y "${missing_packages[@]}"
    fi
  fi
fi

run mkdir -p -- "$code_root" "$HOME/.local/bin" "$HOME/.local/share"

if ! has_linux_command pwsh; then
  stage 'Install PowerShell from the Microsoft package repository'
  if [[ $mode == apply && $non_interactive == 1 ]] && ! sudo -n true; then
    printf '%s\n' 'Installing Linux PowerShell requires sudo. Run the setup interactively in WSL; sudo passwords are never read from .env files.' >&2
    exit 20
  fi
  repository_package=$(mktemp)
  temp_files+=("$repository_package")
  repository_url="https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb"
  if [[ $mode == what-if ]]; then
    printf '[WhatIf] download %s\n' "$repository_url"
    run sudo dpkg -i "$repository_package"
    run sudo apt-get update
    run sudo apt-get install -y powershell
  else
    wget -q "$repository_url" -O "$repository_package"
    if ((non_interactive)); then
      sudo -n dpkg -i "$repository_package"
      sudo -n apt-get update
      sudo -n apt-get install -y powershell
    else
      sudo dpkg -i "$repository_package"
      sudo apt-get update
      sudo apt-get install -y powershell
    fi
    has_linux_command pwsh || { printf '%s\n' 'PowerShell installation did not provide a Linux-native pwsh command.' >&2; exit 1; }
  fi
fi

if ((install_node)); then
  stage 'Install fnm and Node.js LTS'
  if ! has_linux_command fnm; then
    installer=$(mktemp)
    temp_files+=("$installer")
    download 'https://fnm.vercel.app/install' "$installer"
    if [[ $mode == what-if ]]; then
      printf '[WhatIf] sh fnm installer --install-dir %q --skip-shell\n' "$HOME/.local/share/fnm"
    else
      bash "$installer" --install-dir "$HOME/.local/share/fnm" --skip-shell
    fi
  fi
  if [[ $mode == apply ]]; then
    eval "$(fnm env --shell bash)"
    fnm install --lts --use
    fnm default "$(fnm current)"
  else
    printf '%s\n' '[WhatIf] fnm install --lts --use and set the active version as default'
  fi
fi

if ((install_python)); then
  stage 'Install uv and a managed Python runtime'
  if ! has_linux_command uv; then
    installer=$(mktemp)
    temp_files+=("$installer")
    download 'https://astral.sh/uv/install.sh' "$installer"
    if [[ $mode == what-if ]]; then
      printf '[WhatIf] install uv into %s\n' "$HOME/.local/bin"
    else
      UV_UNMANAGED_INSTALL="$HOME/.local/bin" sh "$installer"
    fi
  fi
  run uv python install 3.12 --default
fi

if ((install_pnpm)); then
  stage 'Install pnpm'
  if ! has_linux_command pnpm; then
    installer=$(mktemp)
    temp_files+=("$installer")
    download 'https://get.pnpm.io/install.sh' "$installer"
    if [[ $mode == what-if ]]; then
      printf '[WhatIf] install pnpm into %s\n' "$HOME/.local/share/pnpm"
    else
      ENV=/dev/null SHELL=/bin/bash PNPM_HOME="$HOME/.local/share/pnpm" sh "$installer"
    fi
  fi
fi

if ((install_codex)); then
  stage 'Install Codex CLI'
  if ! has_linux_command codex; then
    installer=$(mktemp)
    temp_files+=("$installer")
    download 'https://chatgpt.com/codex/install.sh' "$installer"
    if [[ $mode == what-if ]]; then
      printf '%s\n' '[WhatIf] run the official Codex CLI installer'
    else
      sh "$installer"
    fi
  fi
fi

if ((configure_git)); then
  stage 'Configure Linux Git baseline'
  run git config --global init.defaultBranch main
  run git config --global fetch.prune true
  run git config --global pull.ff only
  run git config --global core.autocrlf input
  run git config --global core.safecrlf warn
fi

stage 'Configure the WSL shell'
shell_block='export PATH="$HOME/.local/bin:$HOME/.local/share/fnm:$HOME/.local/share/pnpm:$PATH"'
shell_block+=$'\nfnm_path=$(command -v fnm 2>/dev/null || true)'
shell_block+=$'\nif [[ -n $fnm_path && $fnm_path != /mnt/* ]]; then eval "$(fnm env --shell bash)"; fi'
shell_block+=$'\nunset fnm_path'
for alias_spec in "${command_aliases[@]}"; do
  alias_name=${alias_spec%%=*}
  alias_target=${alias_spec#*=}
  printf -v alias_line "alias %s='%s'" "$alias_name" "$alias_target"
  shell_block+=$'\n'"$alias_line"
done
replace_managed_block "$HOME/.bashrc" "$shell_block"

stage 'Write WSL Codex policy'
backup_and_install "$global_agents_template" "$HOME/.codex/AGENTS.md" 0644
set_toml_key "$codex_config" "$codex_config_next" '' approval_policy "\"$approval_policy\""
cp -- "$codex_config_next" "$codex_config"
set_toml_key "$codex_config" "$codex_config_next" '' sandbox_mode "\"$sandbox_mode\""
cp -- "$codex_config_next" "$codex_config"
set_toml_key "$codex_config" "$codex_config_next" '' web_search "\"$web_search\""
cp -- "$codex_config_next" "$codex_config"
set_toml_key "$codex_config" "$codex_config_next" '' check_for_update_on_startup "$check_for_update"
cp -- "$codex_config_next" "$codex_config"
set_toml_key "$codex_config" "$codex_config_next" sandbox_workspace_write network_access "$network_access"
cp -- "$codex_config_next" "$codex_config"
assert_supported_codex_toml "$codex_config"
backup_and_install "$codex_config" "$HOME/.codex/config.toml" 0600

stage 'Install the WSL environment check'
verify_destination="$HOME/.local/lib/codex-dev-setup/verify.sh"
backup_and_install "$verify_script" "$verify_destination" 0755
wrapper=$(mktemp)
temp_files+=("$wrapper")
{
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
  printf '%s\n' 'export PATH="$HOME/.local/bin:$HOME/.local/share/fnm:$HOME/.local/share/pnpm:$PATH"'
  printf 'exec %q --code-root %q --expected-distro %q' "$verify_destination" "$code_root" "$expected_distro"
  printf ' --command %q --command %q' git pwsh
  ((install_node)) && printf ' --command %q --command %q --command %q' fnm node npm
  ((install_python)) && printf ' --command %q --command %q' uv python3
  ((install_pnpm)) && printf ' --command %q' pnpm
  ((install_codex)) && printf ' --command %q' codex
  ((verify_docker)) && printf ' --command %q' docker
  printf ' "$@"\n'
} >"$wrapper"
backup_and_install "$wrapper" "$HOME/.local/bin/codex-env-check" 0755
if [[ $mode == apply ]]; then
  chmod u+x "$verify_destination" "$HOME/.local/bin/codex-env-check"
fi

stage 'Result'
if [[ $mode == what-if ]]; then
  printf '%s\n' 'Preview complete. No persistent changes were made.'
else
  (cd "$code_root" && "$HOME/.local/bin/codex-env-check")
fi
