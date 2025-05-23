#!/bin/bash
set -euo pipefail # Exit on error, unset var, pipefail

# --- Configuration ---
NAMESPACE="keycloak" # Define if not always 'keycloak'
# Helm release name is often used for Ingress name by charts
# If your Ingress name is different, adjust this.
INGRESS_NAME="keycloak" # Default release name, adjust if your ingress is named differently
CERT_NAME="keycloak-certificate" # Default certificate name, adjust if different
MANAGED_CERT_YAML_PATH="k8s/networking.gke.io/ManagedCertificate/keycloak-certificate.yaml"
DOMAIN_PLACEHOLDER="keycloak.example.com" # Placeholder in keycloak-certificate.yaml

# Colors for output
BLUE="\033[0;34m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
NC="\033[0m"

log_info() { echo -e "${BLUE}INFO:${NC} $1"; }
log_success() { echo -e "${GREEN}SUCCESS:${NC} $1"; }
log_warning() { echo -e "${YELLOW}WARNING:${NC} $1"; }
log_error() { echo -e "${RED}ERROR:${NC} $1"; exit 1; }

# --- Helper Functions ---
command_exists() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log_error "$1 is not installed or not in PATH."
  fi
}

get_actual_domain_from_ingress() {
    local domain
    domain=$(kubectl get ingress "$INGRESS_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.rules[0].host}' 2>/dev/null)
    if [[ -z "$domain" ]]; then
        log_warning "Could not automatically determine domain from Ingress '$INGRESS_NAME'. Using placeholder '$DOMAIN_PLACEHOLDER'."
        echo "$DOMAIN_PLACEHOLDER"
    else
        echo "$domain"
    fi
}

# --- Main Logic ---
if [[ $# -ne 1 || ( "$1" != "enable" && "$1" != "disable" ) ]]; then
  echo -e "${BLUE}Usage:${NC} $0 [enable|disable]"
  echo -e "  ${GREEN}enable:${NC}  Enables HTTPS by applying ManagedCertificate and annotating Ingress."
  echo -e "  ${GREEN}disable:${NC} Disables HTTPS by removing ManagedCertificate and Ingress annotations."
  exit 1
fi

ACTION="$1"

command_exists "kubectl"

if [[ "$ACTION" == "enable" ]]; then
  log_info "Enabling HTTPS for Keycloak..."

  ACTUAL_DOMAIN=$(get_actual_domain_from_ingress)
  if [[ "$ACTUAL_DOMAIN" == "$DOMAIN_PLACEHOLDER" && "$ACTUAL_DOMAIN" != "keycloak.example.com" ]]; then # Be more specific if placeholder is generic
      log_warning "Consider updating '$MANAGED_CERT_YAML_PATH' with the correct domain if it's not '$ACTUAL_DOMAIN'."
  fi

  # Create a temporary certificate manifest
  TMP_CERT_MANIFEST=$(mktemp)
  # Replace placeholder domain and ensure correct name/namespace
  sed -e "s/name: .*/name: $CERT_NAME/" \
      -e "s/namespace: .*/namespace: $NAMESPACE/" \
      -e "s/- $DOMAIN_PLACEHOLDER/- $ACTUAL_DOMAIN/" \
      "$MANAGED_CERT_YAML_PATH" > "$TMP_CERT_MANIFEST"

  log_info "Applying ManagedCertificate '$CERT_NAME' for domain '$ACTUAL_DOMAIN'..."
  if ! kubectl apply -f "$TMP_CERT_MANIFEST" -n "$NAMESPACE"; then
    rm "$TMP_CERT_MANIFEST"
    log_error "Failed to apply ManagedCertificate."
  fi
  rm "$TMP_CERT_MANIFEST"

  log_info "Annotating Ingress '$INGRESS_NAME' for HTTPS..."
  # Allow-http=false is often set by the main deploy script if protocol=https
  # This script ensures it's set if enabling HTTPS explicitly.
  if ! kubectl annotate ingress "$INGRESS_NAME" -n "$NAMESPACE" \
        "kubernetes.io/ingress.allow-http"="false" \
        "networking.gke.io/managed-certificates"="$CERT_NAME" --overwrite; then
    log_error "Failed to annotate Ingress."
  fi

  log_success "HTTPS enabled for Keycloak!"
  log_warning "It may take some time for the Google-managed certificate to be provisioned and become active."

elif [[ "$ACTION" == "disable" ]]; then
  log_info "Disabling HTTPS for Keycloak..."

  log_info "Removing HTTPS annotations from Ingress '$INGRESS_NAME'..."
  # The '-' removes an annotation.
  # Check if annotations exist before trying to remove to avoid errors if already removed.
  if kubectl get ingress "$INGRESS_NAME" -n "$NAMESPACE" -o jsonpath="{.metadata.annotations.kubernetes\.io/ingress\.allow-http}" &>/dev/null; then
      kubectl annotate ingress "$INGRESS_NAME" -n "$NAMESPACE" "kubernetes.io/ingress.allow-http"-
  else
      log_info "Annotation 'kubernetes.io/ingress.allow-http' not found on Ingress."
  fi

  if kubectl get ingress "$INGRESS_NAME" -n "$NAMESPACE" -o jsonpath="{.metadata.annotations.networking\.gke\.io/managed-certificates}" &>/dev/null; then
      kubectl annotate ingress "$INGRESS_NAME" -n "$NAMESPACE" "networking.gke.io/managed-certificates"-
  else
      log_info "Annotation 'networking.gke.io/managed-certificates' not found on Ingress."
  fi
  log_success "Ingress annotations for HTTPS removed."


  log_info "Deleting ManagedCertificate '$CERT_NAME'..."
  # Use --ignore-not-found=true to prevent errors if it's already deleted.
  if ! kubectl delete managedcertificate "$CERT_NAME" -n "$NAMESPACE" --ignore-not-found=true; then
    log_error "Failed to delete ManagedCertificate (or it was already gone)."
  fi

  log_success "HTTPS disabled for Keycloak!"
  log_info "You might need to update Ingress to allow HTTP if it was strictly HTTPS before, e.g., by setting 'kubernetes.io/ingress.allow-http=true' or removing the annotation entirely if default is allow."
fi
