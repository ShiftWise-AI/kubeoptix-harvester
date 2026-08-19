#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  run-ocp.sh [--namespaces "ns1 ns2"] [--tail-lines N]

Description:
  1. Collects artifacts from OpenShift namespaces
  2. Collects worker node YAMLs in /app/data/assessment/worknodes
  3. Stores all collected files in /app/data/assessment

Examples:
  ./run-ocp.sh --namespaces "app-a app-b"
EOF
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COLLECT_SCRIPT="$SCRIPT_DIR/collectors/oc_collect_all_namespaces.sh"
COLLECT_WORKNODES_SCRIPT="$SCRIPT_DIR/collectors/oc_collect_worknodes.sh"
REMOVE_SECRETS_SCRIPT="$SCRIPT_DIR/collectors/oc_remove_secret_manifests.sh"

NAMESPACES=""
TAIL_LINES="300"
FIXED_OUTPUT_DIR="/app/data/assessment"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespaces)
      NAMESPACES="${2:-}"
      [[ -n "$NAMESPACES" ]] || fail "--namespaces requires at least one namespace"
      shift 2
      ;;
    --tail-lines)
      TAIL_LINES="${2:-}"
      [[ "$TAIL_LINES" =~ ^[0-9]+$ ]] || fail "--tail-lines requires a non-negative integer"
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

mkdir -p "$FIXED_OUTPUT_DIR"
ARTIFACTS_DIR="$FIXED_OUTPUT_DIR"
require_cmd oc
require_cmd python3

# Remove only legacy artifact roots that should no longer be generated.
find "/app/data" -mindepth 1 -maxdepth 1 -type d -name 'oc-health-artifacts-*' -exec rm -rf {} +

#if [[ ! -d "$VENV_DIR" ]]; then
#  echo "[INFO] Creating Python virtual environment..."
#  python3 -m venv "$VENV_DIR"
#fi
#
## shellcheck disable=SC1091
#source "$VENV_DIR/bin/activate"
#
#echo "[INFO] Installing Python dependencies..."
#pip install --upgrade pip >/dev/null
#pip install -r "$REQUIREMENTS_FILE"

[[ -f "$COLLECT_SCRIPT" ]] || fail "Collection script not found: $COLLECT_SCRIPT"
collect_args=(-o "$ARTIFACTS_DIR" --tail-lines "$TAIL_LINES")
if [[ -n "$NAMESPACES" ]]; then
  collect_args+=(--namespaces "$NAMESPACES")
fi
[[ -f "$COLLECT_WORKNODES_SCRIPT" ]] || fail "Worker node collection script not found: $COLLECT_WORKNODES_SCRIPT"
[[ -f "$REMOVE_SECRETS_SCRIPT" ]] || fail "Secret removal script not found: $REMOVE_SECRETS_SCRIPT"

echo "[INFO] Step 1/3: collecting worker node YAMLs..."
bash "$COLLECT_WORKNODES_SCRIPT" -o "$ARTIFACTS_DIR"
echo "[PROGRESS] 10"

echo "[INFO] Step 2/3: collecting namespace artifacts..."
bash "$COLLECT_SCRIPT" "${collect_args[@]}"
echo "[PROGRESS] 90"

echo "[INFO] Step 3/3: removing secret manifests..."
bash "$REMOVE_SECRETS_SCRIPT" -d "$ARTIFACTS_DIR" --dry-run
echo "[PROGRESS] 100"

printf '\n'
echo "[INFO] Collection finished successfully."
echo "[INFO] Final artifacts directory: $ARTIFACTS_DIR"
