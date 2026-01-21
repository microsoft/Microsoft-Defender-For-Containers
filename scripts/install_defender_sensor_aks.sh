#!/bin/bash
# call like install_defender_sensor_aks.sh --id <CLUSTER_AZURE_RESOURCE_ID> --release_train <RELEASE_TRAIN> --version <VERSION> [--antimalware]
# where <VERSION> is semver or 'latest'
# where <RELEASE_TRAIN> is 'stable', 'public', or 'private'
# including --antimalware will enable antimalware scanning
export MSYS_NO_PATHCONV=1

LOG_FILE=$(mktemp -t 'defender-sensor-install-XXXXXXXX.log')
shopt -s nocasematch

usage() {
      echo " "
      echo "install_defender_sensor_aks - deploy Microsoft Defender for Containers to AKS clusters"
      echo " "
      echo "Usage"
      echo "install_defender_sensor_aks.sh --id <CLUSTER_AZURE_RESOURCE_ID> --release_train <RELEASE_TRAIN> --version <VERSION> [--antimalware]"
      echo " "
      echo "CLUSTER_AZURE_RESOURCE_ID   Expected format: /subscriptions/<subscription-id>/resourceGroups/<resource-group-name>/providers/Microsoft.ContainerService/managedClusters/<cluster-name>"
      echo "RELEASE_TRAIN               Expected format: 'stable', 'public' (Public Preview), or 'private' (Private Preview)"
      echo "VERSION                     Expected format: 'latest' or semver"
      exit 1
}

if [[ $# -eq 0 ]]; then
    usage
fi

ANTIMALWARE_ENABLED=false
RELEASE_TRAIN=stable

while test $# -gt 0; do
  case "$1" in
    --id)
      shift
      if test $# -gt 0; then
        AZURE_RESOURCE_ID=$1
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
if [[ ! $AZURE_RESOURCE_ID =~ ^/subscriptions/[0-9a-fA-F-]+/resourcegroups/[a-zA-Z0-9_.-]+/providers/Microsoft\.ContainerService/managedClusters/[a-zA-Z0-9_-]+$ ]]; then
    echo "Error: Invalid resource ID format."
    echo "Expected format: /subscriptions/<subscription-id>/resourceGroups/<resource-group-name>/providers/Microsoft.ContainerService/managedClusters/<cluster-name>"
    exit 1
fi

CLUSTER_NAME=$(echo $AZURE_RESOURCE_ID | awk -F'/' '{print $9}')
if [ -z "$CLUSTER_NAME" ]; then
    echo "Error: CLUSTER_NAME could not be determined from resource ID."
    exit 1
fi
CLUSTER_RG=$(echo $AZURE_RESOURCE_ID | awk -F'/' '{print $5}')
if [ -z "$CLUSTER_RG" ]; then
    echo "Error: CLUSTER_RG could not be determined from resource ID."
    exit 1
fi
SUBSCRIPTION_ID=$(echo $AZURE_RESOURCE_ID | awk -F'/' '{print $3}')
if [ -z "$SUBSCRIPTION_ID" ]; then
    echo "Error: SUBSCRIPTION_ID could not be determined from resource ID."
    exit 1
fi

if [[ ! "$RELEASE_TRAIN" =~ ^(stable|public|private)$ ]]; then
    echo "Error: Invalid release train specified. Must be 'stable', 'public', or 'private'."
    exit 1
fi

if [ "$RELEASE_TRAIN" == "public" ]; then
    HELM_REPO="oci://mcr.microsoft.com/azuredefender/microsoft-defender-for-containers"
elif [ "$RELEASE_TRAIN" == "stable" ]; then
    HELM_REPO="oci://mcr.microsoft.com/azuredefender/microsoft-defender-for-containers"
else
    HELM_REPO="oci://mcr.microsoft.com/azuredefender-preview/microsoft-defender-for-containers"
fi
if [ -z "$VERSION" ]; then
    echo "Error: No version specified."
    usage
fi

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

echo "Starting Defender for Containers sensor installation script"
echo "Log file: $LOG_FILE"

if [ "$RELEASE_TRAIN" == "public" ]; then
    log "Using public preview release train"
elif [ "$RELEASE_TRAIN" == "stable" ]; then
    log "Using stable release train"
else
    log "Using private preview release train"
fi

log "Setting active subscription to $SUBSCRIPTION_ID"
run "az account set --subscription $SUBSCRIPTION_ID"
log "Setting kube context to cluster $CLUSTER_NAME in resource group $CLUSTER_RG"
run "az aks get-credentials --resource-group $CLUSTER_RG --name $CLUSTER_NAME --overwrite-existing"

# Check if RG/subscription level policies exist that would trigger autoprovisioning
log "Checking for conflicting policies in resource group $CLUSTER_RG"
POLICY_DEFINITION_ID='/providers/Microsoft.Authorization/policyDefinitions/64def556-fbad-4622-930e-72d1d5589bf5'
RG_POLICY_NAME=`az policy assignment list -g ${CLUSTER_RG} -o json --query "[?policyDefinitionId == '${POLICY_DEFINITION_ID}'].name | [0]"`
if [ -n "$RG_POLICY_NAME" ]; then
    log "Conflicting policy assignment $RG_POLICY_NAME found in resource group $CLUSTER_RG, stopping."
    exit 1
fi

log "Checking for conflicting policies in subscription $SUBSCRIPTION_ID"
SUBSCRIPTION_POLICY_NAME=`az policy assignment list -o json --query "[?policyDefinitionId == '${POLICY_DEFINITION_ID}'].name | [0]"`
if [ -n "$RG_POLICY_NAME" ]; then
    log "Conflicting policy assignment $SUBSCRIPTION_POLICY_NAME found in subscription $SUBSCRIPTION_ID, stopping."
    exit 1
fi

log "Fetching cluster region"
CLUSTER_REGION=$(az aks show --resource-group $CLUSTER_RG --name $CLUSTER_NAME --query location -o tsv)
log "Applying tag to cluster"
run "az tag update --resource-id ${AZURE_RESOURCE_ID} --operation merge --tags ms_defender_e2e_discovery_exclude=true"
log "Disabling Defender for Containers on cluster $CLUSTER_NAME in resource group $CLUSTER_RG"
run "az aks update --disable-defender --resource-group $CLUSTER_RG --name $CLUSTER_NAME"
run "kubectl delete crd/policies.defender.microsoft.com || true"
run "kubectl delete crd/runtimepolicies.defender.microsoft.com || true"
run "kubectl delete crd/securityartifactpolicies.defender.microsoft.com || true"

run "kubectl delete ClusterRole defender-admission-controller-cluster-role || true"
run "kubectl delete ClusterRole defender-admission-controller-resource-cluster-role || true"
run "kubectl delete ClusterRoleBinding defender-admission-controller-cluster-role-binding || true"
run "kubectl delete ClusterRoleBinding defender-admission-controller-cluster-resource-role-binding || true"

# create log analytics workspace (if the default one does not exist)
log "Checking if default log analytics workspace exists"
DEFAULT_WORKSPACE_NAME="Default-${SUBSCRIPTION_ID}-${CLUSTER_REGION}"
DEFAULT_WORKSPACE_NAME=$(echo $DEFAULT_WORKSPACE_NAME | cut -c 1-63)
WS_EXISTS=$(az monitor log-analytics workspace list --resource-group $CLUSTER_RG --query "[?name=='$DEFAULT_WORKSPACE_NAME']" -o tsv)
if [ -z "$WS_EXISTS" ]; then
    log "Default log analytics workspace does not exist, creating it"
    run "az monitor log-analytics workspace create --resource-group $CLUSTER_RG --workspace-name $DEFAULT_WORKSPACE_NAME"
fi

log "Fetching workspace GUID and primary key"
WS_GUID=$(az monitor log-analytics workspace show --resource-group $CLUSTER_RG --workspace-name $DEFAULT_WORKSPACE_NAME --query customerId -o tsv)
WS_PRIMARY_KEY=$(az monitor log-analytics workspace get-shared-keys --resource-group $CLUSTER_RG --workspace-name $DEFAULT_WORKSPACE_NAME --query primarySharedKey -o tsv)
# install the sensor helm chart

if [ $VERSION == "latest" ]; then
    log "Installing latest version"    
    if [ "$RELEASE_TRAIN" == "public" ]; then
        INSTALL_VERSION="--devel"
    fi
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
    --set microsoft-defender-for-containers-sensor.omsagent.secret.wsid=$WS_GUID \
    --set microsoft-defender-for-containers-sensor.omsagent.secret.key=$WS_PRIMARY_KEY \
    --set microsoft-defender-for-containers-sensor.Azure.Cluster.kubernetesDistro='generic' \
    --set microsoft-defender-for-containers-sensor.Azure.Cluster.Region=$CLUSTER_REGION \
    --set microsoft-defender-for-containers-sensor.Azure.Cluster.ResourceId=$AZURE_RESOURCE_ID \
    --set microsoft-defender-for-containers-sensor.Azure.Cluster.Distribution='aks' \
    --set microsoft-defender-for-containers-sensor.Azure.Cluster.Infrastructure='Azure' \
    --set microsoft-defender-for-containers-sensor.collectors.antimalwareCollector.enable='$ANTIMALWARE_ENABLED' \
    --set defender-admission-controller.global.azure.cluster.region=$CLUSTER_REGION \
    --set defender-admission-controller.global.azure.cluster.resourceId=$AZURE_RESOURCE_ID \
    --set defender-admission-controller.global.azure.cluster.infrastructure='Azure' \
    --wait \
    $ATOMIC_FLAG"

log "Sensor installation completed successfully."
