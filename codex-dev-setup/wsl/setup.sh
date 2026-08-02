#!/usr/bin/env bash
set -euo pipefail

MODE="what-if"
CODE_ROOT=""
SHARE_CODEX_HOME=""
INSTALL_NODE=0
INSTALL_PYTHON=0
APT_PACKAGES=()
COMMAND_ALIASES=()
ROLLBACK=0
NETWORK_ONLY=0
PROXY_MODE="keep"
PROXY_HOST="127.0.0.1"
PROXY_HTTP_PORT="10808"
PROXY_SOCKS_PORT="10808"
SUDO_AUTH_FAILURE_EXIT=77
SUDO_UNAVAILABLE_EXIT=78
SHELL_MARKER_FAILURE_EXIT=79
APT_OPTIONS=(-o Acquire::Retries=2 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 -o DPkg::Lock::Timeout=60)
SUDO=()
TEMP_FILES=()

cleanup_temp_files() {
  local file
  for file in "${TEMP_FILES[@]}"; do
    [[ -n "$file" ]] && rm -f -- "$file"
  done
}
trap cleanup_temp_files EXIT

register_temp_file() { TEMP_FILES+=("$1"); }

usage() {
  cat <<'EOF'
Codex WSL Ubuntu helper

Usage:
  setup.sh [--what-if|--apply] [--code-root ~/code]
           [--share-codex-home /mnt/c/Users/name/.codex]
           [--install-node] [--install-python] [--rollback]
           [--apt-package name] [--command-alias name=target]
           [--network-only] [--proxy-mode keep|persistent|none]
           [--proxy-host 127.0.0.1] [--proxy-http-port 10808]
           [--proxy-socks-port 10808]

This script never reads authentication files, tokens, SSH private keys, or .env files.

When required Ubuntu packages are missing, the script will first explain why it
needs sudo and validate the Ubuntu user's password. Password input is not shown
in the terminal; this is normal Linux behavior.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --what-if) MODE="what-if"; shift ;;
    --apply) MODE="apply"; shift ;;
    --code-root) CODE_ROOT="$2"; shift 2 ;;
    --share-codex-home) SHARE_CODEX_HOME="$2"; shift 2 ;;
    --install-node) INSTALL_NODE=1; shift ;;
    --install-python) INSTALL_PYTHON=1; shift ;;
    --apt-package) APT_PACKAGES+=("$2"); shift 2 ;;
    --command-alias) COMMAND_ALIASES+=("$2"); shift 2 ;;
    --rollback) ROLLBACK=1; shift ;;
    --network-only) NETWORK_ONLY=1; shift ;;
    --proxy-mode) PROXY_MODE="$2"; shift 2 ;;
    --proxy-host) PROXY_HOST="$2"; shift 2 ;;
    --proxy-http-port) PROXY_HTTP_PORT="$2"; shift 2 ;;
    --proxy-socks-port) PROXY_SOCKS_PORT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ "$NETWORK_ONLY" -eq 0 && "$ROLLBACK" -eq 0 && -z "$CODE_ROOT" ]]; then
  echo 'Missing required argument: --code-root' >&2
  exit 2
fi

for package in "${APT_PACKAGES[@]}"; do
  if [[ ! "$package" =~ ^[a-z0-9][a-z0-9+.-]*$ ]]; then
    echo "Invalid APT package name: $package" >&2
    exit 2
  fi
done
for alias_spec in "${COMMAND_ALIASES[@]}"; do
  if [[ ! "$alias_spec" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*=[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
    echo "Invalid command alias: $alias_spec" >&2
    exit 2
  fi
done

START_MARKER="# >>> CodexDevSetup:WSL >>>"
END_MARKER="# <<< CodexDevSetup:WSL <<<"
BASHRC="$HOME/.bashrc"
PROFILE_START_MARKER="# >>> CodexDevSetup:ProxyProfile >>>"
PROFILE_END_MARKER="# <<< CodexDevSetup:ProxyProfile <<<"
BASH_PROXY_START_MARKER="# >>> CodexDevSetup:ProxyBash >>>"
BASH_PROXY_END_MARKER="# <<< CodexDevSetup:ProxyBash <<<"
PROXY_START_MARKER="# >>> CodexDevSetup:Proxy >>>"
PROXY_END_MARKER="# <<< CodexDevSetup:Proxy <<<"
PROFILE="$HOME/.profile"
PROXY_FILE="$HOME/.config/codex/proxy.sh"
STATE_ROOT="$HOME/.local/state/codex-dev-setup"
DETAIL_LOG=""

# Bash does not expand a tilde that arrives through a variable. Normalize it
# for direct helper invocations; the PowerShell workflow normally passes an
# already resolved Linux absolute path.
if [[ "$CODE_ROOT" == '~' ]]; then
  CODE_ROOT="$HOME"
elif [[ "$CODE_ROOT" == ~/* ]]; then
  CODE_ROOT="$HOME/${CODE_ROOT#~/}"
fi

# Non-interactive WSL commands do not normally read .bashrc. Include the
# managed user locations now so a later run recognizes existing fnm and uv
# installations instead of downloading them again.
export PATH="$HOME/.local/bin:$HOME/.local/share/fnm:$PATH"

stage() { printf '\n[WSL] %s\n' "$*"; }
say() { printf '      %s\n' "$*"; }
run_quiet_with_progress() {
  local description="$1"
  shift
  local command_log pid status elapsed=0
  if [[ -z "$DETAIL_LOG" ]]; then
    mkdir -p "$STATE_ROOT"
    DETAIL_LOG="$STATE_ROOT/setup-$(date +%Y%m%d-%H%M%S).log"
  fi
  command_log="$(mktemp)"
  register_temp_file "$command_log"
  "$@" >"$command_log" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    elapsed=$((elapsed + 1))
    if [[ $((elapsed % 10)) -eq 0 ]] && kill -0 "$pid" 2>/dev/null; then
      say "$description（已等待 ${elapsed} 秒）"
    fi
  done
  if wait "$pid"; then
    status=0
  else
    status=$?
  fi
  if [[ -n "$DETAIL_LOG" ]]; then
    {
      printf '\n--- %s ---\n' "$description"
      cat "$command_log"
    } >>"$DETAIL_LOG"
  fi
  if [[ "$status" -ne 0 ]]; then
    say "$description失败，以下是最后几行诊断信息：" >&2
    tail -n 12 "$command_log" | sed 's/^/        /' >&2
    [[ -n "$DETAIL_LOG" ]] && say "完整记录：$DETAIL_LOG" >&2
  fi
  rm -f "$command_log"
  return "$status"
}
fail_sudo_auth() {
  printf '%s\n' 'CODEX_SETUP_SUDO_AUTH_FAILED' >&2
  say '无法验证 Ubuntu/WSL 用户密码；尚未开始安装。请确认输入的是 Ubuntu 用户密码（不是 Windows PIN 或 Microsoft 帐户密码），然后重新运行。' >&2
  exit "$SUDO_AUTH_FAILURE_EXIT"
}

ensure_sudo() {
  if [[ "$EUID" -eq 0 ]]; then
    SUDO=()
    return 0
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    printf '%s\n' 'CODEX_SETUP_SUDO_UNAVAILABLE' >&2
    say '当前 Ubuntu 用户没有 sudo 命令，无法安装缺少的系统工具。' >&2
    exit "$SUDO_UNAVAILABLE_EXIT"
  fi

  stage '需要 Ubuntu 用户授权'
  say '请输入 Ubuntu 用户密码（不是 Windows PIN 或 Microsoft 帐户密码）。'
  say '输入时不会显示任何字符；输入完成后按 Enter。'
  # Validate before any apt command so an incorrect password does not leave a
  # partially configured toolchain. sudo -v reuses this short-lived ticket for
  # the following apt commands.
  if ! sudo -v; then
    fail_sudo_auth
  fi
  say '密码验证通过，继续安装。'
  SUDO=(sudo)
}

is_package_installed() {
  dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null | grep -qx 'installed'
}

run() {
  if [[ "$MODE" == "what-if" ]]; then
    printf '[WhatIf]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

run_apt() {
  if [[ "$MODE" == "what-if" ]]; then
    run sudo apt-get "$@"
  elif [[ "${#SUDO[@]}" -gt 0 ]]; then
    run "${SUDO[@]}" apt-get "$@"
  else
    run apt-get "$@"
  fi
}

remove_managed_block() {
  local source="$1" destination="$2"
  awk -v start="$START_MARKER" -v end="$END_MARKER" '
    $0 == start { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
  ' "$source" > "$destination"
}

remove_marked_block() {
  local source="$1" destination="$2" start_marker="$3" end_marker="$4"
  awk -v start="$start_marker" -v end="$end_marker" '
    $0 == start { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
  ' "$source" > "$destination"
}

validate_file_markers() {
  local file="$1" start_marker="$2" end_marker="$3"
  [[ -f "$file" ]] || return 0
  local start_count end_count start_line end_line
  start_count="$(grep -Fxc "$start_marker" "$file" || true)"
  end_count="$(grep -Fxc "$end_marker" "$file" || true)"
  if [[ "$start_count" -eq 0 && "$end_count" -eq 0 ]]; then return 0; fi
  if [[ "$start_count" -ne 1 || "$end_count" -ne 1 ]]; then
    printf '%s\n' 'CODEX_SETUP_SHELL_MARKERS_INVALID' >&2
    say "检测到 $file 中的 Codex 管理标记不完整或重复；本次未修改该文件。" >&2
    exit "$SHELL_MARKER_FAILURE_EXIT"
  fi
  start_line="$(grep -Fnx "$start_marker" "$file" | cut -d: -f1)"
  end_line="$(grep -Fnx "$end_marker" "$file" | cut -d: -f1)"
  if [[ "$start_line" -ge "$end_line" ]]; then
    printf '%s\n' 'CODEX_SETUP_SHELL_MARKERS_INVALID' >&2
    say "检测到 $file 中的 Codex 管理标记顺序异常；本次未修改该文件。" >&2
    exit "$SHELL_MARKER_FAILURE_EXIT"
  fi
}

remove_managed_proxy_settings() {
  local managed_file managed_start managed_end tmp should_remove
  for managed_file in "$BASHRC" "$PROFILE" "$PROXY_FILE"; do
    if [[ "$managed_file" == "$BASHRC" ]]; then
      managed_start="$BASH_PROXY_START_MARKER"; managed_end="$BASH_PROXY_END_MARKER"
    elif [[ "$managed_file" == "$PROFILE" ]]; then
      managed_start="$PROFILE_START_MARKER"; managed_end="$PROFILE_END_MARKER"
    else
      managed_start="$PROXY_START_MARKER"; managed_end="$PROXY_END_MARKER"
    fi
    should_remove=0
    if [[ -f "$managed_file" ]] && grep -Fq "$managed_start" "$managed_file"; then
      should_remove=1
    elif [[ "$managed_file" == "$BASHRC" ]] && [[ -f "$managed_file" ]] && grep -Fq '.config/codex/proxy.sh' "$managed_file"; then
      should_remove=1
    fi
    if [[ "$should_remove" -eq 1 ]]; then
      tmp="$(mktemp)"
      register_temp_file "$tmp"
      remove_marked_block "$managed_file" "$tmp" "$managed_start" "$managed_end"
      if [[ "$managed_file" == "$BASHRC" ]]; then
        awk '$0 != "[ -f \"$HOME/.config/codex/proxy.sh\" ] && . \"$HOME/.config/codex/proxy.sh\"" { print }' "$tmp" > "${tmp}.clean"
        mv -- "${tmp}.clean" "$tmp"
      fi
      if [[ "$MODE" == "what-if" ]]; then
        say "预览：将从 $managed_file 删除由本工具管理的代理设置。"
      else
        mkdir -p "$STATE_ROOT"
        cp "$managed_file" "$STATE_ROOT/$(basename "$managed_file")-before-proxy-remove-$(date +%Y%m%d-%H%M%S)"
        chmod --reference="$managed_file" "$tmp"
        mv -- "$tmp" "$managed_file"
        say "已关闭本工具在 $managed_file 中管理的持久代理。"
      fi
    fi
  done
}

extract_managed_block() {
  local source="$1"
  awk -v start="$START_MARKER" -v end="$END_MARKER" '
    $0 == start { inside=1 }
    inside { print }
    $0 == end { exit }
  ' "$source"
}

validate_managed_markers() {
  [[ -f "$BASHRC" ]] || return 0
  local start_count end_count start_line end_line
  start_count="$(grep -Fxc "$START_MARKER" "$BASHRC" || true)"
  end_count="$(grep -Fxc "$END_MARKER" "$BASHRC" || true)"
  if [[ "$start_count" -eq 0 && "$end_count" -eq 0 ]]; then
    return 0
  fi
  if [[ "$start_count" -ne 1 || "$end_count" -ne 1 ]]; then
    printf '%s\n' 'CODEX_SETUP_SHELL_MARKERS_INVALID' >&2
    say "检测到 $BASHRC 中的 Codex 管理标记不完整或重复；为保护你原有的终端设置，本次未修改该文件。" >&2
    exit "$SHELL_MARKER_FAILURE_EXIT"
  fi
  start_line="$(grep -Fnx "$START_MARKER" "$BASHRC" | cut -d: -f1)"
  end_line="$(grep -Fnx "$END_MARKER" "$BASHRC" | cut -d: -f1)"
  if [[ "$start_line" -ge "$end_line" ]]; then
    printf '%s\n' 'CODEX_SETUP_SHELL_MARKERS_INVALID' >&2
    say "检测到 $BASHRC 中的 Codex 管理标记顺序异常；为保护你原有的终端设置，本次未修改该文件。" >&2
    exit "$SHELL_MARKER_FAILURE_EXIT"
  fi
}

# Validate before installing anything. If a previous managed block was edited
# manually, abort cleanly instead of accidentally removing unrelated .bashrc text.
validate_managed_markers
validate_file_markers "$BASHRC" "$BASH_PROXY_START_MARKER" "$BASH_PROXY_END_MARKER"
validate_file_markers "$PROFILE" "$PROFILE_START_MARKER" "$PROFILE_END_MARKER"
validate_file_markers "$PROXY_FILE" "$PROXY_START_MARKER" "$PROXY_END_MARKER"

# Reject invalid proxy input before creating backups, state directories, or shell files.
if [[ "$PROXY_MODE" != "keep" && "$PROXY_MODE" != "persistent" && "$PROXY_MODE" != "none" ]]; then
  say "不支持的代理模式：$PROXY_MODE" >&2
  exit 2
fi
if [[ "$PROXY_MODE" == "persistent" ]]; then
  for port_value in "$PROXY_HTTP_PORT" "$PROXY_SOCKS_PORT"; do
    if [[ ! "$port_value" =~ ^[0-9]+$ ]] || [[ "$port_value" -lt 1 ]] || [[ "$port_value" -gt 65535 ]]; then
      say "代理端口无效：$port_value" >&2
      exit 2
    fi
  done
  if [[ "$PROXY_HOST" != "127.0.0.1" ]]; then
    say 'mirrored 模式只自动配置 127.0.0.1，避免意外使用或暴露 LAN 代理。' >&2
    exit 2
  fi
fi

if [[ "$ROLLBACK" -eq 1 ]]; then
  if [[ "$NETWORK_ONLY" -eq 0 ]]; then
  if [[ -f "$BASHRC" ]] && grep -Fq "$START_MARKER" "$BASHRC"; then
    tmp="$(mktemp "${BASHRC}.codex-setup.XXXXXX")"
    register_temp_file "$tmp"
    remove_managed_block "$BASHRC" "$tmp"
    if [[ "$MODE" == "what-if" ]]; then
      say "预览：将从 $BASHRC 删除由本工具管理的设置。"
      rm -f "$tmp"
    else
      mkdir -p "$STATE_ROOT"
      cp "$BASHRC" "$STATE_ROOT/bashrc-before-rollback-$(date +%Y%m%d-%H%M%S)"
      chmod --reference="$BASHRC" "$tmp"
      mv -- "$tmp" "$BASHRC"
      say '已删除由本工具管理的终端设置；已安装的软件包保持不变。'
    fi
  else
    say '没有找到由本工具管理的终端设置，无需回滚。'
  fi
  fi
  remove_managed_proxy_settings
  exit 0
fi

if [[ "$NETWORK_ONLY" -eq 0 ]]; then
stage '开始准备 Linux 开发环境'
say "项目目录：$CODE_ROOT"

missing_apt_packages=()
for package in "${APT_PACKAGES[@]}"; do
  if ! is_package_installed "$package"; then
    missing_apt_packages+=("$package")
  fi
done

if [[ "${#missing_apt_packages[@]}" -gt 0 ]]; then
  stage '安装已配置的 Ubuntu 软件包'
  say "需要安装：${missing_apt_packages[*]}"
  if [[ "$MODE" == "apply" ]]; then
    ensure_sudo
  fi
  say '步骤 1/2：正在更新软件列表，网络较慢时可能需要几十秒……'
  if [[ "$MODE" == "what-if" ]]; then
    run_apt "${APT_OPTIONS[@]}" update
  else
    run_quiet_with_progress '仍在更新软件列表' "${SUDO[@]}" apt-get "${APT_OPTIONS[@]}" update
  fi
  say '步骤 2/2：正在安装缺少的软件包，通常需要 1–3 分钟……'
  if [[ "$MODE" == "what-if" ]]; then
    run_apt "${APT_OPTIONS[@]}" install -y "${missing_apt_packages[@]}"
  else
    run_quiet_with_progress '仍在安装 Ubuntu 软件包' "${SUDO[@]}" apt-get "${APT_OPTIONS[@]}" install -y "${missing_apt_packages[@]}"
  fi
  if [[ "$MODE" == "what-if" ]]; then
    say '预览完成：以上命令尚未执行。'
  else
    for package in "${missing_apt_packages[@]}"; do
      installed_version="$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null || true)"
      if [[ -n "$installed_version" ]]; then
        say "已安装 $package $installed_version"
      else
        say "已安装 $package；暂时无法读取版本。"
      fi
    done
  fi
else
  stage '检查已配置的 Ubuntu 软件包'
  say '已启用的软件包组均已齐全，无需更新软件包列表或重复安装。'
fi

# Some Debian packages expose a distro-specific command name. Create only the
# explicitly configured aliases in the user's bin directory.
for alias_spec in "${COMMAND_ALIASES[@]}"; do
  alias_name="${alias_spec%%=*}"
  target_name="${alias_spec#*=}"
  alias_link="$HOME/.local/bin/$alias_name"
  target_path="$(command -v "$target_name" 2>/dev/null || true)"
  if [[ -z "$target_path" ]]; then
    say "未创建 $alias_name 快捷入口：目标命令 $target_name 不可用。"
  elif [[ -e "$alias_link" ]] && [[ ! -L "$alias_link" ]]; then
    say "未创建 $alias_name 快捷入口：$alias_link 已存在且不是符号链接。"
  elif [[ ! -L "$alias_link" ]] || [[ "$(readlink "$alias_link")" != "$target_path" ]]; then
    run mkdir -p "$HOME/.local/bin"
    run ln -sfn "$target_path" "$alias_link"
    say "已准备 $alias_name 命令（指向 $target_name）。"
  else
    say "$alias_name 命令已可用，无需重复创建快捷入口。"
  fi
done

if [[ -d "$CODE_ROOT" ]]; then
  say "项目目录已存在，无需创建：$CODE_ROOT"
else
  stage '准备 Linux 项目目录'
  run mkdir -p "$CODE_ROOT"
fi

if [[ "$INSTALL_NODE" -eq 1 ]] && ! command -v fnm >/dev/null 2>&1; then
  stage '准备 Node.js 管理工具'
  if [[ "$MODE" == "what-if" ]]; then
    say '预览：将从 fnm 官方安装脚本准备 Node.js 管理工具。'
  else
    fnm_installer="$(mktemp)"
    register_temp_file "$fnm_installer"
    run_quiet_with_progress '正在下载 Node.js 管理工具' curl -fsSL https://fnm.vercel.app/install -o "$fnm_installer"
    run_quiet_with_progress '正在安装 Node.js 管理工具' bash "$fnm_installer" --skip-shell
    rm -f "$fnm_installer"
    say 'Node.js 管理工具已准备好。'
  fi
fi

if [[ "$INSTALL_PYTHON" -eq 1 ]] && ! command -v uv >/dev/null 2>&1; then
  stage '准备 Python 管理工具'
  if [[ "$MODE" == "what-if" ]]; then
    say '预览：将从 uv 官方安装脚本准备 Python 管理工具。'
  else
    uv_installer="$(mktemp)"
    register_temp_file "$uv_installer"
    run_quiet_with_progress '正在下载 Python 管理工具' curl -LsSf https://astral.sh/uv/install.sh -o "$uv_installer"
    run_quiet_with_progress '正在安装 Python 管理工具' sh "$uv_installer"
    rm -f "$uv_installer"
    say 'Python 管理工具已准备好。'
  fi
fi
fi

effective_proxy_mode="$PROXY_MODE"
if [[ "$PROXY_MODE" == "keep" ]] && { [[ -f "$PROXY_FILE" ]] || { [[ -f "$BASHRC" ]] && grep -Fq '.config/codex/proxy.sh' "$BASHRC"; } || { [[ -f "$PROFILE" ]] && grep -Fq '.config/codex/proxy.sh' "$PROFILE"; }; }; then
  effective_proxy_mode="persistent"
fi

if [[ "$NETWORK_ONLY" -eq 0 ]]; then
block_file="$(mktemp)"
register_temp_file "$block_file"
{
  printf '%s\n' "$START_MARKER"
  printf '%s\n' 'export PATH="$HOME/.local/bin:$HOME/.local/share/fnm:$PATH"'
  printf '%s\n' 'if command -v fnm >/dev/null 2>&1; then eval "$(fnm env --use-on-cd --shell bash)"; fi'
  printf '%s\n' 'alias gst="git status --short --branch"'
  printf '%s\n' 'alias gdf="git diff"'
  if [[ -n "$SHARE_CODEX_HOME" ]]; then
    printf 'export CODEX_HOME=%q\n' "$SHARE_CODEX_HOME"
  fi
  if [[ "$PROXY_MODE" == "keep" && "$effective_proxy_mode" == "persistent" ]] && { [[ ! -f "$BASHRC" ]] || ! grep -Fq "$BASH_PROXY_START_MARKER" "$BASHRC"; }; then
    printf '%s\n' '[ -f "$HOME/.config/codex/proxy.sh" ] && . "$HOME/.config/codex/proxy.sh"'
  fi
  printf '%s\n' "$END_MARKER"
} > "$block_file"

existing_file="$(mktemp)"
register_temp_file "$existing_file"
if [[ -f "$BASHRC" ]]; then
  remove_managed_block "$BASHRC" "$existing_file"
else
  : > "$existing_file"
fi

block_needs_update=1
if [[ -f "$BASHRC" ]] && cmp -s "$block_file" <(extract_managed_block "$BASHRC"); then
  block_needs_update=0
fi

if [[ "$block_needs_update" -eq 0 ]]; then
  say 'WSL 终端快捷设置已符合当前选择，无需备份或重写 .bashrc。'
elif [[ "$MODE" == "what-if" ]]; then
  stage '准备 WSL 终端启动设置'
  say "预览：将把以下由本工具管理的内容写入 $BASHRC："
  sed 's/^/  /' "$block_file"
else
  mkdir -p "$STATE_ROOT"
  if [[ -f "$BASHRC" ]]; then
    cp "$BASHRC" "$STATE_ROOT/bashrc-$(date +%Y%m%d-%H%M%S).bak"
  fi
  bashrc_tmp="$(mktemp "${BASHRC}.codex-setup.XXXXXX")"
  register_temp_file "$bashrc_tmp"
  {
    sed '${/^$/d;}' "$existing_file"
    printf '\n%s\n' "$(cat "$block_file")"
  } > "$bashrc_tmp"
  if [[ -f "$BASHRC" ]]; then
    chmod --reference="$BASHRC" "$bashrc_tmp"
  fi
  mv -- "$bashrc_tmp" "$BASHRC"
fi
rm -f "$block_file" "$existing_file"
fi

if [[ "$PROXY_MODE" == "none" ]]; then
  remove_managed_proxy_settings
fi

if [[ "$PROXY_MODE" == "persistent" ]]; then
  proxy_existing="$(mktemp)"; register_temp_file "$proxy_existing"
  if [[ -f "$PROXY_FILE" ]]; then
    remove_marked_block "$PROXY_FILE" "$proxy_existing" "$PROXY_START_MARKER" "$PROXY_END_MARKER"
  else
    : > "$proxy_existing"
  fi
  proxy_tmp="$(mktemp)"; register_temp_file "$proxy_tmp"
  {
    sed '${/^$/d;}' "$proxy_existing"
    printf '\n%s\n' "$PROXY_START_MARKER"
    printf '%s\n' "proxy_on() {"
    printf '  local host="${1:-%s}" http_port="${2:-%s}" socks_port="${3:-%s}"\n' "$PROXY_HOST" "$PROXY_HTTP_PORT" "$PROXY_SOCKS_PORT"
    printf '%s\n' '  export http_proxy="http://${host}:${http_port}"' '  export https_proxy="$http_proxy"' '  export HTTP_PROXY="$http_proxy"' '  export HTTPS_PROXY="$https_proxy"'
    printf '%s\n' '  export all_proxy="socks5h://${host}:${socks_port}"' '  export ALL_PROXY="$all_proxy"'
    printf '%s\n' '  export no_proxy="localhost,127.0.0.1,::1,.local"' '  export NO_PROXY="$no_proxy"' '}'
    printf '%s\n' 'proxy_off() {' '  unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY' '}'
    printf '%s\n' 'proxy_status() {' "  env | grep -iE '^(http|https|all|no)_proxy=' || true" '}'
    printf 'proxy_on %q %q %q\n' "$PROXY_HOST" "$PROXY_HTTP_PORT" "$PROXY_SOCKS_PORT"
    printf '%s\n' "$PROXY_END_MARKER"
  } > "$proxy_tmp"
  if [[ -f "$PROXY_FILE" ]] && cmp -s "$proxy_tmp" "$PROXY_FILE"; then
    say "Codex 持久代理文件已符合当前端口，无需重写：$PROXY_FILE"
    rm -f "$proxy_tmp"
  elif [[ "$MODE" == "apply" ]]; then
    mkdir -p "$STATE_ROOT" "$(dirname "$PROXY_FILE")"
    [[ -f "$PROXY_FILE" ]] && cp "$PROXY_FILE" "$STATE_ROOT/proxy.sh-$(date +%Y%m%d-%H%M%S).bak"
    chmod 600 "$proxy_tmp"
    mv -- "$proxy_tmp" "$PROXY_FILE"
  else
    say "预览：将生成 $PROXY_FILE（HTTP $PROXY_HTTP_PORT，SOCKS $PROXY_SOCKS_PORT）。"
  fi

  profile_existing="$(mktemp)"; register_temp_file "$profile_existing"
  if [[ -f "$PROFILE" ]]; then
    remove_marked_block "$PROFILE" "$profile_existing" "$PROFILE_START_MARKER" "$PROFILE_END_MARKER"
  else
    : > "$profile_existing"
  fi
  profile_tmp="$(mktemp)"; register_temp_file "$profile_tmp"
  {
    sed '${/^$/d;}' "$profile_existing"
    printf '\n%s\n' "$PROFILE_START_MARKER"
    printf '%s\n' '[ -f "$HOME/.config/codex/proxy.sh" ] && . "$HOME/.config/codex/proxy.sh"'
    printf '%s\n' "$PROFILE_END_MARKER"
  } > "$profile_tmp"
  if [[ -f "$PROFILE" ]] && cmp -s "$profile_tmp" "$PROFILE"; then
    say "登录 shell 已加载 Codex 代理文件，无需重写：$PROFILE"
    rm -f "$profile_tmp"
  elif [[ "$MODE" == "apply" ]]; then
    mkdir -p "$STATE_ROOT"
    [[ -f "$PROFILE" ]] && cp "$PROFILE" "$STATE_ROOT/profile-$(date +%Y%m%d-%H%M%S).bak"
    [[ -f "$PROFILE" ]] && chmod --reference="$PROFILE" "$profile_tmp"
    mv -- "$profile_tmp" "$PROFILE"
  else
    say "预览：将在 $PROFILE 中加载 Codex 代理文件。"
  fi

  bash_proxy_existing="$(mktemp)"; register_temp_file "$bash_proxy_existing"
  if [[ -f "$BASHRC" ]]; then
    remove_marked_block "$BASHRC" "$bash_proxy_existing" "$BASH_PROXY_START_MARKER" "$BASH_PROXY_END_MARKER"
  else
    : > "$bash_proxy_existing"
  fi
  # Migrate the loader from the legacy general block without touching other shell settings.
  awk '$0 != "[ -f \"$HOME/.config/codex/proxy.sh\" ] && . \"$HOME/.config/codex/proxy.sh\"" { print }' "$bash_proxy_existing" > "${bash_proxy_existing}.clean"
  mv -- "${bash_proxy_existing}.clean" "$bash_proxy_existing"
  bash_proxy_tmp="$(mktemp)"; register_temp_file "$bash_proxy_tmp"
  {
    sed '${/^$/d;}' "$bash_proxy_existing"
    printf '\n%s\n' "$BASH_PROXY_START_MARKER"
    printf '%s\n' '[ -f "$HOME/.config/codex/proxy.sh" ] && . "$HOME/.config/codex/proxy.sh"'
    printf '%s\n' "$BASH_PROXY_END_MARKER"
  } > "$bash_proxy_tmp"
  if [[ -f "$BASHRC" ]] && cmp -s "$bash_proxy_tmp" "$BASHRC"; then
    say "交互 shell 已加载 Codex 代理文件，无需重写：$BASHRC"
    rm -f "$bash_proxy_tmp"
  elif [[ "$MODE" == "apply" ]]; then
    mkdir -p "$STATE_ROOT"
    [[ -f "$BASHRC" ]] && cp "$BASHRC" "$STATE_ROOT/bashrc-before-proxy-$(date +%Y%m%d-%H%M%S).bak"
    [[ -f "$BASHRC" ]] && chmod --reference="$BASHRC" "$bash_proxy_tmp"
    mv -- "$bash_proxy_tmp" "$BASHRC"
  else
    say "预览：将在 $BASHRC 中加载 Codex 代理文件。"
  fi
fi

if [[ "$NETWORK_ONLY" -eq 0 ]] && [[ "$MODE" == "apply" ]] && [[ "$INSTALL_NODE" -eq 1 ]]; then
  export PATH="$HOME/.local/bin:$HOME/.local/share/fnm:$PATH"
  if command -v fnm >/dev/null 2>&1; then
    eval "$(fnm env --shell bash)"
    run_quiet_with_progress '正在准备推荐版本的 Node.js' fnm install --lts
    run_quiet_with_progress '正在设置默认 Node.js 版本' fnm default lts-latest
    say '推荐版本的 Node.js 已准备好。'
  fi
fi

if [[ "$NETWORK_ONLY" -eq 0 ]] && [[ "$MODE" == "apply" ]] && [[ "$INSTALL_PYTHON" -eq 1 ]]; then
  export PATH="$HOME/.local/bin:$PATH"
  if command -v uv >/dev/null 2>&1; then
    run_quiet_with_progress '正在准备 Python' uv python install
    say 'Python 已准备好。'
  fi
fi

stage 'WSL/Linux 设置完成'
if [[ "$MODE" == "what-if" ]]; then
  say '本次只是预览，没有安装软件或修改终端设置。'
else
  say '请重新打开 WSL/Linux 终端，以使用更新后的环境。'
fi
