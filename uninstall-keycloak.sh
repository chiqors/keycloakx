#!/bin/bash
set -euo pipefail # Exit on error, unset var, pipefail

# --- Configuration ---
# Colors for better output
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
NC="\033[0m" # No Color

# Default values - consider making these configurable via script arguments if needed
DEFAULT_NAMESPACE="keycloak"
DEFAULT_RELEASE_NAME="keycloak"

# Script parameters
NAMESPACE="$DEFAULT_NAMESPACE"
RELEASE_NAME="$DEFAULT_RELEASE_NAME"

# --- Helper Functions ---
log_info() { echo -e "${BLUE}INFO:${NC} $1"; }
log_step() { echo -e "\n${BLUE}Step $1:${NC} $2"; }
log_success() { echo -e "${GREEN}SUCCESS:${NC} $1"; }
log_warning() { echo -e "${YELLOW}WARNING:${NC} $1"; }
log_error() { echo -e "${RED}ERROR:${NC} $1"; exit 1; } # Exit on error

command_exists() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log_error "$1 is not installed or not in PATH. Please install it."
  fi
}

confirm_action() {
  read -r -p "$(echo -e "${YELLOW}CONFIRM:${NC} $1 (yes/N): ")" response
  case "$response" in
    [yY][eE][sS])
      return 0 # Yes
      ;;
    *)
      return 1 # No or anything else
      ;;
  esac
}

# --- Main Logic ---

# Argument parsing (simple example if you want to make NS/Release configurable)
# while [[ $# -gt 0 ]]; do
#   key="$1"
#   case $key in
#     -n|--namespace) NAMESPACE="$2"; shift 2 ;;
#     -r|--release) RELEASE_NAME="$2"; shift 2 ;;
#     *) log_error "Unknown option: $1"; echo "Usage: $0 [--namespace <ns>] [--release <name>]"; exit 1;;
#   esac
# done


log_info "Starting Keycloak uninstallation process for release '$RELEASE_NAME' in namespace '$NAMESPACE'..."

# Check for required tools
command_exists "kubectl"
command_exists "helm"

# Check if connected to a Kubernetes cluster
if ! kubectl cluster-info &>/dev/null; then
  log_error "Not connected to a Kubernetes cluster. Please check your kubeconfig."
fi

# Confirmation before proceeding
if ! confirm_action "Are you sure you want to uninstall Helm release '$RELEASE_NAME' and delete associated resources in namespace '$NAMESPACE'? This includes secrets, configmaps, and potentially the namespace itself."; then
  log_info "Uninstallation cancelled by user."
  exit 0
fi


# Step 1: Uninstall the Helm Release
log_step 1 "Uninstalling Helm release '$RELEASE_NAME' in namespace '$NAMESPACE'..."
if helm uninstall "$RELEASE_NAME" --namespace "$NAMESPACE"; then
  log_success "Helm release '$RELEASE_NAME' uninstalled successfully."
else
  # Helm uninstall returns 0 if the release is not found, so this warning might not always trigger on non-existence.
  # However, it will catch actual uninstall failures.
  log_warning "Helm release '$RELEASE_NAME' might not exist or failed to uninstall. Continuing with cleanup."
fi

# Step 2: Delete Kubernetes Secrets
# Add any other secrets specific to your Keycloak deployment if they are not managed by Helm
log_step 2 "Deleting Kubernetes secrets..."
kubectl delete secret keycloak-db-credentials -n "$NAMESPACE" --ignore-not-found=true
kubectl delete secret keycloak-client-secrets -n "$NAMESPACE" --ignore-not-found=true
# Example: kubectl delete secret cloudsql-instance-credentials -n "$NAMESPACE" --ignore-not-found=true # If you created this for proxy
log_success "Secrets deleted (if they existed)."

# Step 3: Delete Kubernetes ConfigMaps
# Add any other configmaps specific to your Keycloak deployment
log_step 3 "Deleting Kubernetes ConfigMaps..."
kubectl delete configmap custom-realm-config -n "$NAMESPACE" --ignore-not-found=true
kubectl delete configmap keycloak-client-ids -n "$NAMESPACE" --ignore-not-found=true # Added this based on your files
log_success "ConfigMaps deleted (if they existed)."

# Step 4: Delete the Managed Certificate (if it exists)
# The certificate name might be conventional (e.g., $RELEASE_NAME-certificate)
log_step 4 "Deleting Managed Certificate (if it exists)..."
kubectl delete managedcertificate "$RELEASE_NAME-certificate" -n "$NAMESPACE" --ignore-not-found=true # Assuming convention
kubectl delete managedcertificate keycloak-certificate -n "$NAMESPACE" --ignore-not-found=true # Original name
log_success "Managed Certificate(s) deleted (if they existed)."

# Step 5: Delete PersistentVolumeClaims (optional, use with caution)
# PVCs are often not deleted by Helm to prevent data loss.
# Only uncomment and use if you are sure you want to delete the persistent data.
# log_step 5 "Optionally deleting PersistentVolumeClaims..."
# if confirm_action "Do you want to delete PersistentVolumeClaims associated with '$RELEASE_NAME' in namespace '$NAMESPACE'? This will delete Keycloak's persistent data if it used PVCs not managed by Cloud SQL."; then
#   # List PVCs, e.g., kubectl get pvc -n "$NAMESPACE" -l app.kubernetes.io/instance="$RELEASE_NAME"
#   # Be very specific with labels to avoid deleting wrong PVCs
#   # kubectl delete pvc -n "$NAMESPACE" -l app.kubernetes.io/instance="$RELEASE_NAME" --ignore-not-found=true
#   log_success "PersistentVolumeClaims deletion initiated (if any matched)."
# else
#   log_info "Skipping PVC deletion."
# fi


# Step 6: Delete the Namespace (use with extreme caution)
log_step 6 "Optionally deleting namespace '$NAMESPACE'..."
if confirm_action "Do you want to delete the ENTIRE namespace '$NAMESPACE'? This will delete ALL resources within it."; then
  log_info "Initiating deletion of namespace '$NAMESPACE'..."
  # Give resources a moment to terminate before deleting namespace, especially if --wait=false
  log_info "Waiting a few seconds before namespace deletion..."
  sleep 10
  if kubectl delete namespace "$NAMESPACE" --ignore-not-found=true --wait=true; then # Changed to wait=true for confirmation
    log_success "Namespace '$NAMESPACE' deleted successfully."
  else
    log_warning "Namespace '$NAMESPACE' deletion failed or it was already gone. It might be stuck terminating; check 'kubectl get namespace $NAMESPACE'."
  fi
else
  log_info "Skipping namespace deletion."
fi

echo -e "\n${GREEN}--- Keycloak uninstallation process completed ---${NC}"
log_warning "Remember to manually delete your Cloud SQL instance and static IP address in GCP if you no longer need them."
log_warning "If you skipped namespace deletion, other resources might still exist in '$NAMESPACE'."
