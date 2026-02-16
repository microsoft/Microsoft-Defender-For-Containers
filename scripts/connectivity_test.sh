#!/bin/bash
set -e

# Input handling: normalize to lowercase for easier matching
CLOUD_INPUT=$(echo "$1" | tr '[:upper:]' '[:lower:]')

# Resolve the Suffix based on the Cloud Name
case "$CLOUD_INPUT" in
  fairfax)
    CLOUD_NAME="Fairfax"
    SUFFIX="azure.us"
    ;;
  usnat)
    CLOUD_NAME="USNat"
    SUFFIX="eaglex.ic.gov"
    ;;
  ussec)
    CLOUD_NAME="USSec"
    SUFFIX="microsoft.scloud"
    ;;
  *)
    CLOUD_NAME="Public"
    SUFFIX="microsoft.com"
    ;;
esac

JOB_NAME="curl-connectivity-$CLOUD_INPUT-$(date +%s)"
NAMESPACE="default"

echo "----------------------------------------------------"
echo "Target Cloud: $CLOUD_NAME"
echo "Endpoint:     https://api.cloud.defender.$SUFFIX/api/connectivity/v1/"
echo "----------------------------------------------------"

# Create the Job manifest
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB_NAME
  namespace: $NAMESPACE
spec:
  template:
    spec:
      containers:
      - name: curl
        image: curlimages/curl
        command: [ "sh", "-c" ]
        args:
          - |
            STATUS=\$(curl -s -o /dev/null -w "%{http_code}" https://api.cloud.defender.${SUFFIX}/api/connectivity/v1/);
            if echo "\$STATUS" | grep -q "^20"; then
              echo -e "\033[0;32mConnectivity to ${CLOUD_NAME} works (\$STATUS)\033[0m";
            else
              echo -e "\033[0;31mConnectivity to ${CLOUD_NAME} failed (\$STATUS)\033[0m";
              exit 1;
            fi
      restartPolicy: Never
  backoffLimit: 0
EOF

# Wait for Job to complete
echo "Waiting for job to complete..."
kubectl wait --for=condition=complete --timeout=30s job/$JOB_NAME -n $NAMESPACE || {
  echo -e "\033[0;31mJob failed, timed out, or endpoint unreachable.\033[0m"
}

# Print logs
echo "--- Job Logs ---"
kubectl logs job/$JOB_NAME -n $NAMESPACE

# Clean up
echo "Cleaning up job..."
kubectl delete job $JOB_NAME -n $NAMESPACE
