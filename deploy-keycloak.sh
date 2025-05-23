#!/bin/bash

set -euo pipefail

# --- Configuration & Defaults ---
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[0;33m"; BLUE="\033[0;34m"; NC="\033[0m"

DEFAULT_NAMESPACE="keycloak"
DEFAULT_RELEASE_NAME="keycloak"
DEFAULT_VALUES_DIR="./helm"
DEFAULT_CHART_REPO="codecentric/keycloak"
DEFAULT_CHART_VERSION="" # Latest
DEFAULT_PROTOCOL="http"
DEFAULT_DOMAIN="keycloak.example.com"
DEFAULT_DEPLOYMENT_TYPE="ingress"
DEFAULT_KSA_NAME="keycloak" # Default KSA name to be created/used by Helm

# Script parameters
NAMESPACE="" RELEASE_NAME="" VALUES_DIR="" CHART_REPO="" CHART_VERSION=""
PROTOCOL="" DOMAIN="" STATIC_IP_NAME="" PROJECT_ID="" REGION="" SQL_INSTANCE=""
DEPLOYMENT_TYPE="" KSA_NAME="" GSA_EMAIL="" # Added GSA_EMAIL

# --- Helper Functions ---
log_info() { echo -e "${BLUE}INFO:${NC} $1"; }
log_success() { echo -e "${GREEN}SUCCESS:${NC} $1"; }
log_warning() { echo -e "${YELLOW}WARNING:${NC} $1"; }
log_error() { echo -e "${RED}ERROR:${NC} $1" >&2; }

usage() {
  echo -e "${BLUE}Usage:${NC} $0 [options]"
  echo -e "\n${BLUE}Description:${NC} Deploys Keycloak to GKE with Cloud SQL integration using Workload Identity."
  echo -e "\n${BLUE}Options:${NC}"
  echo -e "  ${GREEN}-n, --namespace${NC} NAMESPACE    Kubernetes namespace (default: ${DEFAULT_NAMESPACE})"
  echo -e "  ${GREEN}-r, --release${NC} RELEASE_NAME  Helm release name (default: ${DEFAULT_RELEASE_NAME})"
  echo -e "  ${GREEN}-c, --chart-dir${NC} DIR        Path to Helm values directory (default: ${DEFAULT_VALUES_DIR})"
  echo -e "  ${GREEN}    --chart-repo${NC} REPO       Helm chart repository (default: ${DEFAULT_CHART_REPO})"
  echo -e "  ${GREEN}-v, --version${NC} VERSION       Helm chart version (default: latest)"
  echo -e "  ${GREEN}-p, --protocol${NC} PROTOCOL     http or https (default: ${DEFAULT_PROTOCOL})"
  echo -e "  ${GREEN}-d, --domain${NC} DOMAIN         Domain for Keycloak (default: ${DEFAULT_DOMAIN})"
  echo -e "  ${GREEN}-i, --ip-name${NC} IP_NAME       Static IP name in GCP (for ingress type)"
  echo -e "  ${GREEN}    --project-id${NC} PROJECT_ID  GCP project ID (required)"
  echo -e "  ${GREEN}    --region${NC} REGION          GCP region for Cloud SQL (required)"
  echo -e "  ${GREEN}    --sql-instance${NC} INSTANCE  Cloud SQL instance name (required)"
  echo -e "  ${GREEN}    --deployment-type${NC} TYPE   ingress or loadbalancer (default: ${DEFAULT_DEPLOYMENT_TYPE})"
  echo -e "  ${GREEN}    --ksa-name${NC} KSA_NAME     Kubernetes Service Account name (default: ${DEFAULT_KSA_NAME})"
  echo -e "  ${GREEN}    --gsa-email${NC} GSA_EMAIL    GCP Service Account email for Workload Identity (required)"
  echo -e "  ${GREEN}-h, --help${NC}                 Display this help message"
  echo -e "\n${BLUE}Example (Workload Identity):${NC}"
  echo -e "  $0 --protocol https --domain keycloak.mydomain.com --ip-name my-static-ip \\"
  echo -e "     --project-id my-gcp-proj --region asia-southeast1 --sql-instance my-keycloak-db \\"
  echo -e "     --gsa-email keycloak-proxy-gsa@my-gcp-proj.iam.gserviceaccount.com"
  exit 1
}

command_exists() {
  if ! command -v "$1" >/dev/null 2>&1; then log_error "$1 not found."; exit 1; fi
}

parse_args() {
  NAMESPACE="$DEFAULT_NAMESPACE"; RELEASE_NAME="$DEFAULT_RELEASE_NAME"; VALUES_DIR="$DEFAULT_VALUES_DIR"
  CHART_REPO="$DEFAULT_CHART_REPO"; CHART_VERSION="$DEFAULT_CHART_VERSION"; PROTOCOL="$DEFAULT_PROTOCOL"
  DOMAIN="$DEFAULT_DOMAIN"; DEPLOYMENT_TYPE="$DEFAULT_DEPLOYMENT_TYPE"; KSA_NAME="$DEFAULT_KSA_NAME"
  STATIC_IP_NAME=""; PROJECT_ID=""; REGION=""; SQL_INSTANCE=""; GSA_EMAIL=""

  while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
      -n|--namespace) NAMESPACE="$2"; shift 2 ;; -r|--release) RELEASE_NAME="$2"; shift 2 ;;
      -c|--chart-dir) VALUES_DIR="$2"; shift 2 ;; --chart-repo) CHART_REPO="$2"; shift 2 ;;
      -v|--version) CHART_VERSION="$2"; shift 2 ;; -p|--protocol) PROTOCOL="$2"; shift 2 ;;
      -d|--domain) DOMAIN="$2"; shift 2 ;; -i|--ip-name) STATIC_IP_NAME="$2"; shift 2 ;;
      --project-id) PROJECT_ID="$2"; shift 2 ;; --region) REGION="$2"; shift 2 ;;
      --sql-instance) SQL_INSTANCE="$2"; shift 2 ;; --deployment-type) DEPLOYMENT_TYPE="$2"; shift 2 ;;
      --ksa-name) KSA_NAME="$2"; shift 2 ;; --gsa-email) GSA_EMAIL="$2"; shift 2 ;;
      -h|--help) usage ;; *) log_error "Unknown option: $1"; usage ;;
    esac
  done
}

validate_inputs_and_prerequisites() {
  log_info "Validating inputs and prerequisites..."
  command_exists "kubectl"; command_exists "helm"
  if ! kubectl cluster-info &>/dev/null; then log_error "Not connected to K8s cluster."; exit 1; fi

  if [[ -z "$PROJECT_ID" || -z "$REGION" || -z "$SQL_INSTANCE" || -z "$GSA_EMAIL" ]]; then
    log_error "Missing required params: --project-id, --region, --sql-instance, --gsa-email are required."
    usage
  fi
  if [[ "$PROTOCOL" != "http" && "$PROTOCOL" != "https" ]]; then log_error "Protocol must be http or https."; usage; fi
  if [[ "$DEPLOYMENT_TYPE" != "ingress" && "$DEPLOYMENT_TYPE" != "loadbalancer" ]]; then log_error "Deployment type must be ingress or loadbalancer."; usage; fi
  if [[ "$DEPLOYMENT_TYPE" == "ingress" && "$PROTOCOL" == "https" && -z "$STATIC_IP_NAME" ]]; then log_error "Static IP name required for ingress with HTTPS."; usage; fi
  if [[ ! -f "$VALUES_DIR/values.yaml" ]]; then log_error "Helm values file '$VALUES_DIR/values.yaml' not found."; exit 1; fi
  log_success "Inputs and prerequisites validated."
}

setup_kubernetes_resources() {
  log_info "Step 1: Setting up Kubernetes resources..."
  if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
    kubectl create namespace "$NAMESPACE"; log_success "Namespace '$NAMESPACE' created."
  else log_info "Namespace '$NAMESPACE' already exists."; fi

  # Create/ensure Kubernetes Service Account (KSA) exists before annotating
  # Helm will create this if serviceAccount.create=true in values.yaml and serviceAccount.name is set (e.g. to $KSA_NAME)
  # If you are sure Helm creates it, this `kubectl create sa` might be redundant or can be made conditional.
  # For simplicity, let's ensure it exists or try to create it.
  if ! kubectl get serviceaccount "$KSA_NAME" -n "$NAMESPACE" &>/dev/null; then
    log_info "Kubernetes Service Account '$KSA_NAME' not found in namespace '$NAMESPACE'. Attempting to create..."
    if kubectl create serviceaccount "$KSA_NAME" -n "$NAMESPACE"; then
        log_success "KSA '$KSA_NAME' created."
    else
        log_warning "Failed to create KSA '$KSA_NAME'. This might be an issue if Helm doesn't create it either."
    fi
  else
    log_info "KSA '$KSA_NAME' already exists in namespace '$NAMESPACE'."
  fi

  # Annotate the KSA for Workload Identity
  log_info "Annotating KSA '$KSA_NAME' in namespace '$NAMESPACE' with GSA '$GSA_EMAIL' for Workload Identity..."
  if kubectl annotate serviceaccount "$KSA_NAME" -n "$NAMESPACE" \
        "iam.gke.io/gcp-service-account=${GSA_EMAIL}" --overwrite; then # Use --overwrite to ensure it's set
    log_success "KSA '$KSA_NAME' annotated successfully for Workload Identity."
  else
    # This could fail if the KSA truly doesn't exist and the create above also failed.
    log_error "Failed to annotate KSA '$KSA_NAME'. Please ensure it exists and you have permissions."
    exit 1 # Critical for Workload Identity
  fi


  local db_creds_file="k8s/v1/Secret/keycloak-db-credentials.yaml"
  if [[ -f "$db_creds_file" ]]; then
    kubectl apply -f "$db_creds_file" -n "$NAMESPACE"; log_success "DB credentials secret applied."
  else log_error "DB credentials secret file '$db_creds_file' not found."; exit 1; fi

  local inject_script_path="./inject-app-realm.sh"
  if [[ -f "$inject_script_path" ]]; then
    if bash "$inject_script_path"; then log_success "Realm injection script executed."
    else log_error "Realm injection script failed."; exit 1; fi
  else log_warning "Realm injection script '$inject_script_path' not found. Skipping."; fi

  local custom_realm_config_file="k8s/v1/ConfigMap/custom-realm-config.yaml"
  if [[ -f "$custom_realm_config_file" ]]; then
    kubectl apply -f "$custom_realm_config_file" -n "$NAMESPACE"; log_success "Custom realm ConfigMap applied."
  else log_warning "Custom realm ConfigMap '$custom_realm_config_file' not found."; fi

  log_success "Kubernetes resources setup completed."
}

update_helm_values_file_for_deploy() {
  log_info "Step 2: Preparing Helm values for deployment..."
  local original_values_file="$VALUES_DIR/values.yaml"
  TMP_VALUES_FILE=$(mktemp)
  cp "$original_values_file" "$TMP_VALUES_FILE"
  VALUES_FILE_TO_USE="$TMP_VALUES_FILE"

  # Using sed as a fallback (yq is preferred):
  # These updates ensure the values file reflects the script parameters.
  # The primary Workload Identity annotation is now handled by `kubectl annotate` above for reliability.
  # However, if values.yaml has a placeholder for gsaEmail or KSA name for other purposes, update it.
  sed -i.bak "s/^\([[:space:]]*project:[[:space:]]*\)\".*\"/\1\"$PROJECT_ID\"/" "$VALUES_FILE_TO_USE"
  sed -i.bak "s/^\([[:space:]]*region:[[:space:]]*\)\".*\"/\1\"$REGION\"/" "$VALUES_FILE_TO_USE"
  sed -i.bak "s/^\([[:space:]]*instance:[[:space:]]*\)\".*\"/\1\"$SQL_INSTANCE\"/" "$VALUES_FILE_TO_USE"
  
  # If your values.yaml *also* uses cloudsql.gsaEmail or serviceAccount.name for other templating,
  # ensure they are updated. The KSA annotation itself is now handled by kubectl annotate.
  # Example: if values.yaml has `cloudsql.gsaEmail` field:
  sed -i.bak "s|^\([[:space:]]*gsaEmail:[[:space:]]*\)\".*\"|\1\"$GSA_EMAIL\"|" "$VALUES_FILE_TO_USE"
  # Example: if values.yaml sets `serviceAccount.name`:
  # Note: KSA_NAME from script param should match serviceAccount.name in values.yaml if helm creates it.
  # The serviceAccount.name in values.yaml (e.g., "keycloak") tells Helm what to name the SA it creates.
  # The kubectl annotate step above uses this $KSA_NAME.
  sed -i.bak "/serviceAccount:/,/^[^[:space:]]/ s/^\([[:space:]]*name:[[:space:]]*\)\".*\"/\1\"$KSA_NAME\"/" "$VALUES_FILE_TO_USE"


  if [[ "$DEPLOYMENT_TYPE" == "ingress" ]]; then
    log_info "Updating ingress parameters (domain, static IP)..."
    sed -i.bak "s/^\([[:space:]]*host:[[:space:]]*\)\"keycloak\.example\.com\"/\1\"$DOMAIN\"/" "$VALUES_FILE_TO_USE"
    if [[ "$PROTOCOL" == "https" && -n "$STATIC_IP_NAME" ]]; then
      sed -i.bak "s|^\([[:space:]]*kubernetes\.io/ingress\.global-static-ip-name:[[:space:]]*\).*|\1\"$STATIC_IP_NAME\"|" "$VALUES_FILE_TO_USE"
    fi
  fi
  rm -f "${VALUES_FILE_TO_USE}.bak"
  log_success "Temporary Helm values file '$VALUES_FILE_TO_USE' prepared."
}

deploy_with_helm() {
  log_info "Step 3: Deploying Keycloak with Helm..."
  local version_flag=""
  if [[ -n "$CHART_VERSION" ]]; then version_flag="--version $CHART_VERSION"; log_info "Using chart version: $CHART_VERSION";
  else log_info "Using latest chart version from repository."; fi

  local helm_set_values=()
  helm_set_values+=("--set" "cloudsql.project=$PROJECT_ID")
  helm_set_values+=("--set" "cloudsql.region=$REGION")
  helm_set_values+=("--set" "cloudsql.instance=$SQL_INSTANCE")
  # Pass KSA name to Helm if the chart uses it to name the service account it creates.
  helm_set_values+=("--set" "serviceAccount.name=$KSA_NAME")
  # No longer need to pass gsaEmail via --set if KSA is annotated directly,
  # unless values.yaml *still* templates it for other reasons.
  # helm_set_values+=("--set" "cloudsql.gsaEmail=$GSA_EMAIL")


  if [[ "$DEPLOYMENT_TYPE" == "ingress" ]]; then
    helm_set_values+=("--set" "ingress.enabled=true"); helm_set_values+=("--set" "service.type=ClusterIP")
    helm_set_values+=("--set" "ingress.rules[0].host=$DOMAIN")
    if [[ "$PROTOCOL" == "https" ]]; then
      helm_set_values+=("--set" "https.enabled=true")
      helm_set_values+=("--set" "ingress.annotations.networking\.gke\.io/managed-certificates=${RELEASE_NAME}-certificate")
      if [[ -n "$STATIC_IP_NAME" ]]; then
        helm_set_values+=("--set" "ingress.annotations.kubernetes\.io/ingress\.global-static-ip-name=$STATIC_IP_NAME")
      fi
    else
      helm_set_values+=("--set" "https.enabled=false")
      helm_set_values+=("--set" "ingress.annotations.networking\.gke\.io/managed-certificates=")
    fi
  elif [[ "$DEPLOYMENT_TYPE" == "loadbalancer" ]]; then
    helm_set_values+=("--set" "ingress.enabled=false"); helm_set_values+=("--set" "service.type=LoadBalancer")
    helm_set_values+=("--set" "https.enabled=false")
  fi

  log_info "Running Helm command..."
  # Ensure the KSA is annotated BEFORE helm tries to create pods that use it.
  # The annotation step was moved to setup_kubernetes_resources.
  if helm upgrade --install "$RELEASE_NAME" "$CHART_REPO" \
    --namespace "$NAMESPACE" --create-namespace \
    --values "$VALUES_FILE_TO_USE" \
    $version_flag "${helm_set_values[@]}"; then
    log_success "Keycloak Helm chart deployment initiated."
  else log_error "Helm deployment failed."; exit 1; fi
}

# ... (configure_https_post_deploy and display_deployment_summary functions remain the same) ...
configure_https_post_deploy() {
  if [[ "$DEPLOYMENT_TYPE" == "ingress" && "$PROTOCOL" == "https" ]]; then
    log_info "Step 4: Configuring HTTPS (ManagedCertificate)..."
    local cert_name="${RELEASE_NAME}-certificate"
    local managed_cert_template="k8s/networking.gke.io/ManagedCertificate/keycloak-certificate.yaml"
    if [[ ! -f "$managed_cert_template" ]]; then
      log_warning "ManagedCertificate template '$managed_cert_template' not found. Skipping cert creation."
      return
    fi
    local tmp_cert_manifest; tmp_cert_manifest=$(mktemp)
    sed -e "s/name: keycloak-certificate/name: $cert_name/" \
        -e "s/- keycloak\.example\.com/- $DOMAIN/" \
        -e "s/namespace: keycloak/namespace: $NAMESPACE/" \
        "$managed_cert_template" > "$tmp_cert_manifest"
    if kubectl apply -f "$tmp_cert_manifest" -n "$NAMESPACE"; then
      log_success "ManagedCertificate '$cert_name' applied."
    else log_error "Failed to apply ManagedCertificate '$cert_name'."; fi
    rm "$tmp_cert_manifest"
  fi
}

display_deployment_summary() {
  log_info "Step 5: Waiting for Keycloak deployment rollout..."
  local resource_type="statefulset"; local resource_name="$RELEASE_NAME"
  if ! kubectl get $resource_type "$resource_name" -n "$NAMESPACE" > /dev/null 2>&1; then
      resource_type="deployment"
      if ! kubectl get $resource_type "$resource_name" -n "$NAMESPACE" > /dev/null 2>&1; then
          log_warning "Could not find statefulset or deployment '$resource_name' to check rollout status."
          resource_type=""
      fi
  fi
  if [[ -n "$resource_type" ]]; then
      if kubectl rollout status "$resource_type/$resource_name" -n "$NAMESPACE" --timeout=600s; then
        log_success "Keycloak deployment rollout complete."
      else log_warning "Keycloak deployment rollout status check failed or timed out."; fi
  fi

  echo -e "\n${BLUE}--- Keycloak Deployment Summary ---${NC}"
  echo -e "${GREEN}Namespace:${NC} $NAMESPACE"; echo -e "${GREEN}Release Name:${NC} $RELEASE_NAME"
  echo -e "${GREEN}Chart Version:${NC} ${CHART_VERSION:-latest}"
  echo -e "${GREEN}KSA Name:${NC} $KSA_NAME"; echo -e "${GREEN}GSA Email for WI:${NC} $GSA_EMAIL"
  # ... (rest of summary) ...
  if [[ "$DEPLOYMENT_TYPE" == "ingress" ]]; then
    # ... (ingress IP fetching) ...
    local EXTERNAL_IP; EXTERNAL_IP=$(kubectl get ingress "$RELEASE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [[ -n "$EXTERNAL_IP" ]]; then echo -e "\n${BLUE}Access Keycloak at:${NC} $PROTOCOL://$DOMAIN (IP: $EXTERNAL_IP)"; else echo -e "\n${YELLOW}Ingress IP not yet available.${NC}"; fi
  elif [[ "$DEPLOYMENT_TYPE" == "loadbalancer" ]]; then
    # ... (loadbalancer IP fetching) ...
    local EXTERNAL_IP; EXTERNAL_IP=$(kubectl get service "$RELEASE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    local SVC_PORT=$(kubectl get service "$RELEASE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "80")
    if [[ -n "$EXTERNAL_IP" ]]; then echo -e "\n${BLUE}Access Keycloak at:${NC} http://$EXTERNAL_IP:$SVC_PORT"; else echo -e "\n${YELLOW}LoadBalancer IP not yet available.${NC}"; fi
  fi
  echo -e "\n${GREEN}--- Deployment script finished ---${NC}"
}
# --- Main Execution ---
main() {
  trap '[[ -n "${TMP_VALUES_FILE:-}" && -f "${TMP_VALUES_FILE:-}" ]] && rm -f "$TMP_VALUES_FILE"; log_info "Cleaned up temporary files."; exit' INT TERM EXIT HUP
  parse_args "$@"
  validate_inputs_and_prerequisites
  setup_kubernetes_resources # KSA annotation now happens here
  update_helm_values_file_for_deploy
  deploy_with_helm
  configure_https_post_deploy
  display_deployment_summary
  trap - INT TERM EXIT HUP # Clear trap on successful exit
  log_info "Script completed successfully."
}

main "$@"
