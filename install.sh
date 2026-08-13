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
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-300}"

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

NS_EXISTS="false"
if oc get namespace "$NS" >/dev/null 2>&1; then
  NS_EXISTS="true"
fi

if [[ "$RESET" == "true" ]]; then
  if [[ "$NS_EXISTS" == "true" ]]; then
    echo "[INFO] Namespace '$NS' already exists. Keeping namespace and updating release in-place."
  else
    echo "[INFO] RESET requested, but namespace '$NS' does not exist yet. Continuing with fresh install."
  fi
fi

if [[ "$NS_EXISTS" == "true" ]]; then
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

echo "[INFO] Waiting for pod scheduling/readiness before health check..."
deadline=$((SECONDS + HEALTH_TIMEOUT_SECONDS))
POD_NAME=""
while (( SECONDS < deadline )); do
  POD_NAME="$(oc get pod -n "$NS" -l app.kubernetes.io/instance="$RELEASE" -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -n1 || true)"
  if [[ -n "$POD_NAME" ]]; then
    POD_PHASE="$(oc get pod "$POD_NAME" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    POD_HOST_IP="$(oc get pod "$POD_NAME" -n "$NS" -o jsonpath='{.status.hostIP}' 2>/dev/null || true)"
    POD_READY="$(oc get pod "$POD_NAME" -n "$NS" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true)"

    if [[ "$POD_PHASE" == "Running" && -n "$POD_HOST_IP" && "$POD_READY" == "True" ]]; then
      break
    fi
  fi
  sleep 3
done

if [[ -z "$POD_NAME" ]]; then
  echo "[WARN] Timed out waiting for a running pod in namespace $NS"
  echo "[WARN] Inspect with: oc get pods -n $NS -o wide"
  exit 1
fi

echo "[INFO] Service health test:"
SVC_NAME="$(oc get svc -n "$NS" -l app.kubernetes.io/instance="$RELEASE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

if [[ -z "$POD_NAME" || -z "$SVC_NAME" ]]; then
  echo "[WARN] Could not resolve pod/service for release $RELEASE in namespace $NS"
  echo "[WARN] Verify deployed objects with: oc get all -n $NS"
  exit 1
fi

health_ok="false"
while (( SECONDS < deadline )); do
  if oc exec -n "$NS" "$POD_NAME" -- /bin/sh -lc "python - <<'PY'
import urllib.request
url = 'http://${SVC_NAME}:8000/health'
with urllib.request.urlopen(url, timeout=10) as response:
    body = response.read().decode()
    print(f'health_url={url} status={response.status} body={body}')
PY" >/dev/null 2>&1; then
    health_ok="true"
    break
  fi
  sleep 3
done

if [[ "$health_ok" != "true" ]]; then
  echo "[WARN] Health check failed. Inspect pods/logs with:"
  echo "  oc get pods -n $NS"
  echo "  oc logs -n $NS statefulset/$RELEASE --tail=200"
  exit 1
fi

oc exec -n "$NS" "$POD_NAME" -- /bin/sh -lc "python - <<'PY'
import urllib.request
url = 'http://${SVC_NAME}:8000/health'
with urllib.request.urlopen(url, timeout=10) as response:
    body = response.read().decode()
    print(f'health_url={url} status={response.status} body={body}')
PY"

echo
echo "[INFO] Installation and health check completed successfully."
