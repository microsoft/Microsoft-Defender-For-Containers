# call like delete_conflicting_policies.sh <CLUSTER_AZURE_RESOURCE_ID>
set -e
shopt -s nocasematch

AZURE_RESOURCE_ID=$1

# verify that resource id has correct format
if [[ ! $AZURE_RESOURCE_ID =~ ^/subscriptions/[0-9a-fA-F-]+/resourceGroups/[a-zA-Z0-9_.-]+/providers/Microsoft\.ContainerService/managedClusters/[a-zA-Z0-9_-]+$ ]]; then
    echo "Error: Invalid resource ID format."
    echo "Expected format: /subscriptions/<subscription-id>/resourceGroups/<resource-group-name>/providers/Microsoft.ContainerService/managedClusters/<cluster-name>"
    exit 1
fi

CLUSTER_NAME=$(echo $1 | awk -F'/' '{print $9}')
if [ -z "$CLUSTER_NAME" ]; then
    echo "Error: CLUSTER_NAME could not be determined from resource ID."
    exit 1
fi
CLUSTER_RG=$(echo $1 | awk -F'/' '{print $5}')
if [ -z "$CLUSTER_RG" ]; then
    echo "Error: CLUSTER_RG could not be determined from resource ID."
    exit 1
fi
SUBSCRIPTION_ID=$(echo $1 | awk -F'/' '{print $3}')
if [ -z "$SUBSCRIPTION_ID" ]; then
    echo "Error: SUBSCRIPTION_ID could not be determined from resource ID."
    exit 1
fi

echo "Checking for conflicting policies in resource group $CLUSTER_RG"
POLICY_DEFINITION_ID='/providers/Microsoft.Authorization/policyDefinitions/64def556-fbad-4622-930e-72d1d5589bf5'
RG_POLICY_NAMES=`az policy assignment list -g ${CLUSTER_RG} -o json --query "[?policyDefinitionId == '${POLICY_DEFINITION_ID}'].name"`
RG_POLICY_NAMES=$(echo $RG_POLICY_NAMES | tr -d '[]')
for RG_POLICY_NAME in $RG_POLICY_NAMES; do
    RG_POLICY_NAME=$(echo $RG_POLICY_NAME | tr -d '"')
    if [ -n "$RG_POLICY_NAME" ]; then
        echo "Conflicting policy assignment $RG_POLICY_NAME found in resource group $CLUSTER_RG"
        az policy assignment delete --name $RG_POLICY_NAME --resource-group $CLUSTER_RG
        echo "Conflicting policy assignment $RG_POLICY_NAME deleted."
    fi
done

echo "Checking for conflicting policies in subscription $SUBSCRIPTION_ID"
SUBSCRIPTION_POLICY_NAMES=`az policy assignment list -o json --query "[?policyDefinitionId == '${POLICY_DEFINITION_ID}'].name"`
SUBSCRIPTION_POLICY_NAMES=$(echo $SUBSCRIPTION_POLICY_NAMES | tr -d '[]')
for SUBSCRIPTION_POLICY_NAME in $SUBSCRIPTION_POLICY_NAMES; do
    SUBSCRIPTION_POLICY_NAME=$(echo $SUBSCRIPTION_POLICY_NAME | tr -d '"')
    if [ -n "$SUBSCRIPTION_POLICY_NAME" ]; then
        echo "Conflicting policy assignment $SUBSCRIPTION_POLICY_NAME found in subscription $SUBSCRIPTION_ID"
        az policy assignment delete --name $SUBSCRIPTION_POLICY_NAME
        echo "Conflicting policy assignment $SUBSCRIPTION_POLICY_NAME deleted."
    fi
done
