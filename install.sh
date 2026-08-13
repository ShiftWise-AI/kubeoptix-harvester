#!/usr/bin/env bash
set -euo pipefail

# Fresh install script for kubeoptix-harvester on OpenShift via Helm.
# Git authentication is read only from the values file.
# Then run:
#   ./install.sh -f ./helm/kubeoptix-harvester/values.example.yaml

RELEASE="${RELEASE:-kubeoptix-harvester}"
NS="${NS:-shiftwise-ai}"
CHART_PATH="${CHART_PATH:-./helm/kubeoptix-harvester}"
VALUES_FILE="${VALUES_FILE:-}"
GIT_URI="${GIT_URI:-https://github.com/ShiftWise-AI/kubeoptix-harvester.git}"
GIT_REF="${GIT_REF:-feature/ocp}"
RESET="${RESET:-true}"
WAIT_BUILD="${WAIT_BUILD:-true}"
BUILD_FROM_LOCAL="${BUILD_FROM_LOCAL:-true}"

usage() {
  echo "Usage: $0 -f <values-file>"
  echo "   or: $0 <values-file>"
  echo
  echo "Example:"
  echo "  $0 -f ./helm/kubeoptix-harvester/values.example.yaml"
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
      if [[ -z "$VALUES_FILE" ]]; then
        VALUES_FILE="$1"
        shift
      else
        echo "[ERROR] Unknown argument: $1"
        usage
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$VALUES_FILE" ]]; then
  echo "[ERROR] Values file parameter is required."
  usage
  exit 1
fi

if [[ ! -f "$VALUES_FILE" ]]; then
  echo "[ERROR] Values file not found: $VALUES_FILE"
  exit 1
fi

command -v helm >/dev/null 2>&1 || { echo "[ERROR] helm not found"; exit 1; }
command -v oc >/dev/null 2>&1 || { echo "[ERROR] oc not found"; exit 1; }

oc whoami >/dev/null

echo "[INFO] Release: $RELEASE"
echo "[INFO] Namespace: $NS"
echo "[INFO] Chart: $CHART_PATH"
echo "[INFO] Values: $VALUES_FILE"

if [[ "$RESET" == "true" ]]; then
  echo "[INFO] Removing previous release/namespace (if any)..."
  helm uninstall "$RELEASE" -n "$NS" || true
  oc delete namespace "$NS" --ignore-not-found=true
  oc wait --for=delete "namespace/$NS" --timeout=180s || true
fi

if oc get namespace "$NS" >/dev/null 2>&1; then
  echo "[INFO] Namespace '$NS' already exists."
else
  echo "[INFO] Namespace '$NS' does not exist. Creating it now..."
  oc create namespace "$NS"
fi

HELM_ARGS=(
  upgrade --install "$RELEASE" "$CHART_PATH"
  -n "$NS"
  --create-namespace
  -f "$VALUES_FILE"
  --set namespace.create=false
  --set namespace.name="$NS"
  --set build.enabled=true
  --set build.source.gitUri="$GIT_URI"
  --set build.source.gitRef="$GIT_REF"
)

echo "[INFO] Git source authentication is managed only by values file settings."

echo "[INFO] Phase 1/2: Deploying build resources only..."
helm "${HELM_ARGS[@]}" --set deploy.enabled=false

echo "[INFO] Triggering OpenShift build..."
BC_NAME="$(oc get bc -n "$NS" -l app.kubernetes.io/instance="$RELEASE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "$BC_NAME" ]]; then
  echo "[ERROR] BuildConfig not found for release $RELEASE in namespace $NS"
  exit 1
fi

if [[ "$BUILD_FROM_LOCAL" == "true" ]]; then
  echo "[INFO] Build source mode: local workspace (binary build)"
  if [[ "$WAIT_BUILD" == "true" ]]; then
    oc start-build "$BC_NAME" -n "$NS" --from-dir=. --follow --wait
  else
    oc start-build "$BC_NAME" -n "$NS" --from-dir=. --wait
  fi
else
  echo "[INFO] Build source mode: remote Git source"
  if [[ "$WAIT_BUILD" == "true" ]]; then
    oc start-build "$BC_NAME" -n "$NS" --follow --wait
  else
    oc start-build "$BC_NAME" -n "$NS" --wait
  fi
fi

echo "[INFO] Phase 2/2: Deploying StatefulSet and runtime objects after successful build..."
helm "${HELM_ARGS[@]}" --set deploy.enabled=true

echo "[INFO] Helm status:"
helm status "$RELEASE" -n "$NS"

echo "[INFO] Current resources:"
oc get all -n "$NS"

echo "[INFO] Service health test:"
POD_NAME="$(oc get pod -n "$NS" -l app.kubernetes.io/instance="$RELEASE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
SVC_NAME="$(oc get svc -n "$NS" -l app.kubernetes.io/instance="$RELEASE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

if [[ -z "$POD_NAME" || -z "$SVC_NAME" ]]; then
  echo "[WARN] Could not resolve pod/service for release $RELEASE in namespace $NS"
  echo "[WARN] Verify deployed objects with: oc get all -n $NS"
  exit 1
fi

oc exec -n "$NS" "$POD_NAME" -- /bin/sh -lc "python - <<'PY'
import urllib.request
url = 'http://${SVC_NAME}:8000/health'
with urllib.request.urlopen(url, timeout=10) as response:
    body = response.read().decode()
    print(f'health_url={url} status={response.status} body={body}')
PY" || {
  echo "[WARN] Health check failed. Inspect pods/logs with:"
  echo "  oc get pods -n $NS"
  echo "  oc logs -n $NS statefulset/$RELEASE --tail=200"
  exit 1
}

echo
echo "[INFO] Installation and health check completed successfully."
