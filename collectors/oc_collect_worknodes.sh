#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  oc_collect_worknodes.sh [-o <output_dir>]

Description:
  Extracts a YAML manifest for each node labeled
  node-role.kubernetes.io/worker and writes the files to:
    <output_dir>/worknodes/<node>.yaml

Requirements:
  - oc installed
  - authenticated cluster session (oc whoami)
  - permission to list and inspect nodes
EOF
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

OUTPUT_DIR="."

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output-dir)
      OUTPUT_DIR="${2:-}"
      [[ -n "$OUTPUT_DIR" ]] || fail "$1 requires a directory"
      shift 2
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

command -v oc >/dev/null 2>&1 || fail "Command 'oc' not found in PATH"
oc whoami >/dev/null 2>&1 || fail "No authenticated OpenShift session. Run: oc login"

WORKNODES_DIR="$OUTPUT_DIR/worknodes"
mkdir -p "$WORKNODES_DIR"

mapfile -t WORKER_NODES < <(
  oc get nodes \
    -l node-role.kubernetes.io/worker \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
)

if [[ "${#WORKER_NODES[@]}" -eq 0 ]]; then
  echo "[WARN] No worker nodes found."
  exit 0
fi

for node in "${WORKER_NODES[@]}"; do
  [[ -n "$node" ]] || continue
  echo "[INFO] Collecting worker node: $node"
  oc get node "$node" -o yaml > "$WORKNODES_DIR/$node.yaml"
done

echo "[INFO] Worker node collection completed in: $WORKNODES_DIR"