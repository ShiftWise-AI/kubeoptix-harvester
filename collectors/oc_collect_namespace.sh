#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  oc_collect_namespace.sh -n <namespace> [-o <output_dir>] [--tail-lines <N>]

Description:
  Collects only the artifacts below from an OpenShift namespace, grouping them by
  namespace and application, along with additional namespaced resources:
    - pod logs
    - deployments
    - deploymentconfigs
    - statefulsets
    - configmaps
    - routes
    - services
    - jobs
    - replicasets
    - hpa

  Main output:
    - <namespace>/apps/<app>/pod-logs/<pod>.log
    - <namespace>/apps/<app>/<resource-type>/<item-name>.yaml
    - <namespace>/apps/__no_app__/... (items without an application label)
    - <namespace>/resources/<resource-type>/<item-name>.yaml

Requirements:
  - oc installed
  - authenticated cluster session (oc whoami)
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

sanitize_name() {
  local value="$1"
  value="${value//\//_}"
  value="${value//:/_}"
  value="${value// /_}"
  printf '%s' "$value"
}

resource_to_dir_name() {
  local kind="$1"
  case "$kind" in
    deployment)
      printf 'deployments'
      ;;
    deploymentconfig)
      printf 'deploymentconfigs'
      ;;
    statefulset)
      printf 'statefulsets'
      ;;
    configmap)
      printf 'configmaps'
      ;;
    route)
      printf 'routes'
      ;;
    service)
      printf 'services'
      ;;
    job)
      printf 'jobs'
      ;;
    replicaset)
      printf 'replicasets'
      ;;
    hpa)
      printf 'hpa'
      ;;
    *)
      printf '%s' "$kind"
      ;;
  esac
}

get_additional_resource_kinds() {
  cat <<'EOF'
activedocs.capabilities.3scale.net
datauploads.velero.io
operatorgroups.operators.coreos.com
alertingrules.monitoring.openshift.io
deletebackuprequests.velero.io
operatorpkis.network.operator.openshift.io
alertmanagerconfigs.monitoring.coreos.com
deploymentconfigs.apps.openshift.io
ossmconsoles.kiali.io
alertmanagers.monitoring.coreos.com
deployments.apps
overlappingrangeipreservations.whereabouts.cni.cncf.io
alertrelabelconfigs.monitoring.openshift.io
developeraccounts.capabilities.3scale.net
packagemanifests.packages.operators.coreos.com
apicasts.apps.3scale.net
developerusers.capabilities.3scale.net
persistentvolumeclaims
apimanagerbackups.apps.3scale.net
devworkspaceoperatorconfigs.controller.devfile.io
poddisruptionbudgets.policy
apimanagerrestores.apps.3scale.net
devworkspaceroutings.controller.devfile.io
podmonitors.monitoring.coreos.com
apimanagers.apps.3scale.net
devworkspaces.workspace.devfile.io
podnetworkconnectivitychecks.controlplane.operator.openshift.io
applicationauths.capabilities.3scale.net
devworkspacetemplates.workspace.devfile.io
pods
applications.capabilities.3scale.net
dnsrecords.ingress.operator.openshift.io
pods.metrics.k8s.io
appliedclusterresourcequotas.quota.openshift.io
downloadrequests.velero.io
podtemplates
awxbackups.awx.ansible.com
drivers.csi.ceph.io
podvolumebackups.velero.io
awxmeshingresses.awx.ansible.com
dynakubes.dynatrace.com
podvolumerestores.velero.io
awxrestores.awx.ansible.com
edgeconnects.dynatrace.com
precachingconfigs.ran.openshift.io
awxs.awx.ansible.com
egressfirewalls.k8s.ovn.org
preprovisioningimages.metal3.io
backends.capabilities.3scale.net
egressqoses.k8s.ovn.org
probes.monitoring.coreos.com
backingstores.noobaa.io
egressrouters.network.operator.openshift.io
products.capabilities.3scale.net
backuprepositories.velero.io
egressservices.k8s.ovn.org
profilebundles.compliance.openshift.io
backupstoragelocations.velero.io
elasticsearches.logging.openshift.io
profiles.compliance.openshift.io
backups.velero.io
encryptionkeyrotationcronjobs.csiaddons.openshift.io
profiles.tuned.openshift.io
baremetalhosts.metal3.io
encryptionkeyrotationjobs.csiaddons.openshift.io
projecthelmchartrepositories.helm.openshift.io
bmceventsubscriptions.metal3.io
endpoints
prometheuses.monitoring.coreos.com
bucketclasses.noobaa.io
endpointslices.discovery.k8s.io
prometheusrules.monitoring.coreos.com
buildconfigs.build.openshift.io
events
proxyconfigpromotes.capabilities.3scale.net
builds.build.openshift.io
events.events.k8s.io
recipes.ramendr.openshift.io
catalogsources.operators.coreos.com
firmwareschemas.metal3.io
reclaimspacecronjobs.csiaddons.openshift.io
centrals.platform.stackrox.io
hardwaredata.metal3.io
reclaimspacejobs.csiaddons.openshift.io
cephblockpoolradosnamespaces.ceph.rook.io
horizontalpodautoscalers.autoscaling
replicasets.apps
cephblockpools.ceph.rook.io
hostfirmwarecomponents.metal3.io
replicationcontrollers
cephbucketnotifications.ceph.rook.io
hostfirmwaresettings.metal3.io
resourcequotas
cephbuckettopics.ceph.rook.io
hostupdatepolicies.metal3.io
restores.velero.io
cephclients.ceph.rook.io
imagestreams.image.openshift.io
rolebindingrestrictions.authorization.openshift.io
cephclusters.ceph.rook.io
imagestreamtags.image.openshift.io
rolebindings.authorization.openshift.io
cephconnections.csi.ceph.io
imagetags.image.openshift.io
rolebindings.rbac.authorization.k8s.io
cephcosidrivers.ceph.rook.io
ingresscontrollers.operator.openshift.io
roles.authorization.openshift.io
cephfilesystemmirrors.ceph.rook.io
ingresses.networking.k8s.io
roles.rbac.authorization.k8s.io
cephfilesystems.ceph.rook.io
installplans.operators.coreos.com
routes.route.openshift.io
cephfilesystemsubvolumegroups.ceph.rook.io
ipaddressclaims.ipam.cluster.x-k8s.io
rules.compliance.openshift.io
cephnfses.ceph.rook.io
ipaddresses.ipam.cluster.x-k8s.io
scansettingbindings.compliance.openshift.io
cephobjectrealms.ceph.rook.io
ipamclaims.k8s.cni.cncf.io
scansettings.compliance.openshift.io
cephobjectstores.ceph.rook.io
ippools.whereabouts.cni.cncf.io
schedules.velero.io
cephobjectstoreusers.ceph.rook.io
jobs.batch
securedclusters.platform.stackrox.io
cephobjectzonegroups.ceph.rook.io
keycloakrealmimports.k8s.keycloak.org
securitypolicies.config.stackrox.io
cephobjectzones.ceph.rook.io
keycloaks.k8s.keycloak.org
serverstatusrequests.velero.io
cephrbdmirrors.ceph.rook.io
kialis.kiali.io
serviceaccounts
clientprofilemappings.csi.ceph.io
kibanas.logging.openshift.io
servicemeshcontrolplanes.maistra.io
clientprofiles.csi.ceph.io
kieapps.app.kiegroup.org
servicemeshmemberrolls.maistra.io
cloudstorages.oadp.openshift.io
leases.coordination.k8s.io
servicemeshmembers.maistra.io
clustergroupupgrades.ran.openshift.io
limitranges
servicemonitors.monitoring.coreos.com
clusterlogforwarders.logging.openshift.io
localvolumediscoveries.local.storage.openshift.io
services
clusterlogforwarders.observability.openshift.io
localvolumediscoveryresults.local.storage.openshift.io
statefulsets.apps
clusterloggings.logging.openshift.io
localvolumesets.local.storage.openshift.io
storageclassclaims.ocs.openshift.io
clusterserviceversions.operators.coreos.com
localvolumes.local.storage.openshift.io
storageclusterpeers.ocs.openshift.io
compliancecheckresults.compliance.openshift.io
logfilemetricexporters.logging.openshift.io
storageclusters.ocs.openshift.io
complianceremediations.compliance.openshift.io
machineautoscalers.autoscaling.openshift.io
storageconsumers.ocs.openshift.io
compliancescans.compliance.openshift.io
machinehealthchecks.machine.openshift.io
storageprofiles.ocs.openshift.io
compliancesuites.compliance.openshift.io
machinesets.machine.openshift.io
storagerequests.ocs.openshift.io
configmaps
machines.machine.openshift.io
storagesystems.odf.openshift.io
controllerrevisions.apps
metal3remediations.infrastructure.cluster.x-k8s.io
subscriptions.operators.coreos.com
controlplanemachinesets.machine.openshift.io
metal3remediationtemplates.infrastructure.cluster.x-k8s.io
tailoredprofiles.compliance.openshift.io
costmanagementmetricsconfigs.costmanagement-metrics-cfg.openshift.io
namespacestores.noobaa.io
templateinstances.template.openshift.io
credentialsrequests.cloudcredential.openshift.io
network-attachment-definitions.k8s.cni.cncf.io
templates.template.openshift.io
cronjobs.batch
networkpolicies.networking.k8s.io
tenants.capabilities.3scale.net
csiaddonsnodes.csiaddons.openshift.io
nodeslicepools.whereabouts.cni.cncf.io
thanosrulers.monitoring.coreos.com
csistoragecapacities.storage.k8s.io
noobaaaccounts.noobaa.io
tuneds.tuned.openshift.io
custompolicydefinitions.capabilities.3scale.net
noobaas.noobaa.io
userdefinednetworks.k8s.ovn.org
customrules.compliance.openshift.io
objectbucketclaims.objectbucket.io
variables.compliance.openshift.io
daemonsets.apps
ocsinitializations.ocs.openshift.io
volumegroupreplications.replication.storage.openshift.io
datadownloads.velero.io
openapis.capabilities.3scale.net
volumereplications.replication.storage.openshift.io
dataimages.metal3.io
operatorconditions.operators.coreos.com
volumesnapshotlocations.velero.io
dataprotectionapplications.oadp.openshift.io
operatorconfigs.csi.ceph.io
volumesnapshots.snapshot.storage.k8s.io
EOF
}

resolve_app_name_for_resource() {
  local resource_kind="$1"
  local resource_name="$2"
  local namespace="$3"

  local app_name=""

  app_name="$(oc get "$resource_kind" "$resource_name" -n "$namespace" -o jsonpath='{.metadata.labels.app}' 2>/dev/null || true)"
  if [[ -z "$app_name" ]]; then
    app_name="$(oc get "$resource_kind" "$resource_name" -n "$namespace" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/name}' 2>/dev/null || true)"
  fi
  if [[ -z "$app_name" ]]; then
    app_name="$(oc get "$resource_kind" "$resource_name" -n "$namespace" -o jsonpath='{.metadata.labels.name}' 2>/dev/null || true)"
  fi

  if [[ -z "$app_name" ]]; then
    app_name="__no_app__"
  fi

  printf '%s' "$(sanitize_name "$app_name")"
}

# Collect core resource manifests and persist them under the namespace/application layout.
collect_resource_kind_items() {
  local namespace="$1"
  local ns_dir="$2"
  local resource_kind="$3"

  local dir_name
  dir_name="$(resource_to_dir_name "$resource_kind")"

  log "Collecting resource kind: $resource_kind"
  mapfile -t items < <(oc get "$resource_kind" -n "$namespace" -o name 2>/dev/null || true)

  local total_items=${#items[@]}
  if (( total_items == 0 )); then
    log "No items found for resource kind: $resource_kind"
    return
  fi

  show_progress "Processing $resource_kind" 0 "$total_items"
  for index in "${!items[@]}"; do
    local item="${items[$index]}"
    local item_name="${item#*/}"
    local app_name
    local safe_item
    local item_dir
    local out_file

    app_name="$(resolve_app_name_for_resource "$resource_kind" "$item_name" "$namespace")"
    safe_item="$(sanitize_name "$item_name")"
    item_dir="$ns_dir/apps/$app_name/$dir_name"
    out_file="$item_dir/${safe_item}.yaml"

    mkdir -p "$item_dir"
    oc get "$item" -n "$namespace" -o yaml >"$out_file" 2>/dev/null || true

    show_progress "Processing $resource_kind" "$((index + 1))" "$total_items"
  done
  clear_progress_line
}

# Collect additional namespace-scoped resources from the curated list before app-level artifacts.
collect_additional_namespace_resources() {
  local namespace="$1"
  local ns_dir="$2"

  local resource_kind
  local resource_dir
  local safe_resource_kind

  local resource_kinds=()
  while IFS= read -r resource_kind; do
    [[ -n "$resource_kind" ]] || continue
    resource_kinds+=("$resource_kind")
  done < <(get_additional_resource_kinds)

  local total_kinds=${#resource_kinds[@]}
  log "Collecting additional namespace resources for namespace=$namespace"
  show_progress "Collecting namespace resources" 0 "$total_kinds"

  for index in "${!resource_kinds[@]}"; do
    resource_kind="${resource_kinds[$index]}"
    safe_resource_kind="$(sanitize_name "$resource_kind")"
    log "Collecting additional resource kind: $resource_kind"
    resource_dir="$ns_dir/resources/$safe_resource_kind"

    mapfile -t items < <(oc get "$resource_kind" -n "$namespace" -o name 2>/dev/null || true)

    for item in "${items[@]}"; do
      local item_name="${item#*/}"
      local safe_item="$(sanitize_name "$item_name")"
      local out_file="$resource_dir/${safe_item}.yaml"

      mkdir -p "$resource_dir"
      oc get "$item" -n "$namespace" -o yaml >"$out_file" 2>/dev/null || true
    done

    show_progress "Collecting namespace resources" "$((index + 1))" "$total_kinds"
  done
  clear_progress_line
}

# Collect pod logs and group them by application label after the namespace resources are gathered.
collect_pod_logs_grouped_by_app() {
  local namespace="$1"
  local ns_dir="$2"
  local tail_lines="$3"

  log "Collecting pod logs for namespace=$namespace"
  mapfile -t pods < <(oc get pods -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

  local total_pods=${#pods[@]}
  if (( total_pods == 0 )); then
    log "No pods found for namespace: $namespace"
    return
  fi

  show_progress "Collecting pod logs" 0 "$total_pods"
  for index in "${!pods[@]}"; do
    local pod="${pods[$index]}"
    [[ -n "$pod" ]] || continue

    local app_name
    local pods_logs_dir
    local pod_log

    app_name="$(resolve_app_name_for_resource "pod" "$pod" "$namespace")"
    pods_logs_dir="$ns_dir/apps/$app_name/pod-logs"
    pod_log="$pods_logs_dir/${pod}.log"

    mkdir -p "$pods_logs_dir"
    oc logs "$pod" -n "$namespace" --all-containers --tail="$tail_lines" >"$pod_log" 2>&1 || true

    show_progress "Collecting pod logs" "$((index + 1))" "$total_pods"
  done
  clear_progress_line
}

main() {
  local namespace=""
  local output_dir=""
  local tail_lines="300"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--namespace)
        namespace="${2:-}"
        shift 2
        ;;
      -o|--output-dir)
        output_dir="${2:-}"
        shift 2
        ;;
      --tail-lines)
        tail_lines="${2:-}"
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

  [[ -n "$namespace" ]] || fail "Specify the namespace with -n|--namespace"
  [[ "$tail_lines" =~ ^[0-9]+$ ]] || fail "--tail-lines must be numeric"

  command -v oc >/dev/null 2>&1 || fail "Command 'oc' not found"
  oc whoami >/dev/null 2>&1 || fail "No authenticated OpenShift session. Run: oc login"

  if [[ -z "$output_dir" ]]; then
    output_dir="./oc-health-artifacts-$(date '+%Y%m%d_%H%M%S')"
  fi

  local ns_dir="$output_dir/$namespace"
  mkdir -p "$ns_dir"

  log "Starting simplified collection for namespace=$namespace"
  log "Step 1/3: collecting namespace resources"
  collect_additional_namespace_resources "$namespace" "$ns_dir"

  log "Step 2/3: collecting core resource manifests"
  collect_resource_kind_items "$namespace" "$ns_dir" "deployment"
  collect_resource_kind_items "$namespace" "$ns_dir" "deploymentconfig"
  collect_resource_kind_items "$namespace" "$ns_dir" "statefulset"
  collect_resource_kind_items "$namespace" "$ns_dir" "configmap"
  collect_resource_kind_items "$namespace" "$ns_dir" "route"
  collect_resource_kind_items "$namespace" "$ns_dir" "service"
  collect_resource_kind_items "$namespace" "$ns_dir" "job"
  collect_resource_kind_items "$namespace" "$ns_dir" "replicaset"
  collect_resource_kind_items "$namespace" "$ns_dir" "hpa"

  log "Step 3/3: collecting application pod logs"
  collect_pod_logs_grouped_by_app "$namespace" "$ns_dir" "$tail_lines"

  log "Collection completed. Output in: $ns_dir/apps and $ns_dir/resources"
  finish_status_line
}

main "$@"
