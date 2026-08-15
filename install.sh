#!/usr/bin/env bash
set -euo pipefail

# Install script for kubeoptix-harvester on OpenShift using Helm.
# Helm values must be provided with -f/--values.
# Example:
#   ./install.sh -f ./helm/kubeoptix-harvester/values.example.yaml

RELEASE="${RELEASE:-kubeoptix-harvester}"
NS="${NS:-shiftwise-ai}"
CHART_PATH="${CHART_PATH:-./helm/kubeoptix-harvester}"
VALUES_FILE=""
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300s}"
BUILD_FROM_LOCAL="${BUILD_FROM_LOCAL:-false}"

usage() {
  cat <<'EOF'
Usage:
  ./install.sh -f <values-file>

Options:
  -f, --values   Helm values file (required)
  -h, --help     Show this help message

Environment variables:
  RELEASE        Helm release name (default: kubeoptix-harvester)
  NS             OpenShift namespace/project (default: shiftwise-ai)
  CHART_PATH     Helm chart path (default: ./helm/kubeoptix-harvester)
  WAIT_TIMEOUT   Rollout timeout (default: 300s)
  BUILD_FROM_LOCAL  Build from the local workspace instead of Git (default: false)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--values)
      if [[ $# -lt 2 ]]; then
        echo "[ERROR] Missing value for $1"
        usage
        exit 1
      fi
      VALUES_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$VALUES_FILE" ]]; then
  echo "[ERROR] Values file is required. Use -f <values-file>."
  usage
  exit 1
fi

if [[ ! -f "$VALUES_FILE" ]]; then
  echo "[ERROR] Values file not found: $VALUES_FILE"
  exit 1
fi

if [[ ! -d "$CHART_PATH" ]]; then
  echo "[ERROR] Chart path not found: $CHART_PATH"
  exit 1
fi

command -v oc >/dev/null 2>&1 || { echo "[ERROR] oc not found"; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "[ERROR] helm not found"; exit 1; }

oc whoami >/dev/null

echo "[INFO] Release: $RELEASE"
echo "[INFO] Namespace: $NS"
echo "[INFO] Chart: $CHART_PATH"
echo "[INFO] Values: $VALUES_FILE"

NS_EXISTS="false"
if oc get namespace "$NS" >/dev/null 2>&1; then
  NS_EXISTS="true"
fi

if [[ "$NS_EXISTS" == "true" ]]; then
  echo "[INFO] Namespace '$NS' already exists. Updating the complete inventory."
else
  echo "[INFO] Namespace '$NS' does not exist. Creating it now..."
  oc create namespace "$NS"
fi

echo "[INFO] Installing/Upgrading the complete Helm inventory..."
helm upgrade --install "$RELEASE" "$CHART_PATH" \
  -n "$NS" \
  -f "$VALUES_FILE" \
  --set namespace.create=false \
  --set namespace.name="$NS"

echo "[INFO] Starting a new OpenShift build..."
BC_NAME="$(oc get buildconfig -n "$NS" -l app.kubernetes.io/instance="$RELEASE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "$BC_NAME" ]]; then
  echo "[ERROR] BuildConfig not found for release '$RELEASE' in namespace '$NS'."
  echo "[ERROR] Ensure build.enabled=true in the Helm values file."
  exit 1
fi

if [[ "$BUILD_FROM_LOCAL" == "true" ]]; then
  echo "[INFO] Build source: local workspace"
  oc start-build "$BC_NAME" -n "$NS" --from-dir=. --follow --wait
else
  echo "[INFO] Build source: Git configured in Helm values"
  oc start-build "$BC_NAME" -n "$NS" --follow --wait
fi

echo "[INFO] Helm status:"
helm status "$RELEASE" -n "$NS"

echo "[INFO] Restarting the workload with the newly built image..."
STATEFULSET_NAME="$(oc get statefulset -n "$NS" -l app.kubernetes.io/instance="$RELEASE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "$STATEFULSET_NAME" ]]; then
  oc rollout restart "statefulset/$STATEFULSET_NAME" -n "$NS"
  oc rollout status "statefulset/$STATEFULSET_NAME" -n "$NS" --timeout="$WAIT_TIMEOUT"
else
  echo "[ERROR] No StatefulSet found for release '$RELEASE' in namespace '$NS'."
  echo "[ERROR] Ensure deploy.enabled=true in the Helm values file."
  exit 1
fi

echo "[INFO] Current resources:"
oc get all -n "$NS"

echo "[INFO] Install completed successfully."
