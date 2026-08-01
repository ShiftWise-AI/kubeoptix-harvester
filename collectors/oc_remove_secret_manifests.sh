#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  oc_remove_secret_manifests.sh -d <directory> [--dry-run]

Description:
  Recursively scans a directory, looks for YAML manifests with kind: Secret,
  and deletes the matching files.

Options:
  -d, --dir       Root directory to scan
  --dry-run       List the files found without deleting them
EOF
}

log() {
  local message="$*"
  render_status_line "[$(date '+%Y-%m-%d %H:%M:%S')] $message" "$PROGRESS_CURRENT" "$PROGRESS_TOTAL"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

PROGRESS_SPINNER_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
PROGRESS_SPINNER_INDEX=0
PROGRESS_CURRENT=0
PROGRESS_TOTAL=0

render_status_line() {
  local message="$1"
  local current="$2"
  local total="$3"

  local spinner="${PROGRESS_SPINNER_CHARS:PROGRESS_SPINNER_INDEX:1}"
  local percent=0
  local filled=0
  local empty=0
  local bar=""
  local i

  if (( total > 0 )); then
    percent=$(( current * 100 / total ))
    filled=$(( percent / 5 ))
  fi

  empty=$(( 20 - filled ))
  if (( filled < 0 )); then filled=0; fi
  if (( empty  < 0 )); then empty=0;  fi

  for ((i = 0; i < filled; i++)); do bar+='█'; done
  for ((i = 0; i < empty;  i++)); do bar+='░'; done

  local suffix=" |${bar}| ${current}/${total} (${percent}%)"
  local GREEN=$'\033[32m'
  local RESET=$'\033[0m'
  local suffix_colored=" ${GREEN}|${bar}|${RESET} ${current}/${total} (${percent}%)"
  local prefix="[${spinner}] "
  local term_cols="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"
  local max_msg=$(( term_cols - ${#prefix} - ${#suffix} - 1 ))

  if (( max_msg > 3 && ${#message} > max_msg )); then
    message="${message:0:$(( max_msg - 3 ))}..."
  fi

  printf '\r\033[K%s%s%s' "$prefix" "$message" "$suffix_colored"
  PROGRESS_SPINNER_INDEX=$(((PROGRESS_SPINNER_INDEX + 1) % 10))
}

show_progress() {
  local message="$1"
  local current="$2"
  local total="$3"

  PROGRESS_CURRENT="$current"
  PROGRESS_TOTAL="$total"
  render_status_line "$message" "$current" "$total"
}

clear_progress_line() {
  printf '\r\033[K'
}

finish_status_line() {
  printf '\n'
}

main() {
  local target_dir=""
  local dry_run="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--dir)
        target_dir="${2:-}"
        shift 2
        ;;
      --dry-run)
        dry_run="true"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Invalid parameter: $1"
        ;;
    esac
  done

  [[ -n "$target_dir" ]] || fail "Specify the directory with -d|--dir"
  [[ -d "$target_dir" ]] || fail "Directory not found: $target_dir"

  local found_count=0
  local removed_count=0
  local file
  local files=()

  while IFS= read -r -d '' file; do
    files+=("$file")
  done < <(find "$target_dir" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0)

  local total_files=${#files[@]}
  show_progress "Scanning files" 0 "$total_files"

  for index in "${!files[@]}"; do
    file="${files[$index]}"
    if grep -Eq '^[[:space:]]*kind:[[:space:]]*Secret([[:space:]]*$)' "$file"; then
      found_count=$((found_count + 1))
      if [[ "$dry_run" == "true" ]]; then
        log "Found Secret: $file"
      else
        rm -f -- "$file"
        removed_count=$((removed_count + 1))
        log "Deleted Secret: $file"
      fi
    fi
    show_progress "Scanning files" "$((index + 1))" "$total_files"
  done
  clear_progress_line

  if [[ "$dry_run" == "true" ]]; then
    log "Dry-run completed. Secrets found: $found_count"
  else
    log "Scan completed. Secrets found: $found_count, deleted: $removed_count"
  fi
  finish_status_line
}

main "$@"