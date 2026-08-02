#!/usr/bin/env bash
set -euo pipefail

MODE="what-if"
CODE_ROOT="$HOME/code"
SHARE_CODEX_HOME=""
INSTALL_NODE=0
INSTALL_PYTHON=0
ROLLBACK=0
SUDO_AUTH_FAILURE_EXIT=77
SUDO_UNAVAILABLE_EXIT=78
SHELL_MARKER_FAILURE_EXIT=79
BASE_PACKAGES=(git curl ca-certificates build-essential unzip zip jq ripgrep fd-find)
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
    --rollback) ROLLBACK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

START_MARKER="# >>> CodexDevSetup:WSL >>>"
END_MARKER="# <<< CodexDevSetup:WSL <<<"
BASHRC="$HOME/.bashrc"
STATE_ROOT="$HOME/.local/state/codex-dev-setup"
DETAIL_LOG=""

# Bash does not expand a tilde that arrives through a variable. The Windows
# caller intentionally passes ~/code so normalize it before testing or making
# the directory.
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

if [[ "$ROLLBACK" -eq 1 ]]; then
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
  exit 0
fi

stage '开始准备 Linux 开发环境'
say "项目目录：$CODE_ROOT"

missing_base_packages=()
for package in "${BASE_PACKAGES[@]}"; do
  if ! is_package_installed "$package"; then
    missing_base_packages+=("$package")
  fi
done

if [[ "${#missing_base_packages[@]}" -gt 0 ]]; then
  stage '安装 Ubuntu 基础工具'
  say "需要安装：${missing_base_packages[*]}"
  if [[ "$MODE" == "apply" ]]; then
    ensure_sudo
  fi
  say '步骤 1/2：正在更新软件列表，网络较慢时可能需要几十秒……'
  if [[ "$MODE" == "what-if" ]]; then
    run_apt "${APT_OPTIONS[@]}" update
  else
    run_quiet_with_progress '仍在更新软件列表' "${SUDO[@]}" apt-get "${APT_OPTIONS[@]}" update
  fi
  say '步骤 2/2：正在安装缺少的工具，通常需要 1–3 分钟……'
  if [[ "$MODE" == "what-if" ]]; then
    run_apt "${APT_OPTIONS[@]}" install -y "${missing_base_packages[@]}"
  else
    run_quiet_with_progress '仍在安装 Ubuntu 基础工具' "${SUDO[@]}" apt-get "${APT_OPTIONS[@]}" install -y "${missing_base_packages[@]}"
  fi
  if [[ "$MODE" == "what-if" ]]; then
    say '预览完成：以上命令尚未执行。'
  else
    say 'Ubuntu 基础工具安装完成。'
  fi
else
  stage '检查 Ubuntu 基础工具'
  say '所需工具已齐全，无需更新软件包列表或重复安装。'
fi

# Ubuntu/Debian installs the fd utility under the command name "fdfind" to
# avoid a package-name collision. Provide the standard cross-platform command
# in the user's own bin directory without changing system files.
if command -v fdfind >/dev/null 2>&1; then
  fd_target="$(command -v fdfind)"
  fd_link="$HOME/.local/bin/fd"
  if [[ -e "$fd_link" ]] && [[ ! -L "$fd_link" ]]; then
    say "未创建 fd 快捷入口：$fd_link 已存在且不是符号链接。"
  elif [[ ! -L "$fd_link" ]] || [[ "$(readlink "$fd_link")" != "$fd_target" ]]; then
    run mkdir -p "$HOME/.local/bin"
    run ln -sfn "$fd_target" "$fd_link"
    say '已准备 fd 命令（Ubuntu 的 fd-find 软件包默认使用 fdfind 名称）。'
  else
    say 'fd 命令已可用，无需重复创建快捷入口。'
  fi
fi

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

if [[ "$MODE" == "apply" ]] && [[ "$INSTALL_NODE" -eq 1 ]]; then
  export PATH="$HOME/.local/bin:$HOME/.local/share/fnm:$PATH"
  if command -v fnm >/dev/null 2>&1; then
    eval "$(fnm env --shell bash)"
    run_quiet_with_progress '正在准备推荐版本的 Node.js' fnm install --lts
    run_quiet_with_progress '正在设置默认 Node.js 版本' fnm default lts-latest
    say '推荐版本的 Node.js 已准备好。'
  fi
fi

if [[ "$MODE" == "apply" ]] && [[ "$INSTALL_PYTHON" -eq 1 ]]; then
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
