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
POST_INSTALL_CLEANUP="${POST_INSTALL_CLEANUP:-true}"
CLEANUP_DRY_RUN="${CLEANUP_DRY_RUN:-false}"

usage() {
  cat <<'EOF'
Usage:
  ./install.sh -f <values-file>

Options:
  -f, --values   Helm values file (required)
  --skip-cleanup Skip post-install cleanup
  --cleanup-dry-run  Show cleanup actions without deleting resources
  -h, --help     Show this help message

Environment variables:
  RELEASE        Helm release name (default: kubeoptix-harvester)
  NS             OpenShift namespace/project (default: shiftwise-ai)
  CHART_PATH     Helm chart path (default: ./helm/kubeoptix-harvester)
  WAIT_TIMEOUT   Rollout timeout (default: 300s)
  BUILD_FROM_LOCAL  Build from the local workspace instead of Git (default: false)
  POST_INSTALL_CLEANUP  Run post-install cleanup (default: true)
  CLEANUP_DRY_RUN  Dry-run cleanup without deleting resources (default: false)
EOF
}

delete_or_echo() {
  local kind="$1"
  local name="$2"
  if [[ "$CLEANUP_DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] oc delete $kind/$name -n $NS"
    return 0
  fi
  oc delete "$kind" "$name" -n "$NS" --ignore-not-found
}

contains_name() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

cleanup_orphaned_helm_and_sa_secrets() {
  local -a service_account_secrets=()
  local -a sa_names=()

  mapfile -t sa_names < <(
    oc get sa -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
  )

  for sa_name in "${sa_names[@]}"; do
    [[ -n "$sa_name" ]] || continue
    while read -r ref_name; do
      [[ -n "$ref_name" ]] || continue
      service_account_secrets+=("$ref_name")
    done < <(
      oc get sa "$sa_name" -n "$NS" -o jsonpath='{range .secrets[*]}{.name}{"\n"}{end}{range .imagePullSecrets[*]}{.name}{"\n"}{end}' 2>/dev/null || true
    )
  done

  echo "[INFO] Cleaning Helm metadata secret and orphan service-account docker secrets..."
  while read -r secret_name; do
    [[ -n "$secret_name" ]] || continue

    if [[ "$secret_name" == sh.helm.release.v1.${RELEASE}* ]]; then
      delete_or_echo "secret" "$secret_name"
      continue
    fi

    if [[ "$secret_name" == *-dockercfg-* ]]; then
      if contains_name "$secret_name" "${used_secrets[@]}"; then
        continue
      fi
      if contains_name "$secret_name" "${service_account_secrets[@]}"; then
        continue
      fi
      delete_or_echo "secret" "$secret_name"
    fi
  done < <(
    oc get secrets -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
  )
}

post_install_cleanup() {
  local release_selector="app.kubernetes.io/instance=$RELEASE"
  echo "[INFO] Starting post-install cleanup (dry-run=$CLEANUP_DRY_RUN)..."

  local -a used_configmaps=()
  local -a used_secrets=()
  mapfile -t used_configmaps < <(
    {
      oc get pods -n "$NS" -o jsonpath='{range .items[*]}{range .spec.volumes[*]}{.configMap.name}{"\n"}{end}{range .spec.initContainers[*]}{range .env[*]}{.valueFrom.configMapKeyRef.name}{"\n"}{end}{range .envFrom[*]}{.configMapRef.name}{"\n"}{end}{end}{range .spec.containers[*]}{range .env[*]}{.valueFrom.configMapKeyRef.name}{"\n"}{end}{range .envFrom[*]}{.configMapRef.name}{"\n"}{end}{end}{end}' 2>/dev/null || true
    } | awk 'NF' | sort -u
  )

  mapfile -t used_secrets < <(
    {
      oc get pods -n "$NS" -o jsonpath='{range .items[*]}{range .spec.volumes[*]}{.secret.secretName}{"\n"}{end}{range .spec.imagePullSecrets[*]}{.name}{"\n"}{end}{range .spec.initContainers[*]}{range .env[*]}{.valueFrom.secretKeyRef.name}{"\n"}{end}{range .envFrom[*]}{.secretRef.name}{"\n"}{end}{end}{range .spec.containers[*]}{range .env[*]}{.valueFrom.secretKeyRef.name}{"\n"}{end}{range .envFrom[*]}{.secretRef.name}{"\n"}{end}{end}{end}' 2>/dev/null || true
    } | awk 'NF' | sort -u
  )

  echo "[INFO] Cleaning completed/failed builds from this release..."
  while read -r build_name build_phase; do
    [[ -n "$build_name" ]] || continue
    case "$build_phase" in
      Complete|Failed|Error|Cancelled)
        delete_or_echo "build" "$build_name"
        ;;
    esac
  done < <(
    oc get builds -n "$NS" -l "$release_selector" \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null || true
  )

  echo "[INFO] Cleaning succeeded/failed pods from this release..."
  while read -r pod_name pod_phase; do
    [[ -n "$pod_name" ]] || continue
    case "$pod_phase" in
      Succeeded|Failed)
        delete_or_echo "pod" "$pod_name"
        ;;
    esac
  done < <(
    oc get pods -n "$NS" -l "$release_selector" \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null || true
  )

  echo "[INFO] Cleaning orphan release ConfigMaps (unused by pods)..."
  while read -r cm_name; do
    [[ -n "$cm_name" ]] || continue
    if contains_name "$cm_name" "${used_configmaps[@]}"; then
      continue
    fi
    delete_or_echo "configmap" "$cm_name"
  done < <(
    oc get configmaps -n "$NS" -l "$release_selector" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
  )

  echo "[INFO] Cleaning unused release secrets, including Helm-created auth secrets..."
  while read -r secret_name owner_kinds; do
    [[ -n "$secret_name" ]] || continue
    if contains_name "$secret_name" "${used_secrets[@]}"; then
      continue
    fi

    # Skip secrets with owner references to avoid deleting active managed certs or generated resources.
    if [[ -n "$owner_kinds" ]]; then
      continue
    fi
    delete_or_echo "secret" "$secret_name"
  done < <(
    oc get secrets -n "$NS" -l "$release_selector" \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .metadata.ownerReferences[*]}{.kind}{","}{end}{"\n"}{end}' 2>/dev/null || true
  )

  cleanup_orphaned_helm_and_sa_secrets

  echo "[INFO] Post-install cleanup finished."
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
    --skip-cleanup)
      POST_INSTALL_CLEANUP="false"
      shift
      ;;
    --cleanup-dry-run)
      CLEANUP_DRY_RUN="true"
      shift
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

echo "[INFO] Installing/Upgrading build resources..."
helm upgrade --install "$RELEASE" "$CHART_PATH" \
  -n "$NS" \
  -f "$VALUES_FILE" \
  --set namespace.create=false \
  --set deploy.enabled=false
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

echo "[INFO] Installing/Upgrading the workload with the newly built image..."
helm upgrade --install "$RELEASE" "$CHART_PATH" \
  -n "$NS" \
  -f "$VALUES_FILE" \
  --set namespace.create=false

STATEFULSET_NAME="$(oc get statefulset -n "$NS" -l app.kubernetes.io/instance="$RELEASE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "$STATEFULSET_NAME" ]]; then
  oc rollout status "statefulset/$STATEFULSET_NAME" -n "$NS" --timeout="$WAIT_TIMEOUT"
else
  echo "[ERROR] No StatefulSet found for release '$RELEASE' in namespace '$NS'."
  echo "[ERROR] Ensure deploy.enabled=true in the Helm values file."
  exit 1
fi

echo "[INFO] Current resources:"
oc get all -n "$NS"

if [[ "$POST_INSTALL_CLEANUP" == "true" ]]; then
  post_install_cleanup
else
  echo "[INFO] Post-install cleanup skipped (--skip-cleanup)."
fi

echo "[INFO] Install completed successfully."
