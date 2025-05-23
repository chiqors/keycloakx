#!/bin/bash

# Colors for better output
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
NC="\033[0m" # No Color

# Default values
NAMESPACE="keycloak"
RELEASE_NAME="keycloak"

# Function to check if a command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Check for required tools
for cmd in kubectl helm; do
  if ! command_exists "$cmd"; then
    echo -e "${RED}Error:${NC} $cmd is not installed or not in PATH"
    exit 1
  fi
done

# Check if connected to a Kubernetes cluster
if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}Error:${NC} Not connected to a Kubernetes cluster"
  exit 1
fi

echo -e "${BLUE}Starting KeycloakX uninstallation...${NC}"

# Step 1: Uninstall the Helm Release
echo -e "\n${BLUE}Step 1:${NC} Uninstalling Helm release '$RELEASE_NAME' in namespace '$NAMESPACE'..."
helm uninstall "$RELEASE_NAME" --namespace "$NAMESPACE"
if [[ $? -eq 0 ]]; then
  echo -e "${GREEN}Helm release '$RELEASE_NAME' uninstalled successfully.${NC}"
else
  echo -e "${YELLOW}Warning:${NC} Helm release '$RELEASE_NAME' might not exist or failed to uninstall. Continuing with cleanup."
fi

# Step 2: Delete Kubernetes Secrets
echo -e "\n${BLUE}Step 2:${NC} Deleting Kubernetes secrets..."
kubectl delete secret keycloak-db-credentials -n "$NAMESPACE" --ignore-not-found=true
kubectl delete secret keycloak-client-secrets -n "$NAMESPACE" --ignore-not-found=true
echo -e "${GREEN}Secrets deleted (if they existed).${NC}"

# Step 3: Delete Kubernetes ConfigMaps
echo -e "\n${BLUE}Step 3:${NC} Deleting Kubernetes ConfigMaps..."
kubectl delete configmap custom-realm-config -n "$NAMESPACE" --ignore-not-found=true
echo -e "${GREEN}ConfigMaps deleted (if they existed).${NC}"

# Step 4: Delete the Managed Certificate (if it exists)
echo -e "\n${BLUE}Step 4:${NC} Deleting Managed Certificate (if it exists)..."
kubectl delete managedcertificate keycloak-certificate -n "$NAMESPACE" --ignore-not-found=true
echo -e "${GREEN}Managed Certificate deleted (if it existed).${NC}"

# Step 5: Delete the Namespace
echo -e "\n${BLUE}Step 5:${NC} Deleting namespace '$NAMESPACE'..."
# Give resources a moment to terminate before deleting namespace
sleep 5
kubectl delete namespace "$NAMESPACE" --ignore-not-found=true --wait=false
echo -e "${GREEN}Namespace '$NAMESPACE' deletion initiated (if it existed).${NC}"
echo -e "${YELLOW}Note:${NC} Namespace deletion can take some time. You can check its status with 'kubectl get namespace $NAMESPACE'."


echo -e "\n${GREEN}KeycloakX uninstallation process completed.${NC}"
echo -e "${YELLOW}Remember to manually delete your Cloud SQL instance if you no longer need it.${NC}"