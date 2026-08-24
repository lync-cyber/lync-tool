#!/usr/bin/env bash
set -euo pipefail

code_root=""
expected_distro=""
commands=()
json_mode=0
uv_managed_python=""

while (($# > 0)); do
  case "$1" in
    --code-root)
      code_root=${2:?missing value for --code-root}
      shift 2
      ;;
    --expected-distro)
      expected_distro=${2:?missing value for --expected-distro}
      shift 2
      ;;
    --command)
      commands+=("${2:?missing value for --command}")
      shift 2
      ;;
    --uv-managed-python)
      uv_managed_python=${2:?missing value for --uv-managed-python}
      shift 2
      ;;
    --json)
      json_mode=1
      shift
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [[ -n $uv_managed_python && ! $uv_managed_python =~ ^[0-9]+\.[0-9]+$ ]]; then
  printf 'Invalid uv-managed Python version: %s\n' "$uv_managed_python" >&2
  exit 2
fi

failures=0
check_ids=()
check_labels=()
check_statuses=()
check_details=()
check_detail=""
resolved_code_root="$code_root"
resolved_working_directory="$PWD"

is_linux() {
  check_detail=$(uname -s 2>/dev/null || true)
  [[ $check_detail == Linux ]]
}

has_expected_distro() {
  check_detail=${WSL_DISTRO_NAME:-none}
  [[ -n ${WSL_DISTRO_NAME:-} ]] && [[ -z $expected_distro || $WSL_DISTRO_NAME == "$expected_distro" ]]
}

uses_bash_shell() {
  check_detail=${SHELL:-none}
  [[ ${SHELL:-} == */bash ]]
}

has_linux_code_root() {
  check_detail=$code_root
  [[ -d $code_root ]] || return 1
  resolved_code_root=$(realpath -e -- "$code_root") || return 1
  check_detail=$resolved_code_root
  [[ $resolved_code_root == /home/* ]]
}

has_project_working_directory() {
  check_detail=$PWD
  resolved_working_directory=$(realpath -e -- "$PWD") || return 1
  check_detail=$resolved_working_directory
  [[ $resolved_working_directory == "$resolved_code_root" || $resolved_working_directory == "$resolved_code_root"/* ]]
}

command_is_native() {
  local resolved
  resolved=$(type -P -- "$1") || {
    check_detail=missing
    return 1
  }
  resolved=$(readlink -f -- "$resolved") || {
    check_detail=$resolved
    return 1
  }
  check_detail=$resolved
  [[ $resolved != /mnt/* ]]
}

has_uv_managed_python() {
  local requested=$1 uv_path managed_root interpreter version
  uv_path=$(type -P -- uv) || {
    check_detail='uv missing'
    return 1
  }
  uv_path=$(readlink -f -- "$uv_path") || {
    check_detail=$uv_path
    return 1
  }
  if [[ $uv_path == /mnt/* ]]; then
    check_detail=$uv_path
    return 1
  fi
  managed_root=$(uv python dir 2>/dev/null) || {
    check_detail='uv python dir failed'
    return 1
  }
  managed_root=$(readlink -f -- "$managed_root") || {
    check_detail=$managed_root
    return 1
  }
  if [[ $managed_root == /mnt/* ]]; then
    check_detail=$managed_root
    return 1
  fi
  interpreter=$(UV_PYTHON_DOWNLOADS=never uv python find --managed-python --no-project "$requested" 2>/dev/null) || {
    check_detail="uv-managed Python $requested missing"
    return 1
  }
  interpreter=$(readlink -f -- "$interpreter") || {
    check_detail=$interpreter
    return 1
  }
  if [[ $interpreter == /mnt/* ]]; then
    check_detail=$interpreter
    return 1
  fi
  case $interpreter in
    "$managed_root"/*) ;;
    *)
      check_detail="$interpreter (outside $managed_root)"
      return 1
      ;;
  esac
  version=$("$interpreter" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null) || {
    check_detail="$interpreter (version probe failed)"
    return 1
  }
  check_detail="$interpreter (uv-managed $version)"
  [[ $version == "$requested" ]]
}

record_check() {
  local id=$1 label=$2
  shift 2
  check_detail=""
  local status
  if "$@"; then
    status=PASS
  else
    status=FAIL
    failures=$((failures + 1))
  fi
  check_ids+=("$id")
  check_labels+=("$label")
  check_statuses+=("$status")
  check_details+=("$check_detail")
  if ((json_mode == 0)); then
    if [[ $status == PASS ]]; then
      printf 'PASS  %s\n' "$label"
    else
      printf 'FAIL  %s\n' "$label" >&2
    fi
  fi
}

json_escape() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

emit_json() {
  local verdict=PASS
  ((failures == 0)) || verdict=FAIL
  printf '{'
  printf '"schemaVersion":2,'
  printf '"verdict":"%s",' "$verdict"
  printf '"failureCount":%d,' "$failures"
  printf '"expectedDistro":"%s",' "$(json_escape "$expected_distro")"
  printf '"currentDistro":"%s",' "$(json_escape "${WSL_DISTRO_NAME:-}")"
  printf '"codeRoot":"%s",' "$(json_escape "$resolved_code_root")"
  printf '"workingDirectory":"%s",' "$(json_escape "$resolved_working_directory")"
  printf '"shell":"%s",' "$(json_escape "${SHELL:-}")"
  printf '"checks":['
  local index
  for ((index = 0; index < ${#check_ids[@]}; index++)); do
    ((index == 0)) || printf ','
    printf '{"id":"%s","label":"%s","status":"%s","detail":"%s"}' \
      "$(json_escape "${check_ids[$index]}")" \
      "$(json_escape "${check_labels[$index]}")" \
      "${check_statuses[$index]}" \
      "$(json_escape "${check_details[$index]}")"
  done
  printf ']}\n'
}

record_check kernel 'Linux kernel' is_linux
record_check distro 'Expected WSL distribution' has_expected_distro
record_check shell 'Bash shell' uses_bash_shell
record_check code-root 'Code root is in the Linux filesystem' has_linux_code_root
record_check working-directory 'Working directory is inside the code root' has_project_working_directory

for command_name in "${commands[@]}"; do
  record_check "command:$command_name" "$command_name resolves to a Linux path" command_is_native "$command_name"
done

if [[ -n $uv_managed_python ]]; then
  record_check "python:uv-managed-$uv_managed_python" "uv manages Python $uv_managed_python" \
    has_uv_managed_python "$uv_managed_python"
fi

if ((json_mode)); then
  emit_json
elif ((failures > 0)); then
  printf '%d environment check(s) failed.\n' "$failures" >&2
else
  printf 'WSL development environment is ready.\n'
fi

((failures == 0))
