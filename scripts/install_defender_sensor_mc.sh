#!/bin/bash
# call like install_defender_sensor_mc.sh --id <SECURITY_CONNECTOR_AZURE_RESOURCE_ID> --release_train <RELEASE_TRAIN> --version <VERSION> --distribution <DISTRIBUTION> [--antimalware]
# where <VERSION> is semver or 'latest'
# where <DISTRIBUTION> is 'eks', 'gke', or 'eksautomode' (eksautomode uses eks distribution with additional security options)
# including --antimalware will enable antimalware scanning
export MSYS_NO_PATHCONV=1

echo "Starting Defender for Containers sensor installation script"
LOG_FILE=$(mktemp -t 'defender-sensor-install-XXXXXXXX.log')
echo "Log file: $LOG_FILE"
log() {
    echo "$*"
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*" >> "$LOG_FILE"
}
run() {
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Executing: $*" >> "$LOG_FILE"
    eval "$@" >> "$LOG_FILE"
    if [ $? -ne 0 ]; then
        echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Command failed: $*" >> "$LOG_FILE"
        echo "Error: Command failed. Check log file $LOG_FILE for details."
        exit 1
    fi
}

shopt -s nocasematch


usage() {
      echo " "
      echo "install_defender_sensor_mc - deploy Microsoft Defender for Containers to EKS and GKE"
      echo " "
      echo "Usage"
      echo "install_defender_sensor_mc.sh --id <SECURITY_CONNECTOR_AZURE_RESOURCE_ID> --release_train <RELEASE_TRAIN> --version <VERSION> --distribution <DISTRIBUTION> [--antimalware]"
      echo " "
      echo "SECURITY_CONNECTOR_AZURE_RESOURCE_ID   Expected format: /subscriptions/<subscription-id>/resource[gG]roups/<resource-group-name>/providers/Microsoft.Security/securityConnectors/<connector-name>"
      echo "RELEASE_TRAIN                          Expected format: 'public' (for public preview) or 'private' (for private preview)"
      echo "VERSION                                Expected format: 'latest' or semver"
      echo "DISTRIBUTION                           Expected format: 'eks', 'gke', or 'eksautomode'"
      echo " "
      exit 1
}

if [[ $# -eq 0 ]]; then
    usage
fi

ANTIMALWARE_ENABLED=false

while test $# -gt 0; do
  case "$1" in
    --id)
      shift
      if test $# -gt 0; then
        CONNECTOR_AZURE_RESOURCE_ID=$1
      else
        echo "missing value for flag --id"
        exit 1
      fi
      shift
      ;;
    --version)
      shift
      if test $# -gt 0; then
        VERSION=$1
      else
        echo "missing value for flag --version"
        exit 1
      fi
      shift
      ;;
    --release_train)
      shift
      if test $# -gt 0; then
        RELEASE_TRAIN=$1
      else
        echo "missing value for flag --release_train"
        exit 1
      fi
      shift
      ;;
    --distribution)
      shift
      if test $# -gt 0; then
        DISTRIBUTION=$1
      else
        echo "missing value for flag --distribution"
        exit 1
      fi
      shift
      ;;
    --antimalware)
      shift
      ANTIMALWARE_ENABLED=true
      ;;
    *)
      echo "Unrecognized flag ${1}"
      exit 1
      ;;
  esac
done


# verify that resource id has correct format
if [[ ! $CONNECTOR_AZURE_RESOURCE_ID =~ ^/subscriptions/[0-9a-fA-F-]+/resource[gG]roups/[a-zA-Z0-9_.-]+/providers/Microsoft\.Security/securityConnectors/[a-zA-Z0-9_-]+$ ]]; then
    log "Error in first argument: Invalid resource ID format."
    log "Expected format: /subscriptions/<subscription-id>/resource[gG]roups/<resource-group-name>/providers/Microsoft.Security/securityConnectors/<connector-name>"
    exit 1
fi

if [ -z "$RELEASE_TRAIN" ]; then
    log "Error: No release train specified."
    usage
    exit 1
fi
if [[ ! "$RELEASE_TRAIN" =~ ^(public|private)$ ]]; then
    log "Error: Invalid release train specified. Must be 'public' or 'private'."
    exit 1
fi

if [ "$RELEASE_TRAIN" == "public" ]; then
    log "Using public preview release train"
    HELM_REPO="oci://mcr.microsoft.com/azuredefender/microsoft-defender-for-containers"
else
    log "Using private preview release train"
    HELM_REPO="oci://mcr.microsoft.com/azuredefender-preview/microsoft-defender-for-containers"
fi

if [ -z "$VERSION" ]; then
    log "Error: No version specified."
    usage
fi

if [ -z "$DISTRIBUTION" ]; then
    log "Error: No distribution specified."
    usage
fi
if [[ ! "$DISTRIBUTION" =~ ^(eks|gke|eksautomode)$ ]]; then
    log "Error: Invalid distribution specified. Must be 'eks', 'gke', or 'eksautomode'."
    exit 1
fi

# Handle eksautomode distribution
HELM_EXTRA_PARAMS=""
if [ "$DISTRIBUTION" == "eksautomode" ]; then
    DISTRIBUTION="eks"
    HELM_EXTRA_PARAMS="--set collectors.seLinuxOptions.type=super_t"
fi

if [ "$DISTRIBUTION" == "gke" ]; then
    INFRASTRUCTURE="gcp"
    GATING_INFRASTRUCTURE="GCP"
else
    INFRASTRUCTURE="aws"
    GATING_INFRASTRUCTURE="AWS"
fi

CONNECTOR_RG=$(echo $CONNECTOR_AZURE_RESOURCE_ID | awk -F'/' '{print $5}')
if [ -z "$CONNECTOR_RG" ]; then
    log "Error: CONNECTOR_RG could not be determined from resource ID."
    exit 1
fi
CONNECTOR_SUBSCRIPTION_ID=$(echo $CONNECTOR_AZURE_RESOURCE_ID | awk -F'/' '{print $3}')
if [ -z "$CONNECTOR_SUBSCRIPTION_ID" ]; then
    log "Error: SUBSCRIPTION_ID could not be determined from resource ID."
    exit 1
fi

log "Setting active subscription to ${CONNECTOR_SUBSCRIPTION_ID}"
run "az account set --subscription ${CONNECTOR_SUBSCRIPTION_ID}"

log "Fetching security connector region"
CLUSTER_REGION=$(az resource show --ids $CONNECTOR_AZURE_RESOURCE_ID --query location -o tsv)
if [ -z "$CLUSTER_REGION" ]; then
    log "Error: Could not determine security connector region."
    exit 1
fi


# Test if cluster has an arc based deployment, and if so remove it
HAS_CLUSTER_CONFIG=$(kubectl get configmap/azure-clusterconfig -n azure-arc --ignore-not-found)
if [ -n "$HAS_CLUSTER_CONFIG" ]; then
    ARC_CLUSTER_NAME=$(kubectl get configmap/azure-clusterconfig -n azure-arc --ignore-not-found -o jsonpath='{.data.AZURE_RESOURCE_NAME}')
    ARC_CLUSTER_RG=$(kubectl get configmap/azure-clusterconfig -n azure-arc --ignore-not-found -o jsonpath='{.data.AZURE_RESOURCE_GROUP}')
    ARC_SUBSCRIPTION_ID=$(kubectl get configmap/azure-clusterconfig -n azure-arc --ignore-not-found -o jsonpath='{.data.AZURE_SUBSCRIPTION_ID}')

    if [ -z "$ARC_CLUSTER_NAME" ]; then
        log "Error: CLUSTER NAME could not be determined from configmap azure-clusterconfig."
    fi
    if [ -z "$ARC_CLUSTER_RG" ]; then
        log "Error: CLUSTER RESOURCE GROUP could not be determined from configmap azure-clusterconfig."
    fi
    if [ -z "$ARC_SUBSCRIPTION_ID" ]; then
        log "Error: ARC RESOURCE SUBSCRIPTION ID could not be determined from configmap azure-clusterconfig."
    fi

    if [[ -n "$ARC_CLUSTER_NAME" && -n "$ARC_CLUSTER_RG" && -n "$ARC_SUBSCRIPTION_ID" ]]; then
        log "Setting active subscription to ${ARC_SUBSCRIPTION_ID} to remove arc-based deployment"
        run "az account set --subscription ${ARC_SUBSCRIPTION_ID}"
        log "Removing arc-based deployment on cluster ${ARC_CLUSTER_NAME} in resource group ${ARC_CLUSTER_RG}"
        run "az k8s-extension delete --cluster-type connectedClusters --cluster-name ${ARC_CLUSTER_NAME} --resource-group ${ARC_CLUSTER_RG} --name microsoft.azuredefender.kubernetes --yes"
        log "Arc-based deployment removed successfully."
        log "Setting active subscription back to ${CONNECTOR_SUBSCRIPTION_ID}"
        run "az account set --subscription ${CONNECTOR_SUBSCRIPTION_ID}"
    fi
fi

# create log analytics workspace (if the default one does not exist)
log "Checking if default log analytics workspace exists"
DEFAULT_WORKSPACE_NAME="Default-${CONNECTOR_SUBSCRIPTION_ID}"
# cut default workspace name to 63 characters to avoid issues with workspace name length
DEFAULT_WORKSPACE_NAME=$(echo $DEFAULT_WORKSPACE_NAME | cut -c 1-63)
run "WS_EXISTS=$(az monitor log-analytics workspace list --resource-group ${CONNECTOR_RG} --query \"[?name=='$DEFAULT_WORKSPACE_NAME']\" -o tsv)"
if [ -z "$WS_EXISTS" ]; then
    log "Default log analytics workspace does not exist, creating it"
    run "az monitor log-analytics workspace create --resource-group ${CONNECTOR_RG} --workspace-name ${DEFAULT_WORKSPACE_NAME}"
fi

log "Fetching workspace GUID and primary key"
run "WS_GUID=$(az monitor log-analytics workspace show --resource-group ${CONNECTOR_RG} --workspace-name ${DEFAULT_WORKSPACE_NAME} --query customerId -o tsv)"
run "WS_PRIMARY_KEY=$(az monitor log-analytics workspace get-shared-keys --resource-group ${CONNECTOR_RG} --workspace-name ${DEFAULT_WORKSPACE_NAME} --query primarySharedKey -o tsv)"
log "Workspace GUID: $WS_GUID"
log "Workspace Primary Key: $WS_PRIMARY_KEY"
# install the sensor helm chart


if [ $VERSION == "latest" ]; then
    log "Installing latest version"
    INSTALL_VERSION="--devel"
else
    log "Installing version ${VERSION}"
    INSTALL_VERSION="--version ${VERSION}"
fi

HELM_VERSION_RAW="$(helm version --short 2>/dev/null || true)"
HELM_MAJOR="$(echo "$HELM_VERSION_RAW" | sed -E 's/^v([0-9]+).*/\1/')"

if [ "$HELM_MAJOR" -ge 4 ]; then
  ATOMIC_FLAG="--rollback-on-failure"
else
  ATOMIC_FLAG="--atomic"
fi

run "helm install microsoft-defender-for-containers \
    ${HELM_REPO} \
    ${INSTALL_VERSION} \
    --namespace mdc \
    --create-namespace \
    --set microsoft-defender-for-containers-sensor.omsagent.secret.wsid=${WS_GUID} \
    --set microsoft-defender-for-containers-sensor.omsagent.secret.key=${WS_PRIMARY_KEY} \
    --set microsoft-defender-for-containers-sensor.Azure.Cluster.kubernetesDistro='generic' \
    --set microsoft-defender-for-containers-sensor.Azure.SecurityConnectorResourceId=${CONNECTOR_AZURE_RESOURCE_ID} \
    --set microsoft-defender-for-containers-sensor.Azure.Cluster.Distribution=${DISTRIBUTION} \
    --set microsoft-defender-for-containers-sensor.Azure.Cluster.Infrastructure='${INFRASTRUCTURE}' \
    --set microsoft-defender-for-containers-sensor.Azure.Cluster.Region='${CLUSTER_REGION}' \
    --set microsoft-defender-for-containers-sensor.collectors.antimalwareCollector.enable='$ANTIMALWARE_ENABLED' \
    --set defender-admission-controller.global.azure.cluster.infrastructure='${GATING_INFRASTRUCTURE}' \
    --set defender-admission-controller.global.azure.cluster.resourceId=$CONNECTOR_AZURE_RESOURCE_ID \
    ${HELM_EXTRA_PARAMS} \
    --wait \
    $ATOMIC_FLAG"

log "Sensor installation completed successfully."
