#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  run-ocp.sh [--deploy-namespace <ns>] [--release-name <name>] [--chart-dir <dir>] [--values-file <file>] [--wait-timeout <duration>] [--namespaces "ns1 ns2"] [-o <output_dir>] [--tail-lines N]

Description:
  1. Deploys/updates Helm chart in OpenShift
  2. If namespace does not exist, creates it before deployment
  3. Waits for StatefulSet pod stabilization
  4. Collects artifacts from OpenShift namespaces
  5. Collects worker node YAMLs in <output_dir>/worknodes

Examples:
  ./run-ocp.sh --deploy-namespace shiftwise-ai --release-name kubeoptix-harvester
  ./run-ocp.sh --namespaces "app-a app-b" -o ./output-dir
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
CHART_DIR="$SCRIPT_DIR/helm/kubeoptix-harvester"
VALUES_FILE="$CHART_DIR/values.yaml"
DEPLOY_NAMESPACE="shiftwise-ai"
HELM_RELEASE="kubeoptix-harvester"
WAIT_TIMEOUT="10m"

OUTPUT_DIR=""
REQUESTED_OUTPUT_DIR=""
NAMESPACES=""
TAIL_LINES="300"
FIXED_OUTPUT_DIR="/app/data/assessment"

normalize_output_dir() {
  printf '%s' "$FIXED_OUTPUT_DIR"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

wait_for_statefulset_ready() {
  local namespace="$1"
  local release="$2"
  local timeout="$3"
  local sts_name

  sts_name="$(oc -n "$namespace" get statefulset -l "app.kubernetes.io/instance=$release" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$sts_name" ]] || fail "No StatefulSet found for Helm release '$release' in namespace '$namespace'"

  echo "[INFO] Waiting for StatefulSet rollout: $sts_name (timeout: $timeout)"
  oc -n "$namespace" rollout status "statefulset/$sts_name" --timeout="$timeout"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output-dir)
      OUTPUT_DIR="${2:-}"
      [[ -n "$OUTPUT_DIR" ]] || fail "$1 requires a directory"
      REQUESTED_OUTPUT_DIR="$OUTPUT_DIR"
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
    --deploy-namespace)
      DEPLOY_NAMESPACE="${2:-}"
      [[ -n "$DEPLOY_NAMESPACE" ]] || fail "--deploy-namespace requires a namespace"
      shift 2
      ;;
    --release-name)
      HELM_RELEASE="${2:-}"
      [[ -n "$HELM_RELEASE" ]] || fail "--release-name requires a release name"
      shift 2
      ;;
    --chart-dir)
      CHART_DIR="${2:-}"
      [[ -n "$CHART_DIR" ]] || fail "--chart-dir requires a directory"
      shift 2
      ;;
    --values-file)
      VALUES_FILE="${2:-}"
      [[ -n "$VALUES_FILE" ]] || fail "--values-file requires a file path"
      shift 2
      ;;
    --wait-timeout)
      WAIT_TIMEOUT="${2:-}"
      [[ -n "$WAIT_TIMEOUT" ]] || fail "--wait-timeout requires a duration (e.g. 10m)"
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
  OUTPUT_DIR="$FIXED_OUTPUT_DIR"
fi
OUTPUT_DIR="$(normalize_output_dir "$OUTPUT_DIR")"
mkdir -p "$OUTPUT_DIR"
ARTIFACTS_DIR="$(cd -- "$OUTPUT_DIR" && pwd)"

if [[ -n "$REQUESTED_OUTPUT_DIR" && "$REQUESTED_OUTPUT_DIR" != "$FIXED_OUTPUT_DIR" ]]; then
  echo "[WARN] Ignoring custom output directory and using fixed path: $FIXED_OUTPUT_DIR"
fi

[[ -d "$CHART_DIR" ]] || fail "Helm chart directory not found: $CHART_DIR"
[[ -f "$VALUES_FILE" ]] || fail "Helm values file not found: $VALUES_FILE"
require_cmd oc
require_cmd helm

echo "[INFO] Checking namespace: $DEPLOY_NAMESPACE"
if oc get namespace "$DEPLOY_NAMESPACE" >/dev/null 2>&1; then
  echo "[INFO] Namespace '$DEPLOY_NAMESPACE' already exists. Updating Helm release '$HELM_RELEASE'."
else
  echo "[INFO] Namespace '$DEPLOY_NAMESPACE' not found. Creating namespace."
  oc create namespace "$DEPLOY_NAMESPACE"
fi

echo "[INFO] Applying updated Helm chart..."
helm upgrade --install "$HELM_RELEASE" "$CHART_DIR" \
  --namespace "$DEPLOY_NAMESPACE" \
  --values "$VALUES_FILE" \
  --wait \
  --timeout "$WAIT_TIMEOUT"

wait_for_statefulset_ready "$DEPLOY_NAMESPACE" "$HELM_RELEASE" "$WAIT_TIMEOUT"
echo "[INFO] Helm deployment completed and pod stabilized."

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
[[ -f "$ANONYMIZATION_SCRIPT" ]] || fail "Anonymization script not found: $ANONYMIZATION_SCRIPT"

echo "[INFO] Step 1/4: collecting worker node YAMLs..."
bash "$COLLECT_WORKNODES_SCRIPT" -o "$ARTIFACTS_DIR"
echo "[PROGRESS] 10"

echo "[INFO] Step 2/4: collecting namespace artifacts..."
bash "$COLLECT_SCRIPT" "${collect_args[@]}"
echo "[PROGRESS] 85"

echo "[INFO] Step 3/4: removing secret manifests..."
bash "$REMOVE_SECRETS_SCRIPT" -d "$ARTIFACTS_DIR" --dry-run
echo "[PROGRESS] 90"

echo "[INFO] Step 4/4: anonymizing collected artifacts..."
python3 "$ANONYMIZATION_SCRIPT" "$ARTIFACTS_DIR"
echo "[PROGRESS] 100"

printf '\n'
echo "[INFO] Collection finished successfully."
echo "[INFO] Final artifacts directory: $ARTIFACTS_DIR"
