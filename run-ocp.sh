#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  run_assessment.sh [--namespaces "ns1 ns2"] [-o <output_dir>] [--tail-lines N]

Description:
  1. Collects artifacts from OpenShift namespaces
  2. Collects worker node YAMLs in <output_dir>/worknodes

Examples:
  ./run_assessment.sh --namespaces "app-a app-b" -o ./output-dir
EOF
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
COLLECT_SCRIPT="$SCRIPT_DIR/collectors/oc_collect_all_namespaces.sh"
COLLECT_WORKNODES_SCRIPT="$SCRIPT_DIR/collectors/oc_collect_worknodes.sh"
REMOVE_SECRETS_SCRIPT="$SCRIPT_DIR/collectors/oc_remove_secret_manifests.sh"
ANONYMIZATION_SCRIPT="$SCRIPT_DIR/src/anonymization.py"
REQUIREMENTS_FILE="$SCRIPT_DIR/requirements.txt"
#VENV_DIR="$SCRIPT_DIR/.venv"

OUTPUT_DIR=""
NAMESPACES=""
TAIL_LINES="300"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output-dir)
      OUTPUT_DIR="${2:-}"
      [[ -n "$OUTPUT_DIR" ]] || fail "$1 requires a directory"
      shift 2
      ;;
    --namespaces)
      NAMESPACES="${2:-}"
      [[ -n "$NAMESPACES" ]] || fail "--namespaces requires at least one namespace"
      shift 2
      ;;
    --tail-lines)
      TAIL_LINES="${2:-}"
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

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="/app/data/oc-health-artifacts-$(date '+%Y%m%d_%H%M%S')"
fi
mkdir -p "$OUTPUT_DIR"
ARTIFACTS_DIR="$(cd -- "$OUTPUT_DIR" && pwd)"

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
[[ -f "$ANONYMIZATION_SCRIPT" ]] || fail "Anonymization script not found: $ANONYMIZATION_SCRIPT"

echo "[INFO] Step 1/4: collecting worker node YAMLs..."
bash "$COLLECT_WORKNODES_SCRIPT" -o "$ARTIFACTS_DIR"

echo "[INFO] Step 2/4: collecting namespace artifacts..."
bash "$COLLECT_SCRIPT" "${collect_args[@]}"

echo "[INFO] Step 3/4: removing secret manifests..."
bash "$REMOVE_SECRETS_SCRIPT" -d "$ARTIFACTS_DIR" --dry-run

echo "[INFO] Step 4/4: anonymizing collected artifacts..."
python3 "$ANONYMIZATION_SCRIPT" "$ARTIFACTS_DIR"

printf '\n'
echo "[INFO] Extraction completed."
echo "[INFO] Artifacts: $ARTIFACTS_DIR"
