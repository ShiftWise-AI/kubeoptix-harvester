#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  oc_collect_all_namespaces.sh [-o <output_dir>] [--tail-lines <N>] [--namespaces "ns1 ns2"]

Description:
  Executes the simplified collection for multiple namespaces and organizes the
  output by namespace/application.
  Collects only: pod logs, deployments, deploymentconfigs, statefulsets,
  configmaps, routes, services, jobs, replicasets, and hpa.
EOF
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COLLECT_SCRIPT="$SCRIPT_DIR/oc_collect_namespace.sh"

[[ -f "$COLLECT_SCRIPT" ]] || fail "Base script not found: $COLLECT_SCRIPT"

OUTPUT_DIR="./oc-health-artifacts-$(date '+%Y%m%d_%H%M%S')"
TAIL_LINES="300"
NAMESPACES="default "

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --tail-lines)
      TAIL_LINES="${2:-}"
      shift 2
      ;;
    --namespaces)
      NAMESPACES="${2:-}"
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

[[ "$TAIL_LINES" =~ ^[0-9]+$ ]] || fail "--tail-lines must be numeric"
command -v oc >/dev/null 2>&1 || fail "Command 'oc' not found in PATH"
oc whoami >/dev/null 2>&1 || fail "No authenticated OpenShift session. Run: oc login"
mkdir -p "$OUTPUT_DIR"

for ns in $NAMESPACES; do
  echo "[INFO] Collecting namespace: $ns"
  bash "$COLLECT_SCRIPT" -n "$ns" -o "$OUTPUT_DIR" --tail-lines "$TAIL_LINES"
done

echo "[INFO] Collection completed in: $OUTPUT_DIR"
